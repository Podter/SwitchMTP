//
//  ContentView.swift
//  SwitchMTP
//
//  Created by Podter on 12/11/26.
//

import SwiftUI
import AppKit
import AVKit

struct ContentView: View {
    @State private var viewModel: MTPViewModel
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    init(initialInspectorOpen: Bool = false) {
        let vm = MTPViewModel()
        vm.showInspector = initialInspectorOpen
        _viewModel = State(initialValue: vm)
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView(viewModel: viewModel)
                .navigationSplitViewColumnWidth(min: 190, ideal: 220, max: 260)
        } detail: {
            MainBrowserPane(viewModel: viewModel)
                .frame(minWidth: viewModel.showInspector ? 420 : 660, minHeight: 540)
                .navigationSplitViewColumnWidth(min: 420, ideal: 680)
                .sheet(item: $viewModel.fullScreenPreviewItem) { item in
                    MediaLightboxSheet(viewModel: viewModel, item: item)
                }
                .inspector(isPresented: $viewModel.showInspector) {
                    InspectorPane(viewModel: viewModel)
                        .inspectorColumnWidth(min: 240, ideal: 265, max: 320)
                }
                .navigationTitle(windowTitle)
                .navigationSubtitle(windowSubtitle)
        }
    }

    private var windowTitle: String {
        if let lastCrumb = viewModel.breadcrumbs.last {
            return lastCrumb.title
        }
        if let selected = viewModel.selectedSidebar {
            switch selected {
            case .allMedia:
                return "All Media"
            case .screenshots:
                return "Screenshots"
            case .videos:
                return "Videos"
            case .storageRoot:
                return "All Games"
            case .gameFolder:
                break
            }
        }
        return viewModel.deviceDetails?.displayName ?? "SwitchMTP"
    }

    private var windowSubtitle: String {
        guard viewModel.isConnected else { return "Not Connected" }
        let count = viewModel.filteredAndSortedItems.count
        let selCount = viewModel.selectedItemIDs.count
        if selCount > 0 {
            return "\(selCount) of \(count) selected"
        }
        return "\(count) item\(count == 1 ? "" : "s")"
    }
}

// MARK: - Toolbar Subviews (Isolated Observation Scopes)

private struct ToolbarBackButton: View {
    var viewModel: MTPViewModel

    var body: some View {
        Button {
            viewModel.navigateBack()
        } label: {
            Label("Back", systemImage: "chevron.left")
        }
        .disabled(!viewModel.canGoBack)
        .help(backHelpText)
    }

    private var backHelpText: String {
        guard viewModel.breadcrumbs.count > 1 else {
            return "Go Back"
        }
        return "Go back to \(viewModel.breadcrumbs[viewModel.breadcrumbs.count - 2].title)"
    }
}

private struct ToolbarLoadingIndicator: View {
    var viewModel: MTPViewModel

    var body: some View {
        ZStack {
            if viewModel.isWorking {
                ProgressView()
                    .controlSize(.small)
                    .help("Loading media from Nintendo Switch…")
            }
        }
        .frame(width: 20, height: 20)
    }
}

private struct ToolbarViewModePicker: View {
    @Bindable var viewModel: MTPViewModel

    var body: some View {
        Picker("View", selection: $viewModel.viewMode) {
            Label("Icons", systemImage: "square.grid.2x2")
                .tag(BrowserViewMode.grid)
            Label("List", systemImage: "list.bullet")
                .tag(BrowserViewMode.table)
        }
        .pickerStyle(.segmented)
        .help("Change how items are shown")
    }
}

private struct ToolbarFilterSortMenu: View {
    @Bindable var viewModel: MTPViewModel

    var body: some View {
        Menu {
            Picker("Filter", selection: $viewModel.mediaFilter) {
                ForEach(MediaTypeFilter.allCases) { filter in
                    Text(filter.rawValue).tag(filter)
                }
            }
            .pickerStyle(.inline)

            Divider()

            Picker("Sort By", selection: $viewModel.sortOrder) {
                ForEach(MediaSortOrder.allCases) { order in
                    Text(order.rawValue).tag(order)
                }
            }
            .pickerStyle(.inline)

            if viewModel.viewMode == .grid {
                Divider()
                Menu("Thumbnail Size") {
                    Button("Small") { viewModel.gridZoom = 1 }
                    Button("Medium") { viewModel.gridZoom = 2 }
                    Button("Large") { viewModel.gridZoom = 3 }
                }
            }

            Divider()

            Button {
                Task { await viewModel.refresh() }
            } label: {
                Label("Reload Device", systemImage: "arrow.clockwise")
            }
            .keyboardShortcut("r", modifiers: .command)
            .disabled(viewModel.isConnecting)
        } label: {
            Label("Filter & Sort", systemImage: "line.3.horizontal.decrease.circle")
        }
        .help("Filter, sort, and view options")
    }
}

private struct ToolbarExportMenu: View {
    var viewModel: MTPViewModel

    var body: some View {
        let selectedCount = viewModel.selectedItemIDs.count
        let hasItems = !viewModel.filteredAndSortedItems.isEmpty

        Menu {
            Button {
                if !viewModel.selectedItems.isEmpty {
                    viewModel.quickSaveToDownloads(viewModel.selectedItems)
                } else {
                    let visibleMedia = viewModel.filteredAndSortedItems.filter { !$0.isFolder }
                    viewModel.quickSaveToDownloads(visibleMedia)
                }
            } label: {
                Label(
                    selectedCount == 0
                        ? "Save All to Downloads"
                        : "Save \(selectedCount) Selected to Downloads",
                    systemImage: "arrow.down.circle"
                )
            }

            Button {
                if !viewModel.selectedItems.isEmpty {
                    viewModel.promptAndExportItems(viewModel.selectedItems)
                } else {
                    viewModel.promptAndExportAllVisible()
                }
            } label: {
                Label(
                    selectedCount == 0
                        ? "Export All to Folder…"
                        : "Export \(selectedCount) Selected to Folder…",
                    systemImage: "folder"
                )
            }
        } label: {
            Label("Export", systemImage: "arrow.down.circle")
        }
        .disabled(!viewModel.isConnected || !hasItems)
        .help("Save to Downloads or export to a folder")
    }
}

private struct ToolbarInspectorButton: View {
    var viewModel: MTPViewModel

    var body: some View {
        Button {
            viewModel.showInspector.toggle()
        } label: {
            Label("Inspector", systemImage: "sidebar.trailing")
        }
        .keyboardShortcut("i", modifiers: .command)
        .help("Show or hide Inspector (⌘I)")
    }
}

private struct ToolbarSearchField: View {
    @Bindable var viewModel: MTPViewModel
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)

            TextField("Search", text: $viewModel.searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused($isFocused)

            if !viewModel.searchText.isEmpty {
                Button {
                    viewModel.searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Clear search")
            }
        }
        .padding(.horizontal, 10)
        .frame(width: 168, height: 28)
    }
}

// MARK: - Sidebar

private struct SidebarView: View {
    @Bindable var viewModel: MTPViewModel
    @State private var showDeviceInfo = false

    var body: some View {
        VStack(spacing: 0) {
            List(selection: $viewModel.selectedSidebar) {
                Section("Library") {
                    NavigationLink(value: SidebarDestination.allMedia) {
                        Label("All Media", systemImage: "photo.on.rectangle")
                            .badge(viewModel.allMediaItems.count)
                    }

                    NavigationLink(value: SidebarDestination.screenshots) {
                        Label("Screenshots", systemImage: "camera.viewfinder")
                            .badge(viewModel.hasLoadedAllMedia ? viewModel.allScreenshotsCount : 0)
                    }

                    NavigationLink(value: SidebarDestination.videos) {
                        Label("Videos", systemImage: "video")
                            .badge(viewModel.hasLoadedAllMedia ? viewModel.allVideosCount : 0)
                    }

                    if let primaryStorage = viewModel.storages.first {
                        NavigationLink(value: SidebarDestination.storageRoot(primaryStorage.id)) {
                            Label("All Games", systemImage: "square.grid.2x2")
                                .badge(viewModel.rootFolders.count)
                        }
                    }
                }

                if !viewModel.rootFolders.isEmpty {
                    Section("Games") {
                        ForEach(viewModel.rootFolders) { folder in
                            NavigationLink(value: SidebarDestination.gameFolder(folder.handle)) {
                                Label(folder.filename, systemImage: "folder")
                                    .lineLimit(1)
                                    .badge(folder.childCount ?? 0)
                            }
                            .contextMenu {
                                Button {
                                    viewModel.quickSaveToDownloads([folder])
                                } label: {
                                    Label("Save to Downloads", systemImage: "arrow.down.circle")
                                }

                                Button {
                                    viewModel.promptAndExportFolders([folder])
                                } label: {
                                    Label("Export Folder…", systemImage: "folder")
                                }
                            }
                        }
                    }
                }
            }
            .listStyle(.sidebar)

            DeviceStatusFooter(viewModel: viewModel, showDeviceInfo: $showDeviceInfo)
        }
    }
}

private struct DeviceStatusFooter: View {
    var viewModel: MTPViewModel
    @Binding var showDeviceInfo: Bool
    @State private var isHovering = false

    var body: some View {
        Button {
            if viewModel.isConnected {
                showDeviceInfo.toggle()
            } else if !viewModel.isConnecting {
                Task { await viewModel.connectToDevice() }
            }
        } label: {
            HStack(spacing: 10) {
                ZStack(alignment: .bottomTrailing) {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(viewModel.isConnected ? Color.accentColor.opacity(0.14) : Color.primary.opacity(0.06))
                        .frame(width: 28, height: 28)
                        .overlay {
                            Image(systemName: "gamecontroller.fill")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(viewModel.isConnected ? Color.accentColor : .secondary)
                        }

                    Circle()
                        .fill(statusColor)
                        .frame(width: 8, height: 8)
                        .overlay {
                            Circle()
                                .strokeBorder(Color(nsColor: .windowBackgroundColor), lineWidth: 1.5)
                        }
                        .offset(x: 2, y: 2)
                }

                VStack(alignment: .leading, spacing: 1) {
                    Text(statusTitle)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(viewModel.isConnected ? .primary : .secondary)
                        .lineLimit(1)

                    Text(statusSubtitle)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 4)

                if viewModel.isConnected {
                    Image(systemName: "info.circle")
                        .font(.system(size: 13, weight: .regular))
                        .foregroundStyle(isHovering ? .primary : .secondary)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(.quaternary.opacity(isHovering ? 0.55 : 0.35))
                    .overlay {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(.primary.opacity(0.07), lineWidth: 0.5)
                    }
            }
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 10)
        .padding(.top, 4)
        .padding(.bottom, 8)
        .onHover { hovering in
            isHovering = hovering
        }
        .help(viewModel.isConnected ? "Show Nintendo Switch details" : "Connect to Nintendo Switch")
        .popover(isPresented: $showDeviceInfo, arrowEdge: .top) {
            if let details = viewModel.deviceDetails {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 8) {
                        Image(systemName: "gamecontroller.fill")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.green)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(details.displayName)
                                .font(.headline)
                            Text(viewModel.totalMediaCountSummary)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Divider()

                    Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 5) {
                        if !details.deviceVersion.isEmpty {
                            GridRow {
                                Text("Firmware")
                                    .foregroundStyle(.secondary)
                                Text(details.deviceVersion)
                            }
                        }
                        if !details.serialNumber.isEmpty {
                            GridRow {
                                Text("Serial")
                                    .foregroundStyle(.secondary)
                                Text(details.serialNumber)
                                    .monospaced()
                            }
                        }
                        GridRow {
                            Text("USB ID")
                                .foregroundStyle(.secondary)
                            Text(String(format: "%04X:%04X", details.vendorID, details.productID))
                                .monospaced()
                        }
                    }
                    .font(.caption)
                    .textSelection(.enabled)
                }
                .padding(14)
                .frame(minWidth: 210)
            }
        }
    }

    private var statusColor: Color {
        if viewModel.isConnected { return .green }
        if viewModel.isConnecting { return .orange }
        return .secondary.opacity(0.5)
    }

    private var statusTitle: String {
        if viewModel.isConnected {
            return viewModel.deviceDetails?.displayName ?? "Nintendo Switch"
        }
        return "Nintendo Switch"
    }

    private var statusSubtitle: String {
        if viewModel.isConnected {
            return "Connected"
        }
        if viewModel.isConnecting {
            return "Connecting…"
        }
        return "Not Connected"
    }
}

// MARK: - Main Browser Area

private struct MainBrowserPane: View {
    @Bindable var viewModel: MTPViewModel

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                if !viewModel.isConnected {
                    DisconnectedPlaceholderView(viewModel: viewModel)
                } else if viewModel.isLoadingDirectory && viewModel.currentItems.isEmpty {
                    VStack(spacing: 10) {
                        ProgressView()
                        Text(viewModel.isScanningAllMedia ? "Loading album…" : "Loading…")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if viewModel.filteredAndSortedItems.isEmpty {
                    ContentUnavailableView {
                        Label("No Media", systemImage: "photo.on.rectangle")
                    } description: {
                        if !viewModel.searchText.isEmpty {
                            Text("No items match \"\(viewModel.searchText)\".")
                        } else if viewModel.mediaFilter != .all {
                            Text("No \(viewModel.mediaFilter.rawValue.lowercased()) in this view.")
                        } else {
                            Text("This folder is empty.")
                        }
                    }
                } else {
                    switch viewModel.viewMode {
                    case .grid:
                        MediaGridView(viewModel: viewModel)
                    case .table:
                        MediaTableView(viewModel: viewModel)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if let errorMessage = viewModel.errorMessage, viewModel.isConnected {
                Divider()
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(errorMessage)
                        .font(.callout)
                        .lineLimit(1)
                    Spacer()
                    Button("Dismiss") {
                        viewModel.errorMessage = nil
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(.bar)
            }

            if viewModel.isConnected {
                BottomStatusBar(viewModel: viewModel)
            }
        }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                ToolbarBackButton(viewModel: viewModel)
            }
            .visibilityPriority(.high)

            ToolbarItem(placement: .primaryAction) {
                ToolbarLoadingIndicator(viewModel: viewModel)
            }
            .sharedBackgroundVisibility(.hidden)
            .visibilityPriority(.high)

            ToolbarItem(placement: .primaryAction) {
                ToolbarViewModePicker(viewModel: viewModel)
            }
            .visibilityPriority(.high)

            ToolbarSpacer(.fixed, placement: .primaryAction)

            ToolbarItem(placement: .primaryAction) {
                ToolbarFilterSortMenu(viewModel: viewModel)
            }
            .visibilityPriority(.high)

            ToolbarSpacer(.fixed, placement: .primaryAction)

            ToolbarItem(placement: .primaryAction) {
                ToolbarExportMenu(viewModel: viewModel)
            }
            .visibilityPriority(.high)

            ToolbarSpacer(.fixed, placement: .primaryAction)

            ToolbarItem(placement: .primaryAction) {
                ToolbarSearchField(viewModel: viewModel)
            }
            .visibilityPriority(.high)

            ToolbarSpacer(.fixed, placement: .primaryAction)

            ToolbarItem(placement: .primaryAction) {
                ToolbarInspectorButton(viewModel: viewModel)
            }
            .visibilityPriority(.high)
        }
    }
}

// MARK: - Grid View

private struct MediaGridView: View {
    @Bindable var viewModel: MTPViewModel
    @State private var containerWidth: CGFloat = 880

    var body: some View {
        let spacing: CGFloat = 16
        let horizontalPadding: CGFloat = 20
        let innerWidth = max(320, containerWidth - horizontalPadding * 2)
        let zoomStep = max(0, min(4, Int(round(viewModel.gridZoom))))
        let columnCount = max(2, 6 - zoomStep)
        let itemWidth = max(80, floor((innerWidth - CGFloat(columnCount - 1) * spacing) / CGFloat(columnCount)))
        let thumbHeight = floor(itemWidth * 9.0 / 16.0)
        let columns = Array(
            repeating: GridItem(.flexible(minimum: 80, maximum: .infinity), spacing: spacing, alignment: .top),
            count: columnCount
        )
        let showGameTag = viewModel.selectedSidebar == .allMedia
            || viewModel.selectedSidebar == .screenshots
            || viewModel.selectedSidebar == .videos

        ScrollView {
            LazyVGrid(columns: columns, alignment: .leading, spacing: spacing) {
                ForEach(viewModel.filteredAndSortedItems) { item in
                    MediaGridCard(
                        item: item,
                        thumbnail: viewModel.thumbnails[item.handle],
                        isSelected: viewModel.selectedItemIDs.contains(item.handle),
                        showGameTag: showGameTag,
                        thumbHeight: thumbHeight,
                        onPlay: { viewModel.openItem(item) }
                    )
                    .onAppear {
                        viewModel.requestThumbnailIfNeeded(for: item)
                    }
                    .onTapGesture(count: 2) {
                        viewModel.openItem(item)
                    }
                    .simultaneousGesture(
                        TapGesture(count: 1).onEnded {
                            let flags = NSEvent.modifierFlags
                            if flags.contains(.command) {
                                if viewModel.selectedItemIDs.contains(item.handle) {
                                    viewModel.selectedItemIDs.remove(item.handle)
                                } else {
                                    viewModel.selectedItemIDs.insert(item.handle)
                                }
                            } else {
                                viewModel.selectedItemIDs = [item.handle]
                            }
                        }
                    )
                    .contextMenu {
                        ItemContextMenu(viewModel: viewModel, item: item)
                    }
                }
            }
            .padding(horizontalPadding)
            .animation(.snappy(duration: 0.2), value: columnCount)
        }
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.width
        } action: { newWidth in
            if abs(newWidth - containerWidth) > 0.5 {
                containerWidth = newWidth
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
        .onExitCommand {
            viewModel.clearSelection()
        }
    }
}

private struct MediaGridCard: View {
    let item: MTPObjectItem
    let thumbnail: NSImage?
    let isSelected: Bool
    let showGameTag: Bool
    let thumbHeight: CGFloat
    let onPlay: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .bottomTrailing) {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.primary.opacity(0.05))
                    .frame(maxWidth: .infinity)
                    .frame(height: thumbHeight)
                    .overlay {
                        if item.isFolder {
                            Image(systemName: "folder.fill")
                                .font(.system(size: 38))
                                .foregroundStyle(.tint)
                        } else if let thumbnail {
                            Image(nsImage: thumbnail)
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                                .frame(maxWidth: .infinity)
                                .frame(height: thumbHeight)
                        } else {
                            Image(systemName: item.isVideo ? "video.fill" : "photo.fill")
                                .font(.system(size: 24))
                                .foregroundStyle(.quaternary)
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(
                                isSelected ? Color.accentColor : Color.primary.opacity(0.08),
                                lineWidth: isSelected ? 3 : 1
                            )
                    )

                if item.isVideo {
                    Button(action: onPlay) {
                        Image(systemName: "play.fill")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(7)
                            .background(.ultraThinMaterial, in: Circle())
                            .environment(\.colorScheme, .dark)
                    }
                    .buttonStyle(.plain)
                    .padding(6)
                    .help("Play Video")
                }
            }

            VStack(alignment: .leading, spacing: 1) {
                Text(primaryLabel)
                    .font(.subheadline)
                    .fontWeight(isSelected ? .medium : .regular)
                    .foregroundStyle(isSelected ? Color.accentColor : .primary)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Text(secondaryLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    private var primaryLabel: String {
        if item.isFolder {
            return item.filename
        }
        if showGameTag && !item.folderName.isEmpty {
            return item.folderName
        }
        if !item.formattedDate.isEmpty {
            return item.formattedDate
        }
        return item.filename
    }

    private var secondaryLabel: String {
        if item.isFolder {
            if let count = item.childCount {
                return "\(count) item\(count == 1 ? "" : "s")"
            }
            return "Folder"
        }
        if showGameTag && !item.formattedDate.isEmpty {
            return item.formattedDate
        }
        return item.formattedSize
    }
}

// MARK: - Table View

private struct MediaTableView: View {
    @Bindable var viewModel: MTPViewModel

    var body: some View {
        Table(viewModel.filteredAndSortedItems, selection: $viewModel.selectedItemIDs) {
            TableColumn("Name") { item in
                HStack(spacing: 10) {
                    if item.isFolder {
                        Image(systemName: "folder.fill")
                            .foregroundStyle(.tint)
                            .frame(width: 32, height: 18)
                    } else if let thumb = viewModel.thumbnails[item.handle] {
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .fill(Color.primary.opacity(0.05))
                            .frame(width: 32, height: 18)
                            .overlay {
                                Image(nsImage: thumb)
                                    .resizable()
                                    .aspectRatio(contentMode: .fit)
                            }
                            .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
                    } else {
                        Image(systemName: item.isVideo ? "video.fill" : "photo.fill")
                            .foregroundStyle(.secondary)
                            .frame(width: 32, height: 18)
                            .onAppear {
                                viewModel.requestThumbnailIfNeeded(for: item)
                            }
                    }
                    Text(item.filename)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .width(min: 180, ideal: 260)

            TableColumn("Game") { item in
                Text(item.isFolder ? "—" : (item.folderName.isEmpty ? "—" : item.folderName))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .width(min: 120, ideal: 180)

            TableColumn("Date") { item in
                if !item.formattedDate.isEmpty {
                    Text(item.formattedDate)
                        .foregroundStyle(.secondary)
                } else {
                    Text("—")
                        .foregroundStyle(.tertiary)
                }
            }
            .width(min: 120, ideal: 150)

            TableColumn("Kind") { item in
                Text(item.kindDescription)
                    .foregroundStyle(.secondary)
            }
            .width(min: 80, ideal: 110)

            TableColumn("Size") { item in
                Text(item.formattedSize)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .width(min: 70, ideal: 90)
        }
        .contextMenu(forSelectionType: UInt32.self) { handles in
            let items = viewModel.filteredAndSortedItems.filter { handles.contains($0.handle) }
            if let first = items.first, items.count == 1 {
                ItemContextMenu(viewModel: viewModel, item: first)
            } else if !items.isEmpty {
                Button {
                    viewModel.quickSaveToDownloads(items)
                } label: {
                    Label("Save \(items.count) Items to Downloads", systemImage: "arrow.down.circle")
                }
                Button {
                    viewModel.promptAndExportItems(items)
                } label: {
                    Label("Export \(items.count) Items…", systemImage: "folder")
                }
            }
        } primaryAction: { handles in
            if let firstHandle = handles.first,
               let item = viewModel.filteredAndSortedItems.first(where: { $0.handle == firstHandle }) {
                viewModel.openItem(item)
            }
        }
    }
}

private struct ItemContextMenu: View {
    var viewModel: MTPViewModel
    let item: MTPObjectItem

    var body: some View {
        if item.isFolder {
            Button {
                viewModel.openItem(item)
            } label: {
                Label("Open", systemImage: "folder")
            }
            Divider()
            Button {
                viewModel.quickSaveToDownloads([item])
            } label: {
                Label("Save to Downloads", systemImage: "arrow.down.circle")
            }
            Button {
                viewModel.promptAndExportFolders([item])
            } label: {
                Label("Export Folder…", systemImage: "folder.badge.plus")
            }
        } else {
            Button {
                viewModel.openItem(item)
            } label: {
                Label(item.isVideo ? "Play Video" : "Quick Look", systemImage: item.isVideo ? "play" : "eye")
            }
            Button {
                viewModel.openInQuickLookOrDefaultApp(item)
            } label: {
                Label("Open in Default App", systemImage: "arrow.up.forward.app")
            }
            Divider()
            if item.isImage {
                Button {
                    viewModel.copyImageToClipboard(item)
                } label: {
                    Label("Copy Image", systemImage: "doc.on.doc")
                }
            }
            Button {
                viewModel.quickSaveToDownloads([item])
            } label: {
                Label("Save to Downloads", systemImage: "arrow.down.circle")
            }
            Button {
                viewModel.promptAndExportItems([item])
            } label: {
                Label("Export…", systemImage: "folder")
            }
        }
        Divider()
        Button {
            viewModel.selectedItemIDs = [item.handle]
            viewModel.showInspector = true
        } label: {
            Label("Get Info", systemImage: "info.circle")
        }
    }
}

// MARK: - Inspector Pane

private struct InspectorPane: View {
    @Bindable var viewModel: MTPViewModel
    @State private var showTechnicalDetails = false

    var body: some View {
        Group {
            if let item = viewModel.inspectedItem {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color.primary.opacity(0.06))
                            .aspectRatio(16.0 / 9.0, contentMode: .fit)
                            .overlay {
                                if item.isFolder {
                                    Image(systemName: "folder.fill")
                                        .font(.system(size: 44))
                                        .foregroundStyle(.tint)
                                } else if let preview = viewModel.previewImage ?? viewModel.thumbnails[item.handle] {
                                    Image(nsImage: preview)
                                        .resizable()
                                        .aspectRatio(contentMode: .fit)
                                        .overlay {
                                            if item.isVideo {
                                                Button {
                                                    viewModel.fullScreenPreviewItem = item
                                                } label: {
                                                    Image(systemName: "play.circle.fill")
                                                        .font(.system(size: 36))
                                                        .foregroundStyle(.white)
                                                        .shadow(radius: 4)
                                                }
                                                .buttonStyle(.plain)
                                            }
                                        }
                                        .onTapGesture(count: 2) {
                                            viewModel.fullScreenPreviewItem = item
                                        }
                                } else {
                                    Image(systemName: item.isVideo ? "video.fill" : "photo.fill")
                                        .font(.system(size: 28))
                                        .foregroundStyle(.quaternary)
                                }
                            }
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.isFolder ? item.filename : (item.folderName.isEmpty ? item.filename : item.folderName))
                                .font(.headline)
                                .textSelection(.enabled)

                            Text(item.isFolder ? item.formattedSize : item.filename)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }

                        HStack(spacing: 8) {
                            Button {
                                viewModel.quickSaveToDownloads([item])
                            } label: {
                                Text("Save")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderedProminent)

                            Button {
                                if item.isFolder {
                                    viewModel.promptAndExportFolders([item])
                                } else {
                                    viewModel.promptAndExportItems([item])
                                }
                            } label: {
                                Text("Export…")
                                    .frame(maxWidth: .infinity)
                            }

                            if item.isImage {
                                Button {
                                    viewModel.copyImageToClipboard(item)
                                } label: {
                                    Image(systemName: "doc.on.doc")
                                }
                                .help("Copy Image")
                            }
                        }

                        Divider()

                        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 8) {
                            if !item.isFolder && !item.folderName.isEmpty {
                                GridRow {
                                    Text("Game")
                                        .foregroundStyle(.secondary)
                                    Text(item.folderName)
                                        .lineLimit(2)
                                }
                            }
                            GridRow {
                                Text("Kind")
                                    .foregroundStyle(.secondary)
                                Text(item.kindDescription)
                            }
                            GridRow {
                                Text("Size")
                                    .foregroundStyle(.secondary)
                                Text(item.formattedSize)
                            }
                            if item.imageWidth > 0 && item.imageHeight > 0 {
                                GridRow {
                                    Text("Dimensions")
                                        .foregroundStyle(.secondary)
                                    Text(item.dimensionsDescription)
                                }
                            }
                            if !item.formattedDate.isEmpty {
                                GridRow {
                                    Text("Created")
                                        .foregroundStyle(.secondary)
                                    Text(item.formattedDate)
                                }
                            }
                        }
                        .font(.subheadline)

                        Divider()

                        DisclosureGroup("Advanced Details", isExpanded: $showTechnicalDetails) {
                            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 6) {
                                GridRow {
                                    Text("Exact Size")
                                        .foregroundStyle(.secondary)
                                    Text("\(item.compressedSize.formatted()) bytes")
                                        .monospacedDigit()
                                }
                                GridRow {
                                    Text("Object ID")
                                        .foregroundStyle(.secondary)
                                    Text(String(format: "0x%08X", item.handle))
                                        .monospaced()
                                }
                                GridRow {
                                    Text("Parent ID")
                                        .foregroundStyle(.secondary)
                                    Text(String(format: "0x%08X", item.parentHandle))
                                        .monospaced()
                                }
                                GridRow {
                                    Text("Storage ID")
                                        .foregroundStyle(.secondary)
                                    Text(String(format: "0x%08X", item.storageID))
                                        .monospaced()
                                }
                                GridRow {
                                    Text("Format")
                                        .foregroundStyle(.secondary)
                                    Text(String(format: "0x%04X", item.formatCode))
                                        .monospaced()
                                }
                            }
                            .font(.caption)
                            .textSelection(.enabled)
                            .padding(.top, 6)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .disclosureGroupStyle(ClickableHeaderDisclosureStyle())
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    }
                    .padding(16)
                }
            } else {
                ContentUnavailableView {
                    Label("No Selection", systemImage: "info.circle")
                } description: {
                    Text("Select an item to view its details.")
                }
            }
        }
    }
}

private struct ClickableHeaderDisclosureStyle: DisclosureGroupStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.snappy(duration: 0.18)) {
                    configuration.isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(configuration.isExpanded ? 90 : 0))
                        .frame(width: 12, height: 12)

                    configuration.label
                        .foregroundStyle(.secondary)

                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 2)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if configuration.isExpanded {
                configuration.content
                    .foregroundStyle(.primary)
            }
        }
    }
}

// MARK: - Disconnected State & Bottom Bar

private struct DisconnectedPlaceholderView: View {
    var viewModel: MTPViewModel
    @State private var showHelpSteps = false

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "gamecontroller")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(.secondary)

            VStack(spacing: 6) {
                Text("Connect Nintendo Switch")
                    .font(.title2.weight(.semibold))
                Text(viewModel.errorMessage ?? "Plug in your Switch with a USB cable to browse screenshots and videos.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 380)
            }

            Button {
                Task { await viewModel.connectToDevice() }
            } label: {
                Text(viewModel.isConnecting ? "Connecting…" : "Connect")
                    .frame(minWidth: 100)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(viewModel.isConnecting)

            VStack(spacing: 10) {
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        showHelpSteps.toggle()
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: showHelpSteps ? "chevron.down" : "chevron.right")
                            .font(.caption2.weight(.semibold))
                            .frame(width: 10, alignment: .center)
                        Text("How to enable USB transfer on Switch")
                            .font(.caption)
                    }
                    .foregroundStyle(.secondary)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if showHelpSteps {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(alignment: .center, spacing: 8) {
                            Image(systemName: "gearshape")
                                .frame(width: 16, alignment: .center)
                            Text("1. Open **System Settings** on your Switch")
                        }
                        HStack(alignment: .center, spacing: 8) {
                            Image(systemName: "photo.on.rectangle")
                                .frame(width: 16, alignment: .center)
                            Text("2. Select **Data Management → Manage Screenshots and Videos**")
                        }
                        HStack(alignment: .center, spacing: 8) {
                            Image(systemName: "cable.connector")
                                .frame(width: 16, alignment: .center)
                            Text("3. Choose **Copy to a Computer via USB Connection**")
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(12)
                    .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct BottomStatusBar: View {
    @Bindable var viewModel: MTPViewModel

    var body: some View {
        HStack(spacing: 10) {
            if let transfer = viewModel.transferStatus {
                ProgressView(value: transfer.fractionCompleted)
                    .controlSize(.small)
                    .frame(width: 110)

                Text("\(transfer.title) \(transfer.currentFile)")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                if transfer.bytesPerSecond > 0 {
                    Text(ByteCountFormatter.string(fromByteCount: Int64(transfer.bytesPerSecond), countStyle: .file) + "/s")
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
            } else if let banner = viewModel.statusBanner {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.system(size: 12))
                Text(banner)
                    .font(.system(size: 12))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
            } else {
                HStack(spacing: 6) {
                    Text(statusSummaryText)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)

                    if let sizeSummary = totalBytesSummaryText {
                        Text("·")
                            .font(.system(size: 12))
                            .foregroundStyle(.tertiary)
                        Text(sizeSummary)
                            .font(.system(size: 12).monospacedDigit())
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }

                    if !viewModel.selectedItemIDs.isEmpty {
                        Button("Clear") {
                            viewModel.selectedItemIDs.removeAll()
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Color.accentColor)
                        .padding(.leading, 4)
                    }
                }
            }

            Spacer(minLength: 8)

            if viewModel.viewMode == .grid {
                HStack(spacing: 6) {
                    Button {
                        withAnimation(.snappy(duration: 0.18)) {
                            viewModel.gridZoom = max(0, round(viewModel.gridZoom) - 1)
                        }
                    } label: {
                        Image(systemName: "minus.magnifyingglass")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                            .frame(width: 18, height: 18)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(viewModel.gridZoom <= 0)
                    .help("Smaller thumbnails")

                    Slider(value: $viewModel.gridZoom, in: 0...4, step: 1)
                        .controlSize(.mini)
                        .tint(.secondary)
                        .frame(width: 96)
                        .help("Adjust thumbnail size")

                    Button {
                        withAnimation(.snappy(duration: 0.18)) {
                            viewModel.gridZoom = min(4, round(viewModel.gridZoom) + 1)
                        }
                    } label: {
                        Image(systemName: "plus.magnifyingglass")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                            .frame(width: 18, height: 18)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(viewModel.gridZoom >= 4)
                    .help("Larger thumbnails")
                }
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 34)
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.quaternary.opacity(0.35))
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(.primary.opacity(0.07), lineWidth: 0.5)
                }
        }
        .padding(.horizontal, 12)
        .padding(.top, 4)
        .padding(.bottom, 10)
    }

    private var statusSummaryText: String {
        let count = viewModel.filteredAndSortedItems.count
        let selCount = viewModel.selectedItemIDs.count
        if selCount > 0 {
            return "\(selCount) of \(count) selected"
        }
        return "\(count) item\(count == 1 ? "" : "s")"
    }

    private var totalBytesSummaryText: String? {
        let itemsToSum: [MTPObjectItem]
        if !viewModel.selectedItemIDs.isEmpty {
            itemsToSum = viewModel.selectedItems.filter { !$0.isFolder }
        } else {
            itemsToSum = viewModel.filteredAndSortedItems.filter { !$0.isFolder }
        }
        let totalBytes = itemsToSum.reduce(Int64(0)) { $0 + Int64($1.compressedSize) }
        guard totalBytes > 0 else { return nil }
        return ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file)
    }
}

// MARK: - Full-Size Lightbox Sheet

private struct MediaLightboxSheet: View {
    @Bindable var viewModel: MTPViewModel
    let item: MTPObjectItem
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                HStack(spacing: 4) {
                    Button {
                        viewModel.navigatePreview(offset: -1, from: item)
                    } label: {
                        Image(systemName: "chevron.left")
                    }
                    .disabled(!viewModel.canNavigatePreview(offset: -1, from: item))
                    .help("Previous Item")

                    Button {
                        viewModel.navigatePreview(offset: 1, from: item)
                    } label: {
                        Image(systemName: "chevron.right")
                    }
                    .disabled(!viewModel.canNavigatePreview(offset: 1, from: item))
                    .help("Next Item")
                }

                VStack(alignment: .leading, spacing: 1) {
                    Text(item.folderName.isEmpty ? item.filename : item.folderName)
                        .font(.headline)
                        .lineLimit(1)
                    if !item.formattedDate.isEmpty {
                        Text(item.formattedDate)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                Spacer()

                if item.isImage {
                    Button {
                        viewModel.copyImageToClipboard(item)
                    } label: {
                        Label("Copy", systemImage: "doc.on.doc")
                    }
                }

                Button {
                    viewModel.quickSaveToDownloads([item])
                } label: {
                    Label("Save", systemImage: "arrow.down.circle.fill")
                }
                .buttonStyle(.borderedProminent)

                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(.bar)

            Divider()

            Color.black
                .aspectRatio(16.0 / 9.0, contentMode: .fit)
                .overlay {
                    if item.isVideo {
                        if let player = viewModel.previewPlayer {
                            MacVideoPlayerView(player: player)
                                .onAppear { player.play() }
                        } else {
                            if let thumb = viewModel.thumbnails[item.handle] {
                                Image(nsImage: thumb)
                                    .resizable()
                                    .aspectRatio(contentMode: .fit)
                                    .opacity(0.4)
                            }
                            ProgressView()
                                .controlSize(.large)
                                .tint(.white)
                        }
                    } else if let img = viewModel.previewImage ?? viewModel.thumbnails[item.handle] {
                        Image(nsImage: img)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                    } else {
                        ProgressView()
                            .tint(.white)
                    }
                }
                .frame(minWidth: 800, minHeight: 450)
        }
        .onAppear {
            if viewModel.inspectedItem?.handle != item.handle {
                viewModel.selectedItemIDs = [item.handle]
            }
        }
        .onDisappear {
            viewModel.previewPlayer?.pause()
            viewModel.previewPlayer = nil
        }
    }
}

struct MacVideoPlayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .inline
        view.videoGravity = .resizeAspect
        view.player = player
        return view
    }

    func updateNSView(_ nsView: AVPlayerView, context: Context) {
        if nsView.player !== player {
            nsView.player = player
        }
    }

    static func dismantleNSView(_ nsView: AVPlayerView, coordinator: ()) {
        nsView.player?.pause()
        nsView.player = nil
    }
}

#Preview("Default") {
    ContentView()
}

#Preview("Inspector Open (Min Width)") {
    ContentView(initialInspectorOpen: true)
}
