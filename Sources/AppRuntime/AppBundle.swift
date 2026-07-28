//
//  AppBundle.swift
//  AppRuntime
//

#if canImport(FoundationEssentials)
import FoundationEssentials
#elseif canImport(Foundation)
import Foundation
#endif

#if canImport(FoundationEssentials) || canImport(Foundation)

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
        var root = path
        while root.count > 1 && root.hasSuffix("/") {
            root.removeLast()
        }
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
        return Self.directoryExists(atPath: libPath, fileManager: fileManager) ? libPath : nil
    }

    /// Select the best architecture for the host and resolve launch paths.
    func selectExecutable(for host: HostCapabilities) throws -> (selection: ArchSelection, executable: String) {
        let selection = try ArchSelector.select(from: manifest.architectures, host: host)
        return (selection, executablePath(for: selection.arch))
    }

    /// The working directory the launcher must set before exec: the bundle root.
    ///
    /// Part of the launch contract — apps ported from other platforms commonly
    /// open assets via paths relative to the working directory, so starting at
    /// the bundle root lets them work unmodified (optionally with a symlink in
    /// the bundle mapping their expected directory name to `resources/`).
    var workingDirectory: String { path }

    /// `true` if a directory exists at the given path.
    internal static func directoryExists(atPath path: String, fileManager: FileManager = .default) -> Bool {
        guard let type = (try? fileManager.attributesOfItem(atPath: path))?[.type] as? FileAttributeType else {
            return false
        }
        return type == .typeDirectory
    }
}

// MARK: - Main Bundle

public extension AppBundle {

    /// Environment variable the launcher sets to the mounted bundle root.
    static var pathEnvironmentVariable: String { "BUNDLE_PATH" }

    /// Default in-container mount point of the running app's bundle.
    static var defaultMountPoint: String { "/app" }

    /// The bundle of the currently running app, resolved from `BUNDLE_PATH`
    /// (set by the launcher) or the standard `/app` mount point.
    ///
    /// `nil` when the process is not running inside an app container.
    static let main: AppBundle? = {
        let path = ProcessInfo.processInfo.environment[pathEnvironmentVariable] ?? defaultMountPoint
        return try? AppBundle(path: path)
    }()
}

// MARK: - Resources

public extension AppBundle {

    /// Path to the bundle's resource directory (`resources/`),
    /// or `nil` if the bundle ships no resources.
    var resourcePath: String? {
        let resources = path + "/resources"
        return Self.directoryExists(atPath: resources) ? resources : nil
    }

    /// URL of the bundle's resource directory (`resources/`).
    var resourceURL: URL? {
        resourcePath.map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    /// Path to the bundle's self-contained launch script (`run.sh`),
    /// or `nil` if it ships none.
    ///
    /// The script selects an architecture and execs the binary without
    /// requiring the Swift launcher or runtime on the host.
    var runScriptPath: String? {
        let script = path + "/run.sh"
        return FileManager.default.fileExists(atPath: script) ? script : nil
    }

    /// Path to the bundle's icon, or `nil` if it ships none.
    var iconPath: String? {
        let icon = path + "/icon.png"
        return FileManager.default.fileExists(atPath: icon) ? icon : nil
    }

    /// Look up a resource in `resources/`, mirroring `Foundation.Bundle`.
    ///
    /// - Parameters:
    ///   - name: Resource file name, optionally with a subdirectory prefix.
    ///   - ext: File extension, appended when non-nil and non-empty.
    /// - Returns: The full path, or `nil` if the file does not exist.
    func path(forResource name: String, ofType ext: String? = nil) -> String? {
        guard name.isEmpty == false, name.contains("..") == false else { return nil }
        var resource = path + "/resources/" + name
        if let ext = ext, ext.isEmpty == false {
            resource += "." + ext
        }
        return FileManager.default.fileExists(atPath: resource) ? resource : nil
    }

    /// Look up a resource URL in `resources/`, mirroring `Foundation.Bundle`.
    func url(forResource name: String, withExtension ext: String? = nil) -> URL? {
        path(forResource: name, ofType: ext).map { URL(fileURLWithPath: $0) }
    }
}
#endif
