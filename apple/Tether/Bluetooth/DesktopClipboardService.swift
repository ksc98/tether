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
import UIKit
import UserNotifications

@MainActor
final class DesktopClipboardService: NSObject {
    static let shared = DesktopClipboardService()

    nonisolated static let notificationCategory = "TETHER_DESKTOP_CLIPBOARD"
    nonisolated static let copyAction = "TETHER_COPY"
    nonisolated private static let notificationIdentifier = "desktop-clipboard"
    nonisolated private static let textKey = "text"

    let monitor = DesktopClipboardMonitor()

    // Set by the view model once it exists. Text applied while the app is in
    // front, or copied from a notification, goes through it so the history and
    // the auto-sync setting stay in one place.
    var applyClipboard: ((String) -> Void)?
    var deviceName: (() -> String?)?

    private var notificationsReady = false

    private override init() {
        super.init()
        monitor.onUpdate = { [weak self] update in
            self?.deliver(update)
        }
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
        if UIApplication.shared.applicationState == .active {
            applyClipboard?(update.text)
            return
        }
        post(update)
    }

    private func post(_ update: DesktopClipboardUpdate) {
        requestNotificationPermission()

        let content = UNMutableNotificationContent()
        let name = deviceName?() ?? "Desktop"
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
            applyClipboard?(text)
        }
    }
}
