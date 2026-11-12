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

        guard ProcessInfo.processInfo.environment["XCODE_RUNNING_FOR_PREVIEWS"] != "1" else {
            return
        }

        if let bundleID = Bundle.main.bundleIdentifier {
            let currentPID = ProcessInfo.processInfo.processIdentifier
            let otherInstances = NSRunningApplication
                .runningApplications(withBundleIdentifier: bundleID)
                .filter { $0.processIdentifier != currentPID }

            for instance in otherInstances where instance.activationPolicy != .regular {
                instance.forceTerminate()
            }

            if let existing = otherInstances.first(where: { $0.activationPolicy == .regular && !$0.isTerminated }) {
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
            if window.identifier?.rawValue == "main" {
                window.contentMinSize = NSSize(width: 860, height: 540)
            }
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

nonisolated enum AppSettings {
    static let revealInFinderAfterExportKey = "SwitchMTP.revealInFinderAfterExport"

    static var revealInFinderAfterExport: Bool {
        UserDefaults.standard.bool(forKey: revealInFinderAfterExportKey)
    }
}

struct SettingsView: View {
    @AppStorage(AppSettings.revealInFinderAfterExportKey)
    private var revealInFinderAfterExport = false

    var body: some View {
        Form {
            Section("Exports") {
                Toggle(isOn: $revealInFinderAfterExport) {
                    Text("Reveal exported items in Finder")
                    Text("Automatically show saved or exported files in Finder when a transfer finishes.")
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 440)
        .fixedSize(horizontal: false, vertical: true)
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
            SidebarCommands()
            InspectorCommands()
        }

        Settings {
            SettingsView()
        }
        .windowResizability(.contentSize)
    }
}
