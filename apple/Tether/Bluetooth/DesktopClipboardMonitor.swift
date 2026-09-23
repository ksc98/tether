//
//  DesktopClipboardMonitor.swift
//  Tether
//
//  Serves the clipboard characteristic tetherd writes desktop clipboard changes
//  into, over Bluetooth LE.
//
//  The Wi-Fi connection only exists while the app is in the foreground. The
//  iPhone already holds an LE link to the desktop for notification mirroring,
//  with the phone as the central; iOS does not share that link with an app's
//  CBCentralManager, but the phone's GATT server is reachable on it. So the app
//  publishes the characteristic (CBPeripheralManager, bluetooth-peripheral
//  background mode) and iOS wakes the app for each write, relaunching it if it
//  was terminated. The value is {"seq":N,"len":L,"text":T}; when the desktop
//  text is longer than the attribute the rest comes over Wi-Fi.
//

import CoreBluetooth
import Foundation
import OSLog
import TetherFramework
import UIKit

private let log = Logger(subsystem: "net.jeedup.Tether", category: "desktop-clipboard")

// One desktop clipboard change, as far as it could be recovered.
struct DesktopClipboardUpdate: Sendable {
    let seq: UInt64
    let text: String
    // False when only the Bluetooth excerpt was available.
    let complete: Bool
}

@MainActor
final class DesktopClipboardMonitor: NSObject {
    static let serviceUUID = CBUUID(string: "467DF1F1-C20A-448E-BA52-4C46BF02C66B")
    static let characteristicUUID = CBUUID(string: "A643D06F-B1D0-40C0-8D71-A752B08E0ABC")

    private static let restoreIdentifier = "net.jeedup.Tether.desktop-clipboard"
    private static let enabledKey = "TetherBluetoothClipboardEnabled"
    private static let lastSeqKey = "TetherBluetoothClipboardLastSeq"

    enum Status: Equatable {
        case off
        case bluetoothOff
        case unauthorized
        case publishing
        // The characteristic is in the phone's GATT table; the desktop can write to it.
        case published
    }

    private(set) var status: Status = .off {
        didSet {
            if status != oldValue {
                note("status \(String(describing: oldValue)) -> \(String(describing: self.status))")
                onStatusChange?(status)
            }
        }
    }

    var onStatusChange: ((Status) -> Void)?
    var onUpdate: ((DesktopClipboardUpdate) -> Void)?
    var onTrace: (([String]) -> Void)?

    // The last few steps, newest last, for the Settings screen. The phone's
    // syslog relay does not show an app's os_log lines, so this is what a user
    // can actually read when the characteristic does not come up.
    private(set) var trace: [String] = []
    private static let traceLimit = 40
    private static let traceClock: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    private func note(_ line: String) {
        log.notice("\(line)")
        trace.append("\(Self.traceClock.string(from: Date())) \(line)")
        if trace.count > Self.traceLimit {
            trace.removeFirst(trace.count - Self.traceLimit)
        }
        onTrace?(trace)
    }

    private var manager: CBPeripheralManager?
    private var service: CBMutableService?
    private var serviceAdded = false
    private var pendingFetch: Task<Void, Never>?

    var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: Self.enabledKey)
    }

    // Called at every launch, including a background relaunch by CoreBluetooth:
    // the manager has to exist again before iOS hands back the restored state.
    func launch() {
        guard isEnabled else { return }
        makeManager()
    }

    func setEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: Self.enabledKey)
        if enabled {
            makeManager()
        } else {
            tearDown()
        }
    }

    // MARK: - Setup

    private func makeManager() {
        guard manager == nil else {
            publish()
            return
        }
        manager = CBPeripheralManager(
            delegate: self,
            queue: nil,
            options: [
                CBPeripheralManagerOptionRestoreIdentifierKey: Self.restoreIdentifier,
                CBPeripheralManagerOptionShowPowerAlertKey: false,
            ]
        )
    }

    private func tearDown() {
        pendingFetch?.cancel()
        manager?.removeAllServices()
        manager = nil
        service = nil
        serviceAdded = false
        status = .off
    }

    private func publish() {
        guard let manager, manager.state == .poweredOn else { return }
        if serviceAdded {
            status = .published
            return
        }
        // Write only, and only over an encrypted link: the phone's bond with
        // the desktop provides that, and nobody else gets to set the clipboard.
        let characteristic = CBMutableCharacteristic(
            type: Self.characteristicUUID,
            properties: [.write],
            value: nil,
            permissions: [.writeEncryptionRequired]
        )
        let service = CBMutableService(type: Self.serviceUUID, primary: true)
        service.characteristics = [characteristic]
        self.service = service
        status = .publishing
        note("adding service")
        manager.add(service)
    }

    // MARK: - Value handling

    private func handle(value: Data) {
        struct Payload: Decodable {
            let seq: UInt64
            let len: Int
            let text: String
        }

        note("write: \(value.count) bytes")
        guard let payload = try? JSONDecoder().decode(Payload.self, from: value) else {
            note("write: not a clipboard payload")
            return
        }

        let lastSeq = UInt64(UserDefaults.standard.integer(forKey: Self.lastSeqKey))
        guard payload.seq > lastSeq || lastSeq == 0 else { return }
        UserDefaults.standard.set(Int(payload.seq), forKey: Self.lastSeqKey)

        if payload.text.utf8.count >= payload.len {
            onUpdate?(DesktopClipboardUpdate(seq: payload.seq, text: payload.text, complete: true))
            return
        }

        // The excerpt is not the whole clipboard. iOS grants a few seconds of
        // background time here, enough for one round trip to the daemon.
        pendingFetch?.cancel()
        pendingFetch = Task { [weak self] in
            let taskID = UIApplication.shared.beginBackgroundTask(withName: "desktop-clipboard-fetch")
            defer { UIApplication.shared.endBackgroundTask(taskID) }

            let update: DesktopClipboardUpdate
            switch await ShareSender.fetchClipboard() {
            case .success(let full) where full.utf8.count >= payload.len:
                update = DesktopClipboardUpdate(seq: payload.seq, text: full, complete: true)
            default:
                update = DesktopClipboardUpdate(seq: payload.seq, text: payload.text, complete: false)
            }
            guard !Task.isCancelled else { return }
            self?.onUpdate?(update)
        }
    }

    // Reassembles one write from its chunks. A long write arrives as a batch
    // of requests, each carrying its offset.
    private static func assemble(_ requests: [CBATTRequest]) -> Data {
        var value = Data()
        for request in requests.sorted(by: { $0.offset < $1.offset }) {
            guard let chunk = request.value else { continue }
            if value.count < request.offset {
                value.append(Data(count: request.offset - value.count))
            }
            let end = request.offset + chunk.count
            if end <= value.count {
                value.replaceSubrange(request.offset..<end, with: chunk)
            } else {
                value.removeSubrange(request.offset..<value.count)
                value.append(chunk)
            }
        }
        return value
    }
}

// MARK: - CBPeripheralManagerDelegate

extension DesktopClipboardMonitor: CBPeripheralManagerDelegate {
    // The manager was created with the main queue, so every callback is on the main actor.
    nonisolated func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        MainActor.assumeIsolated {
            note("manager state \(peripheral.state.rawValue)")
            switch peripheral.state {
            case .poweredOn:
                publish()
            case .unauthorized:
                status = .unauthorized
            case .poweredOff, .resetting, .unsupported, .unknown:
                serviceAdded = false
                status = .bluetoothOff
            @unknown default:
                status = .bluetoothOff
            }
        }
    }

    nonisolated func peripheralManager(_ peripheral: CBPeripheralManager, willRestoreState dict: [String: Any]) {
        MainActor.assumeIsolated {
            let restored = dict[CBPeripheralManagerRestoredStateServicesKey] as? [CBMutableService] ?? []
            note("restoring state: \(restored.count) service(s)")
            if let ours = restored.first(where: { $0.uuid == Self.serviceUUID }) {
                service = ours
                serviceAdded = true
            }
        }
    }

    nonisolated func peripheralManager(_ peripheral: CBPeripheralManager,
                                       didAdd service: CBService,
                                       error: Error?) {
        MainActor.assumeIsolated {
            if let error {
                note("add service failed: \(error.localizedDescription)")
                serviceAdded = false
                status = .bluetoothOff
                return
            }
            note("service added")
            serviceAdded = true
            status = .published
        }
    }

    nonisolated func peripheralManager(_ peripheral: CBPeripheralManager,
                                       didReceiveWrite requests: [CBATTRequest]) {
        MainActor.assumeIsolated {
            guard let first = requests.first else { return }
            let ours = requests.filter { $0.characteristic.uuid == Self.characteristicUUID }
            guard !ours.isEmpty else {
                peripheral.respond(to: first, withResult: .attributeNotFound)
                return
            }
            let value = Self.assemble(ours)
            peripheral.respond(to: first, withResult: .success)
            handle(value: value)
        }
    }
}
