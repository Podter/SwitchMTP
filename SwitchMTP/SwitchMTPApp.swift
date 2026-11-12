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
        let hasCustomSelectAll = menu.items.contains {
            $0.keyEquivalent.lowercased() == "a"
                && $0.keyEquivalentModifierMask.contains(.command)
                && $0.action != #selector(NSResponder.selectAll(_:))
        }
        for item in menu.items.reversed() {
            if let action = item.action, Self.disallowedMenuSelectors.contains(action) {
                menu.removeItem(item)
            } else if hasCustomSelectAll, item.action == #selector(NSResponder.selectAll(_:)) {
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

struct SwitchMTPCommands: Commands {
    @Bindable var viewModel: MTPViewModel

    var body: some Commands {
        // MARK: - File Menu
        CommandGroup(replacing: .newItem) {
            Button("Open") {
                viewModel.openSelectedItem()
            }
            .keyboardShortcut("o", modifiers: .command)
            .disabled(!viewModel.canOpenSelectedItem)

            Button("Open in Default App") {
                viewModel.openSelectedInDefaultApp()
            }
            .keyboardShortcut("o", modifiers: [.command, .shift])
            .disabled(!viewModel.canOpenSelectedInDefaultApp)

            Button("Quick Look") {
                viewModel.toggleQuickLookSelectedItem()
            }
            .keyboardShortcut("y", modifiers: .command)
            .disabled(!viewModel.canQuickLookSelectedItem)

            Divider()

            Button(viewModel.saveMenuTitle) {
                viewModel.saveSelectedOrAllToDownloads()
            }
            .keyboardShortcut("s", modifiers: .command)
            .disabled(!viewModel.canSaveOrExport)

            Button(viewModel.exportMenuTitle) {
                viewModel.exportSelectedOrAllToFolder()
            }
            .keyboardShortcut("e", modifiers: [.command, .shift])
            .disabled(!viewModel.canSaveOrExport)

            Divider()

            Button("Get Info") {
                viewModel.showInspector.toggle()
            }
            .keyboardShortcut("i", modifiers: .command)

            Button("Reload Device") {
                Task {
                    await viewModel.refresh()
                }
            }
            .keyboardShortcut("r", modifiers: .command)
            .disabled(viewModel.isConnecting)
        }

        // MARK: - Edit Menu
        CommandGroup(replacing: .pasteboard) {
            Button("Cut") {
                NSApp.sendAction(#selector(NSText.cut(_:)), to: nil, from: nil)
            }
            .keyboardShortcut("x", modifiers: .command)
            .disabled(!viewModel.isTextInputFirstResponder)

            Button(viewModel.isTextInputFirstResponder ? "Copy" : "Copy Image") {
                viewModel.performCopyCommand()
            }
            .keyboardShortcut("c", modifiers: .command)
            .disabled(!viewModel.canCopyFromSelectionOrTextField)

            Button("Paste") {
                NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: nil)
            }
            .keyboardShortcut("v", modifiers: .command)
            .disabled(!viewModel.isTextInputFirstResponder)

            Button("Delete") {
                NSApp.sendAction(#selector(NSText.delete(_:)), to: nil, from: nil)
            }
            .disabled(!viewModel.isTextInputFirstResponder)
        }

        CommandGroup(replacing: .textEditing) {
            Button("Select All") {
                viewModel.performSelectAllCommand()
            }
            .keyboardShortcut("a", modifiers: .command)
            .disabled(!viewModel.canSelectAllItems)

            Button("Deselect All") {
                viewModel.clearSelection()
            }
            .keyboardShortcut("a", modifiers: [.command, .option])
            .disabled(viewModel.selectedItemIDs.isEmpty)

            Divider()

            Button("Find…") {
                viewModel.focusSearchField()
            }
            .keyboardShortcut("f", modifiers: .command)
            .disabled(!viewModel.isConnected)
        }

        // MARK: - View Menu
        CommandGroup(before: .toolbar) {
            Picker("View", selection: $viewModel.viewMode) {
                Text("as Grid")
                    .tag(BrowserViewMode.grid)
                    .keyboardShortcut("1", modifiers: .command)

                Text("as List")
                    .tag(BrowserViewMode.table)
                    .keyboardShortcut("2", modifiers: .command)
            }
            .pickerStyle(.inline)

            Divider()

            Menu("Filter By") {
                Picker("Filter By", selection: $viewModel.mediaFilter) {
                    ForEach(MediaTypeFilter.allCases) { filter in
                        Text(filter.rawValue).tag(filter)
                    }
                }
                .pickerStyle(.inline)
            }

            Menu("Sort By") {
                Picker("Sort By", selection: $viewModel.sortOrder) {
                    ForEach(MediaSortOrder.allCases) { order in
                        Text(order.rawValue).tag(order)
                    }
                }
                .pickerStyle(.inline)
            }

            Divider()

            Button("Zoom In") {
                viewModel.zoomInGrid()
            }
            .keyboardShortcut("+", modifiers: .command)
            .disabled(!viewModel.canZoomInGrid)

            Button("Zoom Out") {
                viewModel.zoomOutGrid()
            }
            .keyboardShortcut("-", modifiers: .command)
            .disabled(!viewModel.canZoomOutGrid)

            Button("Actual Size") {
                viewModel.resetGridZoom()
            }
            .keyboardShortcut("0", modifiers: .command)
            .disabled(viewModel.viewMode != .grid || Int(round(viewModel.gridZoom)) == 2)

            Divider()
        }

        SidebarCommands()
        InspectorCommands()

        // MARK: - Go Menu
        CommandMenu("Go") {
            Button("Back") {
                viewModel.navigateBack()
            }
            .keyboardShortcut("[", modifiers: .command)
            .disabled(!viewModel.canGoBack)

            Button("Enclosing Folder") {
                viewModel.navigateToEnclosingFolder()
            }
            .keyboardShortcut(.upArrow, modifiers: .command)
            .disabled(!viewModel.canNavigateToEnclosingFolder)

            Button("Open Selected Item") {
                viewModel.openSelectedItem()
            }
            .keyboardShortcut(.downArrow, modifiers: .command)
            .disabled(!viewModel.canOpenSelectedItem)

            Divider()

            Button("All Media") {
                viewModel.selectedSidebar = .allMedia
            }
            .keyboardShortcut("1", modifiers: [.command, .control])
            .disabled(!viewModel.isConnected)

            Button("Screenshots") {
                viewModel.selectedSidebar = .screenshots
            }
            .keyboardShortcut("2", modifiers: [.command, .control])
            .disabled(!viewModel.isConnected)

            Button("Videos") {
                viewModel.selectedSidebar = .videos
            }
            .keyboardShortcut("3", modifiers: [.command, .control])
            .disabled(!viewModel.isConnected)

            Button("All Games") {
                if let firstStorage = viewModel.storages.first {
                    viewModel.selectedSidebar = .storageRoot(firstStorage.id)
                }
            }
            .keyboardShortcut("4", modifiers: [.command, .control])
            .disabled(!viewModel.isConnected || viewModel.storages.isEmpty)

            Divider()

            Button("Downloads") {
                viewModel.openDownloadsFolderInFinder()
            }
            .keyboardShortcut("l", modifiers: [.command, .option])
        }
    }
}

@main
struct SwitchMTPApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var viewModel = MTPViewModel()

    var body: some Scene {
        Window("SwitchMTP", id: "main") {
            ContentView(viewModel: viewModel)
                .frame(minWidth: 860, minHeight: 540)
        }
        .defaultSize(width: 1120, height: 740)
        .windowToolbarStyle(.unified)
        .commands {
            SwitchMTPCommands(viewModel: viewModel)
        }

        Settings {
            SettingsView()
        }
        .windowResizability(.contentSize)
    }
}
