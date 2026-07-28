//
//  Sandbox.swift
//  bundle-runtime
//
//  Namespace + pivot_root sandbox. Linux-only; requires root (or
//  CAP_SYS_ADMIN). The app ends up seeing:
//
//    /app    the bundle, read-only
//    /data   its container, read-write, owned by its uid
//    /tmp    private tmpfs (XDG_RUNTIME_DIR at /tmp/run)
//    /usr /lib /bin /sbin /etc   the OS, read-only
//    /dev    only the devices its capabilities grant
//    /proc   its own PID namespace
//

#if os(Linux)

import AppRuntime
import CBundleRuntime

#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

enum SandboxError: Error, CustomStringConvertible {
    case syscall(String, Int32)

    var description: String {
        switch self {
        case let .syscall(operation, code):
            return "\(operation): \(String(cString: strerror(code)))"
        }
    }
}

struct Sandbox {

    /// Staging root for the new filesystem, private to the mount namespace.
    static let stage = "/run/bundle-root"

    /// System directories bound read-only into the sandbox.
    /// Symlinks (merged-usr layouts) are recreated rather than bound.
    static let systemDirectories = ["/usr", "/lib", "/lib64", "/bin", "/sbin", "/etc"]

    /// Always-available device nodes.
    static let baseDevices = ["null", "zero", "full", "random", "urandom", "tty"]

    let bundle: AppBundle
    let selection: ArchSelection
    let container: Container
    let capabilities: [Capability]

    /// Enter the sandbox and exec the app. Never returns on success:
    /// the parent exits with the app's status, the child becomes the app.
    func launch(arguments: [String]) throws -> Never {
        let network = capabilities.contains(.network)

        // 1. New namespaces. NEWNET only when the app has no Network
        //    capability (no interfaces = no network).
        try check(br_unshare_namespaces(network ? 0 : 1), "unshare")

        // 2. Fork: the PID namespace applies to children only. The parent
        //    stays outside as supervisor and forwards the exit status.
        let child = fork()
        try check(child == -1 ? -1 : 0, "fork")
        if child > 0 {
            var status: Int32 = 0
            while waitpid(child, &status, 0) == -1 && errno == EINTR {}
            if status & 0x7f != 0 {
                exit(128 + (status & 0x7f))    // terminated by signal
            }
            exit((status >> 8) & 0xff)         // normal exit
        }

        // Child: build the new root and become the app.
        try buildRoot()
        try pivot()
        try dropPrivileges()
        try environmentAndExec(arguments: arguments)
    }

    // MARK: - Mounts

    private func buildRoot() throws {
        let fileManager = FileManager.default
        try check(br_make_root_private(), "make / private")
        try? fileManager.createDirectory(atPath: Self.stage, withIntermediateDirectories: true)
        try check(br_mount_tmpfs(Self.stage), "tmpfs \(Self.stage)")

        // OS directories, read-only. Merged-usr symlinks are recreated.
        for directory in Self.systemDirectories {
            guard fileManager.fileExists(atPath: directory) else { continue }
            let target = Self.stage + directory
            if let destination = try? fileManager.destinationOfSymbolicLink(atPath: directory) {
                try fileManager.createSymbolicLink(atPath: target, withDestinationPath: destination)
            } else {
                try fileManager.createDirectory(atPath: target, withIntermediateDirectories: true)
                try check(br_bind_mount(directory, target, 1), "bind \(directory)")
            }
        }

        // Bundle at /app (read-only), container at /data (read-write).
        try fileManager.createDirectory(atPath: Self.stage + "/app", withIntermediateDirectories: true)
        try check(br_bind_mount(bundle.path, Self.stage + "/app", 1), "bind /app")
        try fileManager.createDirectory(atPath: Self.stage + "/data", withIntermediateDirectories: true)
        try check(br_bind_mount(container.path, Self.stage + "/data", 0), "bind /data")

        // tmp (with XDG runtime dir), proc, dev.
        try fileManager.createDirectory(atPath: Self.stage + "/tmp", withIntermediateDirectories: true)
        try check(br_mount_tmpfs(Self.stage + "/tmp"), "tmpfs /tmp")
        let runtimeDirectory = Self.stage + "/tmp/run"
        try fileManager.createDirectory(atPath: runtimeDirectory, withIntermediateDirectories: true)
        try check(chmod(runtimeDirectory, 0o700), "chmod /tmp/run")
        try check(chown(runtimeDirectory, container.uid, container.uid), "chown /tmp/run")

        try fileManager.createDirectory(atPath: Self.stage + "/proc", withIntermediateDirectories: true)
        try check(br_mount_proc(Self.stage + "/proc"), "mount /proc")

        try mountDevices()
        try bindDisplaySocket()
    }

    /// tmpfs /dev populated by bind-mounting host nodes: the base set always,
    /// plus capability-gated directories.
    private func mountDevices() throws {
        let fileManager = FileManager.default
        let dev = Self.stage + "/dev"
        try fileManager.createDirectory(atPath: dev, withIntermediateDirectories: true)
        try check(br_mount_tmpfs(dev), "tmpfs /dev")

        for node in Self.baseDevices {
            let source = "/dev/" + node
            guard fileManager.fileExists(atPath: source) else { continue }
            let target = dev + "/" + node
            fileManager.createFile(atPath: target, contents: nil)
            try check(br_bind_mount(source, target, 0), "bind \(source)")
        }

        var directories: [String] = []
        if capabilities.contains(.display) { directories += ["/dev/dri", "/dev/input"] }
        if capabilities.contains(.audio) { directories.append("/dev/snd") }
        for directory in directories {
            guard fileManager.fileExists(atPath: directory) else { continue }
            let target = Self.stage + directory
            try fileManager.createDirectory(atPath: target, withIntermediateDirectories: true)
            try check(br_bind_mount(directory, target, 0), "bind \(directory)")
        }
    }

    /// Bind the compositor socket into the app's XDG runtime directory
    /// when the app has the Display capability.
    private func bindDisplaySocket() throws {
        guard capabilities.contains(.display) else { return }
        let fileManager = FileManager.default
        let hostRuntime = ProcessInfo.processInfo.environment["XDG_RUNTIME_DIR"] ?? "/run"
        let socket = hostRuntime + "/wayland-0"
        guard fileManager.fileExists(atPath: socket) else { return }
        let target = Self.stage + "/tmp/run/wayland-0"
        fileManager.createFile(atPath: target, contents: nil)
        try check(br_bind_mount(socket, target, 0), "bind wayland socket")
    }

    // MARK: - pivot_root

    private func pivot() throws {
        let oldRoot = Self.stage + "/.old-root"
        try FileManager.default.createDirectory(atPath: oldRoot, withIntermediateDirectories: true)
        try check(chdir(Self.stage), "chdir stage")
        try check(br_pivot_root(".", ".old-root"), "pivot_root")
        try check(chdir("/"), "chdir /")
        try check(br_detach("/.old-root"), "detach old root")
        try? FileManager.default.removeItem(atPath: "/.old-root")
    }

    // MARK: - Privileges

    private func dropPrivileges() throws {
        try check(br_set_no_new_privs(), "PR_SET_NO_NEW_PRIVS")
        try check(setgroups(0, nil), "setgroups")
        try check(setgid(container.uid), "setgid")
        try check(setuid(container.uid), "setuid")
        try check(br_drop_bounding_set(), "drop bounding set")
        // Verify the drop is irreversible.
        guard setuid(0) != 0 else {
            fatalError("privilege drop failed: setuid(0) succeeded")
        }
    }

    // MARK: - Environment & exec

    private func environmentAndExec(arguments: [String]) throws -> Never {
        clearenv()
        setenv("PATH", "/usr/bin:/bin", 1)
        setenv("HOME", "/data", 1)
        setenv("TMPDIR", "/tmp", 1)
        setenv("XDG_RUNTIME_DIR", "/tmp/run", 1)
        setenv(AppBundle.pathEnvironmentVariable, AppBundle.defaultMountPoint, 1)
        setenv("BUNDLE_ID", bundle.manifest.id, 1)
        if capabilities.contains(.display) {
            setenv("WAYLAND_DISPLAY", "wayland-0", 1)
        }

        // Paths are now container-relative: the bundle is /app.
        let inside = AppBundle(unchecked: AppBundle.defaultMountPoint, manifest: bundle.manifest)
        if let libraryPath = inside.libraryPath(for: selection.arch) {
            setenv("LD_LIBRARY_PATH", libraryPath, 1)
        }
        try check(chdir(inside.workingDirectory), "chdir /app")

        var argv: [String] = []
        if let translator = selection.translator {
            argv.append(translator.rawValue)
        }
        argv.append(inside.executablePath(for: selection.arch))
        argv.append(contentsOf: arguments)
        let cArgv: [UnsafeMutablePointer<CChar>?] = argv.map { strdup($0) } + [nil]
        execvp(argv[0], cArgv)
        throw SandboxError.syscall("exec \(argv[0])", errno)
    }

    private func check(_ result: Int32, _ operation: String) throws {
        guard result == 0 else {
            throw SandboxError.syscall(operation, errno)
        }
    }
}

#endif
