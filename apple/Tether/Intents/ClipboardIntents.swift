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
        case .success(let text):
            return .result(value: text)
        case .failure(let error):
            throw ClipboardIntentError.failed(error.localizedDescription)
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
