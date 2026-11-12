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
                        viewModel: viewModel,
                        item: item,
                        showGameTag: showGameTag,
                        thumbHeight: thumbHeight,
                        onPlay: { viewModel.openItem(item) }
                    )
                    .onAppear {
                        viewModel.requestThumbnailIfNeeded(for: item)
                    }
                }
            }
            .padding(horizontalPadding)
            .animation(.snappy(duration: 0.2), value: columnCount)
        }
        .onGeometryChange(for: CGFloat.self) { proxy in
            floor(proxy.size.width)
        } action: { newWidth in
            if newWidth > 100, abs(newWidth - containerWidth) > 1.0 {
                containerWidth = newWidth
            }
        }
        .overlay {
            GridInteractionOverlay(
                viewModel: viewModel,
                columnCount: columnCount,
                itemWidth: itemWidth,
                thumbHeight: thumbHeight,
                spacing: spacing,
                horizontalPadding: horizontalPadding
            )
        }
        .background(Color(nsColor: .textBackgroundColor))
        .onExitCommand {
            viewModel.clearSelection()
        }
    }
}

private struct GridInteractionOverlay: NSViewRepresentable {
    var viewModel: MTPViewModel
    var columnCount: Int
    var itemWidth: CGFloat
    var thumbHeight: CGFloat
    var spacing: CGFloat
    var horizontalPadding: CGFloat

    func makeNSView(context: Context) -> GridInteractionNSView {
        let view = GridInteractionNSView()
        configure(view)
        return view
    }

    func updateNSView(_ nsView: GridInteractionNSView, context: Context) {
        configure(nsView)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: GridInteractionNSView, context: Context) -> CGSize {
        CGSize(width: proposal.width ?? 0, height: proposal.height ?? 0)
    }

    private func configure(_ view: GridInteractionNSView) {
        view.viewModel = viewModel
        view.columnCount = max(1, columnCount)
        view.itemWidth = itemWidth
        view.thumbHeight = thumbHeight
        view.spacing = spacing
        view.horizontalPadding = horizontalPadding
    }
}

private final class GridInteractionNSView: NSView, NSDraggingSource {
    weak var viewModel: MTPViewModel?
    var columnCount: Int = 4
    var itemWidth: CGFloat = 180
    var thumbHeight: CGFloat = 100
    var spacing: CGFloat = 16
    var horizontalPadding: CGFloat = 20

    private weak var cachedScrollView: NSScrollView?
    private var activeMarqueeRect: CGRect? = nil {
        didSet {
            if oldValue != activeMarqueeRect {
                needsDisplay = true
            }
        }
    }
    private var mouseDownViewportPoint: CGPoint = .zero
    private var marqueeStartContentPoint: CGPoint = .zero
    private var dragCandidateItem: MTPObjectItem? = nil
    private var pendingSingleSelectHandle: UInt32? = nil
    private var clickedPlayButtonItem: MTPObjectItem? = nil
    private var hasStartedFileDrag: Bool = false
    private var isMarqueeSelecting: Bool = false
    private var marqueeInitialSelection: Set<UInt32> = []
    private var contextMenuActionTargets: [ContextMenuActionTarget] = []

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard let rect = activeMarqueeRect, rect.width > 1 || rect.height > 1 else { return }
        NSColor.controlAccentColor.withAlphaComponent(0.18).setFill()
        rect.fill()
        NSColor.controlAccentColor.withAlphaComponent(0.85).setStroke()
        let path = NSBezierPath(rect: rect.insetBy(dx: 0.5, dy: 0.5))
        path.lineWidth = 1.0
        path.stroke()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard bounds.contains(point) else { return nil }
        // Let clicks on the right-hand vertical scrollbar pass through to NSScrollView
        if point.x >= bounds.width - 15 {
            return nil
        }
        return self
    }

    private func backingScrollView() -> NSScrollView? {
        if let cachedScrollView, cachedScrollView.window != nil {
            return cachedScrollView
        }
        func findScrollView(in root: NSView) -> NSScrollView? {
            if let sv = root as? NSScrollView {
                return sv
            }
            for sub in root.subviews where sub !== self {
                if let found = findScrollView(in: sub) {
                    return found
                }
            }
            return nil
        }
        var ancestor = superview
        while let current = ancestor {
            if let found = findScrollView(in: current) {
                cachedScrollView = found
                return found
            }
            ancestor = current.superview
        }
        return nil
    }

    private var currentScrollOffsetY: CGFloat {
        guard let sv = backingScrollView() else { return 0 }
        return max(0, sv.contentView.bounds.origin.y)
    }

    private func autoScrollViewportIfNeeded(at viewportPoint: CGPoint) {
        guard let sv = backingScrollView(), let docView = sv.documentView else { return }
        let edgeZone: CGFloat = 36
        var deltaY: CGFloat = 0
        if viewportPoint.y < edgeZone {
            deltaY = -max(4, (edgeZone - viewportPoint.y) * 0.45)
        } else if viewportPoint.y > bounds.height - edgeZone {
            deltaY = max(4, (viewportPoint.y - (bounds.height - edgeZone)) * 0.45)
        }
        guard abs(deltaY) > 0.5 else { return }
        let clipView = sv.contentView
        let maxScrollY = max(0, docView.bounds.height - clipView.bounds.height)
        let newY = min(maxScrollY, max(0, clipView.bounds.origin.y + deltaY))
        if abs(newY - clipView.bounds.origin.y) > 0.5 {
            clipView.scroll(to: NSPoint(x: clipView.bounds.origin.x, y: newY))
            sv.reflectScrolledClipView(clipView)
        }
    }

    override func scrollWheel(with event: NSEvent) {
        if let sv = backingScrollView() {
            sv.scrollWheel(with: event)
        } else {
            super.scrollWheel(with: event)
        }
    }

    private var cardHeight: CGFloat {
        thumbHeight + 42
    }

    private func resolvedContentFrame(at index: Int) -> CGRect {
        let cols = max(1, columnCount)
        let col = index % cols
        let row = index / cols
        let cardH = cardHeight
        return CGRect(
            x: horizontalPadding + CGFloat(col) * (itemWidth + spacing),
            y: horizontalPadding + CGFloat(row) * (cardH + spacing),
            width: itemWidth,
            height: cardH
        )
    }

    private func itemAt(contentPoint: CGPoint) -> (item: MTPObjectItem, contentFrame: CGRect)? {
        guard let viewModel else { return nil }
        for (index, item) in viewModel.filteredAndSortedItems.enumerated() {
            let frame = resolvedContentFrame(at: index)
            guard frame.contains(contentPoint) else { continue }
            let thumbRect = CGRect(x: frame.minX, y: frame.minY, width: frame.width, height: thumbHeight)
            let labelRect = CGRect(
                x: frame.minX,
                y: frame.minY + thumbHeight,
                width: min(frame.width, 160),
                height: max(0, frame.height - thumbHeight)
            )
            if thumbRect.contains(contentPoint) || labelRect.contains(contentPoint) {
                return (item, frame)
            }
        }
        return nil
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        guard let viewModel else { return }

        let viewportPt = convert(event.locationInWindow, from: nil)
        let contentPt = CGPoint(x: viewportPt.x, y: viewportPt.y + currentScrollOffsetY)
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        mouseDownViewportPoint = viewportPt
        marqueeStartContentPoint = contentPt
        hasStartedFileDrag = false
        clickedPlayButtonItem = nil

        if let hit = itemAt(contentPoint: contentPt) {
            let item = hit.item
            let frame = hit.contentFrame

            if event.clickCount >= 2 {
                dragCandidateItem = nil
                pendingSingleSelectHandle = nil
                isMarqueeSelecting = false
                activeMarqueeRect = nil
                viewModel.openItem(item)
                return
            }

            if item.isVideo {
                let playRect = CGRect(
                    x: frame.maxX - 36,
                    y: frame.minY + max(0, thumbHeight - 36),
                    width: 36,
                    height: 36
                )
                if playRect.contains(contentPt) {
                    clickedPlayButtonItem = item
                }
            }

            isMarqueeSelecting = false
            activeMarqueeRect = nil
            dragCandidateItem = item

            if flags.contains(.command) {
                if viewModel.selectedItemIDs.contains(item.handle) {
                    viewModel.selectedItemIDs.remove(item.handle)
                } else {
                    viewModel.selectedItemIDs.insert(item.handle)
                    viewModel.selectionAnchorHandle = item.handle
                }
                pendingSingleSelectHandle = nil
            } else if flags.contains(.shift) {
                viewModel.selectRange(to: item.handle, additive: false)
                pendingSingleSelectHandle = nil
            } else {
                if viewModel.selectedItemIDs.contains(item.handle) {
                    pendingSingleSelectHandle = item.handle
                } else {
                    viewModel.selectedItemIDs = [item.handle]
                    viewModel.selectionAnchorHandle = item.handle
                    pendingSingleSelectHandle = nil
                }
            }
        } else {
            dragCandidateItem = nil
            pendingSingleSelectHandle = nil
            isMarqueeSelecting = true
            if flags.contains(.command) || flags.contains(.shift) {
                marqueeInitialSelection = viewModel.selectedItemIDs
            } else {
                viewModel.clearSelection()
                marqueeInitialSelection = []
            }
            activeMarqueeRect = nil
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let viewModel else { return }
        let viewportPt = convert(event.locationInWindow, from: nil)
        let distance = hypot(viewportPt.x - mouseDownViewportPoint.x, viewportPt.y - mouseDownViewportPoint.y)

        if let candidate = dragCandidateItem {
            guard !hasStartedFileDrag, distance >= 4.0 else { return }
            hasStartedFileDrag = true
            pendingSingleSelectHandle = nil
            clickedPlayButtonItem = nil
            startFileDragSession(with: event, primaryItem: candidate)
        } else if isMarqueeSelecting {
            guard distance >= 2.0 else { return }
            autoScrollViewportIfNeeded(at: viewportPt)
            let scrollY = currentScrollOffsetY
            let currentContentPt = CGPoint(x: viewportPt.x, y: viewportPt.y + scrollY)
            let contentRect = CGRect(
                x: min(marqueeStartContentPoint.x, currentContentPt.x),
                y: min(marqueeStartContentPoint.y, currentContentPt.y),
                width: max(1, abs(currentContentPt.x - marqueeStartContentPoint.x)),
                height: max(1, abs(currentContentPt.y - marqueeStartContentPoint.y))
            )
            let viewportBandRect = contentRect.offsetBy(dx: 0, dy: -scrollY).intersection(bounds)
            if viewportBandRect.isNull || viewportBandRect.isEmpty {
                activeMarqueeRect = nil
            } else {
                activeMarqueeRect = viewportBandRect
            }

            var intersected: Set<UInt32> = []
            for (index, item) in viewModel.filteredAndSortedItems.enumerated() {
                let frame = resolvedContentFrame(at: index)
                if frame.intersects(contentRect) {
                    intersected.insert(item.handle)
                }
            }

            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let updatedSelection: Set<UInt32>
            if flags.contains(.command) {
                updatedSelection = marqueeInitialSelection.symmetricDifference(intersected)
            } else if flags.contains(.shift) {
                updatedSelection = marqueeInitialSelection.union(intersected)
            } else {
                updatedSelection = intersected
            }

            if viewModel.selectedItemIDs != updatedSelection {
                viewModel.selectedItemIDs = updatedSelection
            }
        }
    }

    override func mouseUp(with event: NSEvent) {
        if !hasStartedFileDrag {
            if let playItem = clickedPlayButtonItem {
                viewModel?.openItem(playItem)
            } else if let pending = pendingSingleSelectHandle {
                viewModel?.selectedItemIDs = [pending]
                viewModel?.selectionAnchorHandle = pending
            }
        }
        dragCandidateItem = nil
        pendingSingleSelectHandle = nil
        clickedPlayButtonItem = nil
        hasStartedFileDrag = false
        if isMarqueeSelecting {
            isMarqueeSelecting = false
            activeMarqueeRect = nil
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let viewModel else { return nil }
        let viewportPt = convert(event.locationInWindow, from: nil)
        let contentPt = CGPoint(x: viewportPt.x, y: viewportPt.y + currentScrollOffsetY)
        guard let hit = itemAt(contentPoint: contentPt) else { return nil }
        let item = hit.item

        if !viewModel.selectedItemIDs.contains(item.handle) {
            viewModel.selectedItemIDs = [item.handle]
            viewModel.selectionAnchorHandle = item.handle
        }

        let targetItems = viewModel.selectedItems.isEmpty ? [item] : viewModel.selectedItems
        let built = BrowserContextMenuBuilder.makeMenu(for: targetItems, viewModel: viewModel)
        contextMenuActionTargets = built.targets
        return built.menu
    }

    override func selectAll(_ sender: Any?) {
        viewModel?.selectAll()
    }

    override func cancelOperation(_ sender: Any?) {
        viewModel?.clearSelection()
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 49 || event.keyCode == 36 { // Space or Return
            if let first = viewModel?.selectedItems.first {
                viewModel?.openItem(first)
                return
            }
        }
        super.keyDown(with: event)
    }

    // MARK: - NSDraggingSource

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .outsideApplication ? .copy : []
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        dragCandidateItem = nil
        pendingSingleSelectHandle = nil
        clickedPlayButtonItem = nil
        hasStartedFileDrag = false
        isMarqueeSelecting = false
        activeMarqueeRect = nil
    }

    private func startFileDragSession(with event: NSEvent, primaryItem: MTPObjectItem) {
        guard let viewModel else { return }
        let itemsToDrag = viewModel.itemsForDrag(startingWith: primaryItem)
        guard !itemsToDrag.isEmpty else { return }

        viewModel.dragCoordinator.prepareForDragBatch(items: itemsToDrag)

        let scrollY = currentScrollOffsetY
        var draggingItems: [NSDraggingItem] = []
        draggingItems.reserveCapacity(itemsToDrag.count)

        for item in itemsToDrag {
            let thumb = viewModel.thumbnails[item.handle]
            let provider = viewModel.dragCoordinator.makeFilePromiseProvider(for: item, cachedImage: thumb)
            let dragItem = NSDraggingItem(pasteboardWriter: provider)

            let itemIndex = viewModel.filteredAndSortedItems.firstIndex(where: { $0.handle == item.handle }) ?? 0
            let cardFrame = resolvedContentFrame(at: itemIndex).offsetBy(dx: 0, dy: -scrollY)
            let previewWidth = min(max(96, cardFrame.width), 168)
            let previewHeight = round(previewWidth * 9.0 / 16.0)
            let previewSize = NSSize(width: previewWidth, height: previewHeight)
            let dragOrigin = CGPoint(
                x: cardFrame.minX + (cardFrame.width - previewWidth) * 0.5,
                y: cardFrame.minY + max(0, (thumbHeight - previewHeight) * 0.5)
            )
            let dragFrame = NSRect(origin: dragOrigin, size: previewSize)
            let dragImage = DragPreviewRenderer.makeDragImage(
                for: item,
                thumbnail: thumb,
                size: previewSize
            )
            dragItem.setDraggingFrame(dragFrame, contents: dragImage)
            draggingItems.append(dragItem)
        }

        let session = beginDraggingSession(with: draggingItems, event: event, source: self)
        session.animatesToStartingPositionsOnCancelOrFail = true
        session.draggingFormation = .default
    }
}

private struct MediaGridCard: View {
    var viewModel: MTPViewModel
    let item: MTPObjectItem
    let showGameTag: Bool
    let thumbHeight: CGFloat
    let onPlay: () -> Void

    var body: some View {
        let thumbnail = viewModel.thumbnails[item.handle]
        let isSelected = viewModel.selectedItemIDs.contains(item.handle)

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
            .frame(height: 36, alignment: .topLeading)
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

// MARK: - Table View (Finder-Style List View with Marquee Selection & File Promises)

private struct MediaTableView: View {
    @Bindable var viewModel: MTPViewModel

    var body: some View {
        let _ = viewModel.filteredAndSortedItems
        let _ = viewModel.selectedItemIDs
        let _ = viewModel.thumbnails.count
        MediaTableRepresentable(viewModel: viewModel)
            .onExitCommand {
                viewModel.clearSelection()
            }
    }
}

private struct MediaTableRepresentable: NSViewRepresentable {
    var viewModel: MTPViewModel

    func makeCoordinator() -> Coordinator {
        Coordinator(viewModel: viewModel)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .textBackgroundColor

        let tableView = FinderStyleTableView()
        tableView.style = .inset
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.rowHeight = 28
        tableView.intercellSpacing = NSSize(width: 12, height: 2)
        tableView.allowsMultipleSelection = true
        tableView.allowsEmptySelection = true
        tableView.allowsColumnReordering = false
        tableView.allowsColumnResizing = true
        tableView.allowsColumnSelection = false
        tableView.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        tableView.setDraggingSourceOperationMask(.copy, forLocal: false)
        tableView.setDraggingSourceOperationMask([], forLocal: true)

        let columnsConfig: [(id: String, title: String, minW: CGFloat, idealW: CGFloat, maxW: CGFloat)] = [
            ("name", "Name", 180, 280, 1200),
            ("game", "Game", 120, 190, 600),
            ("date", "Date", 120, 150, 400),
            ("kind", "Kind", 80, 110, 300),
            ("size", "Size", 70, 90, 240)
        ]

        for colInfo in columnsConfig {
            let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(colInfo.id))
            col.title = colInfo.title
            col.minWidth = colInfo.minW
            col.width = colInfo.idealW
            col.maxWidth = colInfo.maxW
            col.resizingMask = .userResizingMask
            tableView.addTableColumn(col)
        }

        let coordinator = context.coordinator
        coordinator.tableView = tableView
        tableView.coordinator = coordinator
        tableView.delegate = coordinator
        tableView.dataSource = coordinator

        scrollView.documentView = tableView
        coordinator.syncFromViewModel()
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        context.coordinator.viewModel = viewModel
        context.coordinator.syncFromViewModel()
    }

    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        var viewModel: MTPViewModel
        weak var tableView: FinderStyleTableView?
        private var displayedItems: [MTPObjectItem] = []
        private var displayedHandles: [UInt32] = []
        private var knownThumbnailCount: Int = 0
        var isProgrammaticSelectionUpdate: Bool = false

        init(viewModel: MTPViewModel) {
            self.viewModel = viewModel
            super.init()
        }

        func syncFromViewModel() {
            guard let tableView else { return }
            let newItems = viewModel.filteredAndSortedItems
            let newHandles = newItems.map(\.handle)
            let itemsChanged = newHandles != displayedHandles
            let thumbCount = viewModel.thumbnails.count

            displayedItems = newItems
            if itemsChanged {
                displayedHandles = newHandles
                tableView.reloadData()
            } else if thumbCount != knownThumbnailCount {
                let visibleRows = tableView.rows(in: tableView.visibleRect)
                if visibleRows.length > 0 {
                    let rowSet = IndexSet(integersIn: visibleRows.location ..< (visibleRows.location + visibleRows.length))
                    tableView.reloadData(forRowIndexes: rowSet, columnIndexes: IndexSet(integer: 0))
                }
            }
            knownThumbnailCount = thumbCount

            if !tableView.isTrackingMouseInteraction {
                var targetIndexSet = IndexSet()
                let selectedIDs = viewModel.selectedItemIDs
                if !selectedIDs.isEmpty {
                    for (idx, item) in displayedItems.enumerated() where selectedIDs.contains(item.handle) {
                        targetIndexSet.insert(idx)
                    }
                }
                if tableView.selectedRowIndexes != targetIndexSet {
                    isProgrammaticSelectionUpdate = true
                    tableView.selectRowIndexes(targetIndexSet, byExtendingSelection: false)
                    isProgrammaticSelectionUpdate = false
                }
            }
        }

        func item(at row: Int) -> MTPObjectItem? {
            guard displayedItems.indices.contains(row) else { return nil }
            return displayedItems[row]
        }

        func pushTableSelectionToViewModel(_ rowIndexes: IndexSet, anchorRow: Int? = nil) {
            var handles = Set<UInt32>()
            handles.reserveCapacity(rowIndexes.count)
            for row in rowIndexes where displayedItems.indices.contains(row) {
                handles.insert(displayedItems[row].handle)
            }
            if let anchorRow, displayedItems.indices.contains(anchorRow) {
                viewModel.selectionAnchorHandle = displayedItems[anchorRow].handle
            }
            if viewModel.selectedItemIDs != handles {
                viewModel.selectedItemIDs = handles
            }
        }

        // MARK: - NSTableViewDataSource & NSTableViewDelegate

        func numberOfRows(in tableView: NSTableView) -> Int {
            displayedItems.count
        }

        func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> (any NSPasteboardWriting)? {
            guard let item = item(at: row) else { return nil }
            return viewModel.dragCoordinator.makeFilePromiseProvider(
                for: item,
                cachedImage: viewModel.thumbnails[item.handle]
            )
        }

        func tableView(_ tableView: NSTableView, draggingSession session: NSDraggingSession, willBeginAt screenPoint: NSPoint, forRowIndexes rowIndexes: IndexSet) {
            let draggedItems = rowIndexes.compactMap { item(at: $0) }
            viewModel.dragCoordinator.prepareForDragBatch(items: draggedItems)
        }

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !isProgrammaticSelectionUpdate, let tableView else { return }
            pushTableSelectionToViewModel(tableView.selectedRowIndexes)
        }

        func tableView(_ tableView: NSTableView, didClick tableColumn: NSTableColumn) {
            switch tableColumn.identifier.rawValue {
            case "name":
                viewModel.sortOrder = .nameAscending
            case "game":
                viewModel.sortOrder = .gameTitle
            case "date":
                viewModel.sortOrder = (viewModel.sortOrder == .dateNewest) ? .dateOldest : .dateNewest
            case "size":
                viewModel.sortOrder = .sizeLargest
            default:
                break
            }
        }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard let tableColumn, let item = item(at: row) else { return nil }
            let colID = tableColumn.identifier.rawValue

            if colID == "name" {
                let id = NSUserInterfaceItemIdentifier("NameCell")
                let cell: MediaNameTableCellView
                if let reused = tableView.makeView(withIdentifier: id, owner: nil) as? MediaNameTableCellView {
                    cell = reused
                } else {
                    cell = MediaNameTableCellView()
                    cell.identifier = id
                }
                let thumb = viewModel.thumbnails[item.handle]
                if thumb == nil && item.hasThumbnail {
                    let vm = viewModel
                    DispatchQueue.main.async {
                        vm.requestThumbnailIfNeeded(for: item)
                    }
                }
                cell.configure(with: item, thumbnail: thumb)
                return cell
            } else {
                let id = NSUserInterfaceItemIdentifier("TextCell_\(colID)")
                let cell: MediaTextTableCellView
                if let reused = tableView.makeView(withIdentifier: id, owner: nil) as? MediaTextTableCellView {
                    cell = reused
                } else {
                    cell = MediaTextTableCellView()
                    cell.identifier = id
                }

                switch colID {
                case "game":
                    let text = item.isFolder ? "—" : (item.folderName.isEmpty ? "—" : item.folderName)
                    cell.configure(text: text, color: .secondaryLabelColor, monospaced: false)
                case "date":
                    if !item.formattedDate.isEmpty {
                        cell.configure(text: item.formattedDate, color: .secondaryLabelColor, monospaced: false)
                    } else {
                        cell.configure(text: "—", color: .tertiaryLabelColor, monospaced: false)
                    }
                case "kind":
                    cell.configure(text: item.kindDescription, color: .secondaryLabelColor, monospaced: false)
                case "size":
                    cell.configure(text: item.formattedSize, color: .secondaryLabelColor, monospaced: true)
                default:
                    cell.configure(text: "", color: .secondaryLabelColor, monospaced: false)
                }
                return cell
            }
        }
    }
}

private final class MediaNameTableCellView: NSTableCellView {
    private let thumbContainer = NSView()
    private let thumbImageView = NSImageView()
    private let titleField = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupViews()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupViews()
    }

    private func setupViews() {
        thumbContainer.translatesAutoresizingMaskIntoConstraints = false
        thumbContainer.wantsLayer = true
        thumbContainer.layer?.cornerRadius = 3
        thumbContainer.layer?.masksToBounds = true

        thumbImageView.translatesAutoresizingMaskIntoConstraints = false
        thumbImageView.imageScaling = .scaleProportionallyUpOrDown

        titleField.translatesAutoresizingMaskIntoConstraints = false
        titleField.lineBreakMode = .byTruncatingMiddle
        titleField.maximumNumberOfLines = 1
        titleField.font = .systemFont(ofSize: NSFont.systemFontSize)
        titleField.textColor = .labelColor

        thumbContainer.addSubview(thumbImageView)
        addSubview(thumbContainer)
        addSubview(titleField)
        self.textField = titleField

        NSLayoutConstraint.activate([
            thumbContainer.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            thumbContainer.centerYAnchor.constraint(equalTo: centerYAnchor),
            thumbContainer.widthAnchor.constraint(equalToConstant: 32),
            thumbContainer.heightAnchor.constraint(equalToConstant: 18),

            thumbImageView.leadingAnchor.constraint(equalTo: thumbContainer.leadingAnchor),
            thumbImageView.trailingAnchor.constraint(equalTo: thumbContainer.trailingAnchor),
            thumbImageView.topAnchor.constraint(equalTo: thumbContainer.topAnchor),
            thumbImageView.bottomAnchor.constraint(equalTo: thumbContainer.bottomAnchor),

            titleField.leadingAnchor.constraint(equalTo: thumbContainer.trailingAnchor, constant: 10),
            titleField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            titleField.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    func configure(with item: MTPObjectItem, thumbnail: NSImage?) {
        titleField.stringValue = item.filename
        if item.isFolder {
            thumbContainer.layer?.backgroundColor = NSColor.clear.cgColor
            let cfg = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
            let img = NSImage(systemSymbolName: "folder.fill", accessibilityDescription: nil)?.withSymbolConfiguration(cfg)
            thumbImageView.image = img
            thumbImageView.contentTintColor = .controlAccentColor
        } else if let thumbnail {
            thumbContainer.layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.05).cgColor
            thumbImageView.image = thumbnail
            thumbImageView.contentTintColor = nil
        } else {
            thumbContainer.layer?.backgroundColor = NSColor.clear.cgColor
            let sym = item.isVideo ? "video.fill" : "photo.fill"
            let cfg = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
            thumbImageView.image = NSImage(systemSymbolName: sym, accessibilityDescription: nil)?.withSymbolConfiguration(cfg)
            thumbImageView.contentTintColor = .secondaryLabelColor
        }
    }

    var contentHitMaxX: CGFloat {
        let textWidth = ceil(titleField.attributedStringValue.size().width)
        return min(bounds.maxX, 2 + 32 + 10 + textWidth + 8)
    }
}

private final class MediaTextTableCellView: NSTableCellView {
    private let labelField = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupViews()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupViews()
    }

    private func setupViews() {
        labelField.translatesAutoresizingMaskIntoConstraints = false
        labelField.lineBreakMode = .byTruncatingTail
        labelField.maximumNumberOfLines = 1
        addSubview(labelField)
        self.textField = labelField

        NSLayoutConstraint.activate([
            labelField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            labelField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            labelField.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    func configure(text: String, color: NSColor, monospaced: Bool) {
        labelField.stringValue = text
        labelField.textColor = color
        if monospaced {
            labelField.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        } else {
            labelField.font = .systemFont(ofSize: NSFont.systemFontSize)
        }
    }
}

private final class MarqueeBandNSView: NSView {
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.controlAccentColor.withAlphaComponent(0.18).setFill()
        bounds.fill()
        NSColor.controlAccentColor.withAlphaComponent(0.85).setStroke()
        let path = NSBezierPath(rect: bounds.insetBy(dx: 0.5, dy: 0.5))
        path.lineWidth = 1.0
        path.stroke()
    }
}

private final class FinderStyleTableView: NSTableView {
    weak var coordinator: MediaTableRepresentable.Coordinator?
    private let marqueeView = MarqueeBandNSView(frame: .zero)
    private var contextMenuActionTargets: [ContextMenuActionTarget] = []
    private var anchorRow: Int? = nil
    var isTrackingMouseInteraction: Bool = false

    private var mouseDownPoint: NSPoint = .zero
    private var clickedRowOnDown: Int = -1
    private var shouldFileDragOnMove: Bool = false
    private var hasStartedFileDrag: Bool = false
    private var marqueeInitialSelection = IndexSet()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        marqueeView.isHidden = true
        addSubview(marqueeView)
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        marqueeView.isHidden = true
        addSubview(marqueeView)
    }

    private func isPointOnNameIconOrText(_ pt: NSPoint, row: Int) -> Bool {
        guard row >= 0, column(at: pt) == 0 else { return false }
        let cellFrame = frameOfCell(atColumn: 0, row: row)
        if let nameCell = view(atColumn: 0, row: row, makeIfNecessary: false) as? MediaNameTableCellView {
            let localX = pt.x - cellFrame.minX
            return localX >= 0 && localX <= nameCell.contentHitMaxX
        }
        return pt.x <= cellFrame.minX + 180
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        guard let coordinator else {
            super.mouseDown(with: event)
            return
        }

        let startPoint = convert(event.locationInWindow, from: nil)
        let clickedRow = row(at: startPoint)
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        mouseDownPoint = startPoint
        clickedRowOnDown = clickedRow
        hasStartedFileDrag = false

        if event.clickCount >= 2, clickedRow >= 0, let item = coordinator.item(at: clickedRow) {
            isTrackingMouseInteraction = false
            marqueeView.isHidden = true
            coordinator.viewModel.openItem(item)
            return
        }

        let wasRowSelected = clickedRow >= 0 && selectedRowIndexes.contains(clickedRow)
        let hitIconOrName = isPointOnNameIconOrText(startPoint, row: clickedRow)

        shouldFileDragOnMove = (clickedRow >= 0)
            && !flags.contains(.command)
            && !flags.contains(.shift)
            && (wasRowSelected || hitIconOrName)

        isTrackingMouseInteraction = true

        if shouldFileDragOnMove {
            if !wasRowSelected {
                let single = IndexSet(integer: clickedRow)
                coordinator.isProgrammaticSelectionUpdate = true
                selectRowIndexes(single, byExtendingSelection: false)
                coordinator.isProgrammaticSelectionUpdate = false
                anchorRow = clickedRow
                coordinator.pushTableSelectionToViewModel(single, anchorRow: clickedRow)
            }
        } else {
            marqueeInitialSelection = selectedRowIndexes

            if clickedRow >= 0 {
                var clickSelection = marqueeInitialSelection
                if flags.contains(.command) {
                    if clickSelection.contains(clickedRow) {
                        clickSelection.remove(clickedRow)
                    } else {
                        clickSelection.insert(clickedRow)
                        anchorRow = clickedRow
                    }
                } else if flags.contains(.shift) {
                    let startAnchor = anchorRow ?? marqueeInitialSelection.first ?? clickedRow
                    let lower = min(startAnchor, clickedRow)
                    let upper = max(startAnchor, clickedRow)
                    clickSelection = IndexSet(integersIn: lower...upper)
                } else {
                    clickSelection = IndexSet(integer: clickedRow)
                    anchorRow = clickedRow
                }
                coordinator.isProgrammaticSelectionUpdate = true
                selectRowIndexes(clickSelection, byExtendingSelection: false)
                coordinator.isProgrammaticSelectionUpdate = false
                coordinator.pushTableSelectionToViewModel(clickSelection, anchorRow: anchorRow)
            } else if !flags.contains(.command) && !flags.contains(.shift) {
                coordinator.isProgrammaticSelectionUpdate = true
                deselectAll(nil)
                coordinator.isProgrammaticSelectionUpdate = false
                anchorRow = nil
                coordinator.pushTableSelectionToViewModel(IndexSet())
            }
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard isTrackingMouseInteraction, let coordinator else { return }
        let currentPoint = convert(event.locationInWindow, from: nil)
        let distance = hypot(currentPoint.x - mouseDownPoint.x, currentPoint.y - mouseDownPoint.y)

        if shouldFileDragOnMove {
            guard !hasStartedFileDrag, distance >= 4.0, clickedRowOnDown >= 0 else { return }
            hasStartedFileDrag = true
            isTrackingMouseInteraction = false
            startTableFileDragSession(with: event, primaryRow: clickedRowOnDown)
        } else {
            guard distance >= 3.0 else { return }
            autoscroll(with: event)
            let scrolledPoint = convert(event.locationInWindow, from: nil)
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

            let bandRect = NSRect(
                x: min(mouseDownPoint.x, scrolledPoint.x),
                y: min(mouseDownPoint.y, scrolledPoint.y),
                width: max(1, abs(scrolledPoint.x - mouseDownPoint.x)),
                height: max(1, abs(scrolledPoint.y - mouseDownPoint.y))
            )

            if marqueeView.superview !== self || subviews.last !== marqueeView {
                marqueeView.removeFromSuperview()
                addSubview(marqueeView)
            }
            marqueeView.frame = bandRect
            marqueeView.isHidden = false
            marqueeView.needsDisplay = true

            let candidateRange = rows(in: bandRect)
            var hitRows = IndexSet()
            if candidateRange.length > 0 {
                let upperBound = min(numberOfRows, candidateRange.location + candidateRange.length)
                for r in max(0, candidateRange.location) ..< upperBound {
                    if rect(ofRow: r).intersects(bandRect) {
                        hitRows.insert(r)
                    }
                }
            }

            let updatedRows: IndexSet
            if flags.contains(.command) {
                var sym = marqueeInitialSelection
                for r in hitRows {
                    if sym.contains(r) {
                        sym.remove(r)
                    } else {
                        sym.insert(r)
                    }
                }
                updatedRows = sym
            } else if flags.contains(.shift) {
                updatedRows = marqueeInitialSelection.union(hitRows)
            } else {
                updatedRows = hitRows
            }

            if selectedRowIndexes != updatedRows {
                coordinator.isProgrammaticSelectionUpdate = true
                selectRowIndexes(updatedRows, byExtendingSelection: false)
                coordinator.isProgrammaticSelectionUpdate = false
                coordinator.pushTableSelectionToViewModel(updatedRows, anchorRow: updatedRows.first)
            }
        }
    }

    override func mouseUp(with event: NSEvent) {
        if isTrackingMouseInteraction, shouldFileDragOnMove, !hasStartedFileDrag, clickedRowOnDown >= 0, let coordinator {
            let single = IndexSet(integer: clickedRowOnDown)
            coordinator.isProgrammaticSelectionUpdate = true
            selectRowIndexes(single, byExtendingSelection: false)
            coordinator.isProgrammaticSelectionUpdate = false
            anchorRow = clickedRowOnDown
            coordinator.pushTableSelectionToViewModel(single, anchorRow: clickedRowOnDown)
        }
        isTrackingMouseInteraction = false
        hasStartedFileDrag = false
        marqueeView.isHidden = true
    }

    private func startTableFileDragSession(with event: NSEvent, primaryRow: Int) {
        guard let coordinator, let primaryItem = coordinator.item(at: primaryRow) else { return }
        let vm = coordinator.viewModel
        let itemsToDrag = vm.itemsForDrag(startingWith: primaryItem)
        guard !itemsToDrag.isEmpty else { return }

        vm.dragCoordinator.prepareForDragBatch(items: itemsToDrag)

        let clickPt = convert(event.locationInWindow, from: nil)
        var draggingItems: [NSDraggingItem] = []
        draggingItems.reserveCapacity(itemsToDrag.count)

        for (idx, item) in itemsToDrag.enumerated() {
            let thumb = vm.thumbnails[item.handle]
            let provider = vm.dragCoordinator.makeFilePromiseProvider(for: item, cachedImage: thumb)
            let dragItem = NSDraggingItem(pasteboardWriter: provider)

            let previewSize = NSSize(width: 120, height: 68)
            let origin = CGPoint(
                x: clickPt.x - previewSize.width * 0.5 + CGFloat(min(idx, 4) * 4),
                y: clickPt.y - previewSize.height * 0.5 + CGFloat(min(idx, 4) * 4)
            )
            let dragImage = DragPreviewRenderer.makeDragImage(
                for: item,
                thumbnail: thumb,
                size: previewSize
            )
            dragItem.setDraggingFrame(NSRect(origin: origin, size: previewSize), contents: dragImage)
            draggingItems.append(dragItem)
        }

        let session = beginDraggingSession(with: draggingItems, event: event, source: self)
        session.animatesToStartingPositionsOnCancelOrFail = true
        session.draggingFormation = .default
    }

    override func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        super.draggingSession(session, endedAt: screenPoint, operation: operation)
        isTrackingMouseInteraction = false
        hasStartedFileDrag = false
        marqueeView.isHidden = true
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let coordinator else { return nil }
        let pt = convert(event.locationInWindow, from: nil)
        let clickedRow = row(at: pt)
        guard clickedRow >= 0, let clickedItem = coordinator.item(at: clickedRow) else { return nil }

        let vm = coordinator.viewModel
        if !selectedRowIndexes.contains(clickedRow) {
            let single = IndexSet(integer: clickedRow)
            coordinator.isProgrammaticSelectionUpdate = true
            selectRowIndexes(single, byExtendingSelection: false)
            coordinator.isProgrammaticSelectionUpdate = false
            anchorRow = clickedRow
            coordinator.pushTableSelectionToViewModel(single, anchorRow: clickedRow)
        }

        let targetItems = vm.selectedItems.isEmpty ? [clickedItem] : vm.selectedItems
        let built = BrowserContextMenuBuilder.makeMenu(for: targetItems, viewModel: vm)
        contextMenuActionTargets = built.targets
        return built.menu
    }

    override func selectAll(_ sender: Any?) {
        super.selectAll(sender)
        coordinator?.pushTableSelectionToViewModel(selectedRowIndexes)
    }

    override func cancelOperation(_ sender: Any?) {
        coordinator?.viewModel.clearSelection()
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 49 || event.keyCode == 36 { // Space or Return
            if let first = coordinator?.viewModel.selectedItems.first {
                coordinator?.viewModel.openItem(first)
                return
            }
        }
        super.keyDown(with: event)
    }
}

// MARK: - Drag Preview & Native Context Menu Builders

private enum DragPreviewRenderer {
    static func makeDragImage(for item: MTPObjectItem, thumbnail: NSImage?, size: NSSize) -> NSImage {
        let img = NSImage(size: size)
        img.lockFocus()
        defer { img.unlockFocus() }

        let rect = NSRect(origin: .zero, size: size)
        let clipPath = NSBezierPath(roundedRect: rect.insetBy(dx: 1, dy: 1), xRadius: 7, yRadius: 7)
        NSGraphicsContext.current?.saveGraphicsState()
        clipPath.addClip()

        if let thumbnail, !item.isFolder {
            thumbnail.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 0.95)
        } else {
            NSColor.windowBackgroundColor.withAlphaComponent(0.95).setFill()
            rect.fill()
            let symbolName = item.isFolder ? "folder.fill" : (item.isVideo ? "video.fill" : "photo.fill")
            let cfg = NSImage.SymbolConfiguration(pointSize: min(size.height * 0.45, 30), weight: .regular)
            if let sym = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?.withSymbolConfiguration(cfg) {
                let symSize = sym.size
                let symRect = NSRect(
                    x: (size.width - symSize.width) * 0.5,
                    y: (size.height - symSize.height) * 0.5,
                    width: symSize.width,
                    height: symSize.height
                )
                sym.draw(in: symRect, from: .zero, operation: .sourceOver, fraction: 0.9)
            }
        }

        NSGraphicsContext.current?.restoreGraphicsState()
        NSColor.white.withAlphaComponent(0.35).setStroke()
        clipPath.lineWidth = 1.5
        clipPath.stroke()
        return img
    }
}

private final class ContextMenuActionTarget: NSObject {
    let handler: () -> Void

    init(_ handler: @escaping () -> Void) {
        self.handler = handler
    }

    @objc func invoke() {
        handler()
    }
}

private enum BrowserContextMenuBuilder {
    static func makeMenu(
        for items: [MTPObjectItem],
        viewModel: MTPViewModel
    ) -> (menu: NSMenu, targets: [ContextMenuActionTarget]) {
        let menu = NSMenu()
        var targets: [ContextMenuActionTarget] = []

        func addItem(title: String, systemImage: String, action: @escaping () -> Void) {
            let target = ContextMenuActionTarget(action)
            targets.append(target)
            let menuItem = NSMenuItem(title: title, action: #selector(ContextMenuActionTarget.invoke), keyEquivalent: "")
            menuItem.target = target
            menuItem.image = NSImage(systemSymbolName: systemImage, accessibilityDescription: nil)
            menu.addItem(menuItem)
        }

        if items.count == 1, let item = items.first {
            if item.isFolder {
                addItem(title: "Open", systemImage: "folder") {
                    viewModel.openItem(item)
                }
                menu.addItem(.separator())
                addItem(title: "Save to Downloads", systemImage: "arrow.down.circle") {
                    viewModel.quickSaveToDownloads([item])
                }
                addItem(title: "Export Folder…", systemImage: "folder.badge.plus") {
                    viewModel.promptAndExportFolders([item])
                }
            } else {
                addItem(
                    title: item.isVideo ? "Play Video" : "Quick Look",
                    systemImage: item.isVideo ? "play" : "eye"
                ) {
                    viewModel.openItem(item)
                }
                addItem(title: "Open in Default App", systemImage: "arrow.up.forward.app") {
                    viewModel.openInQuickLookOrDefaultApp(item)
                }
                menu.addItem(.separator())
                if item.isImage {
                    addItem(title: "Copy Image", systemImage: "doc.on.doc") {
                        viewModel.copyImageToClipboard(item)
                    }
                }
                addItem(title: "Save to Downloads", systemImage: "arrow.down.circle") {
                    viewModel.quickSaveToDownloads([item])
                }
                addItem(title: "Export…", systemImage: "folder") {
                    viewModel.promptAndExportItems([item])
                }
            }
            menu.addItem(.separator())
            addItem(title: "Get Info", systemImage: "info.circle") {
                viewModel.selectedItemIDs = [item.handle]
                viewModel.showInspector = true
            }
        } else if !items.isEmpty {
            addItem(
                title: "Save \(items.count) Items to Downloads",
                systemImage: "arrow.down.circle"
            ) {
                viewModel.quickSaveToDownloads(items)
            }
            addItem(
                title: "Export \(items.count) Items…",
                systemImage: "folder"
            ) {
                viewModel.promptAndExportItems(items)
            }
        }

        return (menu, targets)
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
