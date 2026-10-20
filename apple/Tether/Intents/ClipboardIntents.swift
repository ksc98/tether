//
//  ClipboardIntents.swift
//  Tether
//
//  Shortcuts actions for clipboard sync that run with the app in the background.
//
//  iOS gives a backgrounded app no access to UIPasteboard, so no action
//  touches it. The shortcut moves the clipboard across that boundary instead:
//
//    Phone → desktop:  Get Clipboard  →  Send to Desktop Clipboard (text or image)
//    Desktop → phone:  Get Desktop Clipboard  →  Copy to Clipboard
//    Either way:       Get Clipboard  →  Sync Clipboard  →  Copy to Clipboard
//                      (text or image)
//

import AppIntents
import CryptoKit
import TetherFramework
import UIKit
import UniformTypeIdentifiers

// Both actions take the clipboard as a file: a String parameter would get an
// image's name from Shortcuts, never its pixels. Text arrives as a .txt file,
// an image in whatever format it was copied as.
struct SendToDesktopClipboardIntent: AppIntent {
    static let title: LocalizedStringResource = "Send to Desktop Clipboard"
    static let description = IntentDescription(
        "Sets the clipboard of your paired Linux desktop to the given text or image, without opening Tether.",
        categoryName: "Clipboard"
    )
    static let openAppWhenRun = false

    @Parameter(title: "Clipboard", supportedContentTypes: [.image, .text], inputConnectionBehavior: .connectToPreviousIntentResult)
    var clipboard: IntentFile

    static var parameterSummary: some ParameterSummary {
        Summary("Send \(\.$clipboard) to the desktop clipboard")
    }

    func perform() async throws -> some IntentResult {
        let content = ClipboardContent(clipboard)
        guard !content.isEmpty else { throw ClipboardIntentError.emptyText }
        try await content.push(note: "sent")
        return .result()
    }
}

struct GetDesktopClipboardIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Desktop Clipboard"
    static let description = IntentDescription(
        "Returns the clipboard text of your paired Linux desktop, without opening Tether.",
        categoryName: "Clipboard"
    )
    static let openAppWhenRun = false

    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        switch await ShareSender.fetchClipboard() {
        case .success(let desktop):
            return .result(value: desktop.text)
        case .failure(let error):
            throw ClipboardIntentError.failed(error.localizedDescription)
        }
    }
}

// One action for both directions. iOS gives no time for the phone's clipboard,
// the desktop reports one for its own, so the desktop is the side that can be
// known to be newer:
//
//   1. The desktop clipboard changed since the last sync and differs from the
//      phone's: pull it, text or image.
//   2. Otherwise the phone's clipboard differs from what was last synced: push it.
//   3. Otherwise there is nothing to do.
//
// The result is always what the phone's clipboard should hold, so the
// shortcut can end with Copy to Clipboard unconditionally.
struct SyncClipboardIntent: AppIntent {
    static let title: LocalizedStringResource = "Sync Clipboard"
    static let description = IntentDescription(
        "Sends this text or image to the desktop when it is the newer copy, or returns the desktop clipboard when that changed more recently. Follow with Copy to Clipboard.",
        categoryName: "Clipboard"
    )
    static let openAppWhenRun = false

    @Parameter(title: "Clipboard", supportedContentTypes: [.image, .text], inputConnectionBehavior: .connectToPreviousIntentResult)
    var clipboard: IntentFile

    static var parameterSummary: some ParameterSummary {
        Summary("Sync \(\.$clipboard) with the desktop clipboard")
    }

    private static let lastDesktopChangedAtKey = "TetherSyncLastDesktopChangedAt"
    // ClipboardContent.key of what was last synced.
    private static let lastTextKey = "TetherSyncLastText"

    func perform() async throws -> some IntentResult & ReturnsValue<IntentFile> {
        let defaults = UserDefaults.standard
        let lastDesktopChangedAt = Int64(defaults.integer(forKey: Self.lastDesktopChangedAtKey))
        let lastKey = defaults.string(forKey: Self.lastTextKey) ?? ""
        let phone = ClipboardContent(clipboard)

        // Asked over Wi-Fi, which carries images. A copy that arrived over
        // Bluetooth (text only, its seq on the desktop's clock like changed_at)
        // stands in when the desktop is out of reach.
        let desktopClipboard: ShareSender.DesktopClipboard
        switch await ShareSender.fetchClipboard() {
        case .success(let fetched):
            desktopClipboard = fetched
        case .failure(let error):
            guard let cached = await DesktopClipboardCache.load(), cached.complete else {
                throw ClipboardIntentError.failed(error.localizedDescription)
            }
            desktopClipboard = ShareSender.DesktopClipboard(text: cached.text, changedAt: cached.seq)
        }
        let desktop = ClipboardContent(desktopClipboard)

        // Compared on the desktop's own clock, so phone and desktop clocks need
        // not agree. A push bumps the desktop's time too, so content equal to
        // the last synced content is not a desktop change. With no history at
        // all the desktop would always look changed; the phone's clipboard is
        // what the user is holding, so the first sync pushes it.
        let firstSync = lastDesktopChangedAt == 0 && lastKey.isEmpty
        let desktopChanged = !firstSync && (desktopClipboard.changedAt ?? 0) > lastDesktopChangedAt && desktop.key != lastKey
        let phoneChanged = !phone.isEmpty && phone.key != lastKey

        func remember(_ synced: ClipboardContent) {
            defaults.set(synced.key, forKey: Self.lastTextKey)
            if let changedAt = desktopClipboard.changedAt {
                defaults.set(Int(changedAt), forKey: Self.lastDesktopChangedAtKey)
            }
        }

        // No result card: a Done button on every press is more than the action
        // deserves. The direction goes to the app's Bluetooth log.
        if desktopChanged, !desktop.isEmpty, desktop.key != phone.key {
            remember(desktop)
            await desktop.pulled()
            return .result(value: desktop.file)
        }

        if phoneChanged, desktop.key != phone.key {
            try await phone.push(note: "sync: sent")
            remember(phone)
            return .result(value: phone.file)
        }

        await DesktopClipboardService.shared.monitor.noteExternal("sync: already in sync")
        let held = phone.isEmpty ? desktop : phone
        remember(held)
        return .result(value: held.file)
    }
}

// A clipboard on either side, as the actions move it.
enum ClipboardContent {
    case text(String)
    case image(Data) // PNG, the only image type the daemon takes

    init(_ file: IntentFile) {
        // UIImage refuses text, so anything it decodes is an image.
        if file.type?.conforms(to: .text) != true, let png = Self.normalized(file.data) {
            self = .image(png)
        } else {
            self = .text(String(data: file.data, encoding: .utf8) ?? "")
        }
    }

    init(_ desktop: ShareSender.DesktopClipboard) {
        if let image = desktop.image, let png = Self.normalized(image) {
            self = .image(png)
        } else {
            self = .text(desktop.text)
        }
    }

    // Both sides' images go through the same encoder, so a pulled image that
    // comes back through Get Clipboard has the same bytes, and the same key,
    // rather than looking like a new copy on the phone.
    private static func normalized(_ data: Data) -> Data? {
        UIImage(data: data)?.pngData()
    }

    var isEmpty: Bool {
        switch self {
        case .text(let text): return text.isEmpty
        case .image(let png): return png.isEmpty
        }
    }

    // Identifies the content across syncs: the text itself, or an image's digest.
    var key: String {
        switch self {
        case .text(let text): return text
        case .image(let png): return "image:" + SHA256.hash(data: png).map { String(format: "%02x", $0) }.joined()
        }
    }

    // What Copy to Clipboard puts on the phone. Text goes as the type
    // UIPasteboard reads as a string, so it pastes as text.
    var file: IntentFile {
        switch self {
        case .text(let text): return IntentFile(data: Data(text.utf8), filename: "Clipboard.txt", type: .utf8PlainText)
        case .image(let png): return IntentFile(data: png, filename: "Clipboard.png", type: .png)
        }
    }

    private var summary: String {
        switch self {
        case .text(let text): return "\(text.count) chars"
        case .image(let png): return "image, \(png.count) bytes"
        }
    }

    // Sets the desktop clipboard to this and records it.
    func push(note: String) async throws {
        let payload: SharePayload
        switch self {
        case .text(let text): payload = .clipboard(text)
        case .image(let png): payload = .clipboardImage(png)
        }
        if case .failure(let error) = await ShareSender.send(payload) {
            throw ClipboardIntentError.failed(error.localizedDescription)
        }
        let service = await DesktopClipboardService.shared
        await record(source: .local(service.phoneName()))
        await service.monitor.noteExternal("\(note) \(summary)")
    }

    // Records this as having come from the desktop, which supersedes its notification.
    func pulled() async {
        let service = await DesktopClipboardService.shared
        await service.clearNotification()
        await record(source: .remote(service.desktopName()))
        await service.monitor.noteExternal("sync: pulled \(summary)")
    }

    private func record(source: ClipboardEntry.ClipboardSource) async {
        switch self {
        case .text(let text): await ClipboardHistoryStore.shared.addText(text, source: source)
        case .image(let png): await ClipboardHistoryStore.shared.addImage(png, source: source)
        }
    }
}

enum ClipboardIntentError: Error, CustomLocalizedStringResourceConvertible {
    case emptyText
    case failed(String)

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .emptyText:
            return "There is no text to send."
        case .failed(let message):
            return "\(message)"
        }
    }
}
