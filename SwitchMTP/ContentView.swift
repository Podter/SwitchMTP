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
    @State private var viewModel = MTPViewModel()
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    
    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView(viewModel: viewModel)
                .navigationSplitViewColumnWidth(min: 210, ideal: 240, max: 300)
        } detail: {
            MainBrowserPane(viewModel: viewModel)
                .frame(minWidth: 500, maxWidth: .infinity, maxHeight: .infinity)
        }
        .inspector(isPresented: $viewModel.showInspector) {
            InspectorPane(viewModel: viewModel)
                .inspectorColumnWidth(min: 260, ideal: 290, max: 360)
        }
        .navigationTitle(windowTitle)
        .navigationSubtitle(windowSubtitle)
        .searchable(text: $viewModel.searchText, placement: .toolbar, prompt: "Search")
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                if viewModel.breadcrumbs.count > 1 {
                    Button {
                        let parentStep = viewModel.breadcrumbs[viewModel.breadcrumbs.count - 2]
                        if parentStep.id == 0xFFFFFFFF {
                            viewModel.selectedSidebar = .storageRoot(parentStep.storageID)
                        } else {
                            Task {
                                await viewModel.navigateToDirectory(
                                    storageID: parentStep.storageID,
                                    parentHandle: parentStep.id,
                                    title: parentStep.title
                                )
                            }
                        }
                    } label: {
                        Label("Back", systemImage: "chevron.left")
                    }
                    .help("Go back to \(viewModel.breadcrumbs[viewModel.breadcrumbs.count - 2].title)")
                }
            }
            
            ToolbarItemGroup(placement: .primaryAction) {
                Picker("View", selection: $viewModel.viewMode) {
                    Label("Icons", systemImage: "square.grid.2x2").tag(BrowserViewMode.grid)
                    Label("List", systemImage: "list.bullet").tag(BrowserViewMode.table)
                }
                .pickerStyle(.segmented)
                .help("Change how items are shown")
                
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
                            Button("Small") { viewModel.gridZoom = 140 }
                            Button("Medium") { viewModel.gridZoom = 180 }
                            Button("Large") { viewModel.gridZoom = 240 }
                        }
                    }
                    
                    Divider()
                    
                    Button {
                        Task { await viewModel.refresh() }
                    } label: {
                        Label("Reload Device", systemImage: "arrow.clockwise")
                    }
                    .disabled(viewModel.isConnecting)
                } label: {
                    Label(
                        viewModel.mediaFilter == .all ? "Filter & Sort" : viewModel.mediaFilter.rawValue,
                        systemImage: viewModel.mediaFilter == .all
                            ? "line.3.horizontal.decrease.circle"
                            : "line.3.horizontal.decrease.circle.fill"
                    )
                }
                .help("Filter, sort, and view options")
                
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
                            viewModel.selectedItems.isEmpty ? "Save All to Downloads" : "Save (\(viewModel.selectedItems.count)) to Downloads",
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
                            viewModel.selectedItems.isEmpty ? "Export All to Folder…" : "Export (\(viewModel.selectedItems.count)) to Folder…",
                            systemImage: "folder"
                        )
                    }
                } label: {
                    Label(
                        viewModel.selectedItems.isEmpty ? "Save All" : "Save (\(viewModel.selectedItems.count))",
                        systemImage: "arrow.down.circle"
                    )
                }
                .disabled(!viewModel.isConnected || viewModel.filteredAndSortedItems.isEmpty)
                .help("Save to Downloads or export to a folder")
                
                Button {
                    viewModel.showInspector.toggle()
                } label: {
                    Label("Info", systemImage: viewModel.showInspector ? "info.circle.fill" : "info.circle")
                }
                .help("Show or hide item info")
            }
        }
        .sheet(item: $viewModel.fullScreenPreviewItem) { item in
            MediaLightboxSheet(viewModel: viewModel, item: item)
        }
    }
    
    private var windowTitle: String {
        if let lastCrumb = viewModel.breadcrumbs.last {
            return lastCrumb.title
        }
        return viewModel.deviceDetails?.displayName ?? "SwitchMTP"
    }
    
    private var windowSubtitle: String {
        guard viewModel.isConnected else { return "" }
        let count = viewModel.filteredAndSortedItems.count
        let selCount = viewModel.selectedItemIDs.count
        if selCount > 0 {
            return "\(selCount) of \(count) selected"
        }
        return "\(count) item\(count == 1 ? "" : "s")"
    }
}

// MARK: - Sidebar

private struct SidebarView: View {
    @Bindable var viewModel: MTPViewModel
    @State private var showDeviceInfo = false
    
    var body: some View {
        List(selection: $viewModel.selectedSidebar) {
            Section("Library") {
                NavigationLink(value: SidebarDestination.allMedia) {
                    Label("All Media", systemImage: "photo.on.rectangle")
                        .badge(viewModel.allMediaItems.isEmpty ? 0 : viewModel.allMediaItems.count)
                }
                
                NavigationLink(value: SidebarDestination.screenshots) {
                    Label("Screenshots", systemImage: "camera.viewfinder")
                        .badge(viewModel.hasLoadedAllMedia ? viewModel.allMediaItems.filter(\.isImage).count : 0)
                }
                
                NavigationLink(value: SidebarDestination.videos) {
                    Label("Videos", systemImage: "video")
                        .badge(viewModel.hasLoadedAllMedia ? viewModel.allMediaItems.filter(\.isVideo).count : 0)
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
        .safeAreaInset(edge: .bottom) {
            DeviceStatusFooter(viewModel: viewModel, showDeviceInfo: $showDeviceInfo)
        }
    }
}

private struct DeviceStatusFooter: View {
    var viewModel: MTPViewModel
    @Binding var showDeviceInfo: Bool
    
    var body: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 8) {
                Circle()
                    .fill(viewModel.isConnected ? Color.green : (viewModel.isConnecting ? Color.orange : Color.secondary.opacity(0.5)))
                    .frame(width: 8, height: 8)
                
                Text(viewModel.isConnected ? (viewModel.deviceDetails?.displayName ?? "Nintendo Switch") : (viewModel.isConnecting ? "Connecting…" : "Not Connected"))
                    .font(.subheadline)
                    .foregroundStyle(viewModel.isConnected ? .primary : .secondary)
                    .lineLimit(1)
                
                Spacer()
                
                if viewModel.isScanningAllMedia {
                    ProgressView()
                        .controlSize(.small)
                        .help("Indexing media…")
                } else if let details = viewModel.deviceDetails, viewModel.isConnected {
                    Button {
                        showDeviceInfo.toggle()
                    } label: {
                        Image(systemName: "info.circle")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Device Details")
                    .popover(isPresented: $showDeviceInfo, arrowEdge: .top) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(details.displayName)
                                .font(.headline)
                            
                            Text(viewModel.totalMediaCountSummary)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            
                            Divider()
                            
                            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
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
                        }
                        .padding(12)
                        .frame(minWidth: 200)
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
        .background(.bar)
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
            
            if viewModel.transferStatus != nil || viewModel.statusBanner != nil {
                Divider()
                BottomStatusBar(viewModel: viewModel)
            }
        }
    }
}

// MARK: - Grid View

private struct MediaGridView: View {
    @Bindable var viewModel: MTPViewModel
    
    var body: some View {
        let columns = [
            GridItem(.adaptive(minimum: viewModel.gridZoom, maximum: viewModel.gridZoom + 60), spacing: 16)
        ]
        
        ScrollView {
            LazyVGrid(columns: columns, spacing: 16) {
                ForEach(viewModel.filteredAndSortedItems) { item in
                    MediaGridCard(
                        item: item,
                        thumbnail: viewModel.thumbnails[item.handle],
                        isSelected: viewModel.selectedItemIDs.contains(item.handle),
                        showGameTag: viewModel.selectedSidebar == .allMedia || viewModel.selectedSidebar == .screenshots || viewModel.selectedSidebar == .videos,
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
            .padding(20)
        }
        .background(Color(nsColor: .textBackgroundColor))
    }
}

private struct MediaGridCard: View {
    let item: MTPObjectItem
    let thumbnail: NSImage?
    let isSelected: Bool
    let showGameTag: Bool
    let onPlay: () -> Void
    
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .bottomTrailing) {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.primary.opacity(0.05))
                    .aspectRatio(16.0 / 9.0, contentMode: .fit)
                    .overlay {
                        if item.isFolder {
                            Image(systemName: "folder.fill")
                                .font(.system(size: 40))
                                .foregroundStyle(.tint)
                        } else if let thumbnail {
                            Image(nsImage: thumbnail)
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                        } else {
                            ProgressView()
                                .controlSize(.small)
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(isSelected ? Color.accentColor : Color.primary.opacity(0.08), lineWidth: isSelected ? 3 : 1)
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
        .contentShape(Rectangle())
    }
    
    private var primaryLabel: String {
        if item.isFolder {
            return item.filename
        }
        if showGameTag && !item.folderName.isEmpty {
            return item.folderName
        }
        if let date = item.displayDate {
            return date.formatted(date: .abbreviated, time: .shortened)
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
        if showGameTag, let date = item.displayDate {
            return date.formatted(date: .abbreviated, time: .shortened)
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
                if let date = item.displayDate {
                    Text(date, format: .dateTime.year().month(.abbreviated).day().hour().minute())
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
                        // Media Preview Box
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
                                    ProgressView()
                                        .controlSize(.small)
                                }
                            }
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        
                        // Title & Subtitle
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.isFolder ? item.filename : (item.folderName.isEmpty ? item.filename : item.folderName))
                                .font(.headline)
                                .textSelection(.enabled)
                            
                            Text(item.isFolder ? item.formattedSize : item.filename)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                        
                        // Primary Actions
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
                        
                        // Standard Info
                        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 8) {
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
                            if let date = item.displayDate {
                                GridRow {
                                    Text("Created")
                                        .foregroundStyle(.secondary)
                                    Text(date.formatted(date: .abbreviated, time: .shortened))
                                }
                            }
                        }
                        .font(.subheadline)
                        
                        Divider()
                        
                        // Hidden Technical Details
                        VStack(alignment: .leading, spacing: 8) {
                            Button {
                                withAnimation(.easeInOut(duration: 0.15)) {
                                    showTechnicalDetails.toggle()
                                }
                            } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: showTechnicalDetails ? "chevron.down" : "chevron.right")
                                        .font(.caption2.weight(.semibold))
                                        .frame(width: 10, alignment: .center)
                                    Text("Advanced Details")
                                        .font(.subheadline)
                                    Spacer()
                                }
                                .foregroundStyle(.secondary)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            
                            if showTechnicalDetails {
                                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 8) {
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
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
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
                    VStack(alignment: .center, spacing: 8) {
                        HStack(alignment: .center, spacing: 6) {
                            Image(systemName: "gearshape")
                                .frame(width: 16, alignment: .center)
                            Text("1. Open **System Settings** on your Switch")
                        }
                        HStack(alignment: .center, spacing: 6) {
                            Image(systemName: "photo.on.rectangle")
                                .frame(width: 16, alignment: .center)
                            Text("2. Select **Data Management → Manage Screenshots and Videos**")
                        }
                        HStack(alignment: .center, spacing: 6) {
                            Image(systemName: "cable.connector")
                                .frame(width: 16, alignment: .center)
                            Text("3. Choose **Copy to a Computer via USB Connection**")
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                }
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct BottomStatusBar: View {
    var viewModel: MTPViewModel
    
    var body: some View {
        HStack(spacing: 10) {
            if let transfer = viewModel.transferStatus {
                ProgressView(value: transfer.fractionCompleted)
                    .frame(width: 120)
                Text("\(transfer.title) \(transfer.currentFile)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            } else if let banner = viewModel.statusBanner {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.caption)
                Text(banner)
                    .font(.caption)
            }
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .background(.bar)
    }
}

// MARK: - Full-Size Lightbox Sheet

private struct MediaLightboxSheet: View {
    @Bindable var viewModel: MTPViewModel
    let item: MTPObjectItem
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(item.folderName.isEmpty ? item.filename : item.folderName)
                    .font(.headline)
                    .lineLimit(1)
                
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

#Preview {
    ContentView()
}
