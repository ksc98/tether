//
//  TetherViewModel.swift
//  Tether
//
//  Central observable driving the entire app: discovery, pairing,
//  clipboard sync, and file transfer.
//

import Foundation
import SwiftUI
import UniformTypeIdentifiers
import UIKit
import TetherFramework
internal import Network

// High-level app state.
enum AppConnectionState: Equatable {
    case disconnected
    case discovering
    case connecting
    case pairing
    case connected
}

// The top-level tab currently shown.
enum AppTab: Hashable {
    case dashboard
    case clipboard
    case files
    case settings
}

// Tracks an active file transfer.
struct FileTransfer: Identifiable {
    enum Direction {
        case outgoing
        case incoming
    }

    let id: String // transfer_id
    var filename: String
    let totalSize: Int64
    var direction: Direction
    var bytesTransferred: Int64 = 0
    var isComplete = false
    var failed = false
    var savedURL: URL?

    var progress: Double {
        guard totalSize > 0 else { return 0 }
        return Double(bytesTransferred) / Double(totalSize)
    }
}

@Observable
final class TetherViewModel {
    private static let autoSyncClipboardKey = "TetherAutoSyncClipboard"

    // MARK: - Published State

    // Whether clipboard updates from remote devices are automatically written to the local pasteboard.
    var autoSyncClipboard: Bool = true {
        didSet {
            UserDefaults.standard.set(autoSyncClipboard, forKey: TetherViewModel.autoSyncClipboardKey)
        }
    }

    // Whether desktop clipboard changes arrive over Bluetooth while the app is
    // in the background (as a notification with a Copy action).
    var bluetoothClipboardEnabled: Bool {
        get { DesktopClipboardService.shared.monitor.isEnabled }
        set {
            DesktopClipboardService.shared.setEnabled(newValue)
            bluetoothClipboardStatus = DesktopClipboardService.shared.monitor.status
        }
    }

    private(set) var bluetoothClipboardStatus: DesktopClipboardMonitor.Status = .off

    // MARK: - Speed test

    struct SpeedTestResult: Equatable {
        let roundTripMilliseconds: Double
        let uploadMegabitsPerSecond: Double
        let downloadMegabitsPerSecond: Double
        let measuredAt: Date
    }

    private(set) var speedTestRunning = false
    private(set) var speedTestResult: SpeedTestResult?
    private(set) var speedTestError: String?

    // Replies the running speed test is waiting for, by seq.
    private var speedTestWaiters: [Int: CheckedContinuation<TetherMessage, Error>] = [:]
    private var speedTestSeq = 0

    private static let speedTestChunkBytes = 512 * 1024
    private static let speedTestUploadChunks = 4
    private static let speedTestDownloadBytes = 2 * 1024 * 1024
    private static let speedTestStepTimeout: Double = 20

    // Measures the Wi-Fi session to the desktop: round trip, then upload and
    // download of a few megabytes over the same TLS connection the clipboard
    // uses. Rates are for the raw bytes, before base64.
    func runSpeedTest() {
        guard !speedTestRunning, case .connected = appState else { return }
        speedTestRunning = true
        speedTestError = nil

        Task { [weak self] in
            guard let self else { return }
            do {
                // Round trip: three empty exchanges, the median.
                var trips: [Double] = []
                for _ in 0..<3 {
                    let start = Date()
                    _ = try await speedTestExchange(.speedTestDownload(seq: nextSpeedTestSeq(), bytes: 0))
                    trips.append(Date().timeIntervalSince(start) * 1000)
                }
                let roundTrip = trips.sorted()[1]

                // Upload.
                var chunk = Data(count: Self.speedTestChunkBytes)
                chunk.withUnsafeMutableBytes { buffer in
                    _ = SecRandomCopyBytes(kSecRandomDefault, buffer.count, buffer.baseAddress!)
                }
                let uploadStart = Date()
                for _ in 0..<Self.speedTestUploadChunks {
                    _ = try await speedTestExchange(.speedTestUpload(seq: nextSpeedTestSeq(), data: chunk))
                }
                let uploadSeconds = Date().timeIntervalSince(uploadStart)
                let uploadBytes = Double(Self.speedTestChunkBytes * Self.speedTestUploadChunks)

                // Download.
                let downloadStart = Date()
                let reply = try await speedTestExchange(.speedTestDownload(seq: nextSpeedTestSeq(), bytes: Self.speedTestDownloadBytes))
                let downloadSeconds = Date().timeIntervalSince(downloadStart)
                let downloadBytes = Double(Data(base64Encoded: reply.data ?? "")?.count ?? 0)

                speedTestResult = SpeedTestResult(
                    roundTripMilliseconds: roundTrip,
                    uploadMegabitsPerSecond: uploadBytes * 8 / max(uploadSeconds, 0.001) / 1_000_000,
                    downloadMegabitsPerSecond: downloadBytes * 8 / max(downloadSeconds, 0.001) / 1_000_000,
                    measuredAt: Date()
                )
            } catch {
                speedTestError = error.localizedDescription
            }
            speedTestRunning = false
        }
    }

    private func nextSpeedTestSeq() -> Int {
        speedTestSeq += 1
        return speedTestSeq
    }

    // Sends one speed test message and waits for the reply with the same seq.
    private func speedTestExchange(_ message: TetherMessage) async throws -> TetherMessage {
        let seq = message.seq ?? 0
        return try await withCheckedThrowingContinuation { continuation in
            speedTestWaiters[seq] = continuation
            connection.send(message)
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(Self.speedTestStepTimeout))
                guard let self, let waiting = speedTestWaiters.removeValue(forKey: seq) else { return }
                waiting.resume(throwing: SpeedTestError.timeout)
            }
        }
    }

    private func resolveSpeedTest(_ message: TetherMessage) {
        guard let seq = message.seq, let waiting = speedTestWaiters.removeValue(forKey: seq) else { return }
        waiting.resume(returning: message)
    }

    enum SpeedTestError: LocalizedError {
        case timeout
        var errorDescription: String? { "The desktop did not answer in time." }
    }

    // Whether a desktop copy arriving in the background shows a notification.
    var notifyOnDesktopCopy: Bool {
        get { DesktopClipboardService.shared.notifyOnDesktopCopy }
        set { DesktopClipboardService.shared.notifyOnDesktopCopy = newValue }
    }
    private(set) var bluetoothClipboardTrace: [String] = []

    // Overall connection state.
    private(set) var appState: AppConnectionState = .disconnected

    // Name of the connected device, if any.
    private(set) var connectedDeviceName: String?

    // Whether the daemon answered hello with clipboard_image. Older daemons
    // would save a sent image to Downloads instead of the clipboard.
    private(set) var daemonSupportsClipboardImages = false

    // Clipboard history (most recent first), kept on disk by the store.
    let history = ClipboardHistoryStore.shared
    var clipboardHistory: [ClipboardEntry] { history.entries }

    // Active file transfers.
    private(set) var activeTransfers: [FileTransfer] = []

    // Completed file transfers.
    private(set) var completedTransfers: [FileTransfer] = []

    // Whether the pairing sheet should be presented.
    var showPairingSheet = false

    // The currently selected top-level tab.
    var selectedTab: AppTab = .dashboard

    // Status message for the pairing flow.
    private(set) var pairingStatus: String = ""

    // Which side asked. Inbound means a peer dialled us and this device is the
    // approver. Outbound means we asked and the peer's user decides.
    private(set) var pairingIsInbound = false

    // Error message to display, if any.
    var errorMessage: String?

    // MARK: - Services

    let certificateManager = CertificateManager()
    let discovery = BonjourDiscovery()
    let connection = TetherConnection()
    let server = TetherServer()

    // The chunk size for file transfers (48KB raw → 64KB base64).
    private let fileChunkSize = 48 * 1024
    private var hasInitialized = false
    private var pendingReconnectTask: Task<Void, Never>?
    private var connectTimeoutTask: Task<Void, Never>?
    private var autoConnectingFingerprint: String?

    // Direction of the current transport, set only from the connection state.
    // The trust gate keys off this; `pairingIsInbound` is UI state that messages move.
    private var connectionIsInbound = false
    private var manualDisconnect = false
    private var currentScenePhase: ScenePhase = .active

    // Last desktop text applied from any transport, so Wi-Fi and Bluetooth do not both apply it.
    private var lastRemoteClipboardText: String?

    // Consecutive failed reconnect attempts, used to space out the retries.
    private var reconnectAttempts = 0

    // Base delay before a reconnect attempt, doubled per consecutive failure.
    private static let reconnectBaseDelay: Double = 0.7

    // capped exponential backoff.
    private static let reconnectMaxDelay: Double = 30

    // How long a dial may sit unanswered before it is treated as failed.
    private static let connectTimeout: Double = 8

    private struct IncomingTransferBuffer {
        let filename: String
        let expectedSize: Int64
        var clipboard: String? = nil
        var data = Data()
    }

    private var incomingTransfers: [String: IncomingTransferBuffer] = [:]

    // MARK: - Initialization

    // Call once at app startup.
    func initialize() {
        guard !hasInitialized else { return }
        hasInitialized = true

        if UserDefaults.standard.object(forKey: Self.autoSyncClipboardKey) != nil {
            autoSyncClipboard = UserDefaults.standard.bool(forKey: Self.autoSyncClipboardKey)
        }
        
        certificateManager.initialize()
        discovery.localFingerprint = certificateManager.myFingerprint
        discovery.localDeviceName = certificateManager.localDeviceName
        
        setupConnectionHandlers()
        setupServerHandlers()
        setupDesktopClipboard()
        startDiscovery()
        startServer()
        scheduleAutoReconnectAttempt()
    }

    // MARK: - Bluetooth clipboard

    private func setupDesktopClipboard() {
        let service = DesktopClipboardService.shared
        service.applyClipboard = { [weak self] text in
            self?.applyDesktopClipboard(text)
        }
        service.noteTapped = { [weak self] text in
            self?.recordDesktopClipboard(text)
        }
        service.deviceName = { [weak self] in
            guard let self else { return nil }
            if let connectedDeviceName { return connectedDeviceName }
            guard let fingerprint = certificateManager.lastConnectedFingerprint else { return nil }
            return certificateManager.knownHosts[fingerprint]
        }
        service.monitor.onStatusChange = { [weak self] status in
            self?.bluetoothClipboardStatus = status
        }
        service.monitor.onTrace = { [weak self] lines in
            self?.bluetoothClipboardTrace = lines
        }
        bluetoothClipboardStatus = service.monitor.status
        bluetoothClipboardTrace = service.monitor.trace
    }

    // Text the desktop copied, arriving while the app is in front (over Wi-Fi
    // or Bluetooth). Recorded once, applied per the auto-sync setting.
    private func applyDesktopClipboard(_ text: String) {
        guard recordDesktopClipboard(text) else { return }
        if autoSyncClipboard {
            copyToLocalClipboard(text)
        }
    }

    // Adds a desktop clipboard entry to the history. False when it is the same
    // text as the last one, which happens when a change arrives over both
    // Wi-Fi and Bluetooth.
    @discardableResult
    private func recordDesktopClipboard(_ text: String) -> Bool {
        if text == lastRemoteClipboardText { return false }
        lastRemoteClipboardText = text

        let sourceName = connectedDeviceName ?? DesktopClipboardService.shared.deviceName?() ?? "Desktop"
        history.addText(text, source: .remote(sourceName))
        return true
    }


    // MARK: - Discovery

    func startDiscovery(forceRestart: Bool = false) {
        discovery.startScanning(forceRestart: forceRestart)
        if appState == .disconnected {
            appState = .discovering
        }
    }

    func stopDiscovery(clearHosts: Bool = false) {
        discovery.stopScanning(clearHosts: clearHosts)
    }

    func refreshDiscovery() {
        startDiscovery(forceRestart: true)
        scheduleAutoReconnectAttempt()
    }

    func handleScenePhase(_ phase: ScenePhase) {
        currentScenePhase = phase

        switch phase {
        case .active:
            manualDisconnect = false
            reconnectAttempts = 0
            startServer()
            refreshDiscovery()
        case .background:
            pendingReconnectTask?.cancel()
            pendingReconnectTask = nil
            connectTimeoutTask?.cancel()
            connectTimeoutTask = nil
            suspendForBackground()
        default:
            break
        }
    }

    // MARK: - Connection

    // User-facing message when the TLS identity failed to bootstrap, including the
    // failing Keychain step when one was recorded.
    private var identityErrorMessage: String {
        let base = "TLS identity not available. Please restart the app."
        guard let detail = certificateManager.lastIdentityError else { return base }
        return "\(base) (\(detail))"
    }

    // Connect to a discovered host.
    func connectTo(host: DiscoveredHost) {
        guard let identity = certificateManager.getIdentity() else {
            errorMessage = identityErrorMessage
            return
        }

        manualDisconnect = false
        appState = .connecting
        connectedDeviceName = host.name
        // Persist the service name so the Share Extension can connect without discovery.
        ShareSender.persistLastServiceName(host.name)
        connection.connect(to: host.endpoint, identity: identity)
        startConnectTimeout()
    }

    // Connect by IP address and port.
    func connectTo(host: String, port: UInt16) {
        guard let identity = certificateManager.getIdentity() else {
            errorMessage = identityErrorMessage
            return
        }

        manualDisconnect = false
        appState = .connecting
        connectedDeviceName = host
        connection.connect(host: host, port: port, identity: identity)
        startConnectTimeout()
    }

    // Disconnect from the daemon.
    func disconnect() {
        manualDisconnect = true
        pendingReconnectTask?.cancel()
        pendingReconnectTask = nil
        connectTimeoutTask?.cancel()
        connectTimeoutTask = nil
        reconnectAttempts = 0
        autoConnectingFingerprint = nil
        certificateManager.lastConnectedFingerprint = nil // Also clear last connection
        connection.disconnect()
        appState = .disconnected
        connectedDeviceName = nil
        pairingStatus = ""
    }

    // MARK: - Clipboard

    // Send the current iOS clipboard content to the daemon.
    func sendClipboard() {
        #if canImport(UIKit)
        let pasteboard = UIPasteboard.general
        // Text wins when both are present, matching the daemon.
        if !pasteboard.hasStrings, pasteboard.hasImages {
            guard let png = pasteboard.data(forPasteboardType: UTType.png.identifier) ?? pasteboard.image?.pngData() else {
                errorMessage = "Clipboard is empty."
                return
            }
            sendClipboardImage(png)
            return
        }
        guard let text = pasteboard.string, !text.isEmpty else {
            errorMessage = "Clipboard is empty."
            return
        }
        #else
        guard let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else {
            errorMessage = "Clipboard is empty."
            return
        }
        #endif

        connection.send(.clipboardSet(text))
        history.addText(text, source: .local(certificateManager.localDeviceName))
    }

    // Sends an entry from the history to the desktop clipboard.
    func sendToDesktop(_ entry: ClipboardEntry) {
        if entry.isImage {
            guard let png = history.imageData(for: entry) else { return }
            sendClipboardImage(png)
        } else {
            connection.send(.clipboardSet(entry.content))
        }
    }

    // Send PNG bytes to the daemon's clipboard as a file transfer tagged "set".
    private func sendClipboardImage(_ png: Data) {
        guard daemonSupportsClipboardImages else {
            errorMessage = "Update Tether on your computer to send images."
            return
        }
        // Same cap the daemon enforces.
        guard png.count <= 32 * 1024 * 1024 else {
            errorMessage = "Image is too large to send (32 MB max)."
            return
        }
        sendFile(data: png, filename: "clipboard.png", clipboard: "set")
        history.addImage(png, source: .local(certificateManager.localDeviceName))
    }

    // Request the current clipboard from the daemon.
    func requestClipboard() {
        connection.send(.clipboardGet())
    }

    // Send an OTP code to the tetherd vault (`new_otp`).
    // The daemon stores it so the browser extension can retrieve it via `request_otp`.
    func sendNewOtp(_ code: String, source: String = "iPhone") {
        connection.send(.newOtp(code, source: source))
    }

    // Copy a clipboard entry to the iOS pasteboard.
    func copyToLocalClipboard(_ text: String) {
        #if canImport(UIKit)
        UIPasteboard.general.string = text
        #else
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #endif
    }

    // Copy PNG bytes to the iOS pasteboard.
    func copyImageToLocalClipboard(_ png: Data) {
        UIPasteboard.general.setData(png, forPasteboardType: UTType.png.identifier)
    }

    // MARK: - File Transfer

    // Send a file to the daemon using its URL.
    func sendFile(url: URL) {
        let isSecurityScoped = url.startAccessingSecurityScopedResource()
        let filename = url.lastPathComponent

        Task.detached { [weak self] in
            guard let self else { return }
            defer { if isSecurityScoped { url.stopAccessingSecurityScopedResource() } }

            do {
                let fileData = try Data(contentsOf: url)
                self.sendFile(data: fileData, filename: filename)
            } catch {
                await MainActor.run {
                    self.errorMessage = "File transfer failed: \(error.localizedDescription)"
                }
            }
        }
    }

    // Send raw data to the daemon. A clipboard transfer stays out of the Files tab.
    func sendFile(data fileData: Data, filename: String, clipboard: String? = nil) {
        let transferId = UUID().uuidString
        let totalSize = Int64(fileData.count)

        Task.detached { [weak self] in
            guard let self else { return }

            do {
                if clipboard == nil {
                    await MainActor.run {
                        let transfer = FileTransfer(
                            id: transferId,
                            filename: filename,
                            totalSize: totalSize,
                            direction: .outgoing
                        )
                        self.activeTransfers.append(transfer)
                    }
                }

                // Send file_start
                await MainActor.run {
                    self.connection.send(.fileStart(
                        filename: filename,
                        size: totalSize,
                        transferId: transferId,
                        clipboard: clipboard
                    ))
                }

                // Send chunks
                var offset = 0
                var chunkIndex = 0
                while offset < fileData.count {
                    let end = min(offset + self.fileChunkSize, fileData.count)
                    let chunk = fileData[offset..<end]
                    let base64 = chunk.base64EncodedString()

                    await MainActor.run {
                        self.connection.send(.fileChunk(
                            transferId: transferId,
                            chunkIndex: chunkIndex,
                            data: base64
                        ))

                        if let idx = self.activeTransfers.firstIndex(where: { $0.id == transferId }) {
                            self.activeTransfers[idx].bytesTransferred = Int64(end)
                        }
                    }

                    offset = end
                    chunkIndex += 1

                    // Small delay to avoid overwhelming the connection
                    try await Task.sleep(for: .milliseconds(10))
                }

                // Send file_end
                await MainActor.run {
                    self.connection.send(.fileEnd(transferId: transferId))
                }
            } catch {
                await MainActor.run {
                    if let idx = self.activeTransfers.firstIndex(where: { $0.id == transferId }) {
                        self.activeTransfers[idx].failed = true
                    }
                    self.errorMessage = "File transfer error from daemon: \(error.localizedDescription)"
                }
            }
        }
    }

    // MARK: - Private — Connection Handlers

    private func setupConnectionHandlers() {
        discovery.onHostsChanged = { [weak self] _ in
            self?.scheduleAutoReconnectAttempt()
        }

        connection.onStateChange = { [weak self] state in
            guard let self else { return }
            switch state {
            case .connected(let isInbound):
                if let expected = self.autoConnectingFingerprint, !isInbound,
                   self.connection.serverFingerprint != expected {
                    self.autoConnectingFingerprint = nil
                    self.connection.disconnect()
                    return
                }
                self.cancelConnectTimeout()
                self.pendingReconnectTask?.cancel()
                self.pendingReconnectTask = nil
                self.autoConnectingFingerprint = nil
                self.reconnectAttempts = 0
                self.certificateManager.lastConnectedFingerprint = self.connection.serverFingerprint
                if let endpoint = self.connection.resolvedEndpoint {
                    // On a session the daemon dialled, the remote port is the
                    // ephemeral one it dialled from, not where it listens.
                    let port = isInbound ? TetherConnection.daemonPort : endpoint.port
                    ShareSender.persistLastEndpoint(host: endpoint.host, port: port)
                }
                self.handleConnected(isInbound: isInbound)
            case .disconnected:
                self.cancelConnectTimeout()
                self.autoConnectingFingerprint = nil
                self.appState = .disconnected
                if self.currentScenePhase == .active {
                    self.scheduleAutoReconnectAttempt()
                }
            case .failed(let msg):
                self.cancelConnectTimeout()
                let wasAutoReconnect = self.autoConnectingFingerprint != nil
                self.autoConnectingFingerprint = nil
                self.appState = .disconnected
                if self.currentScenePhase == .active && !wasAutoReconnect {
                    self.errorMessage = "Connection failed: \(msg)"
                }
                if self.currentScenePhase == .active {
                    self.scheduleAutoReconnectAttempt()
                }
            case .connecting:
                self.appState = .connecting
            }
        }

        connection.onMessage = { [weak self] message in
            self?.handleMessage(message)
        }
    }

    private func setupServerHandlers() {
        server.onNewConnection = { [weak self] incomingConn, incomingFingerprint in
            guard let self = self else { return }

            guard self.appState != .connected else {
                incomingConn.cancel()
                return
            }
            if self.appState == .connecting || self.appState == .pairing {
                self.cancelConnectTimeout()
                self.pendingReconnectTask?.cancel()
                self.pendingReconnectTask = nil
                self.autoConnectingFingerprint = nil
                self.showPairingSheet = false
            }

            // We just received an incoming connection from a peer!
            // We give it to our connection manager and start decoding.
            self.connection.accept(incomingConnection: incomingConn, fingerprint: incomingFingerprint)
            
            // Note: `onStateChange` will automatically transition us to .connected 
            // and trigger `handleConnected()` which checks if it's already paired.
        }
    }
    
    private func startServer() {
        guard let identity = certificateManager.getIdentity() else { return }
        server.start(
            identity: identity,
            localDeviceName: certificateManager.localDeviceName,
            fingerprint: certificateManager.myFingerprint
        )
    }

    private func handleConnected(isInbound: Bool = false) {
        connectionIsInbound = isInbound
        let serverFP = connection.serverFingerprint

        if certificateManager.isHostKnown(serverFP) {
            // Already paired — go straight to connected
            appState = .connected
            connectedDeviceName = certificateManager.knownHosts[serverFP] ?? connectedDeviceName
            sendHello()
        } else {
            // Need to pair
            pairingIsInbound = isInbound
            if isInbound {
                // If it's an inbound connection, we wait for the client to send us a pair_request.
                // We don't send one ourselves over their established tunnel.
                appState = .pairing
                // The UI will update when we actually receive the .pairRequest command
            } else {
                appState = .pairing
                showPairingSheet = true
                pairingStatus = "Sending pairing request..."

                let deviceName = certificateManager.localDeviceName
                connection.send(.pairRequest(deviceName: deviceName))
            }
        }
    }

    private func scheduleAutoReconnectAttempt() {
        guard shouldAutoReconnect else { return }
        guard autoConnectingFingerprint == nil else { return }

        // delay is also mDNS's window to answer
        let delay = min(
            Self.reconnectBaseDelay * pow(2, Double(reconnectAttempts)),
            Self.reconnectMaxDelay
        )

        pendingReconnectTask?.cancel()
        pendingReconnectTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                self?.attemptAutoReconnect()
            }
        }
    }

    private var shouldAutoReconnect: Bool {
        if manualDisconnect {
            return false
        }

        switch appState {
        case .disconnected, .discovering:
            return true
        case .connecting, .pairing, .connected:
            return false
        }
    }

    private func attemptAutoReconnect() {
        guard shouldAutoReconnect else { return }

        // If we have a last connected fingerprint, prioritize it.
        let targetFingerprint = certificateManager.lastConnectedFingerprint

        let matchingHosts: [DiscoveredHost]
        if let targetFingerprint {
            matchingHosts = discovery.hosts.filter { $0.fingerprint == targetFingerprint }
        } else {
            // Fallback to any host if we don't have a record,
            // but ONLY if there's exactly one host found.
            matchingHosts = discovery.hosts.count == 1 ? discovery.hosts : []
        }

        // Stay silent when the identity is missing; the error belongs to a user-initiated
        // connect, not to a background reconnect on every launch.
        guard certificateManager.getIdentity() != nil else { return }

        if let targetHost = matchingHosts.first {
            reconnectAttempts += 1
            autoConnectingFingerprint = targetHost.fingerprint
            connectTo(host: targetHost)
            return
        }

        // discovery found nothing.
        guard let targetFingerprint, certificateManager.isHostKnown(targetFingerprint),
              let endpoint = ShareSender.lastEndpoint() else { return }

        reconnectAttempts += 1
        autoConnectingFingerprint = targetFingerprint
        connectTo(host: endpoint.host, port: endpoint.port)
    }

    // Fail a dial that the network never answers, so the reconnect loop can back off and try again.
    private func startConnectTimeout() {
        connectTimeoutTask?.cancel()
        connectTimeoutTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.connectTimeout))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self, self.appState == .connecting else { return }
                self.connection.disconnect()
            }
        }
    }

    private func cancelConnectTimeout() {
        connectTimeoutTask?.cancel()
        connectTimeoutTask = nil
    }

    private func suspendForBackground() {
        guard !manualDisconnect else { return }

        autoConnectingFingerprint = nil
        connection.disconnect()
        server.stop()
        appState = .disconnected
        connectedDeviceName = nil
    }

    private func handleMessage(_ message: TetherMessage) {
        // An unpinned peer may only speak the pairing half of the protocol, and only
        // the half its direction allows. Same boundary tetherd enforces.
        if !certificateManager.isHostKnown(connection.serverFingerprint),
           !TetherCommand.allowedWhileUnpaired(message.parsedCommand, inbound: connectionIsInbound) {
            return
        }

        switch message.parsedCommand {
        case .clipboardUpdated:
            if let content = message.content {
                applyDesktopClipboard(content)
            }

        case .speedTestAck, .speedTestPayload:
            resolveSpeedTest(message)

        case .clipboardContent:
            if let content = message.content {
                let sourceName = connectedDeviceName ?? "Desktop"
                history.addText(content, source: .remote(sourceName))

                // Manual requests ALWAYS write to the pasteboard
                Task { @MainActor in
                    copyToLocalClipboard(content)
                }
            }

        case .pairPending:
            // Manual (IP) connections have no Bonjour name; take the daemon's.
            if let name = message.deviceName, !name.isEmpty {
                connectedDeviceName = name
            }
            pairingStatus = "Waiting for approval on your desktop...\n\nRun: tether --accept \(certificateManager.myFingerprint)"

        case .pairRequest:
            if let targetName = message.deviceName {
                connectedDeviceName = targetName
                appState = .pairing
                pairingIsInbound = true
                pairingStatus = "\(targetName) wants to pair with this device."
                showPairingSheet = true
            }

        case .pairAccepted:
            // The peer's user approved. This, not our own tap, is what makes us paired.
            finishPairing()

        case .hello:
            daemonSupportsClipboardImages = message.features?.contains("clipboard_image") ?? false

        case .fileStatus:
            if let transferId = message.transferId, message.status == "success" {
                if let idx = activeTransfers.firstIndex(where: { $0.id == transferId }) {
                    var transfer = activeTransfers.remove(at: idx)
                    transfer.isComplete = true
                    completedTransfers.insert(transfer, at: 0)
                }
            }

        case .fileStart:
            guard let transferId = message.transferId,
                  let filename = message.filename,
                  let size = message.size else { break }

            incomingTransfers[transferId] = IncomingTransferBuffer(
                filename: filename,
                expectedSize: size,
                clipboard: message.clipboard
            )
            // Clipboard images land in clipboard history, not the Files tab.
            if message.clipboard != nil { break }

            if let idx = activeTransfers.firstIndex(where: { $0.id == transferId }) {
                activeTransfers[idx].filename = filename
                activeTransfers[idx].direction = .incoming
                activeTransfers[idx].bytesTransferred = 0
            } else {
                activeTransfers.append(FileTransfer(
                    id: transferId,
                    filename: filename,
                    totalSize: size,
                    direction: .incoming
                ))
            }

        case .fileChunk:
            guard let transferId = message.transferId,
                  let data = message.data,
                  let chunkData = Data(base64Encoded: data),
                  var transfer = incomingTransfers[transferId] else { break }

            transfer.data.append(chunkData)
            incomingTransfers[transferId] = transfer

            if let idx = activeTransfers.firstIndex(where: { $0.id == transferId }) {
                activeTransfers[idx].bytesTransferred = Int64(transfer.data.count)
            }

        case .fileEnd:
            guard let transferId = message.transferId else { break }
            finalizeIncomingTransfer(transferId: transferId)

        case .error:
            if message.message == "unauthorized" {
                // The daemon rejects every command until it has pinned us, so we are
                // not connected no matter what the last state said.
                appState = .pairing
                pairingIsInbound = false
                showPairingSheet = true
                pairingStatus = "Pairing request sent. Waiting for approval...\n\nRun: tether --accept \(certificateManager.myFingerprint)"
            } else {
                errorMessage = message.message ?? "Unknown error from daemon"
            }

        default:
            break
        }
    }

    // Approve a request from a peer that dialled us. This device is the approver
    // here, so the tap is the real decision and the peer is told about it.
    func acceptIncomingPairing() {
        guard connectionIsInbound else { return }
        connection.send(.pairAccepted)
        finishPairing()
    }

    // Reject a request from a peer that dialled us.
    func rejectIncomingPairing() {
        showPairingSheet = false
        pairingStatus = ""
        disconnect()
    }

    // Pin the peer and go live. Reached only once the pairing is real: either the
    // peer sent pair_accepted, or this device approved an inbound request.
    private func finishPairing() {
        let serverFP = connection.serverFingerprint
        guard !serverFP.isEmpty else { return }

        let name = connectedDeviceName ?? "Desktop"
        certificateManager.addKnownHost(fingerprint: serverFP, name: name)

        showPairingSheet = false
        pairingStatus = ""
        appState = .connected
        sendHello()
    }

    // Announce optional features. Sent only once the peer is pinned, since an
    // unpinned daemon answers anything else with "unauthorized".
    private func sendHello() {
        daemonSupportsClipboardImages = false
        connection.send(.hello(features: ["clipboard_image"]))
    }

    private func finalizeIncomingTransfer(transferId: String) {
        guard let buffered = incomingTransfers.removeValue(forKey: transferId) else { return }

        if let kind = buffered.clipboard {
            guard Int64(buffered.data.count) == buffered.expectedSize, UIImage(data: buffered.data) != nil else {
                errorMessage = "Received a damaged clipboard image."
                return
            }
            let sourceName = connectedDeviceName ?? "Desktop"
            history.addImage(buffered.data, source: .remote(sourceName))
            // "content" answers a manual request, so it always writes, like clipboard_content.
            if kind == "content" || autoSyncClipboard {
                Task { @MainActor in
                    copyImageToLocalClipboard(buffered.data)
                }
            }
            return
        }

        do {
            guard Int64(buffered.data.count) == buffered.expectedSize else {
                throw CocoaError(.fileReadCorruptFile)
            }

            let destination = try incomingFileURL(for: buffered.filename)
            try buffered.data.write(to: destination, options: .atomic)

            if let idx = activeTransfers.firstIndex(where: { $0.id == transferId }) {
                var transfer = activeTransfers.remove(at: idx)
                transfer.bytesTransferred = Int64(buffered.data.count)
                transfer.isComplete = true
                transfer.savedURL = destination
                completedTransfers.insert(transfer, at: 0)
                selectedTab = .files
            }
        } catch {
            if let idx = activeTransfers.firstIndex(where: { $0.id == transferId }) {
                activeTransfers[idx].failed = true
            }
            errorMessage = "Failed to save incoming file: \(error.localizedDescription)"
        }
    }

    private func incomingFileURL(for filename: String) throws -> URL {
        let fm = FileManager.default
        let docs = try fm.url(
            for: .documentDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let incomingDir = docs.appendingPathComponent("Received", isDirectory: true)
        try fm.createDirectory(at: incomingDir, withIntermediateDirectories: true, attributes: nil)

        let base = URL(fileURLWithPath: filename).deletingPathExtension().lastPathComponent
        let ext = URL(fileURLWithPath: filename).pathExtension
        var candidate = incomingDir.appendingPathComponent(filename)
        var counter = 1

        while fm.fileExists(atPath: candidate.path) {
            let deduped = ext.isEmpty ? "\(base)(\(counter))" : "\(base)(\(counter)).\(ext)"
            candidate = incomingDir.appendingPathComponent(deduped)
            counter += 1
        }

        return candidate
    }
}

#if DEBUG
extension TetherViewModel {
    static var previewMock: TetherViewModel {
        let vm = TetherViewModel()
        vm.appState = .connected
        vm.connectedDeviceName = "Arch btw Linux"
        
        vm.history.addText("9A1B-2C3D-4E5F-6G7H", source: .local("iPhone"))
        vm.history.addText("Meeting notes:\n- Review App Store designs\n- Approve new icon\n- Push v1.0", source: .remote(vm.connectedDeviceName!))
        vm.history.addText("func buildAwesomeApp() async throws -> Success", source: .local("iPhone"))
        vm.history.addText("https://developer.apple.com/app-store/connect/", source: .remote(vm.connectedDeviceName!))
        
        vm.activeTransfers = [
            FileTransfer(id: "1", filename: "App_Store_Assets.zip", totalSize: 24_500_000, direction: .outgoing, bytesTransferred: 18_200_000, isComplete: false)
        ]
        
        vm.completedTransfers = [
            FileTransfer(id: "2", filename: "Final_Designs.pdf", totalSize: 4_200_000, direction: .incoming, bytesTransferred: 4_200_000, isComplete: true),
            FileTransfer(id: "3", filename: "architecture_diagram.png", totalSize: 1_200_000, direction: .outgoing, bytesTransferred: 1_200_000, isComplete: true),
            FileTransfer(id: "4", filename: "auth_keys.pem", totalSize: 4_000, direction: .incoming, bytesTransferred: 4_000, isComplete: true)
        ]
        
        return vm
    }
}
#endif
