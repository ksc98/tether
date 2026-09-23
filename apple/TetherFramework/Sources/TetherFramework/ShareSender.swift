//
//  ShareSender.swift
//  TetherFramework
//
//  Bootstraps a fresh mTLS connection from the Share Extension context,
//  sends a SharePayload to the last-known tetherd daemon, and disconnects.
//
//  Design constraints:
//  - The Share Extension process is short-lived with no pre-existing connection.
//  - We connect on-demand to the last-known host (stored in the shared App Group UserDefaults).
//  - We do NOT run BonjourDiscovery; instead we connect directly to the last known
//    NWEndpoint service name which persists in UserDefaults.
//

import Foundation
import Network

/// Errors that can occur during a share send operation.
public enum ShareSenderError: LocalizedError {
    case notPaired
    case noKnownHost
    case identityUnavailable
    case connectionFailed(String)
    case timeout
    case fileTransferFailed(String)

    public var errorDescription: String? {
        switch self {
        case .notPaired:
            return "This device is not paired with a Tether host. Open the Tether app to pair first."
        case .noKnownHost:
            return "No Tether host found. Open the Tether app and connect to your desktop first."
        case .identityUnavailable:
            return "TLS identity unavailable. Open the Tether app to initialize it."
        case .connectionFailed(let msg):
            return "Connection failed: \(msg)"
        case .timeout:
            return "Connection timed out. Make sure tetherd is running on your desktop."
        case .fileTransferFailed(let msg):
            return "File transfer failed: \(msg)"
        }
    }
}

/// Guards a continuation that a reply, a connection failure and a timeout all
/// race to resume, from different threads.
private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    /// True for exactly one caller.
    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if claimed { return false }
        claimed = true
        return true
    }
}

/// Async helper used by the Share Extension to send a payload to tetherd.
///
/// Usage:
/// ```swift
/// let result = await ShareSender.send(.clipboard("Hello, world!"))
/// ```
public actor ShareSender {
    // Keys for the last-known Bonjour service name, stored in shared UserDefaults.
    private static let lastServiceNameKey = "TetherLastServiceName"
    private static let lastHostKey = "TetherLastHost"
    private static let lastPortKey = "TetherLastPort"
    private static let serviceType = "_tether._tcp"
    private static let serviceDomain = "local."

    // Chunk size for file transfers (48 KB raw → ~64 KB base64).
    private static let fileChunkSize = 48 * 1024

    // Maximum seconds to wait for the connection to become ready.
    private static let connectionTimeoutSeconds: Double = 8

    // Maximum seconds to wait for the daemon's clipboard_content reply.
    private static let clipboardReplyTimeoutSeconds: Double = 5

    /// Send a `SharePayload` to the paired tetherd daemon.
    ///
    /// - Parameter payload: The content to send.
    /// - Returns: `Result<Void, Error>` — success or a descriptive error.
    public static func send(_ payload: SharePayload) async -> Result<Void, Error> {
        let connection: TetherConnection
        switch await connectToLastKnownHost() {
        case .success(let conn):
            connection = conn
        case .failure(let error):
            return .failure(error)
        }

        let sendResult: Result<Void, Error>
        switch payload {
        case .clipboard(let text):
            connection.send(.clipboardSet(text))
            // Give the message time to flush before disconnecting
            try? await Task.sleep(for: .milliseconds(300))
            sendResult = .success(())

        case .openUrl(let url):
            connection.send(.openUrl(url))
            try? await Task.sleep(for: .milliseconds(300))
            sendResult = .success(())

        case .otp(let code, let source):
            connection.send(.newOtp(code, source: source))
            try? await Task.sleep(for: .milliseconds(300))
            sendResult = .success(())

        case .file(let data, let filename):
            sendResult = await sendFile(data: data, filename: filename, via: connection)
        }

        connection.disconnect()
        return sendResult
    }

    /// Send several files in one share as a batch, reusing a single mTLS
    /// connection instead of reconnecting per file — matters given the
    /// Share Extension's tight time/memory budget for multi-item shares.
    ///
    /// - Parameters:
    ///   - files: The files to send, in order.
    ///   - onProgress: Called after each file finishes (successfully or not)
    ///     with `(completedCount, total)`.
    /// - Returns: One `Result` per input file, in the same order.
    public static func sendFiles(
        _ files: [(data: Data, filename: String)],
        onProgress: (@Sendable (Int, Int) -> Void)? = nil
    ) async -> [Result<Void, Error>] {
        let connection: TetherConnection
        switch await connectToLastKnownHost() {
        case .success(let conn):
            connection = conn
        case .failure(let error):
            return files.map { _ in .failure(error) }
        }

        var results: [Result<Void, Error>] = []
        results.reserveCapacity(files.count)
        for file in files {
            let result = await sendFile(data: file.data, filename: file.filename, via: connection)
            results.append(result)
            onProgress?(results.count, files.count)
        }

        connection.disconnect()
        return results
    }

    /// The desktop clipboard as the daemon reports it.
    public struct DesktopClipboard: Sendable {
        public let text: String
        // When it last changed on the desktop, ms since the epoch on the desktop's clock.
        // nil from a daemon that predates the field.
        public let changedAt: Int64?

        public init(text: String, changedAt: Int64?) {
            self.text = text
            self.changedAt = changedAt
        }
    }

    /// Fetch the desktop's current clipboard text from the paired tetherd daemon.
    ///
    /// Used by the Shortcuts intents, which run with the app in the background
    /// where no live connection exists.
    public static func fetchClipboard() async -> Result<DesktopClipboard, Error> {
        let connection: TetherConnection
        switch await connectToLastKnownHost() {
        case .success(let conn):
            connection = conn
        case .failure(let error):
            return .failure(error)
        }

        let result: Result<DesktopClipboard, Error> = await withCheckedContinuation { continuation in
            let once = ResumeOnce()

            connection.onMessage = { message in
                switch message.parsedCommand {
                case .clipboardContent:
                    if once.claim() {
                        continuation.resume(returning: .success(
                            DesktopClipboard(text: message.content ?? "", changedAt: message.changedAt)))
                    }
                case .error:
                    if once.claim() {
                        let msg = message.message ?? "Unknown error from daemon"
                        continuation.resume(returning: .failure(ShareSenderError.connectionFailed(msg)))
                    }
                default:
                    // The daemon also broadcasts clipboard_updated to every client.
                    break
                }
            }

            connection.onStateChange = { state in
                let reason: String
                switch state {
                case .failed(let msg): reason = msg
                case .disconnected: reason = "The desktop closed the connection."
                default: return
                }
                if once.claim() {
                    continuation.resume(returning: .failure(ShareSenderError.connectionFailed(reason)))
                }
            }

            connection.send(.clipboardGet())

            Task {
                try? await Task.sleep(for: .seconds(clipboardReplyTimeoutSeconds))
                if once.claim() {
                    continuation.resume(returning: .failure(ShareSenderError.timeout))
                }
            }
        }

        connection.onMessage = nil
        connection.onStateChange = nil
        connection.disconnect()
        return result
    }

    // MARK: - Private — Connection

    /// Bootstraps a fresh mTLS connection to the last-known tetherd host.
    /// Shared by `send(_:)` and `sendFiles(_:onProgress:)` so multi-file
    /// shares only pay the connect/handshake cost once.
    private static func connectToLastKnownHost() async -> Result<TetherConnection, Error> {
        // 1. Initialize certificate manager (reads from shared Keychain + UserDefaults)
        let certManager = CertificateManager()
        certManager.initialize()

        guard let identity = certManager.getIdentity() else {
            return .failure(ShareSenderError.identityUnavailable)
        }

        // 2. Determine last-known fingerprint
        guard let targetFingerprint = certManager.lastConnectedFingerprint,
              certManager.isHostKnown(targetFingerprint) else {
            return .failure(ShareSenderError.noKnownHost)
        }

        // 3. Resolve endpoint — prefer direct IP/Port bypass to avoid Local Network Privacy limits in the extension
        let sharedDefaults = CertificateManager.sharedDefaults
        let endpoint: NWEndpoint

        if let hostStr = sharedDefaults.string(forKey: lastHostKey), !hostStr.isEmpty,
           let portInt = sharedDefaults.object(forKey: lastPortKey) as? Int, portInt > 0,
           let port = NWEndpoint.Port(rawValue: UInt16(portInt)) {
            endpoint = NWEndpoint.hostPort(host: .init(hostStr), port: port)
        } else if let serviceName = sharedDefaults.string(forKey: lastServiceNameKey), !serviceName.isEmpty {
            endpoint = NWEndpoint.service(
                name: serviceName,
                type: serviceType,
                domain: serviceDomain,
                interface: nil
            )
        } else {
            return .failure(ShareSenderError.noKnownHost)
        }

        // 4. Connect
        let connection = TetherConnection()
        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                var resumed = false

                connection.onStateChange = { state in
                    guard !resumed else { return }
                    switch state {
                    case .connected:
                        resumed = true
                        continuation.resume()
                    case .failed(let msg):
                        resumed = true
                        continuation.resume(throwing: ShareSenderError.connectionFailed(msg))
                    default:
                        break
                    }
                }

                connection.connect(to: endpoint, identity: identity)

                // Timeout guard
                Task {
                    try? await Task.sleep(for: .seconds(connectionTimeoutSeconds))
                    if !resumed {
                        resumed = true
                        connection.disconnect()
                        continuation.resume(throwing: ShareSenderError.timeout)
                    }
                }
            }
        } catch {
            return .failure(error)
        }

        return .success(connection)
    }

    // MARK: - Private — File Transfer

    private static func sendFile(
        data fileData: Data,
        filename: String,
        via connection: TetherConnection
    ) async -> Result<Void, Error> {
        let transferId = UUID().uuidString
        let totalSize = Int64(fileData.count)

        // Listen for file_status confirmation
        let statusResult: Result<Void, Error> = await withCheckedContinuation { continuation in
            var resumed = false

            connection.onMessage = { message in
                guard !resumed else { return }
                switch message.parsedCommand {
                case .fileStatus:
                    if message.transferId == transferId, message.status == "success" {
                        resumed = true
                        continuation.resume(returning: .success(()))
                    }
                case .error:
                    resumed = true
                    let msg = message.message ?? "Unknown error from daemon"
                    continuation.resume(returning: .failure(ShareSenderError.fileTransferFailed(msg)))
                default:
                    break
                }
            }

            // Send file_start
            connection.send(.fileStart(filename: filename, size: totalSize, transferId: transferId))

            // Stream chunks
            Task {
                var offset = 0
                var chunkIndex = 0
                while offset < fileData.count {
                    let end = min(offset + fileChunkSize, fileData.count)
                    let chunk = fileData[offset..<end]
                    let base64 = chunk.base64EncodedString()

                    connection.send(.fileChunk(transferId: transferId, chunkIndex: chunkIndex, data: base64))
                    offset = end
                    chunkIndex += 1
                    try? await Task.sleep(for: .milliseconds(10))
                }

                // Send file_end
                connection.send(.fileEnd(transferId: transferId))

                // Timeout for file_status
                try? await Task.sleep(for: .seconds(30))
                if !resumed {
                    resumed = true
                    continuation.resume(returning: .failure(ShareSenderError.timeout))
                }
            }
        }

        return statusResult
    }
}

// MARK: - Main App Helper

extension ShareSender {
    /// Called by the main app whenever it connects to a host, so the Share Extension
    /// can later resolve the Bonjour service name without running its own discovery.
    public static func persistLastServiceName(_ name: String) {
        let sharedDefaults = CertificateManager.sharedDefaults
        sharedDefaults.set(name, forKey: lastServiceNameKey)
    }

    /// Called by the main app once the connection is established to cache the
    /// direct IP and Port, allowing the Share Extension to bypass Bonjour entirely.
    public static func persistLastEndpoint(host: String, port: UInt16) {
        let sharedDefaults = CertificateManager.sharedDefaults
        sharedDefaults.set(host, forKey: lastHostKey)
        sharedDefaults.set(Int(port), forKey: lastPortKey)
    }

    /// The last endpoint a connection actually resolved to, if one was ever cached.
    public static func lastEndpoint() -> (host: String, port: UInt16)? {
        let sharedDefaults = CertificateManager.sharedDefaults
        guard let host = sharedDefaults.string(forKey: lastHostKey), !host.isEmpty,
              let portInt = sharedDefaults.object(forKey: lastPortKey) as? Int,
              portInt > 0, portInt <= Int(UInt16.max) else { return nil }
        return (host, UInt16(portInt))
    }
}
