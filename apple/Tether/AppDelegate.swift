//
//  AppDelegate.swift
//  Tether
//
//  Process-level launch hooks. CoreBluetooth relaunches the app in the
//  background for a clipboard notification, with no scene; the central and the
//  notification delegate have to be back before that state is restored.
//

import UIKit

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        DesktopClipboardService.shared.launch()
        return true
    }
}
