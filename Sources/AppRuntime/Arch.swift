//
//  Arch.swift
//  
//
//  Created by Alsey Coleman Miller on 3/8/22.
//

public struct Arch: RawRepresentable, Equatable, Hashable, Codable {

    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }
}

// MARK: - ExpressibleByStringLiteral

extension Arch: ExpressibleByStringLiteral {
    
    public init(stringLiteral value: String) {
        self.init(rawValue: value)
    }
}

// MARK: - CustomStringConvertible

extension Arch: CustomStringConvertible, CustomDebugStringConvertible {
    
    public var description: String {
        rawValue
    }
    
    public var debugDescription: String {
        rawValue
    }
}

// MARK: - Definitions

public extension Arch {
    
    static var armv5: Arch { "armv5" }
    
    static var armv6: Arch { "armv6" }
    
    static var armv7: Arch { "armv7" }
    
    static var arm64: Arch { "arm64" }
    
    static var x86_64: Arch { "x86_64" }

    static var i386: Arch { "i386" }
}

// MARK: - Host

#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif canImport(Darwin)
import Darwin
#endif

#if canImport(Glibc) || canImport(Musl) || canImport(Darwin)
public extension Arch {

    /// The native architecture of the current host, if recognized.
    static var host: Arch? {
        var systemInfo = utsname()
        guard uname(&systemInfo) == 0 else { return nil }
        let machine = withUnsafeBytes(of: &systemInfo.machine) { buffer in
            String(decoding: buffer.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
        return Arch(machine: machine)
    }
}
#endif

public extension Arch {

    /// Map a `uname -m` machine string to an ``Arch``.
    init?(machine: String) {
        switch machine {
        case "arm64", "aarch64":
            self = .arm64
        case "x86_64", "amd64":
            self = .x86_64
        case "i386", "i486", "i586", "i686":
            self = .i386
        case let arm where arm.hasPrefix("armv7"):
            self = .armv7
        case let arm where arm.hasPrefix("armv6"):
            self = .armv6
        case let arm where arm.hasPrefix("armv5"):
            self = .armv5
        default:
            return nil
        }
    }
}
