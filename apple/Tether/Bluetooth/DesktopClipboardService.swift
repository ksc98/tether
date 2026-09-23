//
//  DesktopClipboardService.swift
//  Tether
//
//  Turns desktop clipboard changes that arrive over Bluetooth into either a
//  pasteboard write (app in front) or a notification with a Copy action (app in
//  the background, where iOS refuses pasteboard writes). Lives for the process
//  so a background relaunch by CoreBluetooth has somewhere to deliver to before
//  any view exists.
//

import Foundation
import TetherFramework
import UIKit
import UserNotifications

@MainActor
final class DesktopClipboardService: NSObject {
    static let shared = DesktopClipboardService()

    nonisolated static let notificationCategory = "TETHER_DESKTOP_CLIPBOARD"
    nonisolated static let copyAction = "TETHER_COPY"
    nonisolated private static let notificationIdentifier = "desktop-clipboard"
    nonisolated private static let textKey = "text"
    nonisolated private static let notifyKey = "TetherNotifyOnDesktopCopy"

    // Whether a desktop copy that arrives in the background shows a
    // notification. Off by default: the Sync Clipboard shortcut pulls the
    // stored copy on demand, so a notification per copy is noise.
    var notifyOnDesktopCopy: Bool {
        get { UserDefaults.standard.bool(forKey: Self.notifyKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.notifyKey) }
    }

    let monitor = DesktopClipboardMonitor()

    // Set by the view model once a view exists. A background relaunch by
    // CoreBluetooth never shows a view, so both may be nil when a write or a
    // notification tap arrives; nothing here depends on them.
    // In-front delivery: the view model records history and applies the
    // auto-sync setting.
    var applyClipboard: ((String) -> Void)?
    // A tapped notification: the view model records history. The pasteboard
    // write is done here.
    var noteTapped: ((String) -> Void)?
    var deviceName: (() -> String?)?

    private var notificationsReady = false

    // Text from a tapped notification, waiting for the app to become active:
    // iOS drops pasteboard writes made during the foreground transition.
    private var pendingTapText: String?

    private override init() {
        super.init()
        monitor.onUpdate = { [weak self] update in
            self?.deliver(update)
        }
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applicationDidBecomeActive),
            name: UIApplication.didBecomeActiveNotification,
            object: nil
        )
    }

    @objc private func applicationDidBecomeActive() {
        guard let text = pendingTapText else { return }
        pendingTapText = nil
        writePasteboard(text)
    }

    private func writePasteboard(_ text: String) {
        UIPasteboard.general.string = text
        monitor.noteExternal("pasteboard set, \(text.count) chars")
    }

    // The desktop's name for the notification title, from the view model when
    // a view exists, else from the pairing store.
    private func desktopName() -> String {
        if let name = deviceName?() { return name }
        let certificates = CertificateManager()
        certificates.initialize()
        if let fingerprint = certificates.lastConnectedFingerprint,
           let name = certificates.knownHosts[fingerprint] {
            return name
        }
        return "Desktop"
    }

    // From the app delegate, at every launch.
    func launch() {
        UNUserNotificationCenter.current().delegate = self
        monitor.launch()
    }

    func setEnabled(_ enabled: Bool) {
        monitor.setEnabled(enabled)
        if enabled {
            requestNotificationPermission()
        }
    }

    private func requestNotificationPermission() {
        guard !notificationsReady else { return }
        notificationsReady = true

        let copy = UNNotificationAction(identifier: Self.copyAction, title: "Copy", options: [.foreground])
        let category = UNNotificationCategory(
            identifier: Self.notificationCategory,
            actions: [copy],
            intentIdentifiers: [],
            options: []
        )
        let center = UNUserNotificationCenter.current()
        center.setNotificationCategories([category])
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    private func deliver(_ update: DesktopClipboardUpdate) {
        // Always kept, so the Sync Clipboard shortcut can pull it without Wi-Fi.
        DesktopClipboardCache.store(update)

        let state = UIApplication.shared.applicationState
        monitor.noteExternal("deliver: app state \(state.rawValue), view model \(applyClipboard == nil ? "absent" : "attached")")
        if state == .active, let applyClipboard {
            applyClipboard(update.text)
            return
        }
        if notifyOnDesktopCopy {
            post(update)
        }
    }

    // Drops the notification for a copy the shortcut has since pulled.
    func clearNotification() {
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [Self.notificationIdentifier])
    }

    private func post(_ update: DesktopClipboardUpdate) {
        requestNotificationPermission()

        let content = UNMutableNotificationContent()
        let name = desktopName()
        content.title = update.complete ? "Copied on \(name)" : "Copied on \(name) (excerpt)"
        content.body = Self.preview(of: update.text)
        content.categoryIdentifier = Self.notificationCategory
        content.threadIdentifier = Self.notificationIdentifier
        content.userInfo = [Self.textKey: update.text]
        content.interruptionLevel = .timeSensitive

        // One identifier, so the newest copy replaces the previous notification
        // instead of stacking up.
        let request = UNNotificationRequest(identifier: Self.notificationIdentifier, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    private static func preview(of text: String) -> String {
        let flattened = text
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return flattened.count > 200 ? String(flattened.prefix(200)) + "…" : flattened
    }
}

extension DesktopClipboardService: UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification) async
        -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse) async {
        let text = response.notification.request.content.userInfo[Self.textKey] as? String
        let action = response.actionIdentifier
        await MainActor.run {
            // Both the Copy button and a plain tap bring the app to the front,
            // which is what makes the pasteboard writable.
            guard let text,
                  action == Self.copyAction || action == UNNotificationDefaultActionIdentifier else { return }
            let state = UIApplication.shared.applicationState
            monitor.noteExternal("notification tapped, \(text.count) chars, app state \(state.rawValue)")
            noteTapped?(text)
            if state == .active {
                writePasteboard(text)
            } else {
                pendingTapText = text
            }
        }
    }
}

// The last desktop copy that arrived over Bluetooth. `seq` is the desktop's
// clock in milliseconds at the copy, the same clock as `changed_at` in
// `clipboard_content`, so the shortcut can compare the two directly.
enum DesktopClipboardCache {
    private static let textKey = "TetherDesktopCacheText"
    private static let seqKey = "TetherDesktopCacheSeq"
    private static let completeKey = "TetherDesktopCacheComplete"

    struct Entry {
        let text: String
        let seq: Int64
        let complete: Bool
    }

    static func store(_ update: DesktopClipboardUpdate) {
        let defaults = UserDefaults.standard
        defaults.set(update.text, forKey: textKey)
        defaults.set(Int(update.seq), forKey: seqKey)
        defaults.set(update.complete, forKey: completeKey)
    }

    static func load() -> Entry? {
        let defaults = UserDefaults.standard
        guard let text = defaults.string(forKey: textKey), defaults.object(forKey: seqKey) != nil else { return nil }
        return Entry(text: text, seq: Int64(defaults.integer(forKey: seqKey)), complete: defaults.bool(forKey: completeKey))
    }
}
