//
//  Adapter.swift
//  BluetoothLinux
//
//  Created by Alsey Coleman Miller on 12/6/15.
//  Copyright © 2015 PureSwift. All rights reserved.
//

#if os(Linux)
    import Glibc
#elseif os(macOS) || os(iOS)
    import Darwin.C
#endif

import CSwiftBluetoothLinux
import Bluetooth
import Foundation

/// Manages connection / communication to the underlying Bluetooth hardware.
public final class Adapter {

    // MARK: - Properties

    /// The device identifier of the Bluetooth adapter.
    public let identifier: CInt

    // MARK: - Internal Properties

    internal let internalSocket: CInt

    // MARK: - Initizalization

    deinit {

        close(internalSocket)
    }

    /// Initializes the Bluetooth Adapter with the specified address.
    ///
    /// If no address is specified then it tries to intialize the first Bluetooth adapter.
    public convenience init(address: Address? = nil) throws {
        
        guard let deviceIdentifier = try HCIGetRoute(address)
            else { throw Adapter.Error.adapterNotFound }
        
        let internalSocket = try HCIOpenDevice(deviceIdentifier)
        
        self.init(identifier: deviceIdentifier, internalSocket: internalSocket)
    }
    
    private init(identifier: CInt, internalSocket: CInt) {
        
        self.identifier = identifier
        self.internalSocket = internalSocket
    }
}

// MARK: - Address Extensions

public extension Address {
    
    /// Extracts the Bluetooth address from the device ID.
    public init(deviceIdentifier: CInt) throws {
        
        self = try HCIDeviceAddress(deviceIdentifier)
    }
}

public extension Adapter {
    
    /// Attempts to get the address from the underlying Bluetooth hardware.
    ///
    /// Fails if the Bluetooth adapter was disconnected or hardware failure.
    public var address: Address? {
        
        return try? Address(deviceIdentifier: identifier)
    }
}

// MARK: - Errors

public extension Adapter {
    
    public typealias Error = AdapterError
}

public enum AdapterError: Error {
    
    /// The specified adapter could not be found.
    case adapterNotFound
    
    /// A method that changed the adapter's filter had en internal error, 
    /// and unsuccessfully tried to restore the previous filter.
    ///
    /// First error is the method's error. Second is the error while trying to restore the filter
    case couldNotRestoreFilter(Error, Error)
    
    /// The recieved data could not be parsed correctly.
    case garbageResponse(Data)
}

// MARK: - Internal HCI Functions

internal func HCIOpenDevice(_ deviceIdentifier: CInt) throws -> CInt {
    
    // Create HCI socket
    let hciSocket = socket(AF_BLUETOOTH, SOCK_RAW | SOCK_CLOEXEC, BluetoothProtocol.HCI.rawValue)
    
    guard hciSocket >= 0 else { throw POSIXError.fromErrno! }
    
    // Bind socket to the HCI device
    var address = HCISocketAddress()
    address.family = sa_family_t(AF_BLUETOOTH)
    address.deviceIdentifier = UInt16(deviceIdentifier)
    
    let didBind = withUnsafeMutablePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            bind(hciSocket, $0, socklen_t(MemoryLayout<HCISocketAddress>.size)) >= 0
        }
    }
    
    guard didBind
        else { close(hciSocket); throw POSIXError.fromErrno! }
    
    return hciSocket
}

internal func HCIIdentifierOfDevice(_ flagFilter: HCIDeviceFlag = HCIDeviceFlag(), _ predicate: (_ deviceDescriptor: CInt, _ deviceIdentifier: CInt) throws -> Bool) throws -> CInt? {

    // open HCI socket

    let hciSocket = socket(AF_BLUETOOTH, SOCK_RAW | SOCK_CLOEXEC, BluetoothProtocol.HCI.rawValue)

    guard hciSocket >= 0 else { throw POSIXError.fromErrno! }

    defer { close(hciSocket) }

    // allocate HCI device list buffer

    var deviceList = HCIDeviceListRequest()

    deviceList.count = UInt16(HCI.maximumDeviceCount)
    
    // request device list
    let ioctlValue = withUnsafeMutablePointer(to: &deviceList) {
        InputOutputControl(hciSocket, HCI.IOCTL.GetDeviceList, $0)
    }
    
    guard ioctlValue >= 0 else { throw POSIXError.fromErrno! }
    
    for i in 0 ..< Int(deviceList.count) {

        let deviceRequest = deviceList[i]

        guard HCITestBit(flagFilter, deviceRequest.options) else { continue }

        let deviceIdentifier = CInt(deviceRequest.identifier)
        
        /* Operation not supported by device */
        guard deviceIdentifier >= 0 else { throw POSIXError(code: POSIXErrorCode.ENODEV) }
        
        if try predicate(hciSocket, deviceIdentifier) {

            return deviceIdentifier
        }
    }

    return nil
}

internal func HCIGetRoute(_ address: Address? = nil) throws -> CInt? {

    return try HCIIdentifierOfDevice { (dd, deviceIdentifier) in

        guard let address = address else { return true }

        var deviceInfo = HCIDeviceInformation()

        deviceInfo.identifier = UInt16(deviceIdentifier)

        guard withUnsafeMutablePointer(to: &deviceInfo, {
            InputOutputControl(dd, HCI.IOCTL.GetDeviceInfo, UnsafeMutableRawPointer($0)) }) == 0
            else { throw POSIXError.fromErrno! }

        return deviceInfo.address == address
    }
}

internal func HCIDeviceInfo(_ deviceIdentifier: CInt) throws -> HCIDeviceInformation {
    
    // open HCI socket
    
    let hciSocket = socket(AF_BLUETOOTH, SOCK_RAW | SOCK_CLOEXEC, BluetoothProtocol.HCI.rawValue)
    
    guard hciSocket >= 0 else { throw POSIXError.fromErrno! }
    
    defer { close(hciSocket) }
    
    var deviceInfo = HCIDeviceInformation()
    deviceInfo.identifier = UInt16(deviceIdentifier)
    
    guard withUnsafeMutablePointer(to: &deviceInfo, {
        InputOutputControl(hciSocket, HCI.IOCTL.GetDeviceInfo, UnsafeMutableRawPointer($0)) }) == 0
        else { throw POSIXError.fromErrno! }
    
    return deviceInfo
}

internal func HCIDeviceAddress(_ deviceIdentifier: CInt) throws -> Address {
    
    let deviceInfo = try HCIDeviceInfo(deviceIdentifier)
    
    guard HCITestBit(HCI.DeviceFlag.Up, deviceInfo.flags)
        else { throw POSIXError(code: .ENETDOWN) }
    
    return deviceInfo.address
}

@inline (__always)
internal func HCITestBit(_ flag: CInt,  _ options: UInt32) -> Bool {

    return (options + (UInt32(bitPattern: flag) >> 5)) & (1 << (UInt32(bitPattern: flag) & 31)) != 0
}

@inline (__always)
internal func HCITestBit(_ flag: HCI.DeviceFlag, _ options: UInt32) -> Bool {
    
    return HCITestBit(flag.rawValue, options)
}

// MARK: - Linux Support

#if os(Linux)

    let SOCK_RAW = CInt(Glibc.SOCK_RAW.rawValue)

    let SOCK_CLOEXEC = CInt(Glibc.SOCK_CLOEXEC.rawValue)
    
    typealias sa_family_t = Glibc.sa_family_t

#endif

// MARK: - Darwin Stubs

#if os(OSX) || os(iOS)

    var SOCK_CLOEXEC: CInt { stub() }
    
#endif
