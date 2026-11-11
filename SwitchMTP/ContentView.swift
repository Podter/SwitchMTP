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
    
    var body: some View {
        NavigationSplitView {
            SidebarView(viewModel: viewModel)
                .navigationSplitViewColumnWidth(min: 230, ideal: 265, max: 340)
        } detail: {
            HSplitView {
                MainBrowserPane(viewModel: viewModel)
                    .frame(minWidth: 520, maxWidth: .infinity, maxHeight: .infinity)
                
                if viewModel.showInspector {
                    InspectorPane(viewModel: viewModel)
                        .frame(minWidth: 280, idealWidth: 320, maxWidth: 380, maxHeight: .infinity)
                }
            }
        }
        .navigationTitle(windowTitle)
        .navigationSubtitle(windowSubtitle)
        . searchable(text: $viewModel.searchText, placement: .toolbar, prompt: "Search files or games…")
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                Button {
                    Task { await viewModel.refresh() }
                } label: {
                    Label("Refresh USB", systemImage: "arrow.clockwise")
                }
                .help("Rescan USB bus and refresh Nintendo Switch MTP session")
                .disabled(viewModel.isConnecting)
            }
            
            ToolbarItemGroup(placement: .primaryAction) {
                Picker("View", selection: $viewModel.viewMode) {
                    Label("Grid", systemImage: "square.grid.2x2").tag(BrowserViewMode.grid)
                    Label("List", systemImage: "list.bullet").tag(BrowserViewMode.table)
                }
                .pickerStyle(.segmented)
                .help("Switch between thumbnail grid and detailed list view")
                
                Picker("Sort By", selection: $viewModel.sortOrder) {
                    ForEach(MediaSortOrder.allCases) { order in
                        Text(order.rawValue).tag(order)
                    }
                }
                .frame(width: 175)
                .help("Sort items")
                
                Button {
                    if !viewModel.selectedItems.isEmpty {
                        viewModel.quickSaveToDownloads(viewModel.selectedItems)
                    } else {
                        let visibleMedia = viewModel.filteredAndSortedItems.filter { !$0.isFolder }
                        viewModel.quickSaveToDownloads(visibleMedia)
                    }
                } label: {
                    Label(
                        viewModel.selectedItems.isEmpty ? "Save All to Downloads" : "Save (\(viewModel.selectedItems.count))",
                        systemImage: "arrow.down.circle"
                    )
                }
                .disabled(!viewModel.isConnected || viewModel.filteredAndSortedItems.isEmpty)
                .help("Quickly save selected or visible items into ~/Downloads/Nintendo Switch Album")
                
                Button {
                    if !viewModel.selectedItems.isEmpty {
                        viewModel.promptAndExportItems(viewModel.selectedItems)
                    } else {
                        viewModel.promptAndExportAllVisible()
                    }
                } label: {
                    Label(
                        viewModel.selectedItems.isEmpty ? "Export All…" : "Export (\(viewModel.selectedItems.count))…",
                        systemImage: "square.and.arrow.up"
                    )
                }
                .disabled(!viewModel.isConnected || viewModel.filteredAndSortedItems.isEmpty)
                .help("Choose a destination folder on your Mac to export files")
                
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        viewModel.showInspector.toggle()
                    }
                } label: {
                    Label("Inspector", systemImage: "sidebar.right")
                }
                .help("Toggle preview and metadata inspector")
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
        guard viewModel.isConnected else { return "Not Connected" }
        let count = viewModel.filteredAndSortedItems.count
        let selCount = viewModel.selectedItemIDs.count
        if selCount > 0 {
            return "\(count) items • \(selCount) selected"
        }
        return "\(count) item\(count == 1 ? "" : "s")"
    }
}

// MARK: - Sidebar

private struct SidebarView: View {
    @Bindable var viewModel: MTPViewModel
    
    var body: some View {
        VStack(spacing: 0) {
            DeviceHeaderCard(viewModel: viewModel)
                .padding(10)
            
            Divider()
            
            List(selection: $viewModel.selectedSidebar) {
                Section("Library") {
                    NavigationLink(value: SidebarDestination.allMedia) {
                        HStack {
                            Label("All Media", systemImage: "photo.on.rectangle.angled")
                            Spacer()
                            if viewModel.isScanningAllMedia {
                                ProgressView()
                                    .controlSize(.mini)
                            } else if !viewModel.allMediaItems.isEmpty {
                                Text("\(viewModel.allMediaItems.count)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    
                    NavigationLink(value: SidebarDestination.screenshots) {
                        HStack {
                            Label("Screenshots", systemImage: "camera.viewfinder")
                            Spacer()
                            if viewModel.hasLoadedAllMedia {
                                Text("\(viewModel.allMediaItems.filter(\.isImage).count)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    
                    NavigationLink(value: SidebarDestination.videos) {
                        HStack {
                            Label("Videos", systemImage: "video")
                            Spacer()
                            if viewModel.hasLoadedAllMedia {
                                Text("\(viewModel.allMediaItems.filter(\.isVideo).count)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                
                if !viewModel.storages.isEmpty {
                    Section("MTP Storage") {
                        ForEach(viewModel.storages) { storage in
                            NavigationLink(value: SidebarDestination.storageRoot(storage.id)) {
                                HStack {
                                    Label(storage.displayName, systemImage: "externaldrive.fill.badge.checkmark")
                                    Spacer()
                                    Text("\(viewModel.rootFolders.count) folders")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
                
                if !viewModel.rootFolders.isEmpty {
                    Section("Games & Folders (\(viewModel.rootFolders.count))") {
                        ForEach(viewModel.rootFolders) { folder in
                            NavigationLink(value: SidebarDestination.gameFolder(folder.handle)) {
                                HStack(spacing: 8) {
                                    Image(systemName: "folder.fill")
                                        .foregroundStyle(.tint)
                                    Text(folder.filename)
                                        .lineLimit(1)
                                        .truncationMode(.tail)
                                    Spacer()
                                    if let count = folder.childCount {
                                        Text("\(count)")
                                            .font(.caption2.monospacedDigit())
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 1)
                                            .background(.quaternary, in: Capsule())
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                            .contextMenu {
                                Button {
                                    viewModel.promptAndExportFolders([folder])
                                } label: {
                                    Label("Export Folder \"\(folder.filename)\"…", systemImage: "square.and.arrow.up")
                                }
                                
                                Button {
                                    viewModel.quickSaveToDownloads([folder])
                                } label: {
                                    Label("Save Folder to Downloads", systemImage: "arrow.down.circle")
                                }
                            }
                        }
                    }
                }
            }
            .listStyle(.sidebar)
        }
    }
}

private struct DeviceHeaderCard: View {
    var viewModel: MTPViewModel
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(viewModel.isConnected ? Color.red.opacity(0.15) : Color.secondary.opacity(0.12))
                        .frame(width: 38, height: 38)
                    Image(systemName: "gamecontroller.fill")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(viewModel.isConnected ? .red : .secondary)
                }
                
                VStack(alignment: .leading, spacing: 2) {
                    Text(viewModel.deviceDetails?.displayName ?? "Nintendo Switch")
                        .font(.headline)
                        .lineLimit(1)
                    
                    HStack(spacing: 5) {
                        Circle()
                            .fill(viewModel.isConnected ? Color.green : (viewModel.isConnecting ? Color.orange : Color.red))
                            .frame(width: 7, height: 7)
                        Text(viewModel.isConnected ? "Connected via USB (MTP)" : (viewModel.isConnecting ? "Connecting…" : "Disconnected"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }
            
            if let details = viewModel.deviceDetails, viewModel.isConnected {
                Divider()
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text("System")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(details.deviceVersion.isEmpty ? "MTP 1.0" : "FW \(details.deviceVersion)")
                            .fontWeight(.medium)
                    }
                    if !details.serialNumber.isEmpty {
                        HStack {
                            Text("Serial")
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text(details.serialNumber)
                                .monospaced()
                        }
                    }
                    HStack {
                        Text("USB ID")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(String(format: "%04X:%04X", details.vendorID, details.productID))
                            .monospaced()
                    }
                    HStack {
                        Text("Album")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(viewModel.totalMediaCountSummary)
                            .fontWeight(.medium)
                    }
                }
                .font(.caption2)
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

// MARK: - Main Browser Area

private struct MainBrowserPane: View {
    @Bindable var viewModel: MTPViewModel
    
    var body: some View {
        VStack(spacing: 0) {
            SubheaderFilterBar(viewModel: viewModel)
            Divider()
            
            ZStack {
                if !viewModel.isConnected {
                    DisconnectedPlaceholderView(viewModel: viewModel)
                } else if viewModel.isLoadingDirectory && viewModel.currentItems.isEmpty {
                    VStack(spacing: 12) {
                        ProgressView()
                            .controlSize(.large)
                        Text(viewModel.isScanningAllMedia ? "Scanning Nintendo Switch Album folders…" : "Loading MTP directory…")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if viewModel.filteredAndSortedItems.isEmpty {
                    ContentUnavailableView {
                        Label("No Items Found", systemImage: "photo.on.rectangle.angled")
                    } description: {
                        if !viewModel.searchText.isEmpty {
                            Text("No screenshots, videos, or folders match \"\(viewModel.searchText)\".")
                        } else {
                            Text("This folder does not contain any matching media.")
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
                        .font(.caption)
                        .lineLimit(1)
                    Spacer()
                    Button("Dismiss") {
                        viewModel.errorMessage = nil
                    }
                    .buttonStyle(.borderless)
                    .font(.caption)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Color.orange.opacity(0.1))
            }
            
            Divider()
            BottomStatusBar(viewModel: viewModel)
        }
    }
}

private struct SubheaderFilterBar: View {
    @Bindable var viewModel: MTPViewModel
    
    var body: some View {
        HStack(spacing: 12) {
            // Breadcrumbs
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(Array(viewModel.breadcrumbs.enumerated()), id: \.element.id) { idx, step in
                        if idx > 0 {
                            Image(systemName: "chevron.right")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                        Button {
                            guard idx < viewModel.breadcrumbs.count - 1 else { return }
                            if step.id == 0xFFFFFFFF {
                                viewModel.selectedSidebar = .storageRoot(step.storageID)
                            } else {
                                Task {
                                    await viewModel.navigateToDirectory(
                                        storageID: step.storageID,
                                        parentHandle: step.id,
                                        title: step.title
                                    )
                                }
                            }
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: step.id == 0xFFFFFFFF ? "externaldrive.fill" : "folder.fill")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text(step.title)
                                    .font(.subheadline.weight(idx == viewModel.breadcrumbs.count - 1 ? .semibold : .regular))
                                    .lineLimit(1)
                            }
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(
                                idx == viewModel.breadcrumbs.count - 1
                                    ? Color.primary.opacity(0.07)
                                    : Color.clear,
                                in: RoundedRectangle(cornerRadius: 6)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            
            Spacer()
            
            Picker("Filter", selection: $viewModel.mediaFilter) {
                ForEach(MediaTypeFilter.allCases) { filter in
                    Text(filter.rawValue).tag(filter)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 210)
            
            if viewModel.viewMode == .grid {
                HStack(spacing: 4) {
                    Image(systemName: "photo")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Slider(value: $viewModel.gridZoom, in: 130...280)
                        .frame(width: 80)
                    Image(systemName: "photo.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .fixedSize()
                .help("Adjust thumbnail grid size")
            }
            
            Toggle("Group by Game", isOn: $viewModel.organizeExportsByGame)
                .toggleStyle(.checkbox)
                .font(.caption)
                .fixedSize()
                .help("When exporting, place files into subfolders named after their Game Title")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.bar)
    }
}

// MARK: - Grid View

private struct MediaGridView: View {
    @Bindable var viewModel: MTPViewModel
    
    var body: some View {
        let columns = [
            GridItem(.adaptive(minimum: viewModel.gridZoom, maximum: viewModel.gridZoom + 60), spacing: 14)
        ]
        
        ScrollView {
            LazyVGrid(columns: columns, spacing: 14) {
                ForEach(viewModel.filteredAndSortedItems) { item in
                    MediaGridCard(
                        item: item,
                        thumbnail: viewModel.thumbnails[item.handle],
                        isSelected: viewModel.selectedItemIDs.contains(item.handle),
                        showGameTag: viewModel.selectedSidebar == .allMedia || viewModel.selectedSidebar == .screenshots || viewModel.selectedSidebar == .videos
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
            .padding(16)
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }
}

private struct MediaGridCard: View {
    let item: MTPObjectItem
    let thumbnail: NSImage?
    let isSelected: Bool
    let showGameTag: Bool
    
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .bottomTrailing) {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.secondary.opacity(0.12))
                    .aspectRatio(16.0 / 9.0, contentMode: .fit)
                    .overlay {
                        if item.isFolder {
                            VStack(spacing: 6) {
                                Image(systemName: "folder.fill")
                                    .font(.system(size: 38))
                                    .foregroundStyle(.tint)
                                if let count = item.childCount {
                                    Text("\(count) item\(count == 1 ? "" : "s")")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        } else if let thumbnail {
                            Image(nsImage: thumbnail)
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                        } else {
                            VStack(spacing: 6) {
                                ProgressView()
                                    .controlSize(.small)
                                Image(systemName: item.isVideo ? "film" : "photo")
                                    .font(.title3)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                
                if item.isVideo {
                    HStack(spacing: 4) {
                        Image(systemName: "play.fill")
                            .font(.system(size: 9, weight: .bold))
                        Text("VIDEO")
                            .font(.system(size: 9, weight: .bold))
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(.black.opacity(0.75), in: Capsule())
                    .foregroundStyle(.white)
                    .padding(6)
                }
            }
            
            VStack(alignment: .leading, spacing: 2) {
                if showGameTag && !item.folderName.isEmpty && !item.isFolder {
                    Text(item.folderName)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.tint)
                        .lineLimit(1)
                }
                
                Text(item.filename)
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                
                HStack {
                    if let date = item.displayDate {
                        Text(date, format: .dateTime.year().month(.abbreviated).day().hour().minute())
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    } else {
                        Text(item.kindDescription)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(item.formattedSize)
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 4)
        }
        .padding(6)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isSelected ? Color.accentColor.opacity(0.18) : Color(nsColor: .windowBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(isSelected ? Color.accentColor : Color.primary.opacity(0.08), lineWidth: isSelected ? 2 : 1)
        )
    }
}

// MARK: - Table View

private struct MediaTableView: View {
    @Bindable var viewModel: MTPViewModel
    
    var body: some View {
        Table(viewModel.filteredAndSortedItems, selection: $viewModel.selectedItemIDs) {
            TableColumn("Name") { item in
                HStack(spacing: 8) {
                    if item.isFolder {
                        Image(systemName: "folder.fill")
                            .foregroundStyle(.tint)
                            .frame(width: 28, height: 18)
                    } else if let thumb = viewModel.thumbnails[item.handle] {
                        Image(nsImage: thumb)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: 32, height: 18)
                            .clipShape(RoundedRectangle(cornerRadius: 3))
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
            .width(min: 180, ideal: 240)
            
            TableColumn("Game / Folder") { item in
                Text(item.isFolder ? "Album" : (item.folderName.isEmpty ? "—" : item.folderName))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .width(min: 120, ideal: 180)
            
            TableColumn("Kind") { item in
                Text(item.kindDescription)
                    .foregroundStyle(.secondary)
            }
            .width(min: 90, ideal: 115)
            
            TableColumn("Dimensions") { item in
                Text(item.dimensionsDescription)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .width(min: 80, ideal: 95)
            
            TableColumn("Size") { item in
                Text(item.formattedSize)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .width(min: 75, ideal: 90)
            
            TableColumn("Date Captured") { item in
                if let date = item.displayDate {
                    Text(date, format: .dateTime.year().month(.abbreviated).day().hour().minute().second())
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                } else {
                    Text("—")
                        .foregroundStyle(.tertiary)
                }
            }
            .width(min: 130, ideal: 160)
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
                    Label("Export \(items.count) Items…", systemImage: "square.and.arrow.up")
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
                Label("Open Folder", systemImage: "folder")
            }
            Divider()
            Button {
                viewModel.quickSaveToDownloads([item])
            } label: {
                Label("Save Folder to Downloads", systemImage: "arrow.down.circle")
            }
            Button {
                viewModel.promptAndExportFolders([item])
            } label: {
                Label("Export Folder…", systemImage: "square.and.arrow.up")
            }
        } else {
            Button {
                viewModel.openItem(item)
            } label: {
                Label(item.isVideo ? "Play Video" : "View Full Size", systemImage: item.isVideo ? "play.rectangle" : "magnifyingglass")
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
                    Label("Copy Image to Clipboard", systemImage: "doc.on.doc")
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
                Label("Export File…", systemImage: "square.and.arrow.up")
            }
        }
    }
}

// MARK: - Inspector Pane

private struct InspectorPane: View {
    @Bindable var viewModel: MTPViewModel
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Inspector")
                    .font(.headline)
                Spacer()
                if viewModel.isLoadingPreview {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            .padding(12)
            
            Divider()
            
            if let item = viewModel.inspectedItem {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        // Media Preview Box
                        ZStack {
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(Color.black.opacity(0.88))
                                .aspectRatio(16.0 / 9.0, contentMode: .fit)
                            
                            if item.isFolder {
                                VStack(spacing: 8) {
                                    Image(systemName: "folder.fill")
                                        .font(.system(size: 46))
                                        .foregroundStyle(.tint)
                                    Text(item.formattedSize)
                                        .font(.caption)
                                        .foregroundStyle(.white.opacity(0.8))
                                }
                            } else if item.isVideo, let player = viewModel.previewPlayer {
                                MacVideoPlayerView(player: player)
                                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                            } else if let preview = viewModel.previewImage ?? viewModel.thumbnails[item.handle] {
                                Image(nsImage: preview)
                                    .resizable()
                                    .aspectRatio(contentMode: .fit)
                                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                                    .onTapGesture(count: 2) {
                                        viewModel.fullScreenPreviewItem = item
                                    }
                            } else {
                                ProgressView()
                                    .tint(.white)
                            }
                        }
                        
                        // Action Buttons
                        VStack(spacing: 8) {
                            HStack(spacing: 8) {
                                Button {
                                    viewModel.quickSaveToDownloads([item])
                                } label: {
                                    Label("Save to Downloads", systemImage: "arrow.down.circle.fill")
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
                                    Label("Export…", systemImage: "folder.badge.plus")
                                }
                                .buttonStyle(.bordered)
                            }
                            
                            if !item.isFolder {
                                HStack(spacing: 8) {
                                    if item.isImage {
                                        Button {
                                            viewModel.copyImageToClipboard(item)
                                        } label: {
                                            Label("Copy Image", systemImage: "doc.on.doc")
                                                .frame(maxWidth: .infinity)
                                        }
                                        .buttonStyle(.bordered)
                                    }
                                    
                                    Button {
                                        viewModel.fullScreenPreviewItem = item
                                    } label: {
                                        Label("Expand", systemImage: "arrow.up.left.and.arrow.down.right")
                                            .frame(maxWidth: .infinity)
                                    }
                                    .buttonStyle(.bordered)
                                    
                                    Button {
                                        viewModel.openInQuickLookOrDefaultApp(item)
                                    } label: {
                                        Label("Open", systemImage: "arrow.up.forward.app")
                                            .frame(maxWidth: .infinity)
                                    }
                                    .buttonStyle(.bordered)
                                }
                            }
                        }
                        
                        Divider()
                        
                        // Metadata rows
                        VStack(alignment: .leading, spacing: 8) {
                            Text("MTP Object Metadata")
                                .font(.subheadline.weight(.semibold))
                            
                            MetadataRow(label: "Filename", value: item.filename)
                            if !item.folderName.isEmpty {
                                MetadataRow(label: "Game / Folder", value: item.folderName)
                            }
                            MetadataRow(label: "Kind", value: item.kindDescription)
                            if item.imageWidth > 0 && item.imageHeight > 0 {
                                MetadataRow(label: "Resolution", value: item.dimensionsDescription)
                            }
                            MetadataRow(label: "Size", value: "\(item.formattedSize) (\(item.compressedSize.formatted()) B)")
                            if let date = item.displayDate {
                                MetadataRow(
                                    label: "Captured",
                                    value: date.formatted(date: .abbreviated, time: .standard)
                                )
                            }
                            MetadataRow(label: "Object Handle", value: String(format: "0x%08X", item.handle), monospaced: true)
                            MetadataRow(label: "Parent Handle", value: String(format: "0x%08X", item.parentHandle), monospaced: true)
                            MetadataRow(label: "Storage ID", value: String(format: "0x%08X", item.storageID), monospaced: true)
                            MetadataRow(label: "Format Code", value: String(format: "0x%04X", item.formatCode), monospaced: true)
                        }
                    }
                    .padding(14)
                }
            } else {
                ContentUnavailableView {
                    Label("No Selection", systemImage: "sidebar.right")
                } description: {
                    Text("Select a screenshot, video, or folder to preview it and inspect its MTP properties.")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(.background)
    }
}

private struct MetadataRow: View {
    let label: String
    let value: String
    var monospaced: Bool = false
    
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(monospaced ? .caption.monospaced() : .caption)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Disconnected State & Bottom Bar

private struct DisconnectedPlaceholderView: View {
    var viewModel: MTPViewModel
    
    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "cable.connector.horizontal")
                .font(.system(size: 48, weight: .light))
                .foregroundStyle(.secondary)
            
            VStack(spacing: 6) {
                Text("Connect Your Nintendo Switch via USB")
                    .font(.title2.weight(.semibold))
                Text(viewModel.errorMessage ?? "Waiting for Nintendo Switch in MTP mode (VID 0x057E / PID 0x201D)…")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 460)
            }
            
            VStack(alignment: .leading, spacing: 10) {
                Text("How to enable USB file transfer on Nintendo Switch:")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                
                Label("1. Open **System Settings** on your Nintendo Switch", systemImage: "gearshape")
                Label("2. Go to **Data Management → Manage Screenshots and Videos**", systemImage: "photo.on.rectangle")
                Label("3. Select **Copy to a Computer via USB Connection**", systemImage: "cable.connector")
            }
            .font(.caption)
            .padding(14)
            .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            
            Button {
                Task { await viewModel.connectToDevice() }
            } label: {
                Label(viewModel.isConnecting ? "Connecting…" : "Scan & Connect Now", systemImage: "bolt.horizontal.fill")
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(viewModel.isConnecting)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct BottomStatusBar: View {
    var viewModel: MTPViewModel
    
    var body: some View {
        HStack(spacing: 12) {
            if let transfer = viewModel.transferStatus {
                ProgressView(value: transfer.fractionCompleted)
                    .frame(width: 140)
                Text("\(transfer.title) \(transfer.currentFile)")
                    .font(.caption)
                    .lineLimit(1)
                if transfer.bytesPerSecond > 0 {
                    Text(String(format: "(%.1f MB/s)", transfer.bytesPerSecond / 1_048_576.0))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            } else if let banner = viewModel.statusBanner {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.caption)
                Text(banner)
                    .font(.caption.weight(.medium))
            } else {
                let items = viewModel.filteredAndSortedItems
                let totalBytes = items.reduce(UInt64(0)) { $0 + $1.compressedSize }
                Text("\(items.count) item\(items.count == 1 ? "" : "s") (\(ByteCountFormatter.string(fromByteCount: Int64(totalBytes), countStyle: .file)))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                
                if !viewModel.selectedItems.isEmpty {
                    let selBytes = viewModel.selectedItems.reduce(UInt64(0)) { $0 + $1.compressedSize }
                    Text("• \(viewModel.selectedItems.count) selected (\(ByteCountFormatter.string(fromByteCount: Int64(selBytes), countStyle: .file)))")
                        .font(.caption.weight(.medium))
                }
            }
            
            Spacer()
            
            if viewModel.isConnected && !viewModel.filteredAndSortedItems.isEmpty {
                Button("Select All") {
                    viewModel.selectAll()
                }
                .buttonStyle(.borderless)
                .font(.caption)
                
                if !viewModel.selectedItemIDs.isEmpty {
                    Button("Deselect") {
                        viewModel.clearSelection()
                    }
                    .buttonStyle(.borderless)
                    .font(.caption)
                }
            }
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
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.filename)
                        .font(.headline)
                    if !item.folderName.isEmpty {
                        Text("\(item.folderName) • \(item.dimensionsDescription) • \(item.formattedSize)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                
                Spacer()
                
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
                    Label("Save to Downloads", systemImage: "arrow.down.circle.fill")
                }
                .buttonStyle(.borderedProminent)
                
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
            }
            .padding(14)
            .background(.bar)
            
            Divider()
            
            ZStack {
                Color.black
                
                if item.isVideo, let player = viewModel.previewPlayer {
                    MacVideoPlayerView(player: player)
                        .onAppear { player.play() }
                } else if let img = viewModel.previewImage ?? viewModel.thumbnails[item.handle] {
                    Image(nsImage: img)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                } else {
                    ProgressView("Loading full resolution from Nintendo Switch…")
                        .foregroundStyle(.white)
                }
            }
            .frame(minWidth: 820, minHeight: 480)
        }
        .onAppear {
            if viewModel.inspectedItem?.handle != item.handle {
                viewModel.selectedItemIDs = [item.handle]
            }
        }
    }
}

struct MacVideoPlayerView: NSViewRepresentable {
    let player: AVPlayer
    
    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .inline
        view.player = player
        return view
    }
    
    func updateNSView(_ nsView: AVPlayerView, context: Context) {
        if nsView.player !== player {
            nsView.player = player
        }
    }
}

#Preview {
    ContentView()
}
