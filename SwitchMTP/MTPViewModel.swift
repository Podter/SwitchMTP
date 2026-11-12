//
//  MTPViewModel.swift
//  SwitchMTP
//

import Foundation
import SwiftUI
import AppKit
import AVFoundation

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
    var currentItems: [MTPObjectItem] = []
    var allMediaItems: [MTPObjectItem] = []
    var hasLoadedAllMedia: Bool = false
    
    var selectedItemIDs: Set<UInt32> = [] {
        didSet {
            handlePrimarySelectionChange()
        }
    }
    
    var searchText: String = ""
    var mediaFilter: MediaTypeFilter = .all
    var sortOrder: MediaSortOrder = .dateNewest
    var viewMode: BrowserViewMode = .grid
    var gridZoom: Double = 175
    var showInspector: Bool = false
    
    var thumbnails: [UInt32: NSImage] = [:]
    private var loadingThumbnails: Set<UInt32> = []
    private var folderItemsCache: [UInt32: [MTPObjectItem]] = [:]
    
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
    
    var isWorking: Bool {
        isConnecting || isLoadingDirectory || isScanningAllMedia || !loadingThumbnails.isEmpty || transferStatus != nil
    }
    
    private var usbMonitorTask: Task<Void, Never>? = nil
    
    init() {
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
    
    // MARK: - Filtering & Sorting
    
    var filteredAndSortedItems: [MTPObjectItem] {
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
        return list
    }
    
    var selectedItems: [MTPObjectItem] {
        filteredAndSortedItems.filter { selectedItemIDs.contains($0.handle) }
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
    }
    
    // MARK: - Thumbnails & Preview
    
    func requestThumbnailIfNeeded(for item: MTPObjectItem) {
        guard item.hasThumbnail,
              thumbnails[item.handle] == nil,
              !loadingThumbnails.contains(item.handle) else {
            return
        }
        loadingThumbnails.insert(item.handle)
        let handle = item.handle
        Task {
            do {
                let data = try await client.fetchThumbnail(handle: handle)
                if let image = NSImage(data: data) {
                    self.thumbnails[handle] = image
                }
            } catch {
                // Ignore individual thumbnail failures
            }
            self.loadingThumbnails.remove(handle)
        }
    }
    
    private func preloadVisibleThumbnails(for items: [MTPObjectItem]) {
        for item in items.prefix(40) where item.hasThumbnail {
            requestThumbnailIfNeeded(for: item)
        }
    }
    
    private func handlePrimarySelectionChange() {
        guard let firstID = selectedItemIDs.first,
              let item = currentItems.first(where: { $0.handle == firstID }) ?? allMediaItems.first(where: { $0.handle == firstID }) else {
            inspectedItem = nil
            previewImage = nil
            previewPlayer?.pause()
            previewPlayer = nil
            previewVideoURL = nil
            return
        }
        guard inspectedItem?.handle != item.handle else { return }
        inspectedItem = item
        loadPreview(for: item)
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
        
        var lastExportedURL: URL? = nil
        let startTime = CFAbsoluteTimeGetCurrent()
        var cumulativeBytes: Int64 = 0
        
        for (index, fileItem) in flatFiles.enumerated() {
            let fileURL = baseDirectory.appendingPathComponent(Self.sanitizeFilename(fileItem.filename))
            
            self.transferStatus = TransferStatus(
                title: flatFiles.count == 1 ? "Exporting File…" : "Exporting \(index + 1) of \(flatFiles.count)…",
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
                        title: flatFiles.count == 1 ? "Exporting File…" : "Exporting \(index + 1) of \(flatFiles.count)…",
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
        
        self.transferStatus = nil
        showTemporaryBanner("Exported \(flatFiles.count) file\(flatFiles.count == 1 ? "" : "s") to \"\(baseDirectory.lastPathComponent)\"")
        
        if revealWhenDone, let lastExportedURL {
            NSWorkspace.shared.activateFileViewerSelecting([lastExportedURL])
        }
    }
    
    private func showTemporaryBanner(_ text: String) {
        statusBanner = text
        Task {
            try? await Task.sleep(for: .seconds(4))
            if self.statusBanner == text {
                self.statusBanner = nil
            }
        }
    }
    
    private static func sanitizeFilename(_ name: String) -> String {
        let invalid = CharacterSet(charactersIn: "/:\\")
        return name.components(separatedBy: invalid).joined(separator: "-")
    }
}
