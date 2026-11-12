//
//  SwitchMTPApp.swift
//  SwitchMTP
//
//  Created by Podter on 12/11/26.
//

import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    private static let disallowedMenuSelectors: Set<Selector> = [
        #selector(NSWindow.toggleTabBar(_:)),
        #selector(NSWindow.toggleTabOverview(_:)),
        #selector(NSWindow.selectNextTab(_:)),
        #selector(NSWindow.selectPreviousTab(_:)),
        #selector(NSWindow.moveTabToNewWindow(_:)),
        #selector(NSWindow.mergeAllWindows(_:))
    ]

    override init() {
        super.init()
        NSWindow.allowsAutomaticWindowTabbing = false
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSWindow.allowsAutomaticWindowTabbing = false

        if let bundleID = Bundle.main.bundleIdentifier {
            let currentPID = ProcessInfo.processInfo.processIdentifier
            let otherInstances = NSRunningApplication
                .runningApplications(withBundleIdentifier: bundleID)
                .filter { $0.processIdentifier != currentPID }

            if let existing = otherInstances.first {
                existing.activate()
                NSApp.terminate(nil)
                return
            }
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSWindow.allowsAutomaticWindowTabbing = false
        configureWindowsAndMenus()

        NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeMainNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.configureWindowsAndMenus()
            }
        }
    }

    func applicationDidUpdate(_ notification: Notification) {
        if let mainMenu = NSApp.mainMenu {
            removeTabMenuItems(in: mainMenu)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    private func configureWindowsAndMenus() {
        for window in NSApp.windows {
            window.tabbingMode = .disallowed
        }
        if let mainMenu = NSApp.mainMenu {
            removeTabMenuItems(in: mainMenu)
        }
    }

    private func removeTabMenuItems(in menu: NSMenu) {
        for item in menu.items.reversed() {
            if let action = item.action, Self.disallowedMenuSelectors.contains(action) {
                menu.removeItem(item)
            } else if let submenu = item.submenu {
                removeTabMenuItems(in: submenu)
            }
        }
    }
}

@main
struct SwitchMTPApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Window("SwitchMTP", id: "main") {
            ContentView()
                .frame(minWidth: 860, minHeight: 540)
        }
        .defaultSize(width: 1120, height: 740)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}
