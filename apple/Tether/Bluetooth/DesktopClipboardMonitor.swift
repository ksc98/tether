//
//  DesktopClipboardMonitor.swift
//  Tether
//
//  Subscribes to the clipboard characteristic tetherd serves over Bluetooth LE.
//
//  The Wi-Fi connection only exists while the app is in the foreground; a GATT
//  subscription with the bluetooth-central background mode keeps delivering
//  after the app is backgrounded, and iOS relaunches the app for a notification
//  if it was terminated. The characteristic value is {"seq":N,"len":L,"text":T};
//  when the desktop text is longer than the ATT value the rest comes over Wi-Fi.
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
    private static let peripheralKey = "TetherBluetoothClipboardPeripheral"
    private static let lastSeqKey = "TetherBluetoothClipboardLastSeq"
    private static let scanSeconds: Double = 30

    enum Status: Equatable {
        case off
        case bluetoothOff
        case unauthorized
        // No desktop known yet; a scan is needed.
        case unknownDesktop
        case scanning
        case connecting
        case subscribed
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
    // can actually read when the subscription does not come up.
    private(set) var trace: [String] = []
    private static let traceLimit = 40
    private static let traceClock: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    private func note(_ line: String) {
        note("\(line, privacy: .public)")
        trace.append("\(Self.traceClock.string(from: Date())) \(line)")
        if trace.count > Self.traceLimit {
            trace.removeFirst(trace.count - Self.traceLimit)
        }
        onTrace?(trace)
    }

    private var central: CBCentralManager?
    private var peripheral: CBPeripheral?
    private var characteristic: CBCharacteristic?
    private var scanTimeout: Task<Void, Never>?
    private var pendingFetch: Task<Void, Never>?

    var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: Self.enabledKey)
    }

    // Called at every launch, including a background relaunch by CoreBluetooth:
    // the central has to exist again before iOS hands back the restored state.
    func launch() {
        guard isEnabled else { return }
        makeCentral()
    }

    func setEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: Self.enabledKey)
        if enabled {
            makeCentral()
        } else {
            tearDown()
        }
    }

    // Looks for the desktop in a scan. The daemon has to be advertising the
    // service for this to find anything; the caller asks it to over Wi-Fi first.
    func findDesktop() {
        guard let central, central.state == .poweredOn else { return }
        if let peripheral {
            central.cancelPeripheralConnection(peripheral)
            self.peripheral = nil
            characteristic = nil
        }
        note("scanning for the clipboard service")
        central.scanForPeripherals(withServices: [Self.serviceUUID], options: nil)
        status = .scanning
        scanTimeout?.cancel()
        scanTimeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.scanSeconds))
            guard let self, !Task.isCancelled, status == .scanning else { return }
            central.stopScan()
            status = .unknownDesktop
        }
    }

    // MARK: - Setup

    private func makeCentral() {
        guard central == nil else {
            attach()
            return
        }
        central = CBCentralManager(
            delegate: self,
            queue: nil,
            options: [
                CBCentralManagerOptionRestoreIdentifierKey: Self.restoreIdentifier,
                CBCentralManagerOptionShowPowerAlertKey: false,
            ]
        )
    }

    private func tearDown() {
        scanTimeout?.cancel()
        pendingFetch?.cancel()
        if let central, let peripheral {
            central.cancelPeripheralConnection(peripheral)
        }
        central?.stopScan()
        central = nil
        peripheral = nil
        characteristic = nil
        status = .off
    }

    // Finds the desktop without a scan when it can: a peripheral restored by
    // iOS, the one remembered from last time, or one the system already holds a
    // connection to (it does, for notification mirroring) that carries the service.
    private func attach() {
        guard let central, central.state == .poweredOn else { return }

        if let peripheral {
            note("attach: reusing peripheral \(peripheral.identifier) state \(peripheral.state.rawValue)")
            connect(peripheral)
            return
        }

        if let stored = UserDefaults.standard.string(forKey: Self.peripheralKey),
           let id = UUID(uuidString: stored),
           let known = central.retrievePeripherals(withIdentifiers: [id]).first {
            note("attach: remembered peripheral \(id) state \(known.state.rawValue)")
            connect(known)
            return
        }

        let connected = central.retrieveConnectedPeripherals(withServices: [Self.serviceUUID])
        note("attach: \(connected.count) system-connected peripheral(s) carry the service")
        if let first = connected.first {
            connect(first)
            return
        }

        status = .unknownDesktop
    }

    private func connect(_ peripheral: CBPeripheral) {
        guard let central else { return }
        self.peripheral = peripheral
        peripheral.delegate = self
        UserDefaults.standard.set(peripheral.identifier.uuidString, forKey: Self.peripheralKey)

        note("connect: \(peripheral.identifier) name \(peripheral.name ?? "-") state \(peripheral.state.rawValue)")
        switch peripheral.state {
        case .connected:
            status = .connecting
            peripheral.discoverServices([Self.serviceUUID])
        default:
            status = .connecting
            // A pending connect never times out; it completes whenever the desktop is in range.
            central.connect(peripheral, options: nil)
        }
    }

    // MARK: - Value handling

    private func handle(value: Data) {
        struct Payload: Decodable {
            let seq: UInt64
            let len: Int
            let text: String
        }

        note("value: \(value.count) bytes")
        guard let payload = try? JSONDecoder().decode(Payload.self, from: value) else {
            // A notification is cut to the link MTU; the whole value comes from a read.
            if let peripheral, let characteristic {
                peripheral.readValue(for: characteristic)
            }
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
}

// MARK: - CBCentralManagerDelegate

extension DesktopClipboardMonitor: CBCentralManagerDelegate {
    // The central was created with the main queue, so every callback is on the main actor.
    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        MainActor.assumeIsolated {
            note("central state \(central.state.rawValue)")
            switch central.state {
            case .poweredOn:
                attach()
            case .unauthorized:
                status = .unauthorized
            case .poweredOff, .resetting, .unsupported, .unknown:
                status = .bluetoothOff
            @unknown default:
                status = .bluetoothOff
            }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        MainActor.assumeIsolated {
            note("restoring state: \(dict.keys.joined(separator: ","))")
            if let restored = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral],
               let first = restored.first {
                peripheral = first
                first.delegate = self
                characteristic = first.services?
                    .first { $0.uuid == Self.serviceUUID }?
                    .characteristics?
                    .first { $0.uuid == Self.characteristicUUID }
            }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager,
                                    didDiscover peripheral: CBPeripheral,
                                    advertisementData: [String: Any],
                                    rssi RSSI: NSNumber) {
        MainActor.assumeIsolated {
            note("discovered \(peripheral.identifier) name \(peripheral.name ?? "-") rssi \(RSSI)")
            central.stopScan()
            scanTimeout?.cancel()
            connect(peripheral)
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        MainActor.assumeIsolated {
            note("connected \(peripheral.identifier)")
            peripheral.discoverServices([Self.serviceUUID])
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager,
                                    didFailToConnect peripheral: CBPeripheral,
                                    error: Error?) {
        MainActor.assumeIsolated {
            note("connect failed: \(error?.localizedDescription ?? "-")")
            status = .connecting
            central.connect(peripheral, options: nil)
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager,
                                    didDisconnectPeripheral peripheral: CBPeripheral,
                                    error: Error?) {
        MainActor.assumeIsolated {
            note("disconnected: \(error?.localizedDescription ?? "-")")
            characteristic = nil
            guard isEnabled else { return }
            status = .connecting
            central.connect(peripheral, options: nil)
        }
    }
}

// MARK: - CBPeripheralDelegate

extension DesktopClipboardMonitor: CBPeripheralDelegate {
    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        MainActor.assumeIsolated {
            let uuids = (peripheral.services ?? []).map(\.uuid.uuidString).joined(separator: ",")
            note("services: [\(uuids)] error \(error?.localizedDescription ?? "-")")
            guard let service = peripheral.services?.first(where: { $0.uuid == Self.serviceUUID }) else {
                // Connected, but this peripheral does not serve the clipboard: wrong device, or an
                // older tetherd. iOS may also be holding a stale GATT cache for it.
                UserDefaults.standard.removeObject(forKey: Self.peripheralKey)
                status = .unknownDesktop
                return
            }
            peripheral.discoverCharacteristics([Self.characteristicUUID], for: service)
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral,
                                didDiscoverCharacteristicsFor service: CBService,
                                error: Error?) {
        MainActor.assumeIsolated {
            note("characteristics: \((service.characteristics ?? []).count) error \(error?.localizedDescription ?? "-")")
            guard let found = service.characteristics?.first(where: { $0.uuid == Self.characteristicUUID }) else {
                status = .unknownDesktop
                return
            }
            characteristic = found
            peripheral.setNotifyValue(true, for: found)
            peripheral.readValue(for: found)
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral,
                                didUpdateNotificationStateFor characteristic: CBCharacteristic,
                                error: Error?) {
        MainActor.assumeIsolated {
            note("notify state \(characteristic.isNotifying) error \(error?.localizedDescription ?? "-")")
            if characteristic.isNotifying {
                status = .subscribed
            } else if error != nil {
                // encrypt-notify refused: the LE bond is missing. Keep the connection; a
                // read still works once the link is encrypted.
                status = .connecting
            }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral,
                                didUpdateValueFor characteristic: CBCharacteristic,
                                error: Error?) {
        MainActor.assumeIsolated {
            if let error { note("value error: \(error.localizedDescription)") }
            guard error == nil, let value = characteristic.value, !value.isEmpty else { return }
            handle(value: value)
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didModifyServices invalidatedServices: [CBService]) {
        MainActor.assumeIsolated {
            // tetherd restarted or was upgraded; its handles moved.
            characteristic = nil
            peripheral.discoverServices([Self.serviceUUID])
        }
    }
}
