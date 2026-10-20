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

// The clipboard comes in as a file: a String parameter would get an image's
// name from Shortcuts, never its pixels. Text arrives as a .txt file, an image
// in whatever format it was copied as; the daemon only takes PNG.
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
        let service = await DesktopClipboardService.shared
        switch ClipboardContent(clipboard) {
        case .image(let png):
            switch await ShareSender.send(.clipboardImage(png)) {
            case .success:
                await ClipboardHistoryStore.shared.addImage(png, source: .local(service.phoneName()))
                await service.monitor.noteExternal("sent image, \(png.count) bytes")
                return .result()
            case .failure(let error):
                throw ClipboardIntentError.failed(error.localizedDescription)
            }
        case .text(let text):
            guard !text.isEmpty else { throw ClipboardIntentError.emptyText }
            switch await ShareSender.send(.clipboard(text)) {
            case .success:
                await ClipboardHistoryStore.shared.addText(text, source: .local(service.phoneName()))
                return .result()
            case .failure(let error):
                throw ClipboardIntentError.failed(error.localizedDescription)
            }
        }
    }
}

// What a shortcut handed over as the phone's clipboard.
enum ClipboardContent {
    case text(String)
    case image(Data) // PNG

    init(_ file: IntentFile) {
        // UIImage refuses text, so anything it decodes is an image.
        if file.type?.conforms(to: .text) != true, let png = UIImage(data: file.data)?.pngData() {
            self = .image(png)
        } else {
            self = .text(String(data: file.data, encoding: .utf8) ?? "")
        }
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
//      phone's: pull it (the returned text goes on the phone's clipboard).
//   2. Otherwise the phone's text or image differs from what was last synced:
//      push it.
//   3. Otherwise there is nothing to do.
//
// The clipboard comes in as a file, as for Send to Desktop Clipboard.
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
    // Text, or "image:<sha256>" for an image.
    private static let lastTextKey = "TetherSyncLastText"

    func perform() async throws -> some IntentResult & ReturnsValue<IntentFile> {
        let defaults = UserDefaults.standard
        let lastDesktopChangedAt = Int64(defaults.integer(forKey: Self.lastDesktopChangedAtKey))
        let lastText = defaults.string(forKey: Self.lastTextKey) ?? ""

        var png: Data?
        var text = ""
        switch ClipboardContent(clipboard) {
        case .image(let data): png = data
        case .text(let string): text = string
        }
        let phoneKey = png.map { "image:" + SHA256.hash(data: $0).map { String(format: "%02x", $0) }.joined() } ?? text

        // A copy that arrived over Bluetooth is the desktop clipboard as of its
        // seq (the desktop's clock, like changed_at); when it is complete there
        // is no need to ask over Wi-Fi.
        let desktop: ShareSender.DesktopClipboard
        if let cached = await DesktopClipboardCache.load(), cached.complete {
            desktop = ShareSender.DesktopClipboard(text: cached.text, changedAt: cached.seq)
        } else {
            switch await ShareSender.fetchClipboard() {
            case .success(let fetched):
                desktop = fetched
            case .failure(let error):
                throw ClipboardIntentError.failed(error.localizedDescription)
            }
        }

        // Compared on the desktop's own clock, so phone and desktop clocks need
        // not agree. A push bumps the desktop's time too, so text that equals the
        // last synced text is not a desktop change; after an image push the
        // desktop reports empty text, which is never pulled. With no history at
        // all the desktop would always look changed; the phone's clipboard is
        // what the user is holding, so the first sync pushes it.
        let firstSync = lastDesktopChangedAt == 0 && lastText.isEmpty
        let desktopChanged = !firstSync && (desktop.changedAt ?? 0) > lastDesktopChangedAt && desktop.text != lastText
        let phoneChanged = !phoneKey.isEmpty && phoneKey != lastText

        func remember(_ synced: String) {
            defaults.set(synced, forKey: Self.lastTextKey)
            if let changedAt = desktop.changedAt {
                defaults.set(Int(changedAt), forKey: Self.lastDesktopChangedAtKey)
            }
        }

        // No result card: a Done button on every press is more than the action
        // deserves. The direction goes to the app's Bluetooth log.
        let service = await DesktopClipboardService.shared

        if desktopChanged, !desktop.text.isEmpty, desktop.text != text {
            remember(desktop.text)
            await service.clearNotification()
            await ClipboardHistoryStore.shared.addText(desktop.text, source: .remote(service.desktopName()))
            await service.monitor.noteExternal("sync: pulled \(desktop.text.count) chars")
            return .result(value: Self.textFile(desktop.text))
        }

        if phoneChanged, let png {
            switch await ShareSender.send(.clipboardImage(png)) {
            case .success:
                remember(phoneKey)
                await ClipboardHistoryStore.shared.addImage(png, source: .local(service.phoneName()))
                await service.monitor.noteExternal("sync: sent image, \(png.count) bytes")
                return .result(value: clipboard)
            case .failure(let error):
                throw ClipboardIntentError.failed(error.localizedDescription)
            }
        }

        if phoneChanged, desktop.text != text {
            switch await ShareSender.send(.clipboard(text)) {
            case .success:
                remember(text)
                await ClipboardHistoryStore.shared.addText(text, source: .local(service.phoneName()))
                await service.monitor.noteExternal("sync: sent \(text.count) chars")
                return .result(value: clipboard)
            case .failure(let error):
                throw ClipboardIntentError.failed(error.localizedDescription)
            }
        }

        await service.monitor.noteExternal("sync: already in sync")
        if phoneKey.isEmpty {
            remember(desktop.text)
            return .result(value: Self.textFile(desktop.text))
        }
        remember(phoneKey)
        return .result(value: clipboard)
    }

    // The type UIPasteboard reads as a string, so Copy to Clipboard pastes as text.
    private static func textFile(_ text: String) -> IntentFile {
        IntentFile(data: Data(text.utf8), filename: "Clipboard.txt", type: .utf8PlainText)
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
