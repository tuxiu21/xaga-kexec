#define _GNU_SOURCE
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mount.h>
#include <sys/stat.h>
#include <sys/sysmacros.h>
#include <sys/ioctl.h>
#include <sys/wait.h>
#include <linux/watchdog.h>
#include <unistd.h>

#ifndef MS_MOVE
#define MS_MOVE 8192
#endif

#define NEWROOT "/kexec"
#define LOG_FILE NEWROOT "/var/log/kexec-runtime/boot-rootfs.log"
#define SYSTEMD_INIT "/sbin/init"

static int early_watchdog_fd = -1;

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

static void vlogmsg(const char *fmt, va_list ap)
{
    char msg[512];
    int fd;

    vsnprintf(msg, sizeof(msg), fmt, ap);
    fd = open("/dev/kmsg", O_WRONLY | O_CLOEXEC);
    if (fd >= 0) {
        dprintf(fd, "boot-ubuntu-rootfs: %s\n", msg);
        close(fd);
    }
    fd = open(LOG_FILE, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0644);
    if (fd >= 0) {
        dprintf(fd, "boot-ubuntu-rootfs: %s\n", msg);
        close(fd);
    }
}

static void logmsg(const char *fmt, ...)
{
    va_list ap;

    va_start(ap, fmt);
    vlogmsg(fmt, ap);
    va_end(ap);
}

static void panic_now(void)
{
    int fd;

    sync();
    fd = open("/proc/sys/kernel/sysrq", O_WRONLY | O_CLOEXEC);
    if (fd >= 0) {
        if (write(fd, "1\n", 2) < 0) {
        }
        close(fd);
    }
    fd = open("/proc/sysrq-trigger", O_WRONLY | O_CLOEXEC);
    if (fd >= 0) {
        if (write(fd, "c\n", 2) < 0) {
        }
        close(fd);
    }
    for (;;)
        sleep(60);
}

static void early_timeout(int signo)
{
    (void)signo;
    panic_now();
}

static void start_early_safety(void)
{
    const char *devices[] = { "/dev/watchdog0", "/dev/watchdog", NULL };
    const char **p;
    int timeout = 30;

    signal(SIGALRM, early_timeout);
    alarm(300);
    for (p = devices; *p; p++) {
        early_watchdog_fd = open(*p, O_WRONLY);
        if (early_watchdog_fd >= 0) {
            ioctl(early_watchdog_fd, WDIOC_SETTIMEOUT, &timeout);
            if (write(early_watchdog_fd, "\0", 1) < 0)
                logmsg("warning: initial early watchdog kick failed errno=%d", errno);
            logmsg("early watchdog armed dev=%s requested_timeout=%ds", *p, timeout);
            return;
        }
    }
    logmsg("warning: no early hardware watchdog; 300s panic alarm remains armed");
}

static void kick_early_watchdog(void)
{
    if (early_watchdog_fd >= 0 && write(early_watchdog_fd, "\0", 1) < 0)
        logmsg("warning: early watchdog kick failed errno=%d", errno);
}

static void die(const char *fmt, ...)
{
    va_list ap;

    va_start(ap, fmt);
    vlogmsg(fmt, ap);
    va_end(ap);
    panic_now();
}

static int mount_if_needed(const char *src, const char *target, const char *type,
                           unsigned long flags, const char *data)
{
    mkdir_p(target, 0755);
    if (mount(src, target, type, flags, data) == 0)
        return 0;
    if (errno == EBUSY)
        return 0;
    return -1;
}

static void move_mount_if_present(const char *src, const char *dst)
{
    mkdir_p(dst, 0755);
    if (mount(src, dst, NULL, MS_MOVE, NULL) != 0) {
        if (errno != EINVAL && errno != ENOENT)
            logmsg("warning: move %s -> %s failed errno=%d", src, dst, errno);
    }
}

static int read_major_minor(const char *path, int *major_no, int *minor_no)
{
    char buf[64];
    char *colon;
    int fd;
    ssize_t n;

    fd = open(path, O_RDONLY | O_CLOEXEC);
    if (fd < 0)
        return -1;
    n = read(fd, buf, sizeof(buf) - 1);
    close(fd);
    if (n <= 0)
        return -1;
    buf[n] = '\0';
    colon = strchr(buf, ':');
    if (!colon)
        return -1;
    *colon = '\0';
    *major_no = atoi(buf);
    *minor_no = atoi(colon + 1);
    if (*major_no < 0 || *minor_no < 0)
        return -1;
    return 0;
}

static void mknod_char_if_missing(const char *path, mode_t mode,
                                  int major_no, int minor_no, int *created)
{
    struct stat st;

    if (lstat(path, &st) == 0)
        return;
    if (mknod(path, S_IFCHR | mode, makedev(major_no, minor_no)) == 0) {
        (*created)++;
        return;
    }
    if (errno != EEXIST)
        logmsg("warning: mknod %s failed errno=%d", path, errno);
}

static void ensure_misc_node(const char *class_name, const char *name,
                             const char *path, mode_t mode, int *created)
{
    char dev_attr[256];
    int major_no;
    int minor_no;

    snprintf(dev_attr, sizeof(dev_attr), "/sys/class/%s/%s/dev", class_name, name);
    if (read_major_minor(dev_attr, &major_no, &minor_no) != 0)
        return;
    mknod_char_if_missing(path, mode, major_no, minor_no, created);
}

static int wanted_top_block_link(const char *name)
{
    if (strncmp(name, "sd", 2) == 0)
        return 1;
    if (strncmp(name, "dm-", 3) == 0)
        return 1;
    if (strncmp(name, "loop", 4) == 0)
        return 1;
    if (strncmp(name, "ram", 3) == 0)
        return 1;
    return 0;
}

static void ensure_top_block_links(int *created)
{
    DIR *dir;
    struct dirent *de;

    dir = opendir("/dev/block");
    if (!dir)
        return;
    while ((de = readdir(dir)) != NULL) {
        char dst[256];
        char target[256];
        struct stat st;

        if (de->d_name[0] == '.' || !wanted_top_block_link(de->d_name))
            continue;
        if (snprintf(dst, sizeof(dst), "/dev/%s", de->d_name) >= (int)sizeof(dst))
            continue;
        if (lstat(dst, &st) == 0)
            continue;
        if (snprintf(target, sizeof(target), "block/%s", de->d_name) >=
            (int)sizeof(target))
            continue;
        if (symlink(target, dst) == 0) {
            (*created)++;
        } else if (errno != EEXIST) {
            logmsg("warning: symlink %s -> %s failed errno=%d", dst, target, errno);
        }
    }
    closedir(dir);
}

static void prepare_dev_nodes(void)
{
    int created = 0;

    mkdir_p("/dev", 0755);
    mkdir_p("/dev/net", 0755);
    mknod_char_if_missing("/dev/null", 0666, 1, 3, &created);
    mknod_char_if_missing("/dev/zero", 0666, 1, 5, &created);
    mknod_char_if_missing("/dev/full", 0666, 1, 7, &created);
    mknod_char_if_missing("/dev/random", 0666, 1, 8, &created);
    mknod_char_if_missing("/dev/urandom", 0666, 1, 9, &created);
    mknod_char_if_missing("/dev/tty", 0666, 5, 0, &created);
    mknod_char_if_missing("/dev/console", 0600, 5, 1, &created);

    ensure_misc_node("rfkill", "rfkill", "/dev/rfkill", 0664, &created);
    ensure_misc_node("misc", "tun", "/dev/net/tun", 0666, &created);
    ensure_misc_node("misc", "fuse", "/dev/fuse", 0666, &created);
    ensure_misc_node("misc", "loop-control", "/dev/loop-control", 0660, &created);
    ensure_top_block_links(&created);
    logmsg("prepared /dev nodes created=%d", created);
}

static int parse_pid(const char *name, pid_t *pid)
{
    long val = 0;
    const char *p;

    for (p = name; *p; p++) {
        if (*p < '0' || *p > '9')
            return -1;
        val = val * 10 + (*p - '0');
        if (val > 4194304)
            return -1;
    }
    if (val <= 0)
        return -1;
    *pid = (pid_t)val;
    return 0;
}

static int process_has_cmdline(pid_t pid)
{
    char path[64];
    char buf[1];
    int fd;
    ssize_t n;

    snprintf(path, sizeof(path), "/proc/%d/cmdline", pid);
    fd = open(path, O_RDONLY | O_CLOEXEC);
    if (fd < 0)
        return 0;
    n = read(fd, buf, sizeof(buf));
    close(fd);
    return n > 0;
}

static void signal_other_processes(int sig, int *sent, int *failed)
{
    DIR *dir;
    struct dirent *de;
    pid_t self = getpid();
    pid_t pid;

    dir = opendir("/proc");
    if (!dir)
        return;
    while ((de = readdir(dir)) != NULL) {
        if (parse_pid(de->d_name, &pid) != 0 || pid == self)
            continue;
        if (!process_has_cmdline(pid))
            continue;
        if (kill(pid, sig) == 0)
            (*sent)++;
        else if (errno != ESRCH)
            (*failed)++;
    }
    closedir(dir);
}

static void clean_bootstrap_processes(void)
{
    int sent = 0, failed = 0;

    logmsg("cleaning bootstrap userspace before rootfs handoff");
    signal_other_processes(SIGTERM, &sent, &failed);
    logmsg("sent SIGTERM to %d processes (%d failed)", sent, failed);
    sleep(1);
    while (waitpid(-1, NULL, WNOHANG) > 0)
        ;
    sent = 0;
    failed = 0;
    signal_other_processes(SIGKILL, &sent, &failed);
    logmsg("sent SIGKILL to %d remaining processes (%d failed)", sent, failed);
    sleep(1);
}

int main(void)
{
    const char *init_path = SYSTEMD_INIT;
    char *systemd_argv[] = { SYSTEMD_INIT, NULL };
    char **argv = systemd_argv;
    char *envp[] = {
        "HOME=/root",
        "TERM=linux",
        "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
        NULL,
    };

    logmsg("begin direct rootfs newroot=%s init=%s", NEWROOT, SYSTEMD_INIT);
    mount_if_needed("proc", "/proc", "proc", 0, "");
    mount_if_needed("sysfs", "/sys", "sysfs", 0, "");
    mount_if_needed("devtmpfs", "/dev", "devtmpfs", 0, "mode=0755");
    mount_if_needed("devpts", "/dev/pts", "devpts", 0, "mode=0620,ptmxmode=0666");
    mount_if_needed("configfs", "/config", "configfs", 0, "");
    prepare_dev_nodes();
    start_early_safety();

    if (access(NEWROOT "/bin/sh", X_OK) != 0)
        die("missing Ubuntu shell at " NEWROOT "/bin/sh errno=%d", errno);
    if (access(NEWROOT "/etc/os-release", R_OK) != 0)
        die("missing Ubuntu os-release errno=%d", errno);
    if (access(NEWROOT SYSTEMD_INIT, X_OK) != 0)
        die("default systemd boot missing " SYSTEMD_INIT " errno=%d", errno);
    logmsg("default systemd boot; will exec " SYSTEMD_INIT);

    mkdir_p(NEWROOT "/proc", 0755);
    mkdir_p(NEWROOT "/sys", 0755);
    mkdir_p(NEWROOT "/dev", 0755);
    mkdir_p(NEWROOT "/dev/pts", 0755);
    mkdir_p(NEWROOT "/run", 0755);
    mkdir_p(NEWROOT "/data", 0755);
    mkdir_p(NEWROOT "/config", 0755);
    mkdir_p(NEWROOT "/sys/fs/cgroup", 0755);

    mount_if_needed("tmpfs", NEWROOT "/run", "tmpfs", 0, "mode=0755");
    mount_if_needed("none", "/sys/fs/cgroup", "cgroup2", 0, "");

    clean_bootstrap_processes();
    kick_early_watchdog();

    logmsg("moving mounts and switching root");
    move_mount_if_present("/sys", NEWROOT "/sys");
    move_mount_if_present("/data", NEWROOT "/data");
    move_mount_if_present("/dev", NEWROOT "/dev");
    move_mount_if_present("/config", NEWROOT "/config");
    move_mount_if_present("/proc", NEWROOT "/proc");

    if (chdir(NEWROOT) != 0)
        die("chdir newroot failed errno=%d", errno);
    if (mount(".", "/", NULL, MS_MOVE, NULL) != 0)
        die("MS_MOVE newroot to / failed errno=%d", errno);
    if (chroot(".") != 0)
        die("chroot failed errno=%d", errno);
    if (chdir("/") != 0)
        die("chdir / failed errno=%d", errno);

    kick_early_watchdog();
    alarm(0);
    /*
     * Do not magic-close the hardware watchdog. Closing here leaves the
     * countdown armed across exec; kexec-watchdog.service takes ownership
     * during early multi-user startup.
     */
    if (early_watchdog_fd >= 0)
        close(early_watchdog_fd);
    execve(init_path, argv, envp);
    die("exec %s failed errno=%d", init_path, errno);
}
