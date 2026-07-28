//
//  Container.swift
//  bundle-runtime
//
//  Per-app data containers and stable uid allocation.
//

import AppRuntime

#if canImport(FoundationEssentials)
import FoundationEssentials
#elseif canImport(Foundation)
import Foundation
#endif

#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif canImport(Darwin)
import Darwin
#endif

/// A per-app writable container directory owned by the app's stable uid.
struct Container {

    /// Root under which per-app containers live.
    static let root = "/data/containers"

    /// First uid in the app uid range.
    static let firstUID: uid_t = 20000

    /// Persistent id→uid map, so an identifier keeps its uid for the
    /// lifetime of the installation and two apps can never collide.
    static let uidMapPath = root + "/.uid-map.json"

    let path: String
    let uid: uid_t

    /// Create (if needed) the container for a bundle identifier, allocate a
    /// stable uid from the persistent map, and chown the container to it.
    ///
    /// Must run as root, before entering the sandbox.
    static func setup(id: String) throws -> Container {
        let fileManager = FileManager.default
        let path = root + "/" + id
        try fileManager.createDirectory(atPath: path, withIntermediateDirectories: true)

        // Load or initialize the uid map.
        var map: [String: uid_t] = [:]
        if let data = try? Data(contentsOf: URL(fileURLWithPath: uidMapPath)) {
            map = try JSONDecoder().decode([String: uid_t].self, from: data)
        }
        let uid: uid_t
        if let existing = map[id] {
            uid = existing
        } else {
            uid = (map.values.max() ?? (firstUID - 1)) + 1
            map[id] = uid
            let data = try JSONEncoder().encode(map)
            try data.write(to: URL(fileURLWithPath: uidMapPath))
        }

        guard chown(path, uid, uid) == 0 else {
            throw ContainerError.chownFailed(path, errno)
        }
        return Container(path: path, uid: uid)
    }
}

enum ContainerError: Error {
    case chownFailed(String, Int32)
}
