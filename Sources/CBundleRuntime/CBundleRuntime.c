//
//  CBundleRuntime.c
//  bundle-runtime
//

// Must precede every include: unlocks unshare(2), pivot_root, CLONE_NEW*.
#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif

#include "include/CBundleRuntime.h"

#ifdef __linux__

#include <errno.h>
#include <fcntl.h>
#include <sched.h>
#include <stdio.h>
#include <string.h>
#include <sys/mount.h>
#include <sys/prctl.h>
#include <sys/syscall.h>
#include <unistd.h>

int br_unshare_namespaces(int new_network, int new_user) {
    int flags = CLONE_NEWNS | CLONE_NEWUTS | CLONE_NEWIPC | CLONE_NEWPID | CLONE_NEWCGROUP;
    if (new_network) {
        flags |= CLONE_NEWNET;
    }
    if (new_user) {
        flags |= CLONE_NEWUSER;
    }
    return unshare(flags);
}

static int br_write_file(const char *path, const char *content) {
    int fd = open(path, O_WRONLY);
    if (fd < 0) {
        return -1;
    }
    ssize_t length = (ssize_t)strlen(content);
    ssize_t written = write(fd, content, (size_t)length);
    int saved = errno;
    close(fd);
    errno = saved;
    return written == length ? 0 : -1;
}

int br_map_identity(unsigned int uid, unsigned int gid) {
    char map[64];
    // Order is mandated by the kernel: setgroups must be denied before
    // an unprivileged process may write gid_map.
    if (br_write_file("/proc/self/setgroups", "deny") != 0) {
        return -1;
    }
    snprintf(map, sizeof(map), "%u %u 1", gid, gid);
    if (br_write_file("/proc/self/gid_map", map) != 0) {
        return -1;
    }
    snprintf(map, sizeof(map), "%u %u 1", uid, uid);
    return br_write_file("/proc/self/uid_map", map);
}

int br_make_root_private(void) {
    return mount(NULL, "/", NULL, MS_REC | MS_PRIVATE, NULL);
}

int br_mount_tmpfs(const char *target) {
    return mount("tmpfs", target, "tmpfs", MS_NOSUID | MS_NODEV, "mode=0755");
}

int br_bind_mount(const char *source, const char *target, int read_only) {
    if (mount(source, target, NULL, MS_BIND | MS_REC, NULL) != 0) {
        return -1;
    }
    if (read_only) {
        // Read-only requires a remount of the bind.
        return mount(NULL, target, NULL,
                     MS_BIND | MS_REC | MS_REMOUNT | MS_RDONLY | MS_NOSUID, NULL);
    }
    return 0;
}

int br_mount_proc(const char *target) {
    return mount("proc", target, "proc", MS_NOSUID | MS_NODEV | MS_NOEXEC, NULL);
}

int br_pivot_root(const char *new_root, const char *put_old) {
    return (int)syscall(SYS_pivot_root, new_root, put_old);
}

int br_detach(const char *path) {
    return umount2(path, MNT_DETACH);
}

int br_set_no_new_privs(void) {
    return prctl(PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0);
}

int br_drop_bounding_set(void) {
    for (int cap = 0; ; cap++) {
        if (prctl(PR_CAPBSET_DROP, cap, 0, 0, 0) != 0) {
            // EINVAL past the last supported capability: done.
            if (errno == EINVAL) {
                return 0;
            }
            return -1;
        }
    }
}

#include <linux/audit.h>
#include <linux/filter.h>
#include <linux/seccomp.h>
#include <stddef.h>

#if defined(__aarch64__)
#define BR_AUDIT_ARCH AUDIT_ARCH_AARCH64
#elif defined(__x86_64__)
#define BR_AUDIT_ARCH AUDIT_ARCH_X86_64
#elif defined(__arm__)
#define BR_AUDIT_ARCH AUDIT_ARCH_ARM
#elif defined(__i386__)
#define BR_AUDIT_ARCH AUDIT_ARCH_I386
#else
#error "unsupported architecture for seccomp"
#endif

/// Syscalls denied inside the sandbox. Guarded per-arch: a syscall that
/// does not exist on this architecture is simply not filtered.
static const int br_denied_syscalls[] = {
#ifdef __NR_mount
    __NR_mount,
#endif
#ifdef __NR_umount2
    __NR_umount2,
#endif
#ifdef __NR_pivot_root
    __NR_pivot_root,
#endif
#ifdef __NR_chroot
    __NR_chroot,
#endif
#ifdef __NR_setns
    __NR_setns,
#endif
#ifdef __NR_unshare
    __NR_unshare,
#endif
#ifdef __NR_ptrace
    __NR_ptrace,
#endif
#ifdef __NR_process_vm_readv
    __NR_process_vm_readv,
#endif
#ifdef __NR_process_vm_writev
    __NR_process_vm_writev,
#endif
#ifdef __NR_perf_event_open
    __NR_perf_event_open,
#endif
#ifdef __NR_bpf
    __NR_bpf,
#endif
#ifdef __NR_userfaultfd
    __NR_userfaultfd,
#endif
#ifdef __NR_init_module
    __NR_init_module,
#endif
#ifdef __NR_finit_module
    __NR_finit_module,
#endif
#ifdef __NR_delete_module
    __NR_delete_module,
#endif
#ifdef __NR_kexec_load
    __NR_kexec_load,
#endif
#ifdef __NR_kexec_file_load
    __NR_kexec_file_load,
#endif
#ifdef __NR_open_by_handle_at
    __NR_open_by_handle_at,
#endif
#ifdef __NR_add_key
    __NR_add_key,
#endif
#ifdef __NR_request_key
    __NR_request_key,
#endif
#ifdef __NR_keyctl
    __NR_keyctl,
#endif
#ifdef __NR_acct
    __NR_acct,
#endif
#ifdef __NR_reboot
    __NR_reboot,
#endif
#ifdef __NR_swapon
    __NR_swapon,
#endif
#ifdef __NR_swapoff
    __NR_swapoff,
#endif
#ifdef __NR_settimeofday
    __NR_settimeofday,
#endif
#ifdef __NR_clock_settime
    __NR_clock_settime,
#endif
#ifdef __NR_quotactl
    __NR_quotactl,
#endif
};

#define BR_DENIED_COUNT (sizeof(br_denied_syscalls) / sizeof(br_denied_syscalls[0]))

int br_apply_seccomp(void) {
    // Program: check arch, load syscall nr, one EQ jump per denied
    // syscall to the shared EPERM return, else allow.
    //
    // Layout: [0] arch load, [1] arch check, [2] nr load,
    //         [3 .. 3+N-1] denies, [3+N] allow, [4+N] eperm.
    // 4 prologue + N denies + allow + eperm.
    struct sock_filter filter[BR_DENIED_COUNT + 6];
    unsigned int index = 0;

    filter[index++] = (struct sock_filter)BPF_STMT(
        BPF_LD | BPF_W | BPF_ABS, offsetof(struct seccomp_data, arch));
    // Wrong architecture (e.g. 32-bit personality on a 64-bit kernel):
    // kill rather than risk syscall-number aliasing.
    filter[index++] = (struct sock_filter)BPF_JUMP(
        BPF_JMP | BPF_JEQ | BPF_K, BR_AUDIT_ARCH, 1, 0);
    filter[index++] = (struct sock_filter)BPF_STMT(
        BPF_RET | BPF_K, SECCOMP_RET_KILL_PROCESS);
    filter[index++] = (struct sock_filter)BPF_STMT(
        BPF_LD | BPF_W | BPF_ABS, offsetof(struct seccomp_data, nr));
    for (unsigned int i = 0; i < BR_DENIED_COUNT; i++) {
        // Jump to the EPERM return (the last instruction) on match.
        unsigned int remaining = BR_DENIED_COUNT - 1 - i;
        filter[index++] = (struct sock_filter)BPF_JUMP(
            BPF_JMP | BPF_JEQ | BPF_K, (unsigned int)br_denied_syscalls[i],
            (unsigned char)(remaining + 1), 0);
    }
    filter[index++] = (struct sock_filter)BPF_STMT(
        BPF_RET | BPF_K, SECCOMP_RET_ALLOW);
    filter[index++] = (struct sock_filter)BPF_STMT(
        BPF_RET | BPF_K, SECCOMP_RET_ERRNO | (EPERM & SECCOMP_RET_DATA));

    struct sock_fprog prog = {
        .len = (unsigned short)index,
        .filter = filter,
    };
    return prctl(PR_SET_SECCOMP, SECCOMP_MODE_FILTER, &prog, 0, 0);
}

#else /* !__linux__ */

#include <errno.h>

static int br_unsupported(void) {
    errno = ENOSYS;
    return -1;
}

int br_unshare_namespaces(int new_network, int new_user) {
    (void)new_network; (void)new_user; return br_unsupported();
}
int br_map_identity(unsigned int uid, unsigned int gid) {
    (void)uid; (void)gid; return br_unsupported();
}
int br_make_root_private(void) { return br_unsupported(); }
int br_mount_tmpfs(const char *target) { (void)target; return br_unsupported(); }
int br_bind_mount(const char *source, const char *target, int read_only) {
    (void)source; (void)target; (void)read_only; return br_unsupported();
}
int br_mount_proc(const char *target) { (void)target; return br_unsupported(); }
int br_pivot_root(const char *new_root, const char *put_old) {
    (void)new_root; (void)put_old; return br_unsupported();
}
int br_detach(const char *path) { (void)path; return br_unsupported(); }
int br_set_no_new_privs(void) { return br_unsupported(); }
int br_drop_bounding_set(void) { return br_unsupported(); }
int br_apply_seccomp(void) { return br_unsupported(); }

#endif /* __linux__ */
