//
//  MTPViewModel.swift
//  SwitchMTP
//

import Foundation
import SwiftUI
import AppKit
import AVFoundation
import UniformTypeIdentifiers

enum SidebarDestination: Hashable, Identifiable {
    case allMedia
    case screenshots
    case videos
    case storageRoot(UInt32)
    case gameFolder(UInt32)
    
    var id: String {
        switch self {
        case .allMedia: return "allMedia"
        case .screenshots: return "screenshots"
        case .videos: return "videos"
        case .storageRoot(let sid): return "storage_\(sid)"
        case .gameFolder(let handle): return "folder_\(handle)"
        }
    }
}

enum MediaTypeFilter: String, CaseIterable, Identifiable {
    case all = "All"
    case screenshots = "Screenshots"
    case videos = "Videos"
    
    var id: String { rawValue }
}

enum MediaSortOrder: String, CaseIterable, Identifiable {
    case dateNewest = "Date (Newest First)"
    case dateOldest = "Date (Oldest First)"
    case nameAscending = "Name (A–Z)"
    case sizeLargest = "Size (Largest First)"
    case gameTitle = "Game Title"
    
    var id: String { rawValue }
}

enum BrowserViewMode: String, CaseIterable, Identifiable {
    case grid = "Grid"
    case table = "List"
    
    var id: String { rawValue }
}

struct BreadcrumbStep: Identifiable, Equatable {
    let id: UInt32 // 0xFFFFFFFF for root
    let storageID: UInt32
    let title: String
}

struct TransferStatus: Equatable {
    var title: String
    var currentFile: String
    var completedFiles: Int
    var totalFiles: Int
    var currentBytes: Int64
    var totalBytes: Int64
    var bytesPerSecond: Double
    
    var fractionCompleted: Double {
        if totalFiles > 1 {
            let filePart = Double(completedFiles) / Double(max(1, totalFiles))
            let currentPart = totalBytes > 0 ? (Double(currentBytes) / Double(totalBytes)) / Double(max(1, totalFiles)) : 0
            return min(1.0, max(0.0, filePart + currentPart))
        } else if totalBytes > 0 {
            return min(1.0, max(0.0, Double(currentBytes) / Double(totalBytes)))
        }
        return 0
    }
}

@Observable
final class MTPViewModel {
    private let client = MTPUSBClient()
    
    var isConnected: Bool = false
    var isConnecting: Bool = false
    var isLoadingDirectory: Bool = false
    var isScanningAllMedia: Bool = false
    var errorMessage: String? = nil
    var statusBanner: String? = nil
    
    var deviceDetails: MTPDeviceDetails? = nil
    var storages: [MTPStorage] = []
    var rootFolders: [MTPObjectItem] = []
    
    var selectedSidebar: SidebarDestination? = .allMedia {
        didSet {
            if oldValue != selectedSidebar {
                handleSidebarSelectionChange()
            }
        }
    }
    
    var breadcrumbs: [BreadcrumbStep] = []
    var currentItems: [MTPObjectItem] = [] {
        didSet {
            rebuildFilteredItems()
        }
    }
    var allMediaItems: [MTPObjectItem] = [] {
        didSet {
            allScreenshotsCount = allMediaItems.reduce(0) { $0 + ($1.isImage ? 1 : 0) }
            allVideosCount = allMediaItems.reduce(0) { $0 + ($1.isVideo ? 1 : 0) }
        }
    }
    private(set) var allScreenshotsCount: Int = 0
    private(set) var allVideosCount: Int = 0
    private(set) var filteredAndSortedItems: [MTPObjectItem] = []
    var hasLoadedAllMedia: Bool = false
    
    var selectedItemIDs: Set<UInt32> = [] {
        didSet {
            handlePrimarySelectionChange()
        }
    }
    @ObservationIgnored var selectionAnchorHandle: UInt32? = nil
    @ObservationIgnored lazy var dragCoordinator = MTPDragExportCoordinator(client: client, viewModel: self)
    
    var searchText: String = "" {
        didSet {
            if oldValue != searchText {
                rebuildFilteredItems()
            }
        }
    }
    var mediaFilter: MediaTypeFilter = .all {
        didSet {
            if oldValue != mediaFilter {
                rebuildFilteredItems()
            }
        }
    }
    var sortOrder: MediaSortOrder = .dateNewest {
        didSet {
            if oldValue != sortOrder {
                rebuildFilteredItems()
            }
        }
    }
    var viewMode: BrowserViewMode = .grid
    var gridZoom: Double = 2
    var showInspector: Bool = false {
        didSet {
            if showInspector, let item = inspectedItem {
                schedulePreviewLoad(for: item)
            }
        }
    }
    
    var thumbnails: [UInt32: NSImage] = [:]
    private(set) var isLoadingThumbnails: Bool = false
    @ObservationIgnored private var loadingThumbnails: Set<UInt32> = []
    @ObservationIgnored private var pendingThumbnailQueue: [UInt32] = []
    @ObservationIgnored private var thumbnailWorkerTask: Task<Void, Never>? = nil
    @ObservationIgnored private var previewLoadTask: Task<Void, Never>? = nil
    @ObservationIgnored private var folderItemsCache: [UInt32: [MTPObjectItem]] = [:]
    
    // Preview state
    var inspectedItem: MTPObjectItem? = nil
    var isLoadingPreview: Bool = false
    var previewImage: NSImage? = nil
    var previewVideoURL: URL? = nil
    var previewPlayer: AVPlayer? = nil
    var fullScreenPreviewItem: MTPObjectItem? = nil {
        didSet {
            if let item = fullScreenPreviewItem {
                loadPreview(for: item, forLightbox: true)
            } else {
                previewPlayer?.pause()
                previewPlayer = nil
            }
        }
    }
    
    // Transfer state
    var transferStatus: TransferStatus? = nil
    private(set) var isTransferring: Bool = false
    
    var isWorking: Bool {
        isConnecting || isLoadingDirectory || isScanningAllMedia || isLoadingThumbnails || isTransferring
    }
    
    var canGoBack: Bool {
        breadcrumbs.count > 1
    }
    
    func navigateBack() {
        guard breadcrumbs.count > 1 else { return }
        let parentStep = breadcrumbs[breadcrumbs.count - 2]
        if parentStep.id == 0xFFFFFFFF {
            selectedSidebar = .storageRoot(parentStep.storageID)
        } else {
            Task {
                await navigateToDirectory(
                    storageID: parentStep.storageID,
                    parentHandle: parentStep.id,
                    title: parentStep.title
                )
            }
        }
    }
    
    private var usbMonitorTask: Task<Void, Never>? = nil
    
    static var isRunningInPreview: Bool {
        ProcessInfo.processInfo.environment["XCODE_RUNNING_FOR_PREVIEWS"] == "1"
    }
    
    init() {
        guard !Self.isRunningInPreview else { return }
        startUSBMonitoring()
    }
    
    func startUSBMonitoring() {
        usbMonitorTask?.cancel()
        usbMonitorTask = Task { [weak self] in
            guard let self else { return }
            await self.connectToDevice()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled else { break }
                let present = MTPUSBClient.isSwitchPresentInRegistry()
                if present && !self.isConnected && !self.isConnecting {
                    await self.connectToDevice()
                } else if !present && self.isConnected {
                    await self.handleUnexpectedDisconnect()
                }
            }
        }
    }
    
    func connectToDevice() async {
        guard !isConnecting else { return }
        isConnecting = true
        errorMessage = nil
        
        do {
            let details = try await client.connect()
            self.deviceDetails = details
            self.isConnected = true
            
            let fetchedStorages = try await client.fetchStorages()
            self.storages = fetchedStorages
            
            self.folderItemsCache.removeAll()
            self.allMediaItems.removeAll()
            self.hasLoadedAllMedia = false
            
            if let primaryStorage = fetchedStorages.first {
                let rootItems = try await client.fetchDirectoryItems(
                    storageID: primaryStorage.id,
                    parentHandle: 0xFFFFFFFF,
                    folderName: primaryStorage.displayName,
                    includeChildCountsForFolders: true
                )
                self.rootFolders = rootItems.filter(\.isFolder)
                print("[SwitchMTP] Connected to \(details.displayName) (FW \(details.deviceVersion), SN \(details.serialNumber)) — \(self.rootFolders.count) game folders loaded")
                
                if selectedSidebar == nil {
                    selectedSidebar = .allMedia
                }
                await loadSelectedDestination()
            }
        } catch {
            print("[SwitchMTP] connectToDevice error: \(error.localizedDescription)")
            self.isConnected = false
            self.deviceDetails = nil
            self.storages = []
            self.rootFolders = []
            self.currentItems = []
            if case MTPError.deviceNotFound = error {
                self.errorMessage = nil
            } else {
                self.errorMessage = error.localizedDescription
            }
        }
        
        isConnecting = false
    }
    
    func refresh() async {
        folderItemsCache.removeAll()
        loadingThumbnails.removeAll()
        isLoadingThumbnails = false
        hasLoadedAllMedia = false
        allMediaItems.removeAll()
        await connectToDevice()
    }
    
    private func handleUnexpectedDisconnect() async {
        await client.disconnect()
        isConnected = false
        deviceDetails = nil
        storages = []
        rootFolders = []
        currentItems = []
        allMediaItems = []
        loadingThumbnails.removeAll()
        isLoadingThumbnails = false
        hasLoadedAllMedia = false
        selectedItemIDs.removeAll()
        inspectedItem = nil
        previewImage = nil
        previewVideoURL = nil
        previewPlayer = nil
        errorMessage = nil
    }
    
    // MARK: - Navigation & Loading
    
    private func handleSidebarSelectionChange() {
        selectedItemIDs.removeAll()
        Task {
            await loadSelectedDestination()
        }
    }
    
    func loadSelectedDestination() async {
        guard isConnected, let primaryStorage = storages.first else { return }
        
        switch selectedSidebar {
        case .allMedia:
            mediaFilter = .all
            breadcrumbs = [BreadcrumbStep(id: 0xFFFFFFFF, storageID: primaryStorage.id, title: "All Media")]
            await loadAllMediaIfNeeded(storage: primaryStorage)
            currentItems = allMediaItems
            preloadVisibleThumbnails(for: filteredAndSortedItems)
            
        case .screenshots:
            mediaFilter = .screenshots
            breadcrumbs = [BreadcrumbStep(id: 0xFFFFFFFF, storageID: primaryStorage.id, title: "Screenshots")]
            await loadAllMediaIfNeeded(storage: primaryStorage)
            currentItems = allMediaItems.filter(\.isImage)
            preloadVisibleThumbnails(for: filteredAndSortedItems)
            
        case .videos:
            mediaFilter = .videos
            breadcrumbs = [BreadcrumbStep(id: 0xFFFFFFFF, storageID: primaryStorage.id, title: "Videos")]
            await loadAllMediaIfNeeded(storage: primaryStorage)
            currentItems = allMediaItems.filter(\.isVideo)
            preloadVisibleThumbnails(for: filteredAndSortedItems)
            
        case .storageRoot(let sid):
            mediaFilter = .all
            let storage = storages.first(where: { $0.id == sid }) ?? primaryStorage
            await navigateToDirectory(storageID: storage.id, parentHandle: 0xFFFFFFFF, title: storage.displayName, resetBreadcrumbs: true)
            
        case .gameFolder(let folderHandle):
            mediaFilter = .all
            if let folder = rootFolders.first(where: { $0.handle == folderHandle }) {
                breadcrumbs = [
                    BreadcrumbStep(id: 0xFFFFFFFF, storageID: folder.storageID, title: primaryStorage.displayName),
                    BreadcrumbStep(id: folder.handle, storageID: folder.storageID, title: folder.filename)
                ]
                await loadFolderItems(folder: folder)
            }
            
        case .none:
            break
        }
    }
    
    private func loadAllMediaIfNeeded(storage: MTPStorage) async {
        if hasLoadedAllMedia && !allMediaItems.isEmpty {
            return
        }
        isScanningAllMedia = true
        isLoadingDirectory = true
        defer {
            isScanningAllMedia = false
            isLoadingDirectory = false
        }
        
        var aggregated: [MTPObjectItem] = []
        for folder in rootFolders {
            while isTransferring {
                try? await Task.sleep(for: .milliseconds(100))
            }
            if let cached = folderItemsCache[folder.handle] {
                aggregated.append(contentsOf: cached.filter { !$0.isFolder })
                continue
            }
            do {
                let items = try await client.fetchDirectoryItems(
                    storageID: folder.storageID,
                    parentHandle: folder.handle,
                    folderName: folder.filename,
                    includeChildCountsForFolders: false
                )
                folderItemsCache[folder.handle] = items
                aggregated.append(contentsOf: items.filter { !$0.isFolder })
                // Stream progressive results into view
                self.allMediaItems = aggregated
                switch selectedSidebar {
                case .allMedia:
                    self.currentItems = aggregated
                case .screenshots:
                    self.currentItems = aggregated.filter(\.isImage)
                case .videos:
                    self.currentItems = aggregated.filter(\.isVideo)
                default:
                    break
                }
            } catch {
                continue
            }
        }
        self.allMediaItems = aggregated
        self.hasLoadedAllMedia = true
    }
    
    private func loadFolderItems(folder: MTPObjectItem) async {
        if let cached = folderItemsCache[folder.handle] {
            self.currentItems = cached
            preloadVisibleThumbnails(for: filteredAndSortedItems)
            return
        }
        isLoadingDirectory = true
        defer { isLoadingDirectory = false }
        do {
            let items = try await client.fetchDirectoryItems(
                storageID: folder.storageID,
                parentHandle: folder.handle,
                folderName: folder.filename,
                includeChildCountsForFolders: true
            )
            folderItemsCache[folder.handle] = items
            self.currentItems = items
            preloadVisibleThumbnails(for: filteredAndSortedItems)
        } catch {
            self.errorMessage = error.localizedDescription
        }
    }
    
    func navigateToDirectory(storageID: UInt32, parentHandle: UInt32, title: String, resetBreadcrumbs: Bool = false) async {
        isLoadingDirectory = true
        selectedItemIDs.removeAll()
        defer { isLoadingDirectory = false }
        
        if resetBreadcrumbs {
            breadcrumbs = [BreadcrumbStep(id: parentHandle, storageID: storageID, title: title)]
        } else if let existingIndex = breadcrumbs.firstIndex(where: { $0.id == parentHandle && $0.storageID == storageID }) {
            breadcrumbs = Array(breadcrumbs.prefix(through: existingIndex))
        } else {
            breadcrumbs.append(BreadcrumbStep(id: parentHandle, storageID: storageID, title: title))
        }
        
        if parentHandle == 0xFFFFFFFF, storageID == storages.first?.id, !rootFolders.isEmpty {
            currentItems = rootFolders
            return
        }
        
        if let cached = folderItemsCache[parentHandle] {
            currentItems = cached
            preloadVisibleThumbnails(for: filteredAndSortedItems)
            return
        }
        
        do {
            let items = try await client.fetchDirectoryItems(
                storageID: storageID,
                parentHandle: parentHandle,
                folderName: title,
                includeChildCountsForFolders: true
            )
            folderItemsCache[parentHandle] = items
            currentItems = items
            preloadVisibleThumbnails(for: filteredAndSortedItems)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
    
    func openItem(_ item: MTPObjectItem) {
        if item.isFolder {
            if rootFolders.contains(where: { $0.handle == item.handle }) {
                selectedSidebar = .gameFolder(item.handle)
            } else {
                Task {
                    await navigateToDirectory(storageID: item.storageID, parentHandle: item.handle, title: item.filename)
                }
            }
        } else {
            selectedItemIDs = [item.handle]
            fullScreenPreviewItem = item
        }
    }
    
    func canNavigatePreview(offset: Int, from item: MTPObjectItem) -> Bool {
        let mediaItems = filteredAndSortedItems.filter { !$0.isFolder }
        guard let currentIndex = mediaItems.firstIndex(where: { $0.handle == item.handle }) else {
            return false
        }
        let targetIndex = currentIndex + offset
        return mediaItems.indices.contains(targetIndex)
    }
    
    func navigatePreview(offset: Int, from item: MTPObjectItem) {
        let mediaItems = filteredAndSortedItems.filter { !$0.isFolder }
        guard let currentIndex = mediaItems.firstIndex(where: { $0.handle == item.handle }) else {
            return
        }
        let targetIndex = currentIndex + offset
        guard mediaItems.indices.contains(targetIndex) else { return }
        let nextItem = mediaItems[targetIndex]
        selectedItemIDs = [nextItem.handle]
        fullScreenPreviewItem = nextItem
    }
    
    // MARK: - Filtering & Sorting
    
    private func rebuildFilteredItems() {
        var list = currentItems
        
        // Apply media filter
        switch mediaFilter {
        case .all:
            break
        case .screenshots:
            list = list.filter { $0.isFolder || $0.isImage }
        case .videos:
            list = list.filter { $0.isFolder || $0.isVideo }
        }
        
        // Apply search
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !query.isEmpty {
            list = list.filter {
                $0.filename.localizedStandardContains(query) ||
                $0.folderName.localizedStandardContains(query)
            }
        }
        
        // Sort folders first, then by chosen sort order
        list.sort { a, b in
            if a.isFolder != b.isFolder {
                return a.isFolder && !b.isFolder
            }
            switch sortOrder {
            case .dateNewest:
                let da = a.displayDate ?? .distantPast
                let db = b.displayDate ?? .distantPast
                if da != db { return da > db }
                return a.filename > b.filename
            case .dateOldest:
                let da = a.displayDate ?? .distantFuture
                let db = b.displayDate ?? .distantFuture
                if da != db { return da < db }
                return a.filename < b.filename
            case .nameAscending:
                return a.filename.localizedStandardCompare(b.filename) == .orderedAscending
            case .sizeLargest:
                if a.compressedSize != b.compressedSize {
                    return a.compressedSize > b.compressedSize
                }
                return a.filename < b.filename
            case .gameTitle:
                let cmp = a.folderName.localizedStandardCompare(b.folderName)
                if cmp != .orderedSame { return cmp == .orderedAscending }
                return a.filename > b.filename
            }
        }
        filteredAndSortedItems = list
    }
    
    var selectedItems: [MTPObjectItem] {
        guard !selectedItemIDs.isEmpty else { return [] }
        return filteredAndSortedItems.filter { selectedItemIDs.contains($0.handle) }
    }
    
    var totalMediaCountSummary: String {
        let total = rootFolders.reduce(0) { $0 + ($1.childCount ?? 0) }
        return "\(rootFolders.count) Games • \(total) Captures"
    }
    
    func selectAll() {
        selectedItemIDs = Set(filteredAndSortedItems.map(\.handle))
    }
    
    func clearSelection() {
        selectedItemIDs.removeAll()
        selectionAnchorHandle = nil
    }
    
    func selectRange(to targetHandle: UInt32, additive: Bool = false) {
        let items = filteredAndSortedItems
        guard let targetIndex = items.firstIndex(where: { $0.handle == targetHandle }) else {
            selectedItemIDs = [targetHandle]
            selectionAnchorHandle = targetHandle
            return
        }
        let anchorHandle = selectionAnchorHandle ?? selectedItemIDs.first ?? targetHandle
        guard let anchorIndex = items.firstIndex(where: { $0.handle == anchorHandle }) else {
            selectedItemIDs = [targetHandle]
            selectionAnchorHandle = targetHandle
            return
        }
        let lower = min(anchorIndex, targetIndex)
        let upper = max(anchorIndex, targetIndex)
        let rangeHandles = Set(items[lower...upper].map(\.handle))
        if additive {
            selectedItemIDs.formUnion(rangeHandles)
        } else {
            selectedItemIDs = rangeHandles
        }
    }
    
    func itemsForDrag(startingWith primaryItem: MTPObjectItem) -> [MTPObjectItem] {
        if selectedItemIDs.contains(primaryItem.handle) {
            let selected = selectedItems
            if !selected.isEmpty {
                return selected
            }
        }
        selectedItemIDs = [primaryItem.handle]
        selectionAnchorHandle = primaryItem.handle
        return [primaryItem]
    }
    
    // MARK: - Thumbnails & Preview
    
    func requestThumbnailIfNeeded(for item: MTPObjectItem) {
        guard item.hasThumbnail,
              thumbnails[item.handle] == nil,
              !loadingThumbnails.contains(item.handle) else {
            return
        }
        loadingThumbnails.insert(item.handle)
        pendingThumbnailQueue.append(item.handle)
        startThumbnailWorkerIfNeeded()
    }
    
    private func startThumbnailWorkerIfNeeded() {
        guard thumbnailWorkerTask == nil else { return }
        if !isLoadingThumbnails {
            isLoadingThumbnails = true
        }
        thumbnailWorkerTask = Task { [weak self] in
            guard let self else { return }
            while !self.pendingThumbnailQueue.isEmpty {
                while self.isTransferring {
                    try? await Task.sleep(for: .milliseconds(80))
                }
                guard !self.pendingThumbnailQueue.isEmpty else { break }
                let handle = self.pendingThumbnailQueue.removeFirst()
                if self.thumbnails[handle] != nil {
                    self.loadingThumbnails.remove(handle)
                    continue
                }
                do {
                    let data = try await self.client.fetchThumbnail(handle: handle)
                    if let image = NSImage(data: data) {
                        self.thumbnails[handle] = image
                    }
                } catch {
                    // Ignore individual thumbnail failures
                }
                self.loadingThumbnails.remove(handle)
            }
            self.thumbnailWorkerTask = nil
            if self.isLoadingThumbnails {
                self.isLoadingThumbnails = false
            }
        }
    }
    
    private func preloadVisibleThumbnails(for items: [MTPObjectItem]) {
        for item in items.prefix(24) where item.hasThumbnail {
            requestThumbnailIfNeeded(for: item)
        }
    }
    
    private func handlePrimarySelectionChange() {
        guard !selectedItemIDs.isEmpty,
              let item = selectedItems.first ?? currentItems.first(where: { selectedItemIDs.contains($0.handle) }) else {
            previewLoadTask?.cancel()
            inspectedItem = nil
            previewImage = nil
            previewPlayer?.pause()
            previewPlayer = nil
            previewVideoURL = nil
            return
        }
        guard inspectedItem?.handle != item.handle else { return }
        inspectedItem = item
        previewImage = thumbnails[item.handle]
        if showInspector {
            schedulePreviewLoad(for: item)
        }
    }
    
    private func schedulePreviewLoad(for item: MTPObjectItem) {
        previewLoadTask?.cancel()
        previewLoadTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(160))
            guard !Task.isCancelled, let self, self.inspectedItem?.handle == item.handle else { return }
            self.loadPreview(for: item)
        }
    }
    
    func loadPreview(for item: MTPObjectItem, forLightbox: Bool = false) {
        previewPlayer?.pause()
        previewPlayer = nil
        previewVideoURL = nil
        
        if item.isFolder {
            previewImage = nil
            isLoadingPreview = false
            return
        }
        
        // Show cached thumbnail immediately while full asset loads
        previewImage = thumbnails[item.handle]
        if item.isVideo && !forLightbox && fullScreenPreviewItem?.handle != item.handle {
            requestThumbnailIfNeeded(for: item)
            isLoadingPreview = false
            return
        }
        
        isLoadingPreview = true
        let handle = item.handle
        
        Task {
            do {
                if item.isImage {
                    let data = try await client.fetchObjectData(handle: handle)
                    guard self.inspectedItem?.handle == handle || self.fullScreenPreviewItem?.handle == handle else { return }
                    if let fullImg = NSImage(data: data) {
                        self.previewImage = fullImg
                        if self.thumbnails[handle] == nil {
                            self.thumbnails[handle] = fullImg
                        }
                    }
                } else if item.isVideo {
                    let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("SwitchMTPPreview", isDirectory: true)
                    let tempURL = tempDir.appendingPathComponent(item.filename)
                    if !FileManager.default.fileExists(atPath: tempURL.path) {
                        try await client.downloadObjectToFile(item: item, destinationURL: tempURL)
                    }
                    guard self.fullScreenPreviewItem?.handle == handle else { return }
                    self.previewVideoURL = tempURL
                    self.previewPlayer = AVPlayer(url: tempURL)
                }
            } catch {
                // Keep thumbnail fallback
            }
            if self.inspectedItem?.handle == handle || self.fullScreenPreviewItem?.handle == handle {
                self.isLoadingPreview = false
            }
        }
    }
    
    // MARK: - Export & Quick Actions
    
    func copyImageToClipboard(_ item: MTPObjectItem) {
        guard item.isImage else { return }
        Task {
            do {
                let data = try await client.fetchObjectData(handle: item.handle)
                guard let image = NSImage(data: data) else { return }
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.writeObjects([image])
                showTemporaryBanner("Copied \"\(item.filename)\" to Clipboard")
            } catch {
                errorMessage = "Could not copy image: \(error.localizedDescription)"
            }
        }
    }
    
    func openInQuickLookOrDefaultApp(_ item: MTPObjectItem) {
        guard !item.isFolder else { return }
        Task {
            do {
                let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("SwitchMTPQuickOpen", isDirectory: true)
                let destURL = tempDir.appendingPathComponent(item.filename)
                if !FileManager.default.fileExists(atPath: destURL.path) {
                    try await exportItems([item], toDirectory: tempDir, revealWhenDone: false)
                }
                NSWorkspace.shared.open(destURL)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
    
    func quickSaveToDownloads(_ items: [MTPObjectItem]) {
        guard !items.isEmpty else { return }
        guard let downloadsURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first else {
            return
        }
        Task {
            try? await exportItems(items, toDirectory: downloadsURL, revealWhenDone: true)
        }
    }
    
    func promptAndExportItems(_ items: [MTPObjectItem]) {
        guard !items.isEmpty else { return }
        let panel = NSOpenPanel()
        panel.title = items.count == 1 ? "Export \"\(items[0].filename)\"" : "Export \(items.count) Items from Nintendo Switch"
        panel.prompt = "Export Here"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        
        if panel.runModal() == .OK, let destinationDir = panel.url {
            Task {
                try? await exportItems(items, toDirectory: destinationDir, revealWhenDone: true)
            }
        }
    }
    
    func promptAndExportAllVisible() {
        let mediaOnly = filteredAndSortedItems.filter { !$0.isFolder }
        if !mediaOnly.isEmpty {
            promptAndExportItems(mediaOnly)
        } else if !currentItems.filter(\.isFolder).isEmpty {
            promptAndExportFolders(currentItems.filter(\.isFolder))
        }
    }
    
    func promptAndExportFolders(_ folders: [MTPObjectItem]) {
        guard !folders.isEmpty else { return }
        let panel = NSOpenPanel()
        panel.title = folders.count == 1 ? "Export Folder \"\(folders[0].filename)\"" : "Export \(folders.count) Game Folders"
        panel.prompt = "Export Here"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        
        if panel.runModal() == .OK, let destinationDir = panel.url {
            Task {
                var filesToExport: [MTPObjectItem] = []
                for folder in folders where folder.isFolder {
                    if let cached = folderItemsCache[folder.handle] {
                        filesToExport.append(contentsOf: cached.filter { !$0.isFolder })
                    } else if let fetched = try? await client.fetchDirectoryItems(
                        storageID: folder.storageID,
                        parentHandle: folder.handle,
                        folderName: folder.filename,
                        includeChildCountsForFolders: false
                    ) {
                        folderItemsCache[folder.handle] = fetched
                        filesToExport.append(contentsOf: fetched.filter { !$0.isFolder })
                    }
                }
                try? await exportItems(filesToExport, toDirectory: destinationDir, revealWhenDone: true)
            }
        }
    }
    
    func exportItems(
        _ items: [MTPObjectItem],
        toDirectory baseDirectory: URL,
        revealWhenDone: Bool
    ) async throws {
        // Expand any folders included in items
        var flatFiles: [MTPObjectItem] = []
        for item in items {
            if item.isFolder {
                if let cached = folderItemsCache[item.handle] {
                    flatFiles.append(contentsOf: cached.filter { !$0.isFolder })
                } else {
                    let children = try await client.fetchDirectoryItems(
                        storageID: item.storageID,
                        parentHandle: item.handle,
                        folderName: item.filename,
                        includeChildCountsForFolders: false
                    )
                    folderItemsCache[item.handle] = children
                    flatFiles.append(contentsOf: children.filter { !$0.isFolder })
                }
            } else {
                flatFiles.append(item)
            }
        }
        
        guard !flatFiles.isEmpty else { return }
        
        isTransferring = true
        defer {
            isTransferring = false
            transferStatus = nil
        }
        
        var lastExportedURL: URL? = nil
        let startTime = CFAbsoluteTimeGetCurrent()
        var cumulativeBytes: Int64 = 0
        
        for (index, fileItem) in flatFiles.enumerated() {
            let fileURL = baseDirectory.appendingPathComponent(Self.sanitizeFilename(fileItem.filename))
            let statusTitle = flatFiles.count == 1 ? "Exporting File…" : "Exporting \(index + 1) of \(flatFiles.count)…"
            
            self.transferStatus = TransferStatus(
                title: statusTitle,
                currentFile: fileItem.filename,
                completedFiles: index,
                totalFiles: flatFiles.count,
                currentBytes: 0,
                totalBytes: Int64(fileItem.compressedSize),
                bytesPerSecond: 0
            )
            
            let baseCumulative = cumulativeBytes
            try await client.downloadObjectToFile(item: fileItem, destinationURL: fileURL) { [weak self] current, total in
                let elapsed = max(0.001, CFAbsoluteTimeGetCurrent() - startTime)
                let speed = Double(baseCumulative + current) / elapsed
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.transferStatus = TransferStatus(
                        title: statusTitle,
                        currentFile: fileItem.filename,
                        completedFiles: index,
                        totalFiles: flatFiles.count,
                        currentBytes: current,
                        totalBytes: total,
                        bytesPerSecond: speed
                    )
                }
            }
            cumulativeBytes += Int64(fileItem.compressedSize)
            lastExportedURL = fileURL
        }
        
        showTemporaryBanner("Exported \(flatFiles.count) file\(flatFiles.count == 1 ? "" : "s") to \"\(baseDirectory.lastPathComponent)\"")
        
        if revealWhenDone, let lastExportedURL {
            NSWorkspace.shared.activateFileViewerSelecting([lastExportedURL])
        }
    }
    
    func showTemporaryBanner(_ text: String) {
        statusBanner = text
        Task {
            try? await Task.sleep(for: .seconds(4))
            if self.statusBanner == text {
                self.statusBanner = nil
            }
        }
    }
    
    nonisolated static func sanitizeFilename(_ name: String) -> String {
        let invalid = CharacterSet(charactersIn: "/:\\")
        return name.components(separatedBy: invalid).joined(separator: "-")
    }
    
    func setTransferStateFromDrag(isTransferring: Bool, status: TransferStatus?) {
        self.isTransferring = isTransferring
        self.transferStatus = status
    }
}

// MARK: - Native Finder & App Drag-and-Drop Support

nonisolated final class MTPFilePromiseProvider: NSFilePromiseProvider, @unchecked Sendable {
    let item: MTPObjectItem
    weak var coordinator: MTPDragExportCoordinator?
    var cachedImageFallback: NSImage?
    private var extraPromisedTypes: [NSPasteboard.PasteboardType] = []
    
    init(item: MTPObjectItem, coordinator: MTPDragExportCoordinator, cachedImageFallback: NSImage? = nil) {
        self.item = item
        self.coordinator = coordinator
        self.cachedImageFallback = cachedImageFallback
        
        let resolvedFileType = Self.resolveUTI(for: item)
        var extras: [NSPasteboard.PasteboardType] = []
        
        // Only advertise a direct .fileURL if the file is already materialized on local disk.
        // Otherwise, NSFilePromiseProvider's promised-file-url types handle Finder, Desktop,
        // and external apps asynchronously on filePromiseQueue without blocking the main thread.
        if coordinator.existingCachedFileURL(for: item) != nil {
            extras.append(.fileURL)
        }
        if item.isImage {
            extras.append(.tiff)
        }
        self.extraPromisedTypes = extras
        
        super.init()
        self.fileType = resolvedFileType
        self.delegate = coordinator
    }
    
    static func resolveUTI(for item: MTPObjectItem) -> String {
        if item.isFolder {
            return UTType.folder.identifier
        }
        let ext = (item.filename as NSString).pathExtension.lowercased()
        if !ext.isEmpty, let utType = UTType(filenameExtension: ext) {
            return utType.identifier
        }
        if item.isImage {
            return UTType.jpeg.identifier
        }
        if item.isVideo {
            return UTType.mpeg4Movie.identifier
        }
        return UTType.data.identifier
    }
    
    override func writableTypes(for pasteboard: NSPasteboard) -> [NSPasteboard.PasteboardType] {
        var types = super.writableTypes(for: pasteboard)
        for extra in extraPromisedTypes where !types.contains(extra) {
            types.append(extra)
        }
        return types
    }
    
    override func writingOptions(forType type: NSPasteboard.PasteboardType, pasteboard: NSPasteboard) -> NSPasteboard.WritingOptions {
        if extraPromisedTypes.contains(type) {
            return .promised
        }
        return super.writingOptions(forType: type, pasteboard: pasteboard)
    }
    
    override func pasteboardPropertyList(forType type: NSPasteboard.PasteboardType) -> Any? {
        if !extraPromisedTypes.contains(type) {
            return super.pasteboardPropertyList(forType: type)
        }
        guard let coordinator else { return nil }
        
        if type == .fileURL {
            if let existingURL = coordinator.existingCachedFileURL(for: item) {
                return (existingURL as NSURL).pasteboardPropertyList(forType: .fileURL)
            }
            return nil
        }
        
        if type == .tiff {
            if let existingURL = coordinator.existingCachedFileURL(for: item),
               let data = try? Data(contentsOf: existingURL),
               let image = NSImage(data: data) {
                return image.tiffRepresentation
            }
            if let fallback = cachedImageFallback {
                return fallback.tiffRepresentation
            }
            return nil
        }
        
        return super.pasteboardPropertyList(forType: type)
    }
}

nonisolated final class MTPDragExportCoordinator: NSObject, NSFilePromiseProviderDelegate, @unchecked Sendable {
    let client: MTPUSBClient
    nonisolated(unsafe) weak var viewModel: MTPViewModel?
    
    private let filePromiseQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "me.podter.SwitchMTP.filePromiseQueue"
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .userInitiated
        return queue
    }()
    
    private let batchLock = NSLock()
    private var batchTotalCount: Int = 0
    private var batchCompletedCount: Int = 0
    
    init(client: MTPUSBClient, viewModel: MTPViewModel) {
        self.client = client
        self.viewModel = viewModel
        super.init()
    }
    
    func prepareForDragBatch(items: [MTPObjectItem]) {
        batchLock.lock()
        batchTotalCount = items.count
        batchCompletedCount = 0
        batchLock.unlock()
    }
    
    func makeFilePromiseProvider(for item: MTPObjectItem, cachedImage: NSImage? = nil) -> MTPFilePromiseProvider {
        MTPFilePromiseProvider(item: item, coordinator: self, cachedImageFallback: cachedImage)
    }
    
    // MARK: - NSFilePromiseProviderDelegate
    
    func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider, fileNameForType fileType: String) -> String {
        guard let provider = filePromiseProvider as? MTPFilePromiseProvider else {
            return "SwitchMedia"
        }
        return MTPViewModel.sanitizeFilename(provider.item.filename)
    }
    
    func operationQueue(for filePromiseProvider: NSFilePromiseProvider) -> OperationQueue {
        filePromiseQueue
    }
    
    nonisolated func filePromiseProvider(
        _ filePromiseProvider: NSFilePromiseProvider,
        writePromiseTo url: URL,
        completionHandler: @escaping @Sendable ((any Error)?) -> Void
    ) {
        guard let provider = filePromiseProvider as? MTPFilePromiseProvider else {
            completionHandler(MTPError.invalidData)
            return
        }
        do {
            try fulfillPromiseBlocking(for: provider.item, destinationURL: url)
            completionHandler(nil)
        } catch {
            Task { @MainActor [weak self] in
                self?.viewModel?.setTransferStateFromDrag(isTransferring: false, status: nil)
                self?.viewModel?.errorMessage = "Drag export failed: \(error.localizedDescription)"
            }
            completionHandler(error)
        }
    }
    
    // MARK: - Transfer & Materialization Helpers
    
    nonisolated func existingCachedFileURL(for item: MTPObjectItem) -> URL? {
        guard !item.isFolder else { return nil }
        let fm = FileManager.default
        let sanitized = MTPViewModel.sanitizeFilename(item.filename)
        let candidateDirs = [
            fm.temporaryDirectory.appendingPathComponent("SwitchMTPPreview", isDirectory: true),
            fm.temporaryDirectory.appendingPathComponent("SwitchMTPQuickOpen", isDirectory: true),
            fm.temporaryDirectory.appendingPathComponent("SwitchMTPDragDrop", isDirectory: true)
        ]
        for dir in candidateDirs {
            let candidate = dir.appendingPathComponent(sanitized)
            if fm.fileExists(atPath: candidate.path),
               let attrs = try? fm.attributesOfItem(atPath: candidate.path),
               let fileSize = attrs[.size] as? UInt64,
               fileSize > 0,
               (item.compressedSize == 0 || fileSize == item.compressedSize) {
                return candidate
            }
        }
        return nil
    }
    
    nonisolated func materializeToTempURLBlocking(for item: MTPObjectItem) throws -> URL {
        if let existing = existingCachedFileURL(for: item) {
            return existing
        }
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SwitchMTPDragDrop", isDirectory: true)
        let destURL = tempDir.appendingPathComponent(MTPViewModel.sanitizeFilename(item.filename))
        try fulfillPromiseBlocking(for: item, destinationURL: destURL, showCompletionBanner: false)
        return destURL
    }
    
    nonisolated func materializeDataBlocking(for item: MTPObjectItem) throws -> Data {
        if let existing = existingCachedFileURL(for: item),
           let data = try? Data(contentsOf: existing) {
            return data
        }
        let tempURL = try materializeToTempURLBlocking(for: item)
        return try Data(contentsOf: tempURL)
    }
    
    nonisolated private func fulfillPromiseBlocking(
        for item: MTPObjectItem,
        destinationURL: URL,
        showCompletionBanner: Bool = true
    ) throws {
        batchLock.lock()
        let currentIndex = batchCompletedCount
        let totalCount = max(1, batchTotalCount)
        batchLock.unlock()
        
        let fm = FileManager.default
        let startTime = CFAbsoluteTimeGetCurrent()
        
        if item.isFolder {
            if !fm.fileExists(atPath: destinationURL.path) {
                try fm.createDirectory(at: destinationURL, withIntermediateDirectories: true)
            }
            let children = try client.fetchDirectoryItemsBlocking(
                storageID: item.storageID,
                parentHandle: item.handle,
                folderName: item.filename,
                includeChildCountsForFolders: false
            )
            let mediaChildren = children.filter { !$0.isFolder }
            var cumulativeBytes: Int64 = 0
            
            for (idx, child) in mediaChildren.enumerated() {
                let childURL = destinationURL.appendingPathComponent(MTPViewModel.sanitizeFilename(child.filename))
                let title = "Exporting \"\(item.filename)\" (\(idx + 1)/\(mediaChildren.count))…"
                
                Task { @MainActor [weak self] in
                    self?.viewModel?.setTransferStateFromDrag(
                        isTransferring: true,
                        status: TransferStatus(
                            title: title,
                            currentFile: child.filename,
                            completedFiles: idx,
                            totalFiles: mediaChildren.count,
                            currentBytes: 0,
                            totalBytes: Int64(child.compressedSize),
                            bytesPerSecond: 0
                        )
                    )
                }
                
                if let cached = existingCachedFileURL(for: child) {
                    if fm.fileExists(atPath: childURL.path) {
                        try? fm.removeItem(at: childURL)
                    }
                    try fm.copyItem(at: cached, to: childURL)
                } else {
                    let baseCumulative = cumulativeBytes
                    try client.downloadObjectToFileBlocking(item: child, destinationURL: childURL) { [weak self] current, total in
                        let elapsed = max(0.001, CFAbsoluteTimeGetCurrent() - startTime)
                        let speed = Double(baseCumulative + current) / elapsed
                        Task { @MainActor [weak self] in
                            self?.viewModel?.setTransferStateFromDrag(
                                isTransferring: true,
                                status: TransferStatus(
                                    title: title,
                                    currentFile: child.filename,
                                    completedFiles: idx,
                                    totalFiles: mediaChildren.count,
                                    currentBytes: current,
                                    totalBytes: total,
                                    bytesPerSecond: speed
                                )
                            )
                        }
                    }
                }
                cumulativeBytes += Int64(child.compressedSize)
            }
        } else {
            let parentDir = destinationURL.deletingLastPathComponent()
            if !fm.fileExists(atPath: parentDir.path) {
                try fm.createDirectory(at: parentDir, withIntermediateDirectories: true)
            }
            
            let title = totalCount == 1
                ? "Exporting File…"
                : "Exporting \(min(totalCount, currentIndex + 1)) of \(totalCount)…"
            
            Task { @MainActor [weak self] in
                self?.viewModel?.setTransferStateFromDrag(
                    isTransferring: true,
                    status: TransferStatus(
                        title: title,
                        currentFile: item.filename,
                        completedFiles: currentIndex,
                        totalFiles: totalCount,
                        currentBytes: 0,
                        totalBytes: Int64(item.compressedSize),
                        bytesPerSecond: 0
                    )
                )
            }
            
            if let cached = existingCachedFileURL(for: item), cached.standardizedFileURL != destinationURL.standardizedFileURL {
                if fm.fileExists(atPath: destinationURL.path) {
                    try fm.removeItem(at: destinationURL)
                }
                try fm.copyItem(at: cached, to: destinationURL)
            } else {
                try client.downloadObjectToFileBlocking(item: item, destinationURL: destinationURL) { [weak self] current, total in
                    let elapsed = max(0.001, CFAbsoluteTimeGetCurrent() - startTime)
                    let speed = Double(current) / elapsed
                    Task { @MainActor [weak self] in
                        self?.viewModel?.setTransferStateFromDrag(
                            isTransferring: true,
                            status: TransferStatus(
                                title: title,
                                currentFile: item.filename,
                                completedFiles: currentIndex,
                                totalFiles: totalCount,
                                currentBytes: current,
                                totalBytes: total,
                                bytesPerSecond: speed
                            )
                        )
                    }
                }
            }
        }
        
        batchLock.lock()
        batchCompletedCount += 1
        let finishedAll = batchCompletedCount >= max(1, batchTotalCount)
        let finalCount = max(1, batchCompletedCount)
        if finishedAll {
            batchTotalCount = 0
            batchCompletedCount = 0
        }
        batchLock.unlock()
        
        if finishedAll {
            let folderDisplayName = destinationURL.deletingLastPathComponent().lastPathComponent
            Task { @MainActor [weak self] in
                guard let self, let vm = self.viewModel else { return }
                vm.setTransferStateFromDrag(isTransferring: false, status: nil)
                if showCompletionBanner {
                    if item.isFolder && finalCount == 1 {
                        vm.showTemporaryBanner("Exported folder \"\(item.filename)\" to \"\(folderDisplayName)\"")
                    } else {
                        vm.showTemporaryBanner("Exported \(finalCount) item\(finalCount == 1 ? "" : "s") to \"\(folderDisplayName)\"")
                    }
                }
            }
        }
    }
}
