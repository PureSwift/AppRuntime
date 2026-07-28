//
//  main.swift
//  bundle-runtime
//
//  System launcher for AppRuntime bundles.
//
//  This is the unsandboxed slice of the launcher: resolve → parse/validate →
//  select architecture → environment → chdir → exec. Namespace isolation,
//  pivot_root, and privilege dropping layer on top of this sequence.
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

/// Directories searched when launching by bundle identifier,
/// in priority order.
let installDirectories = ["/data/apps", "/Applications"]

func fail(_ message: String) -> Never {
    fputs("bundle-runtime: " + message + "\n", stderr)
    exit(1)
}

// MARK: - Resolve

let arguments = CommandLine.arguments
guard arguments.count >= 2 else {
    fail("usage: bundle-runtime <bundle-path | bundle-id> [args...]")
}
let target = arguments[1]
let appArguments = Array(arguments.dropFirst(2))

/// A path (contains a separator or `.app` suffix) is used directly;
/// anything else is treated as an identifier and looked up in the
/// install directories, where bundles are named `<id>.app`.
let bundlePath: String
if target.contains("/") || target.hasSuffix(".app") {
    bundlePath = target
} else {
    guard AppBundle.isSafePathComponent(target) else {
        fail("invalid bundle identifier '\(target)'")
    }
    guard let found = installDirectories
        .map({ $0 + "/" + target + ".app" })
        .first(where: { FileManager.default.fileExists(atPath: $0) })
    else {
        fail("bundle '\(target)' not found in \(installDirectories.joined(separator: ", "))")
    }
    bundlePath = found
}

// MARK: - Parse & Select

let bundle: AppBundle
do {
    bundle = try AppBundle(path: bundlePath)
} catch {
    fail("invalid bundle at \(bundlePath): \(error)")
}

guard let host = HostCapabilities.probe() else {
    fail("unrecognized host architecture")
}
let selection: ArchSelection
let executable: String
do {
    (selection, executable) = try bundle.selectExecutable(for: host)
} catch {
    fail("no runnable architecture: bundle provides \(bundle.manifest.architectures), host is \(host)")
}

// MARK: - Sandbox

// With root (CAP_SYS_ADMIN) on Linux, launch inside the namespace sandbox.
// Otherwise fall through to the direct, unsandboxed exec (development mode).
#if os(Linux)
if geteuid() == 0 {
    // Root (CAP_SYS_ADMIN): full sandbox with a per-app uid.
    do {
        // Resource caps first: joining the cgroup before fork means the
        // app and everything it spawns inherit the limits.
        if ResourceLimits.isAvailable {
            do {
                try ResourceLimits.default.apply(id: bundle.manifest.id)
            } catch {
                fputs("bundle-runtime: warning: resource limits not applied: \(error)\n", stderr)
            }
        }
        let container = try Container.setup(id: bundle.manifest.id)
        let sandbox = Sandbox(
            bundle: bundle,
            selection: selection,
            container: container,
            capabilities: bundle.manifest.capabilities ?? [],
            mode: .privileged
        )
        try sandbox.launch(arguments: appArguments)
    } catch {
        fail("sandbox: \(error)")
    }
} else {
    // Unprivileged: user-namespace sandbox. The app runs as the invoking
    // user; device access is limited to what that user already has.
    // Falls back to a direct exec if user namespaces are unavailable.
    do {
        let container = try Container.setupUnprivileged(id: bundle.manifest.id)
        let sandbox = Sandbox(
            bundle: bundle,
            selection: selection,
            container: container,
            capabilities: bundle.manifest.capabilities ?? [],
            mode: .userNamespace
        )
        try sandbox.launch(arguments: appArguments)
    } catch {
        fputs("bundle-runtime: warning: user-namespace sandbox unavailable (\(error)), launching without sandbox\n", stderr)
    }
}
#endif

// MARK: - Environment (unsandboxed)

setenv(AppBundle.pathEnvironmentVariable, bundle.path, 1)
setenv("BUNDLE_ID", bundle.manifest.id, 1)
if let libraryPath = bundle.libraryPath(for: selection.arch) {
    let existing = ProcessInfo.processInfo.environment["LD_LIBRARY_PATH"]
    let value = existing.map { libraryPath + ":" + $0 } ?? libraryPath
    setenv("LD_LIBRARY_PATH", value, 1)
}

// Launch contract: the working directory is the bundle root.
guard chdir(bundle.workingDirectory) == 0 else {
    fail("cannot chdir to \(bundle.workingDirectory): \(String(cString: strerror(errno)))")
}

// MARK: - Exec

/// argv: translator (via PATH) when selected, then the binary, then app args.
var argv: [String] = []
if let translator = selection.translator {
    argv.append(translator.rawValue)
}
argv.append(executable)
argv.append(contentsOf: appArguments)

let cArgv: [UnsafeMutablePointer<CChar>?] = argv.map { strdup($0) } + [nil]
execvp(argv[0], cArgv)
// execvp only returns on failure.
fail("exec \(argv[0]) failed: \(String(cString: strerror(errno)))")
