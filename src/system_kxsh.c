#define _GNU_SOURCE
#include <dirent.h>
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

#define LINUX_MOUNT "/kexec"
#define LINUX_RUNTIME "/kexec/lean"

static int make_block_node_from_sysfs(const char *name);
static void dump_dir_names(const char *label, const char *path, int max_entries);
static void dump_path_state(const char *label, const char *path);
static void dump_file_text(const char *label, const char *path);
static void dump_storage_probe_state(const char *tag);
static void try_bind_ufshcd_mtk(void);

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

static void dump_dir_names(const char *label, const char *path, int max_entries)
{
    DIR *dir;
    struct dirent *de;
    char buf[512];
    size_t len = 0;
    int count = 0;

    dir = opendir(path);
    if (!dir) {
        logmsg("%s: cannot open %s errno=%d", label, path, errno);
        return;
    }

    while ((de = readdir(dir)) != NULL) {
        int n;

        if (de->d_name[0] == '.')
            continue;
        n = snprintf(buf + len, sizeof(buf) - len, "%s%s",
                     len ? " " : "", de->d_name);
        if (n < 0 || (size_t)n >= sizeof(buf) - len) {
            break;
        }
        len += (size_t)n;
        count++;
        if (count >= max_entries)
            break;
    }
    closedir(dir);

    logmsg("%s: %s%s", label, len ? buf : "<empty>",
           count >= max_entries ? " ..." : "");
}

static void dump_path_state(const char *label, const char *path)
{
    struct stat st;

    if (lstat(path, &st) == 0) {
        logmsg("%s: exists mode=%o", label, st.st_mode);
        return;
    }
    logmsg("%s: missing %s errno=%d", label, path, errno);
}

static void dump_file_text(const char *label, const char *path)
{
    char buf[384];
    int fd;
    ssize_t n;

    fd = open(path, O_RDONLY | O_CLOEXEC);
    if (fd < 0) {
        logmsg("%s: cannot open %s errno=%d", label, path, errno);
        return;
    }
    n = read(fd, buf, sizeof(buf) - 1);
    close(fd);
    if (n <= 0) {
        logmsg("%s: read %s failed n=%zd errno=%d", label, path, n, errno);
        return;
    }
    buf[n] = '\0';
    for (char *p = buf; *p; p++) {
        if (*p == '\0')
            break;
        if (*p == '\n' || *p == '\r')
            *p = ' ';
    }
    logmsg("%s: %s", label, buf);
}

static int write_text_file(const char *path, const char *text)
{
    int fd;
    ssize_t len;
    ssize_t n;

    fd = open(path, O_WRONLY | O_CLOEXEC);
    if (fd < 0)
        return -1;
    len = (ssize_t)strlen(text);
    n = write(fd, text, (size_t)len);
    close(fd);
    if (n != len)
        return -1;
    return 0;
}

static void try_bind_ufshcd_mtk(void)
{
    static int tried;

    if (tried)
        return;
    if (access("/sys/bus/platform/drivers/ufshcd-mtk", F_OK) != 0)
        return;
    if (access("/sys/bus/platform/drivers/ufshcd-mtk/112b0000.ufshci", F_OK) == 0)
        return;

    tried = 1;
    errno = 0;
    if (write_text_file("/sys/bus/platform/drivers/ufshcd-mtk/bind",
                        "112b0000.ufshci") == 0) {
        logmsg("manual bind ufshcd-mtk -> 112b0000.ufshci ok");
    } else {
        logmsg("manual bind ufshcd-mtk -> 112b0000.ufshci failed errno=%d", errno);
    }
}

static void dump_storage_probe_state(const char *tag)
{
    char label[96];

    snprintf(label, sizeof(label), "%s platform devices", tag);
    dump_dir_names(label, "/sys/bus/platform/devices", 96);
    snprintf(label, sizeof(label), "%s platform drivers", tag);
    dump_dir_names(label, "/sys/bus/platform/drivers", 96);

    dump_path_state("ufshci bus device", "/sys/bus/platform/devices/112b0000.ufshci");
    dump_path_state("ufshci soc device", "/sys/devices/platform/soc/112b0000.ufshci");
    dump_path_state("ufs module", "/sys/module/ufs_mediatek_mod");
    dump_path_state("ufs phy module", "/sys/module/phy_mtk_ufs");
    dump_path_state("ufshcd-mtk driver", "/sys/bus/platform/drivers/ufshcd-mtk");
    dump_path_state("ufshcd-mtk bound device",
                    "/sys/bus/platform/drivers/ufshcd-mtk/112b0000.ufshci");
    dump_path_state("ufshci driver symlink",
                    "/sys/bus/platform/devices/112b0000.ufshci/driver");
    dump_dir_names("ufshcd-mtk driver dir",
                   "/sys/bus/platform/drivers/ufshcd-mtk", 32);
    dump_file_text("ufshci modalias",
                   "/sys/bus/platform/devices/112b0000.ufshci/modalias");
    dump_file_text("ufshci driver_override",
                   "/sys/bus/platform/devices/112b0000.ufshci/driver_override");
    dump_file_text("devices_deferred", "/sys/kernel/debug/devices_deferred");
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
            logmsg("linux runtime candidate missing: %s errno=%d", *p, errno);
            continue;
        }
        logmsg("trying linux runtime from %s", *p);
        if (mount(*p, LINUX_MOUNT, "ext4", MS_NOSUID | MS_NODEV | MS_NOATIME, "") == 0 ||
            errno == EBUSY) {
            if (access(LINUX_RUNTIME "/busybox", X_OK) == 0 &&
                access(LINUX_RUNTIME "/kxsh.sh", R_OK) == 0) {
                logmsg("mounted linux root at " LINUX_MOUNT ", lean runtime at " LINUX_RUNTIME);
                return 0;
            }
            logmsg("linux partition mounted, but lean runtime is incomplete at " LINUX_RUNTIME);
            return -1;
        }
        logmsg("mount linux runtime from %s failed errno=%d", *p, errno);
    }

    logmsg("failed to mount linux runtime: errno=%d", errno);
    return -1;
}

static void wait_for_runtime_nodes(void)
{
    int i;

    for (i = 0; i < 30; i++) {
        int made;

        made = make_block_node_from_sysfs("sdc88");
        if (access("/dev/block/sdc88", F_OK) == 0 ||
            access("/dev/block/by-name/linux", F_OK) == 0) {
            logmsg("runtime node ready after %ds: sdc88=%d by-name-linux=%d",
                   i,
                   access("/dev/block/sdc88", F_OK) == 0,
                   access("/dev/block/by-name/linux", F_OK) == 0);
            return;
        }
        if (i == 0 || i == 5 || i == 15 || i == 29) {
            logmsg("waiting runtime nodes t=%ds make_sdc88_rc=%d sdc88=%d by-name-linux=%d",
                   i, made,
                   access("/dev/block/sdc88", F_OK) == 0,
                   access("/dev/block/by-name/linux", F_OK) == 0);
            dump_dir_names("sys block", "/sys/class/block", 48);
            dump_dir_names("dev block", "/dev/block", 48);
            dump_dir_names("dev by-name", "/dev/block/by-name", 48);
            dump_dir_names("ufs hosts", "/sys/class/ufs", 16);
            dump_dir_names("scsi hosts", "/sys/class/scsi_host", 16);
            try_bind_ufshcd_mtk();
            dump_storage_probe_state("wait");
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

static int prepare_linux_runtime(void)
{
    logmsg("prepare linux runtime begin");

    mount(NULL, "/", NULL, MS_REMOUNT, NULL);
    mount_one("proc", "/proc", "proc", 0, "");
    mount_one("sysfs", "/sys", "sysfs", 0, "");
    mount_one("devtmpfs", "/dev", "devtmpfs", 0, "mode=0755");
    mount_one("devpts", "/dev/pts", "devpts", 0, "mode=0620,ptmxmode=0666");
    mount_one("tmpfs", "/run", "tmpfs", 0, "mode=0755");
    mount_one("tmpfs", "/tmp", "tmpfs", 0, "mode=1777");
    mount_one("configfs", "/config", "configfs", 0, "");
    mount_one("debugfs", "/sys/kernel/debug", "debugfs", 0, "");

    dump_dir_names("initial sys block", "/sys/class/block", 48);
    dump_dir_names("initial dev block", "/dev/block", 48);
    dump_dir_names("initial scsi hosts", "/sys/class/scsi_host", 16);
    dump_dir_names("initial ufs hosts", "/sys/class/ufs", 16);
    dump_storage_probe_state("initial");

    wait_for_runtime_nodes();
    if (mount_linux_runtime() == 0) {
        logmsg("prepare linux runtime ok");
        return 0;
    }

    logmsg("prepare linux runtime failed");
    return 1;
}

int main(int argc, char **argv)
{
    char *linux_argv[] = { LINUX_RUNTIME "/busybox", "sh", LINUX_RUNTIME "/kxsh.sh", NULL };
    char *linux_envp[] = {
        "KEXEC_BASE=" LINUX_RUNTIME,
        "PATH=" LINUX_RUNTIME ":/system/bin:/vendor/bin",
        "HOME=" LINUX_RUNTIME "/root",
        NULL,
    };

    logmsg("entered static ramdisk kxsh");

    if (argc > 1 && strcmp(argv[1], "--prepare") == 0) {
        return prepare_linux_runtime();
    }

    if (prepare_linux_runtime() == 0) {
        logmsg("exec " LINUX_RUNTIME "/busybox sh " LINUX_RUNTIME "/kxsh.sh");
        execve(linux_argv[0], linux_argv, linux_envp);
        logmsg("exec linux runtime failed: errno=%d", errno);
    }

    logmsg("no linux runtime available; halting in ramdisk bootstrap");

    for (;;) {
        sleep(3600);
    }
}
