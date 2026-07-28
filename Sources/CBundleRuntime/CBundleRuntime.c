//
//  CBundleRuntime.c
//  bundle-runtime
//

#include "include/CBundleRuntime.h"

#ifdef __linux__

#define _GNU_SOURCE
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

#endif /* __linux__ */
