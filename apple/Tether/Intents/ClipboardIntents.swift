//
//  ClipboardIntents.swift
//  Tether
//
//  Shortcuts actions for clipboard sync that run with the app in the background.
//
//  iOS gives a backgrounded app no access to UIPasteboard, so neither action
//  touches it. The shortcut moves the text across that boundary instead:
//
//    Phone → desktop:  Get Clipboard  →  Send to Desktop Clipboard
//    Desktop → phone:  Get Desktop Clipboard  →  Copy to Clipboard
//    Either way:       Get Clipboard  →  Sync Clipboard  →  Copy to Clipboard
//

import AppIntents
import TetherFramework

struct SendToDesktopClipboardIntent: AppIntent {
    static let title: LocalizedStringResource = "Send to Desktop Clipboard"
    static let description = IntentDescription(
        "Sets the clipboard of your paired Linux desktop to the given text, without opening Tether.",
        categoryName: "Clipboard"
    )
    static let openAppWhenRun = false

    @Parameter(title: "Text", inputOptions: String.IntentInputOptions(multiline: true))
    var text: String

    static var parameterSummary: some ParameterSummary {
        Summary("Send \(\.$text) to the desktop clipboard")
    }

    func perform() async throws -> some IntentResult {
        guard !text.isEmpty else { throw ClipboardIntentError.emptyText }

        switch await ShareSender.send(.clipboard(text)) {
        case .success:
            return .result()
        case .failure(let error):
            throw ClipboardIntentError.failed(error.localizedDescription)
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
//   2. Otherwise the phone's text differs from what was last synced: push it.
//   3. Otherwise there is nothing to do.
//
// The result is always the text the phone's clipboard should hold, so the
// shortcut can end with Copy to Clipboard unconditionally.
struct SyncClipboardIntent: AppIntent {
    static let title: LocalizedStringResource = "Sync Clipboard"
    static let description = IntentDescription(
        "Sends this text to the desktop when it is the newer copy, or returns the desktop clipboard when that changed more recently. Follow with Copy to Clipboard.",
        categoryName: "Clipboard"
    )
    static let openAppWhenRun = false

    @Parameter(title: "Text", inputOptions: String.IntentInputOptions(multiline: true))
    var text: String

    static var parameterSummary: some ParameterSummary {
        Summary("Sync \(\.$text) with the desktop clipboard")
    }

    private static let lastDesktopChangedAtKey = "TetherSyncLastDesktopChangedAt"
    private static let lastTextKey = "TetherSyncLastText"

    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let defaults = UserDefaults.standard
        let lastDesktopChangedAt = Int64(defaults.integer(forKey: Self.lastDesktopChangedAtKey))
        let lastText = defaults.string(forKey: Self.lastTextKey) ?? ""

        let desktop: ShareSender.DesktopClipboard
        switch await ShareSender.fetchClipboard() {
        case .success(let fetched):
            desktop = fetched
        case .failure(let error):
            throw ClipboardIntentError.failed(error.localizedDescription)
        }

        // Compared on the desktop's own clock, so phone and desktop clocks need
        // not agree. A push bumps the desktop's time too, so text that equals the
        // last synced text is not a desktop change. With no history at all the
        // desktop would always look changed; the phone's text is what the user
        // is holding, so the first sync pushes it.
        let firstSync = lastDesktopChangedAt == 0 && lastText.isEmpty
        let desktopChanged = !firstSync && (desktop.changedAt ?? 0) > lastDesktopChangedAt && desktop.text != lastText
        let phoneChanged = !text.isEmpty && text != lastText

        func remember(_ synced: String) {
            defaults.set(synced, forKey: Self.lastTextKey)
            if let changedAt = desktop.changedAt {
                defaults.set(Int(changedAt), forKey: Self.lastDesktopChangedAtKey)
            }
        }

        if desktopChanged, !desktop.text.isEmpty, desktop.text != text {
            remember(desktop.text)
            return .result(value: desktop.text, dialog: "Pulled from the desktop")
        }

        if phoneChanged, desktop.text != text {
            switch await ShareSender.send(.clipboard(text)) {
            case .success:
                remember(text)
                return .result(value: text, dialog: "Sent to the desktop")
            case .failure(let error):
                throw ClipboardIntentError.failed(error.localizedDescription)
            }
        }

        remember(text.isEmpty ? desktop.text : text)
        return .result(value: text.isEmpty ? desktop.text : text, dialog: "Already in sync")
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
