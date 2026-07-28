# AppRuntime Sandbox

How `bundle-runtime` isolates an app, what an app can and cannot reach, and
which parts of the design are load-bearing for security.

Companion to [BundleFormat.md](BundleFormat.md), which specifies the bundle
format and the (unsandboxed) launch contract.

## 1. What the app sees

Inside the sandbox the filesystem is exactly:

| Path | Contents | Access |
|---|---|---|
| `/app` | The bundle | read-only |
| `/data` | The app's own container | read-write |
| `/tmp` | Private tmpfs (`XDG_RUNTIME_DIR` at `/tmp/run`, mode 0700) | read-write |
| `/usr` `/lib` `/lib64` `/bin` `/sbin` `/etc` | The OS | read-only |
| `/proc` | The app's own PID namespace | — |
| `/dev` | tmpfs: `null zero full random urandom tty`, plus capability-gated nodes | — |

Nothing else on the host is reachable: the old root is detached after
`pivot_root`, so there is no path back out of the new root.

## 2. Launch modes

| | Privileged | User namespace |
|---|---|---|
| Trigger | launcher runs as root | launcher runs as any user |
| Privilege source | real `CAP_SYS_ADMIN` | `CLONE_NEWUSER` grants capabilities over the namespace |
| App uid | per-app uid (20000+) | the invoking user |
| Container | `/data/containers/<id>` | `~/.local/share/bundle-runtime/containers/<id>` |
| Device gating | kernel-enforced per app | limited to what the invoking user can already open |
| Intended for | the appliance OS | development, desktop Linux |

Both modes run the *same* mount, `pivot_root`, and privilege-drop sequence.
If user namespaces are unavailable (kernel without `CONFIG_USER_NS`), the
launcher warns and execs unsandboxed — acceptable for development, never for
the shipping OS.

## 3. Launch sequence

1. **Resource limits** (privileged only) — create `/sys/fs/cgroup/apps/<id>`,
   write `memory.max` / `pids.max` / optional `cpu.max`, and join the group
   *before* fork so the app and its descendants inherit the caps.
2. **Container** — create the app's data directory; in privileged mode chown
   it to the app's uid.
3. **Unshare** — mount, UTS, IPC, PID, and cgroup namespaces; **network too
   unless the app declares the `Network` capability**; user namespace in
   unprivileged mode (then write identity uid/gid maps, `setgroups` denied
   first as the kernel requires).
4. **Fork** — a PID namespace only applies to children, so the child becomes
   PID 1 and the parent supervises. The parent immediately drops to the app
   uid and sets `no_new_privs`: no root process remains for the app's
   lifetime. It forwards the exit status, mapping death-by-signal to `128+n`.
5. **Build root** — mark `/` recursively private (so nothing propagates to the
   host), tmpfs at the stage, bind the OS directories read-only (merged-usr
   symlinks are recreated, not bound), bind the bundle at `/app` read-only and
   the container at `/data`, mount private `/tmp` and a fresh `/proc`.
6. **Devices** — tmpfs `/dev` with only the base nodes, plus `/dev/dri` and
   `/dev/input` for `Display`, `/dev/snd` for `Audio`.
7. **Services** — bind the Wayland socket into `/tmp/run` for `Display`.
8. **pivot_root** into the stage; detach the old root (`MNT_DETACH`).
9. **Drop privileges** — `PR_SET_NO_NEW_PRIVS`; `setgroups(0)`, `setgid`,
   `setuid` to the app uid; empty the capability bounding set; **verify** the
   drop by asserting `setuid(0)` now fails.
10. **Seccomp** — install the BPF denylist (§5), last so it covers the app and
    anything it execs.
11. **Environment** — `clearenv`, then set `PATH`, `HOME=/data`, `TMPDIR`,
    `XDG_RUNTIME_DIR`, `BUNDLE_PATH=/app`, `BUNDLE_ID`, `LD_LIBRARY_PATH`
    (when the bundle ships private libraries), and `WAYLAND_DISPLAY` for
    `Display`.
12. **chdir `/app`** and exec, translator-prefixed when the architecture
    selection chose one.

## 4. Capabilities

Manifest capabilities are enforced, not advisory:

| Capability | Effect when present | Effect when absent |
|---|---|---|
| `Network` | shares the host network namespace | `CLONE_NEWNET`: no interfaces at all |
| `Display` | `/dev/dri`, `/dev/input`, Wayland socket, `WAYLAND_DISPLAY` | none of those exist |
| `Audio` | `/dev/snd` | no sound devices |
| `Bluetooth`, `NFC` | reserved — no enforcement yet | — |

## 5. Seccomp filter

A BPF denylist returning `EPERM`, installed after `no_new_privs` and the uid
drop. It blocks sandbox-escape and kernel-attack-surface calls: `mount`,
`umount2`, `pivot_root`, `chroot`, `setns`, `unshare`, `ptrace`,
`process_vm_readv`/`writev`, `bpf`, `perf_event_open`, `userfaultfd`,
`init_module`/`finit_module`/`delete_module`, `kexec_load`/`kexec_file_load`,
`open_by_handle_at`, `add_key`/`request_key`/`keyctl`, `acct`, `reboot`,
`swapon`/`swapoff`, `settimeofday`, `clock_settime`, `quotactl`.

Each entry is `#ifdef`-guarded on its `__NR_*`, so an architecture lacking a
syscall simply omits it. The filter first checks `seccomp_data.arch` and
**kills** the process on mismatch, rather than risking syscall-number aliasing
under a different personality.

## 6. Why these choices

- **`pivot_root`, not `chroot`** — `chroot` is escapable by a process holding
  a directory fd; `pivot_root` plus detaching the old root leaves no route out.
- **Persistent uid map, not a hash** — the original design hashed the bundle id
  into 10,000 uid slots. By the birthday bound that collides ~50 % of the time
  at ~118 apps, and two apps sharing a uid can read each other's containers.
  `/data/containers/.uid-map.json` assigns each id a distinct uid permanently.
- **Deny-network by default** — absence of a capability must mean absence of
  access, so no `Network` yields an empty network namespace rather than a
  filtered one.
- **Verified privilege drop** — `setuid` can fail silently in edge cases;
  asserting `setuid(0)` fails turns a silent security hole into a crash.
- **Seccomp last** — it must not block the mount work the sandbox itself does,
  and installing it after `no_new_privs` lets an unprivileged process apply it.
- **Supervisor drops privileges** — the parent only waits; leaving it as root
  for the app's lifetime would be needless attack surface.

## 7. Limitations

- **Not verified on hardware.** The security properties are compiled and
  logic-tested but await on-target confirmation (see §8).
- **Unprivileged mode is weaker.** Apps share the invoking user's uid, so
  per-app data isolation is by directory, not ownership; device access is
  whatever that user already has. Distinct host uids per app would need
  `newuidmap`/`newgidmap` with a `/etc/subuid` range.
- **No bundle integrity checking.** Nothing verifies a bundle before launch;
  a signature or hash check belongs between resolve and parse.
- **`Bluetooth` and `NFC` are unenforced**, and audio has no sound-server
  socket path (only raw `/dev/snd`).
- **No seccomp in the unprivileged fallback path** when user namespaces are
  missing entirely — that path has no isolation by definition.

## 8. Verifying on hardware

```sh
# The app sees only the sandbox root
bundle-runtime com.example.app -- ls /            # app, data, tmp, usr, proc, dev...

# Privilege drop is irreversible
id -u                                             # 20000+, not 0

# No network without the capability
ip link                                           # only lo, or nothing

# Seccomp denies escapes
mount -t tmpfs none /mnt                          # EPERM

# Resource caps are live
cat /sys/fs/cgroup/apps/<id>/memory.max
```

Kernel requirements: `CONFIG_USER_NS` (unprivileged mode), `CONFIG_SECCOMP_FILTER`,
cgroup v2 mounted at `/sys/fs/cgroup`, and `squashfuse` in the rootfs for
unprivileged mounting of self-executing images.

## 9. Reference implementation

- Namespace/mount/`pivot_root`/privilege/seccomp shim: `Sources/CBundleRuntime/`
- Sandbox sequence: `Sources/BundleRuntime/Sandbox.swift`
- Containers and the uid map: `Sources/BundleRuntime/Container.swift`
- cgroup limits: `Sources/BundleRuntime/ResourceLimits.swift`
- Mode selection and fallbacks: `Sources/BundleRuntime/main.swift`
