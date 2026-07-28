//
//  ResourceLimits.swift
//  bundle-runtime
//
//  Per-app cgroup v2 resource limits.
//

#if os(Linux)

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

/// Memory, process, and CPU caps applied to an app before it starts.
///
/// Applied by creating a cgroup v2 group per app and moving the launcher
/// into it before fork, so the app and everything it spawns inherit it.
struct ResourceLimits {

    /// cgroup v2 mount point.
    static let root = "/sys/fs/cgroup"

    /// Parent group for app cgroups.
    static let parent = root + "/apps"

    /// Maximum memory in bytes; `nil` for no limit.
    var memoryBytes: Int?

    /// Maximum number of processes/threads; `nil` for no limit.
    var processes: Int?

    /// CPU bandwidth as (quota microseconds, period microseconds);
    /// `nil` for no limit. E.g. (50_000, 100_000) is half a core.
    var cpu: (quota: Int, period: Int)?

    /// Conservative defaults for an embedded device.
    static let `default` = ResourceLimits(
        memoryBytes: 512 * 1024 * 1024,
        processes: 512,
        cpu: nil
    )

    /// `true` when cgroup v2 is mounted and writable (requires root).
    static var isAvailable: Bool {
        FileManager.default.fileExists(atPath: root + "/cgroup.controllers")
            && geteuid() == 0
    }

    /// Create the app's cgroup, write the limits, and move this process
    /// into it. Best-effort: a missing controller is skipped rather than
    /// failing the launch.
    func apply(id: String) throws {
        let fileManager = FileManager.default
        // Delegate the controllers we need to the parent group.
        try? write("+memory +pids +cpu", to: Self.root + "/cgroup.subtree_control")
        try? fileManager.createDirectory(atPath: Self.parent, withIntermediateDirectories: true)
        try? write("+memory +pids +cpu", to: Self.parent + "/cgroup.subtree_control")

        let group = Self.parent + "/" + id
        try fileManager.createDirectory(atPath: group, withIntermediateDirectories: true)

        if let memoryBytes = memoryBytes {
            try? write("\(memoryBytes)", to: group + "/memory.max")
        }
        if let processes = processes {
            try? write("\(processes)", to: group + "/pids.max")
        }
        if let cpu = cpu {
            try? write("\(cpu.quota) \(cpu.period)", to: group + "/cpu.max")
        }

        // Join the group: children inherit membership across fork.
        try write("\(getpid())", to: group + "/cgroup.procs")
    }

    private func write(_ value: String, to path: String) throws {
        try Data(value.utf8).write(to: URL(fileURLWithPath: path))
    }
}

#endif
