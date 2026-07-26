//
//  AppBundle.swift
//  AppRuntime
//

#if canImport(Foundation)
import Foundation

/// An installed (or authored) app bundle on disk.
public struct AppBundle: Equatable, Hashable {

    public enum Error: Swift.Error, Equatable {
        /// `manifest.json` is missing from the bundle.
        case missingManifest(String)
        /// The executable name is not a single safe path component.
        case invalidExecutable(String)
        /// The bundle identifier is not a single safe path component.
        case invalidIdentifier(String)
        /// The manifest declares no architectures.
        case noArchitectures
        /// A declared architecture has no matching binary in `bin/`.
        case missingBinary(Arch, path: String)
    }

    /// Root directory of the bundle (the mounted squashfs or `.app` folder).
    public let path: String

    /// The parsed and validated manifest.
    public let manifest: Manifest

    /// Load and validate a bundle at the given directory.
    public init(path: String, fileManager: FileManager = .default) throws {
        let root = (path as NSString).standardizingPath
        let manifestPath = root + "/" + Manifest.fileName
        guard fileManager.fileExists(atPath: manifestPath) else {
            throw Error.missingManifest(manifestPath)
        }
        let manifest = try Manifest(json: Data(contentsOf: URL(fileURLWithPath: manifestPath)))
        try Self.validate(manifest)
        // Verify each declared architecture ships its binary.
        for arch in manifest.architectures {
            let binary = root + "/bin/" + arch.rawValue + "/" + manifest.executable
            guard fileManager.fileExists(atPath: binary) else {
                throw Error.missingBinary(arch, path: binary)
            }
        }
        self.path = root
        self.manifest = manifest
    }

    /// Validate manifest fields that affect path construction.
    public static func validate(_ manifest: Manifest) throws {
        guard Self.isSafePathComponent(manifest.id) else {
            throw Error.invalidIdentifier(manifest.id)
        }
        guard Self.isSafePathComponent(manifest.executable) else {
            throw Error.invalidExecutable(manifest.executable)
        }
        guard manifest.architectures.isEmpty == false else {
            throw Error.noArchitectures
        }
    }

    /// A single path component: non-empty, no separators, not `.` or `..`.
    static func isSafePathComponent(_ value: String) -> Bool {
        value.isEmpty == false
            && value != "."
            && value != ".."
            && value.contains("/") == false
            && value.contains("\0") == false
    }
}

// MARK: - Path Resolution

public extension AppBundle {

    /// Path to the executable for the given architecture.
    func executablePath(for arch: Arch) -> String {
        path + "/bin/" + arch.rawValue + "/" + manifest.executable
    }

    /// Path to the private library directory for the given architecture,
    /// or `nil` if the bundle ships none.
    func libraryPath(for arch: Arch, fileManager: FileManager = .default) -> String? {
        let libPath = path + "/lib/" + arch.rawValue
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: libPath, isDirectory: &isDirectory), isDirectory.boolValue else {
            return nil
        }
        return libPath
    }

    /// Select the best architecture for the host and resolve launch paths.
    func selectExecutable(for host: HostCapabilities) throws -> (selection: ArchSelection, executable: String) {
        let selection = try ArchSelector.select(from: manifest.architectures, host: host)
        return (selection, executablePath(for: selection.arch))
    }
}
#endif
