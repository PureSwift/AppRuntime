//
//  CBundleRuntime.h
//  bundle-runtime
//
//  C shim for the pieces of the sandbox Swift cannot reach directly:
//  syscalls without glibc wrappers (pivot_root), variadic prctl, and
//  mount(2) flag constants.
//
//  All functions return 0 on success and -1 on failure with errno set.
//  On non-Linux platforms every function fails with ENOSYS.
//

#ifndef C_BUNDLE_RUNTIME_H
#define C_BUNDLE_RUNTIME_H

/// Unshare mount, UTS, IPC, PID, and cgroup namespaces;
/// additionally the network namespace when `new_network` is non-zero,
/// and a user namespace when `new_user` is non-zero (unprivileged launch).
int br_unshare_namespaces(int new_network, int new_user);

/// Inside a fresh user namespace: deny setgroups and write identity
/// uid/gid maps so the caller keeps its ids while holding full
/// capabilities over the namespace.
int br_map_identity(unsigned int uid, unsigned int gid);

/// Remount `/` recursively private so mounts don't propagate to the host.
int br_make_root_private(void);

/// Mount a tmpfs at `target`.
int br_mount_tmpfs(const char *target);

/// Bind-mount `source` onto `target`. Recursive; remounted read-only when
/// `read_only` is non-zero.
int br_bind_mount(const char *source, const char *target, int read_only);

/// Mount a fresh procfs at `target` (valid only after the PID namespace
/// has taken effect, i.e. in the forked child).
int br_mount_proc(const char *target);

/// pivot_root(2) into `new_root`, placing the old root at `put_old`
/// (a path inside `new_root`).
int br_pivot_root(const char *new_root, const char *put_old);

/// Lazily detach the old root mounted at `path` (umount2 MNT_DETACH).
int br_detach(const char *path);

/// prctl(PR_SET_NO_NEW_PRIVS, 1): irreversible; execve can never grant
/// privileges after this.
int br_set_no_new_privs(void);

/// Drop every capability from the bounding set
/// (prctl(PR_CAPBSET_DROP) for all supported capabilities).
int br_drop_bounding_set(void);

/// Install a seccomp BPF denylist blocking sandbox-escape and
/// kernel-attack-surface syscalls (mount, pivot_root, ptrace, bpf,
/// module loading, kexec, ...). Blocked syscalls fail with EPERM.
/// Requires PR_SET_NO_NEW_PRIVS to have been set.
int br_apply_seccomp(void);

#endif /* C_BUNDLE_RUNTIME_H */
