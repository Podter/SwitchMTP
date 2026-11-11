//
//  MTPUSBClient.swift
//  SwitchMTP
//

import Foundation
import IOKit
import IOUSBHost

nonisolated final class MTPUSBClient: @unchecked Sendable {
    static let nintendoVendorID = 0x057E
    static let switchMTPProductID = 0x201D
    
    private let usbQueue = DispatchQueue(label: "me.podter.SwitchMTP.usbQueue", qos: .userInitiated)
    
    private var hostInterface: IOUSBHostInterface?
    private var pipeIn: IOUSBHostPipe?
    private var pipeOut: IOUSBHostPipe?
    private var pipeInterrupt: IOUSBHostPipe?
    private var maxPacketSizeIn: Int = 512
    private var transactionID: UInt32 = 1
    private var isSessionOpen: Bool = false
    
    init() {}
    
    static func isSwitchPresentInRegistry() -> Bool {
        guard let matching = IOServiceMatching("IOUSBHostInterface") else { return false }
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else {
            return false
        }
        defer { IOObjectRelease(iterator) }
        
        var service = IOIteratorNext(iterator)
        while service != 0 {
            defer {
                IOObjectRelease(service)
                service = IOIteratorNext(iterator)
            }
            var props: Unmanaged<CFMutableDictionary>?
            if IORegistryEntryCreateCFProperties(service, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
               let dict = props?.takeRetainedValue() as? [String: Any] {
                let vid = dict["idVendor"] as? Int ?? -1
                let pid = dict["idProduct"] as? Int ?? -1
                let ifClass = dict["bInterfaceClass"] as? Int ?? -1
                let usbString = dict["kUSBString"] as? String ?? ""
                if (vid == nintendoVendorID && pid == switchMTPProductID) ||
                   (vid == nintendoVendorID && ifClass == 6) ||
                   usbString == "MTP" {
                    return true
                }
            }
        }
        return false
    }
    
    private func runOnUSBQueue<T: Sendable>(_ block: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            usbQueue.async {
                do {
                    let result = try block()
                    continuation.resume(returning: result)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
    
    func connect() async throws -> MTPDeviceDetails {
        try await runOnUSBQueue {
            self.disconnectSync()
            
            guard let matching = IOServiceMatching("IOUSBHostInterface") else {
                throw MTPError.deviceNotFound
            }
            var iterator: io_iterator_t = 0
            let kr = IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator)
            guard kr == KERN_SUCCESS else {
                throw MTPError.deviceNotFound
            }
            defer { IOObjectRelease(iterator) }
            
            var matchedService: io_service_t = 0
            var matchedDict: [String: Any] = [:]
            
            var service = IOIteratorNext(iterator)
            while service != 0 {
                var props: Unmanaged<CFMutableDictionary>?
                if IORegistryEntryCreateCFProperties(service, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
                   let dict = props?.takeRetainedValue() as? [String: Any] {
                    let vid = dict["idVendor"] as? Int ?? -1
                    let pid = dict["idProduct"] as? Int ?? -1
                    let ifClass = dict["bInterfaceClass"] as? Int ?? -1
                    let ifSubClass = dict["bInterfaceSubClass"] as? Int ?? -1
                    let usbString = dict["kUSBString"] as? String ?? ""
                    
                    let isSwitch = (vid == Self.nintendoVendorID && (pid == Self.switchMTPProductID || ifClass == 6))
                    let isMTP = (ifClass == 6 && ifSubClass == 1) || usbString == "MTP"
                    
                    if isSwitch || isMTP {
                        if matchedService != 0 {
                            IOObjectRelease(matchedService)
                        }
                        matchedService = service
                        matchedDict = dict
                        if isSwitch {
                            service = IOIteratorNext(iterator)
                            while service != 0 {
                                IOObjectRelease(service)
                                service = IOIteratorNext(iterator)
                            }
                            break
                        }
                        service = IOIteratorNext(iterator)
                        continue
                    }
                }
                IOObjectRelease(service)
                service = IOIteratorNext(iterator)
            }
            
            guard matchedService != 0 else {
                throw MTPError.deviceNotFound
            }
            
            let interface: IOUSBHostInterface
            do {
                interface = try IOUSBHostInterface(
                    __ioService: matchedService,
                    options: [.deviceSeize],
                    queue: nil,
                    interestHandler: nil
                )
            } catch {
                throw MTPError.interfaceOpenFailed(error.localizedDescription)
            }
            
            let ifDesc = interface.interfaceDescriptor
            let cfgDesc = interface.configurationDescriptor
            
            var currentHeader: UnsafePointer<IOUSBDescriptorHeader>? = nil
            var bulkInAddr: UInt8 = 0
            var bulkOutAddr: UInt8 = 0
            var intrInAddr: UInt8 = 0
            var inMaxPacket: Int = 512
            
            while let nextEp = IOUSBGetNextEndpointDescriptor(cfgDesc, ifDesc, currentHeader) {
                currentHeader = UnsafeRawPointer(nextEp).assumingMemoryBound(to: IOUSBDescriptorHeader.self)
                let addr = nextEp.pointee.bEndpointAddress
                let type = IOUSBGetEndpointType(nextEp)
                let maxPkt = Int(nextEp.pointee.wMaxPacketSize & 0x07FF)
                if type == 2 && (addr & 0x80) != 0 {
                    bulkInAddr = addr
                    if maxPkt > 0 { inMaxPacket = maxPkt }
                } else if type == 2 && (addr & 0x80) == 0 {
                    bulkOutAddr = addr
                } else if type == 3 && (addr & 0x80) != 0 {
                    intrInAddr = addr
                }
            }
            
            guard bulkInAddr != 0 && bulkOutAddr != 0 else {
                interface.destroy()
                throw MTPError.pipeNotFound
            }
            
            do {
                let inPipe = try interface.copyPipe(withAddress: Int(bulkInAddr))
                let outPipe = try interface.copyPipe(withAddress: Int(bulkOutAddr))
                let intrPipe = intrInAddr != 0 ? (try? interface.copyPipe(withAddress: Int(intrInAddr))) : nil
                
                self.hostInterface = interface
                self.pipeIn = inPipe
                self.pipeOut = outPipe
                self.pipeInterrupt = intrPipe
                self.maxPacketSizeIn = inMaxPacket
                
                try self.openSessionSync()
                
                let devInfoPayload = try self.executeCommandSync(.getDeviceInfo, timeout: 4.0).data
                return self.parseDeviceInfo(devInfoPayload, usbProperties: matchedDict)
            } catch {
                self.disconnectSync()
                throw error
            }
        }
    }
    
    func disconnect() async {
        await withCheckedContinuation { continuation in
            usbQueue.async {
                self.disconnectSync()
                continuation.resume()
            }
        }
    }
    
    private func disconnectSync() {
        if isSessionOpen {
            _ = try? executeCommandSync(.closeSession, timeout: 1.0)
            isSessionOpen = false
        }
        pipeIn = nil
        pipeOut = nil
        pipeInterrupt = nil
        if let hostInterface {
            hostInterface.destroy()
            self.hostInterface = nil
        }
        transactionID = 1
    }
    
    private func openSessionSync() throws {
        transactionID = 0
        let resp = try executeCommandSync(.openSession, parameters: [1], useExplicitTransactionID: 0, timeout: 3.0)
        print(String(format: "[SwitchMTP] OpenSession initial response: 0x%04X", resp.responseCode))
        if resp.responseCode == MTPResponseCode.sessionAlreadyOpen.rawValue {
            // Probe for the active TransactionID to send CloseSession (try last known tx first, then scan)
            let savedTx = UInt32(UserDefaults.standard.integer(forKey: "SwitchMTP.lastTransactionID"))
            var candidates: [UInt32] = []
            if savedTx > 0 {
                candidates.append(savedTx)
                candidates.append(savedTx &+ 1)
            }
            candidates.append(contentsOf: 0...5000)
            
            var closed = false
            for candidateTx in candidates {
                if let closeResp = try? executeCommandSync(.closeSession, useExplicitTransactionID: candidateTx, timeout: 1.0),
                   closeResp.responseCode == MTPResponseCode.ok.rawValue {
                    print("[SwitchMTP] Recovered open session at tx=\(candidateTx) and closed cleanly")
                    closed = true
                    break
                }
            }
            if closed {
                let reopen = try executeCommandSync(.openSession, parameters: [1], useExplicitTransactionID: 0, timeout: 3.0)
                guard reopen.responseCode == MTPResponseCode.ok.rawValue else {
                    throw MTPError.unexpectedResponse(MTPResponseCode(rawValue: reopen.responseCode), reopen.responseCode)
                }
            }
        } else if resp.responseCode != MTPResponseCode.ok.rawValue {
            throw MTPError.unexpectedResponse(MTPResponseCode(rawValue: resp.responseCode), resp.responseCode)
        }
        transactionID = 1
        isSessionOpen = true
    }
    
    // MARK: - Async MTP Operations
    
    func fetchStorages() async throws -> [MTPStorage] {
        try await runOnUSBQueue {
            let resp = try self.executeCommandSync(.getStorageIDs)
            guard resp.responseCode == MTPResponseCode.ok.rawValue else {
                throw MTPError.unexpectedResponse(MTPResponseCode(rawValue: resp.responseCode), resp.responseCode)
            }
            var offset = 0
            let storageIDs = Self.readUInt32Array(resp.data, offset: &offset)
            var storages: [MTPStorage] = []
            for sid in storageIDs {
                let infoResp = try self.executeCommandSync(.getStorageInfo, parameters: [sid])
                if infoResp.responseCode == MTPResponseCode.ok.rawValue,
                   let storage = self.parseStorageInfo(id: sid, data: infoResp.data) {
                    storages.append(storage)
                }
            }
            return storages
        }
    }
    
    func fetchDirectoryItems(
        storageID: UInt32,
        parentHandle: UInt32,
        folderName: String = "",
        includeChildCountsForFolders: Bool = true
    ) async throws -> [MTPObjectItem] {
        try await runOnUSBQueue {
            let handles = try self.fetchObjectHandlesSync(storageID: storageID, parentHandle: parentHandle)
            var items: [MTPObjectItem] = []
            items.reserveCapacity(handles.count)
            for handle in handles {
                var item = try self.fetchObjectInfoSync(handle: handle, folderName: folderName)
                if item.isFolder && includeChildCountsForFolders {
                    if let childHandles = try? self.fetchObjectHandlesSync(storageID: storageID, parentHandle: handle) {
                        item.childCount = childHandles.count
                    }
                }
                items.append(item)
            }
            return items
        }
    }
    
    func fetchThumbnail(handle: UInt32) async throws -> Data {
        try await runOnUSBQueue {
            let resp = try self.executeCommandSync(.getThumb, parameters: [handle], timeout: 6.0)
            guard resp.responseCode == MTPResponseCode.ok.rawValue else {
                throw MTPError.unexpectedResponse(MTPResponseCode(rawValue: resp.responseCode), resp.responseCode)
            }
            return resp.data
        }
    }
    
    func fetchObjectData(handle: UInt32, progress: (@Sendable (Int64, Int64) -> Void)? = nil) async throws -> Data {
        try await runOnUSBQueue {
            let resp = try self.executeCommandSync(.getObject, parameters: [handle], timeout: 30.0, progress: progress)
            guard resp.responseCode == MTPResponseCode.ok.rawValue else {
                throw MTPError.unexpectedResponse(MTPResponseCode(rawValue: resp.responseCode), resp.responseCode)
            }
            return resp.data
        }
    }
    
    func downloadObjectToFile(
        item: MTPObjectItem,
        destinationURL: URL,
        progress: (@Sendable (Int64, Int64) -> Void)? = nil
    ) async throws {
        try await runOnUSBQueue {
            let fm = FileManager.default
            let parentDir = destinationURL.deletingLastPathComponent()
            if !fm.fileExists(atPath: parentDir.path) {
                try fm.createDirectory(at: parentDir, withIntermediateDirectories: true)
            }
            if fm.fileExists(atPath: destinationURL.path) {
                try fm.removeItem(at: destinationURL)
            }
            fm.createFile(atPath: destinationURL.path, contents: nil)
            let fileHandle = try FileHandle(forWritingTo: destinationURL)
            defer {
                try? fileHandle.close()
            }
            
            let respCode = try self.streamCommandToFileSync(
                .getObject,
                parameters: [item.handle],
                fileHandle: fileHandle,
                timeout: 30.0,
                progress: progress
            )
            guard respCode == MTPResponseCode.ok.rawValue else {
                try? fm.removeItem(at: destinationURL)
                throw MTPError.unexpectedResponse(MTPResponseCode(rawValue: respCode), respCode)
            }
            
            if let date = item.displayDate {
                try? fm.setAttributes([
                    .creationDate: date,
                    .modificationDate: date
                ], ofItemAtPath: destinationURL.path)
            }
        }
    }
    
    // MARK: - Internal Synchronous Helpers (run on usbQueue)
    
    private func fetchObjectHandlesSync(storageID: UInt32, formatCode: UInt32 = 0, parentHandle: UInt32 = 0xFFFFFFFF) throws -> [UInt32] {
        let resp = try executeCommandSync(.getObjectHandles, parameters: [storageID, formatCode, parentHandle])
        guard resp.responseCode == MTPResponseCode.ok.rawValue else {
            throw MTPError.unexpectedResponse(MTPResponseCode(rawValue: resp.responseCode), resp.responseCode)
        }
        var offset = 0
        return Self.readUInt32Array(resp.data, offset: &offset)
    }
    
    private func fetchObjectInfoSync(handle: UInt32, folderName: String = "") throws -> MTPObjectItem {
        let resp = try executeCommandSync(.getObjectInfo, parameters: [handle])
        guard resp.responseCode == MTPResponseCode.ok.rawValue else {
            throw MTPError.unexpectedResponse(MTPResponseCode(rawValue: resp.responseCode), resp.responseCode)
        }
        guard var item = parseObjectInfo(handle: handle, data: resp.data) else {
            throw MTPError.invalidData
        }
        item.folderName = folderName
        return item
    }
    
    private func executeCommandSync(
        _ op: MTPOperationCode,
        parameters: [UInt32] = [],
        useExplicitTransactionID: UInt32? = nil,
        timeout: TimeInterval = 8.0,
        progress: (@Sendable (Int64, Int64) -> Void)? = nil
    ) throws -> (data: Data, responseCode: UInt16, responseParams: [UInt32]) {
        guard let pipeIn, let pipeOut else {
            throw MTPError.deviceNotFound
        }
        
        let tx: UInt32
        if let explicit = useExplicitTransactionID {
            tx = explicit
        } else {
            tx = transactionID
            transactionID &+= 1
            UserDefaults.standard.set(Int(transactionID), forKey: "SwitchMTP.lastTransactionID")
        }
        
        let cmdData = Self.makeCommandPacket(code: op.rawValue, transactionID: tx, parameters: parameters)
        let outBuf = NSMutableData(data: cmdData)
        var outTransferred = 0
        do {
            try pipeOut.__sendIORequest(with: outBuf, bytesTransferred: &outTransferred, completionTimeout: timeout)
        } catch {
            throw MTPError.transferFailed(error.localizedDescription)
        }
        
        func readBulkPacket(maxLength: Int) throws -> Data {
            let alignedLength = max(maxPacketSizeIn, ((maxLength + maxPacketSizeIn - 1) / maxPacketSizeIn) * maxPacketSizeIn)
            let buf = NSMutableData(length: alignedLength)!
            var count = 0
            do {
                try pipeIn.__sendIORequest(with: buf, bytesTransferred: &count, completionTimeout: timeout)
            } catch {
                throw MTPError.transferFailed(error.localizedDescription)
            }
            return Data(bytes: buf.bytes, count: count)
        }
        
        var firstPkt = try readBulkPacket(maxLength: 65536)
        while firstPkt.isEmpty {
            firstPkt = try readBulkPacket(maxLength: 65536)
        }
        guard firstPkt.count >= 12 else {
            throw MTPError.invalidData
        }
        
        let containerLen = firstPkt.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 0, as: UInt32.self) }
        let containerType = firstPkt.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 4, as: UInt16.self) }
        
        var payload = Data()
        var responsePkt = firstPkt
        
        if containerType == MTPContainerType.data.rawValue {
            let expectedPayload = max(0, Int(containerLen) - 12)
            payload.reserveCapacity(expectedPayload)
            
            if firstPkt.count > 12 {
                payload.append(firstPkt.subdata(in: 12..<firstPkt.count))
                progress?(Int64(payload.count), Int64(expectedPayload))
            }
            
            while payload.count < expectedPayload {
                let remaining = expectedPayload - payload.count
                let chunkReq = min(1_048_576, remaining)
                let chunk = try readBulkPacket(maxLength: chunkReq)
                if chunk.isEmpty { break }
                payload.append(chunk)
                progress?(Int64(payload.count), Int64(expectedPayload))
            }
            
            if payload.count > expectedPayload {
                let extra = payload.subdata(in: expectedPayload..<payload.count)
                payload = payload.subdata(in: 0..<expectedPayload)
                if extra.count >= 12 {
                    responsePkt = extra
                } else {
                    responsePkt = try readBulkPacket(maxLength: 512)
                }
            } else {
                responsePkt = try readBulkPacket(maxLength: 512)
                while responsePkt.isEmpty {
                    responsePkt = try readBulkPacket(maxLength: 512)
                }
            }
        }
        
        guard responsePkt.count >= 12 else {
            throw MTPError.invalidData
        }
        let respCode = responsePkt.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 6, as: UInt16.self) }
        var respParams: [UInt32] = []
        if responsePkt.count > 12 {
            let pCount = (responsePkt.count - 12) / 4
            for i in 0..<pCount {
                let p = responsePkt.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 12 + i * 4, as: UInt32.self) }
                respParams.append(p)
            }
        }
        return (payload, respCode, respParams)
    }
    
    private func streamCommandToFileSync(
        _ op: MTPOperationCode,
        parameters: [UInt32],
        fileHandle: FileHandle,
        timeout: TimeInterval,
        progress: (@Sendable (Int64, Int64) -> Void)?
    ) throws -> UInt16 {
        guard let pipeIn, let pipeOut else {
            throw MTPError.deviceNotFound
        }
        
        let tx = transactionID
        transactionID &+= 1
        
        let cmdData = Self.makeCommandPacket(code: op.rawValue, transactionID: tx, parameters: parameters)
        let outBuf = NSMutableData(data: cmdData)
        var outTransferred = 0
        do {
            try pipeOut.__sendIORequest(with: outBuf, bytesTransferred: &outTransferred, completionTimeout: timeout)
        } catch {
            throw MTPError.transferFailed(error.localizedDescription)
        }
        
        func readBulkPacket(maxLength: Int) throws -> Data {
            let alignedLength = max(maxPacketSizeIn, ((maxLength + maxPacketSizeIn - 1) / maxPacketSizeIn) * maxPacketSizeIn)
            let buf = NSMutableData(length: alignedLength)!
            var count = 0
            do {
                try pipeIn.__sendIORequest(with: buf, bytesTransferred: &count, completionTimeout: timeout)
            } catch {
                throw MTPError.transferFailed(error.localizedDescription)
            }
            return Data(bytes: buf.bytes, count: count)
        }
        
        var firstPkt = try readBulkPacket(maxLength: 65536)
        while firstPkt.isEmpty {
            firstPkt = try readBulkPacket(maxLength: 65536)
        }
        guard firstPkt.count >= 12 else {
            throw MTPError.invalidData
        }
        
        let containerLen = firstPkt.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 0, as: UInt32.self) }
        let containerType = firstPkt.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 4, as: UInt16.self) }
        
        var responsePkt = firstPkt
        if containerType == MTPContainerType.data.rawValue {
            let expectedPayload = max(0, Int64(containerLen) - 12)
            var writtenBytes: Int64 = 0
            
            if firstPkt.count > 12 {
                let initialData = firstPkt.subdata(in: 12..<firstPkt.count)
                try fileHandle.write(contentsOf: initialData)
                writtenBytes += Int64(initialData.count)
                progress?(writtenBytes, expectedPayload)
            }
            
            while writtenBytes < expectedPayload {
                let remaining = Int(expectedPayload - writtenBytes)
                let chunkReq = min(1_048_576, remaining)
                let chunk = try readBulkPacket(maxLength: chunkReq)
                if chunk.isEmpty { break }
                try fileHandle.write(contentsOf: chunk)
                writtenBytes += Int64(chunk.count)
                progress?(writtenBytes, expectedPayload)
            }
            
            responsePkt = try readBulkPacket(maxLength: 512)
            while responsePkt.isEmpty {
                responsePkt = try readBulkPacket(maxLength: 512)
            }
        }
        
        guard responsePkt.count >= 12 else {
            throw MTPError.invalidData
        }
        return responsePkt.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 6, as: UInt16.self) }
    }
    
    private static func makeCommandPacket(code: UInt16, transactionID: UInt32, parameters: [UInt32]) -> Data {
        var data = Data(capacity: 12 + parameters.count * 4)
        var length = UInt32(12 + parameters.count * 4).littleEndian
        var type = MTPContainerType.command.rawValue.littleEndian
        var opCode = code.littleEndian
        var tx = transactionID.littleEndian
        withUnsafeBytes(of: &length) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: &type) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: &opCode) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: &tx) { data.append(contentsOf: $0) }
        for param in parameters {
            var p = param.littleEndian
            withUnsafeBytes(of: &p) { data.append(contentsOf: $0) }
        }
        return data
    }
    
    // MARK: - Binary Parsers
    
    private func parseDeviceInfo(_ data: Data, usbProperties: [String: Any]) -> MTPDeviceDetails {
        let vid = usbProperties["idVendor"] as? Int ?? Self.nintendoVendorID
        let pid = usbProperties["idProduct"] as? Int ?? Self.switchMTPProductID
        let usbProd = usbProperties["USB Product Name"] as? String ?? "Nintendo Switch"
        let usbVend = usbProperties["USB Vendor Name"] as? String ?? "Nintendo"
        let usbSer = usbProperties["USB Serial Number"] as? String ?? ""
        
        guard data.count >= 8 else {
            return MTPDeviceDetails(
                vendorID: vid,
                productID: pid,
                usbProductName: usbProd,
                usbVendorName: usbVend,
                usbSerialNumber: usbSer,
                manufacturer: usbVend,
                model: usbProd,
                deviceVersion: "",
                serialNumber: usbSer,
                vendorExtensionDesc: "",
                operationsSupported: []
            )
        }
        
        var offset = 8
        let vendorExtDesc = Self.readMTPString(data, offset: &offset)
        offset += 2
        let opsSupported = Self.readUInt16Array(data, offset: &offset)
        _ = Self.readUInt16Array(data, offset: &offset)
        _ = Self.readUInt16Array(data, offset: &offset)
        _ = Self.readUInt16Array(data, offset: &offset)
        _ = Self.readUInt16Array(data, offset: &offset)
        let manufacturer = Self.readMTPString(data, offset: &offset)
        let model = Self.readMTPString(data, offset: &offset)
        let version = Self.readMTPString(data, offset: &offset)
        let serial = Self.readMTPString(data, offset: &offset)
        
        return MTPDeviceDetails(
            vendorID: vid,
            productID: pid,
            usbProductName: usbProd,
            usbVendorName: usbVend,
            usbSerialNumber: usbSer,
            manufacturer: manufacturer.isEmpty ? usbVend : manufacturer,
            model: model.isEmpty ? usbProd : model,
            deviceVersion: version,
            serialNumber: serial.isEmpty ? usbSer : serial,
            vendorExtensionDesc: vendorExtDesc.trimmingCharacters(in: .whitespacesAndNewlines),
            operationsSupported: opsSupported
        )
    }
    
    private func parseStorageInfo(id: UInt32, data: Data) -> MTPStorage? {
        guard data.count >= 26 else { return nil }
        let storageType = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 0, as: UInt16.self) }
        let fsType = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 2, as: UInt16.self) }
        let accessCap = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 4, as: UInt16.self) }
        let maxCap = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 6, as: UInt64.self) }
        let freeBytes = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 14, as: UInt64.self) }
        var offset = 26
        let desc = Self.readMTPString(data, offset: &offset)
        let volID = Self.readMTPString(data, offset: &offset)
        
        return MTPStorage(
            id: id,
            storageType: storageType,
            filesystemType: fsType,
            accessCapability: accessCap,
            maxCapacity: maxCap,
            freeSpaceInBytes: freeBytes,
            description: desc,
            volumeIdentifier: volID
        )
    }
    
    private func parseObjectInfo(handle: UInt32, data: Data) -> MTPObjectItem? {
        guard data.count >= 52 else { return nil }
        let storageID = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 0, as: UInt32.self) }
        let formatCode = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 4, as: UInt16.self) }
        let compSize = UInt64(data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 8, as: UInt32.self) })
        let thumbFormat = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 12, as: UInt16.self) }
        let thumbCompSize = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 14, as: UInt32.self) }
        let thumbW = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 18, as: UInt32.self) }
        let thumbH = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 22, as: UInt32.self) }
        let imgW = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 26, as: UInt32.self) }
        let imgH = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 30, as: UInt32.self) }
        let parentHandle = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 38, as: UInt32.self) }
        
        var offset = 52
        let filename = Self.readMTPString(data, offset: &offset)
        let captureDateStr = Self.readMTPString(data, offset: &offset)
        let modDateStr = Self.readMTPString(data, offset: &offset)
        
        return MTPObjectItem(
            handle: handle,
            storageID: storageID,
            parentHandle: parentHandle,
            formatCode: formatCode,
            compressedSize: compSize,
            thumbFormat: thumbFormat,
            thumbCompressedSize: thumbCompSize,
            thumbWidth: thumbW,
            thumbHeight: thumbH,
            imageWidth: imgW,
            imageHeight: imgH,
            filename: filename.isEmpty ? String(format: "Object_%08X", handle) : filename,
            captureDateString: captureDateStr,
            modificationDateString: modDateStr,
            captureDate: MTPDateParser.parse(captureDateStr),
            modificationDate: MTPDateParser.parse(modDateStr)
        )
    }
    
    private static func readMTPString(_ data: Data, offset: inout Int) -> String {
        guard offset < data.count else { return "" }
        let numChars = Int(data[offset])
        offset += 1
        guard numChars > 0 else { return "" }
        let byteLen = numChars * 2
        guard offset + byteLen <= data.count else {
            offset = data.count
            return ""
        }
        let strBytesLen = max(0, byteLen - 2)
        let sub = data.subdata(in: offset..<(offset + strBytesLen))
        offset += byteLen
        return String(data: sub, encoding: .utf16LittleEndian) ?? ""
    }
    
    private static func readUInt16Array(_ data: Data, offset: inout Int) -> [UInt16] {
        guard offset + 4 <= data.count else { return [] }
        let count = Int(data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self) })
        offset += 4
        guard count > 0 && count < 100_000 else { return [] }
        var result: [UInt16] = []
        result.reserveCapacity(min(count, 256))
        for _ in 0..<count {
            guard offset + 2 <= data.count else { break }
            let val = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt16.self) }
            offset += 2
            result.append(val)
        }
        return result
    }
    
    private static func readUInt32Array(_ data: Data, offset: inout Int) -> [UInt32] {
        guard offset + 4 <= data.count else { return [] }
        let count = Int(data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self) })
        offset += 4
        guard count > 0 && count < 1_000_000 else { return [] }
        var result: [UInt32] = []
        result.reserveCapacity(min(count, 4096))
        for _ in 0..<count {
            guard offset + 4 <= data.count else { break }
            let val = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self) }
            offset += 4
            result.append(val)
        }
        return result
    }
}
