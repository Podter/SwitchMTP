//
//  MTPModels.swift
//  SwitchMTP
//

import Foundation
import AppKit

nonisolated enum MTPContainerType: UInt16, Sendable {
    case command = 1
    case data = 2
    case response = 3
    case event = 4
}

nonisolated enum MTPOperationCode: UInt16, Sendable {
    case getDeviceInfo = 0x1001
    case openSession = 0x1002
    case closeSession = 0x1003
    case getStorageIDs = 0x1004
    case getStorageInfo = 0x1005
    case getNumObjects = 0x1006
    case getObjectHandles = 0x1007
    case getObjectInfo = 0x1008
    case getObject = 0x1009
    case getThumb = 0x100A
    case getPartialObject = 0x101B
}

nonisolated enum MTPResponseCode: UInt16, Sendable {
    case ok = 0x2001
    case generalError = 0x2002
    case sessionNotOpen = 0x2003
    case invalidTransactionID = 0x2004
    case operationNotSupported = 0x2005
    case parameterNotSupported = 0x2006
    case incompleteTransfer = 0x2007
    case invalidStorageID = 0x2008
    case invalidObjectHandle = 0x2009
    case noThumbnailPresent = 0x2010
    case deviceBusy = 0x2019
    case sessionAlreadyOpen = 0x201E
    
    var description: String {
        switch self {
        case .ok: return "OK (0x2001)"
        case .generalError: return "General Error (0x2002)"
        case .sessionNotOpen: return "Session Not Open (0x2003)"
        case .invalidTransactionID: return "Invalid Transaction ID (0x2004)"
        case .operationNotSupported: return "Operation Not Supported (0x2005)"
        case .parameterNotSupported: return "Parameter Not Supported (0x2006)"
        case .incompleteTransfer: return "Incomplete Transfer (0x2007)"
        case .invalidStorageID: return "Invalid Storage ID (0x2008)"
        case .invalidObjectHandle: return "Invalid Object Handle (0x2009)"
        case .noThumbnailPresent: return "No Thumbnail Present (0x2010)"
        case .deviceBusy: return "Device Busy (0x2019)"
        case .sessionAlreadyOpen: return "Session Already Open (0x201E)"
        }
    }
}

nonisolated enum MTPObjectFormat: UInt16, Sendable {
    case undefined = 0x3000
    case association = 0x3001 // Folder / Directory
    case exifJPEG = 0x3801
    case jfif = 0x3808
    case png = 0x380B
    case mp4Container = 0xB982
    case wmv = 0xB981
    case avi = 0x300A
    case mpeg = 0x300B
    
    static func isFolder(_ raw: UInt16) -> Bool {
        raw == Self.association.rawValue
    }
    
    static func isImage(_ raw: UInt16, filename: String) -> Bool {
        if raw == Self.exifJPEG.rawValue || raw == Self.jfif.rawValue || raw == Self.png.rawValue {
            return true
        }
        let ext = (filename as NSString).pathExtension.lowercased()
        return ["jpg", "jpeg", "png", "bmp", "gif", "heic", "webp"].contains(ext)
    }
    
    static func isVideo(_ raw: UInt16, filename: String) -> Bool {
        if raw == Self.mp4Container.rawValue || raw == Self.avi.rawValue || raw == Self.mpeg.rawValue || raw == Self.wmv.rawValue {
            return true
        }
        let ext = (filename as NSString).pathExtension.lowercased()
        return ["mp4", "mov", "avi", "mkv", "webm"].contains(ext)
    }
}

nonisolated struct MTPDeviceDetails: Sendable, Equatable {
    var vendorID: Int
    var productID: Int
    var usbProductName: String
    var usbVendorName: String
    var usbSerialNumber: String
    var manufacturer: String
    var model: String
    var deviceVersion: String
    var serialNumber: String
    var vendorExtensionDesc: String
    var operationsSupported: [UInt16]
    
    var displayName: String {
        if !model.isEmpty { return model }
        if !usbProductName.isEmpty { return usbProductName }
        return "MTP Device"
    }
}

nonisolated struct MTPStorage: Identifiable, Sendable, Equatable, Hashable {
    let id: UInt32
    var storageType: UInt16
    var filesystemType: UInt16
    var accessCapability: UInt16
    var maxCapacity: UInt64
    var freeSpaceInBytes: UInt64
    var description: String
    var volumeIdentifier: String
    
    var displayName: String {
        if !description.isEmpty { return description }
        if !volumeIdentifier.isEmpty { return volumeIdentifier }
        return String(format: "Storage 0x%08X", id)
    }
    
    var isReadOnly: Bool {
        accessCapability == 0x0001 || accessCapability == 0x0002
    }
    
    var hasFiniteCapacity: Bool {
        maxCapacity > 0 && maxCapacity != UInt64.max
    }
}

nonisolated struct MTPObjectItem: Identifiable, Sendable, Equatable, Hashable {
    let handle: UInt32
    let storageID: UInt32
    let parentHandle: UInt32
    let formatCode: UInt16
    let compressedSize: UInt64
    let thumbFormat: UInt16
    let thumbCompressedSize: UInt32
    let thumbWidth: UInt32
    let thumbHeight: UInt32
    let imageWidth: UInt32
    let imageHeight: UInt32
    let filename: String
    let captureDateString: String
    let modificationDateString: String
    let captureDate: Date?
    let modificationDate: Date?
    var folderName: String = ""
    var childCount: Int? = nil
    
    var id: UInt32 { handle }
    
    var isFolder: Bool {
        MTPObjectFormat.isFolder(formatCode)
    }
    
    var isImage: Bool {
        !isFolder && MTPObjectFormat.isImage(formatCode, filename: filename)
    }
    
    var isVideo: Bool {
        !isFolder && MTPObjectFormat.isVideo(formatCode, filename: filename)
    }
    
    var hasThumbnail: Bool {
        thumbCompressedSize > 0
    }
    
    var kindDescription: String {
        if isFolder { return "Folder" }
        if isVideo { return "MP4 Video" }
        if isImage { return "JPEG Screenshot" }
        let ext = (filename as NSString).pathExtension.uppercased()
        return ext.isEmpty ? String(format: "MTP Object (0x%04X)", formatCode) : "\(ext) File"
    }
    
    var dimensionsDescription: String {
        guard imageWidth > 0 && imageHeight > 0 else { return "—" }
        return "\(imageWidth) × \(imageHeight)"
    }
    
    var formattedSize: String {
        if isFolder {
            if let childCount {
                return "\(childCount) item\(childCount == 1 ? "" : "s")"
            }
            return "—"
        }
        return ByteCountFormatter.string(fromByteCount: Int64(compressedSize), countStyle: .file)
    }
    
    var displayDate: Date? {
        captureDate ?? modificationDate
    }
}

nonisolated enum MTPError: LocalizedError, Sendable {
    case deviceNotFound
    case interfaceOpenFailed(String)
    case pipeNotFound
    case transferFailed(String)
    case unexpectedResponse(MTPResponseCode?, UInt16)
    case invalidData
    
    var errorDescription: String? {
        switch self {
        case .deviceNotFound:
            return "No Nintendo Switch or MTP USB device detected."
        case .interfaceOpenFailed(let msg):
            return "Could not claim USB MTP interface: \(msg)"
        case .pipeNotFound:
            return "USB Bulk IN/OUT endpoints not found on interface."
        case .transferFailed(let msg):
            return "USB transfer error: \(msg)"
        case .unexpectedResponse(let known, let raw):
            if let known {
                return "MTP device returned \(known.description)"
            }
            return String(format: "MTP device returned response code 0x%04X", raw)
        case .invalidData:
            return "Received malformed MTP packet data."
        }
    }
}

nonisolated enum MTPDateParser {
    private static let formatterWithSeconds: DateFormatter = {
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "yyyyMMdd'T'HHmmss"
        return df
    }()
    
    private static let formatterFractional: DateFormatter = {
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "yyyyMMdd'T'HHmmss.S"
        return df
    }()
    
    static func parse(_ raw: String) -> Date? {
        guard !raw.isEmpty else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count >= 15 {
            let base = String(trimmed.prefix(15))
            if let d = formatterWithSeconds.date(from: base) {
                return d
            }
        }
        return formatterFractional.date(from: trimmed)
    }
}
