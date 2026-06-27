#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <stdarg.h>
#include <stdio.h>
#include <string.h>
#include <sys/mount.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/sysmacros.h>
#include <unistd.h>

#define LINUX_MOUNT "/mnt"
#define LINUX_RUNTIME "/mnt/kexec"

static int make_block_node_from_sysfs(const char *name);

static void logmsg(const char *fmt, ...)
{
    char buf[512];
    int fd;
    va_list ap;

    va_start(ap, fmt);
    vsnprintf(buf, sizeof(buf), fmt, ap);
    va_end(ap);

    fd = open("/dev/kmsg", O_WRONLY | O_CLOEXEC);
    if (fd >= 0) {
        dprintf(fd, "kexec-system-init: %s\n", buf);
        close(fd);
    }
}

static void mkdir_p(const char *path, mode_t mode)
{
    char tmp[256];
    char *p;

    snprintf(tmp, sizeof(tmp), "%s", path);
    for (p = tmp + 1; *p; p++) {
        if (*p == '/') {
            *p = '\0';
            mkdir(tmp, mode);
            *p = '/';
        }
    }
    mkdir(tmp, mode);
}

static int mount_one(const char *src, const char *target, const char *type,
                     unsigned long flags, const char *data)
{
    mkdir_p(target, 0755);
    if (mount(src, target, type, flags, data) == 0) {
        return 0;
    }
    if (errno == EBUSY) {
        return 0;
    }
    return -1;
}

static int mount_linux_runtime(void)
{
    const char *candidates[] = {
        "/dev/block/by-name/linux",
        "/dev/block/sdc88",
        NULL,
    };
    const char **p;

    mkdir_p(LINUX_MOUNT, 0755);
    for (p = candidates; *p; p++) {
        if (access(*p, F_OK) != 0) {
            continue;
        }
        logmsg("trying linux runtime from %s", *p);
        if (mount(*p, LINUX_MOUNT, "ext4", MS_NOSUID | MS_NODEV | MS_NOATIME, "") == 0 ||
            errno == EBUSY) {
            if (access(LINUX_RUNTIME "/busybox", X_OK) == 0 &&
                access(LINUX_RUNTIME "/kxsh.sh", R_OK) == 0) {
                logmsg("mounted linux runtime at " LINUX_RUNTIME);
                return 0;
            }
            logmsg("linux partition mounted, but " LINUX_RUNTIME " is incomplete");
            return -1;
        }
    }

    logmsg("failed to mount linux runtime: errno=%d", errno);
    return -1;
}

static void wait_for_runtime_nodes(void)
{
    int i;

    for (i = 0; i < 30; i++) {
        make_block_node_from_sysfs("sdc88");
        if (access("/dev/block/sdc88", F_OK) == 0 ||
            access("/dev/block/by-name/linux", F_OK) == 0) {
            return;
        }
        sleep(1);
    }
}

static int make_block_node_from_sysfs(const char *name)
{
    char sysfs[128];
    char devnode[128];
    char buf[64];
    int fd;
    unsigned int maj, min;
    ssize_t n;

    snprintf(devnode, sizeof(devnode), "/dev/block/%s", name);
    if (access(devnode, F_OK) == 0) {
        return 0;
    }

    snprintf(sysfs, sizeof(sysfs), "/sys/class/block/%s/dev", name);
    fd = open(sysfs, O_RDONLY | O_CLOEXEC);
    if (fd < 0) {
        return -1;
    }

    n = read(fd, buf, sizeof(buf) - 1);
    close(fd);
    if (n <= 0) {
        return -1;
    }
    buf[n] = '\0';

    if (sscanf(buf, "%u:%u", &maj, &min) != 2) {
        return -1;
    }

    mkdir_p("/dev/block", 0755);
    unlink(devnode);
    if (mknod(devnode, S_IFBLK | 0600, makedev(maj, min)) != 0) {
        logmsg("mknod %s failed: errno=%d", devnode, errno);
        return -1;
    }

    logmsg("created %s major=%u minor=%u", devnode, maj, min);
    return 0;
}

int main(void)
{
    char *linux_argv[] = { LINUX_RUNTIME "/busybox", "sh", LINUX_RUNTIME "/kxsh.sh", NULL };
    char *linux_envp[] = {
        "KEXEC_BASE=" LINUX_RUNTIME,
        "PATH=" LINUX_RUNTIME ":/system/bin:/vendor/bin",
        "HOME=" LINUX_RUNTIME "/root",
        NULL,
    };

    logmsg("entered static ramdisk kxsh");

    mount(NULL, "/", NULL, MS_REMOUNT, NULL);
    mount_one("proc", "/proc", "proc", 0, "");
    mount_one("sysfs", "/sys", "sysfs", 0, "");
    mount_one("devtmpfs", "/dev", "devtmpfs", 0, "mode=0755");
    mount_one("devpts", "/dev/pts", "devpts", 0, "mode=0620,ptmxmode=0666");
    mount_one("tmpfs", "/run", "tmpfs", 0, "mode=0755");
    mount_one("tmpfs", "/tmp", "tmpfs", 0, "mode=1777");
    mount_one("configfs", "/config", "configfs", 0, "");

    wait_for_runtime_nodes();
    if (mount_linux_runtime() == 0) {
        logmsg("exec " LINUX_RUNTIME "/busybox sh " LINUX_RUNTIME "/kxsh.sh");
        execve(linux_argv[0], linux_argv, linux_envp);
        logmsg("exec linux runtime failed: errno=%d", errno);
    }

    logmsg("no linux runtime available; halting in ramdisk bootstrap");

    for (;;) {
        sleep(3600);
    }
}
