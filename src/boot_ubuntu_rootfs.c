#define _GNU_SOURCE
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdarg.h>
#include <stdio.h>
#include <string.h>
#include <sys/mount.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <unistd.h>

#ifndef MS_MOVE
#define MS_MOVE 8192
#endif

#define NEWROOT "/kexec"
#define LEAN "/kexec/lean"
#define LOG_FILE LEAN "/boot_ubuntu_rootfs.log"
#define INIT_SRC LEAN "/ubuntu_phase_a_init.sh"
#define SWITCH_INIT "/phase_a_init"
#define SYSTEMD_FLAG LEAN "/boot_systemd.once"
#define SYSTEMD_INIT "/sbin/init"

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

static void die(const char *fmt, ...)
{
    va_list ap;

    va_start(ap, fmt);
    vlogmsg(fmt, ap);
    va_end(ap);
    panic_now();
}

static int copy_file(const char *src, const char *dst, mode_t mode)
{
    char buf[65536];
    int in, out;
    ssize_t n;

    in = open(src, O_RDONLY | O_CLOEXEC);
    if (in < 0)
        return -1;
    out = open(dst, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, mode);
    if (out < 0) {
        close(in);
        return -1;
    }
    while ((n = read(in, buf, sizeof(buf))) > 0) {
        char *p = buf;
        ssize_t left = n;
        while (left > 0) {
            ssize_t w = write(out, p, left);
            if (w <= 0) {
                close(in);
                close(out);
                return -1;
            }
            p += w;
            left -= w;
        }
    }
    close(in);
    if (fsync(out) != 0) {
        close(out);
        return -1;
    }
    close(out);
    chmod(dst, mode);
    return n == 0 ? 0 : -1;
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

static void clean_lean_processes(void)
{
    int sent = 0, failed = 0;

    logmsg("cleaning lean userspace before rootfs handoff");
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
    char new_init[256];
    const char *init_path = SWITCH_INIT;
    char *phase_a_argv[] = { SWITCH_INIT, NULL };
    char *systemd_argv[] = { SYSTEMD_INIT, NULL };
    char **argv = phase_a_argv;
    char *envp[] = {
        "HOME=/root",
        "TERM=linux",
        "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
        NULL,
    };

    logmsg("begin direct rootfs newroot=%s init=%s", NEWROOT, INIT_SRC);
    mount_if_needed("proc", "/proc", "proc", 0, "");
    mount_if_needed("sysfs", "/sys", "sysfs", 0, "");
    mount_if_needed("devtmpfs", "/dev", "devtmpfs", 0, "mode=0755");
    mount_if_needed("devpts", "/dev/pts", "devpts", 0, "mode=0620,ptmxmode=0666");
    mount_if_needed("configfs", "/config", "configfs", 0, "");

    if (access(NEWROOT "/bin/sh", X_OK) != 0)
        die("missing Ubuntu shell at " NEWROOT "/bin/sh errno=%d", errno);
    if (access(NEWROOT "/etc/os-release", R_OK) != 0)
        die("missing Ubuntu os-release errno=%d", errno);
    if (access(INIT_SRC, X_OK) != 0)
        die("missing init %s errno=%d", INIT_SRC, errno);
    if (access(SYSTEMD_FLAG, F_OK) == 0) {
        if (access(NEWROOT SYSTEMD_INIT, X_OK) != 0)
            die("systemd flag present but missing " SYSTEMD_INIT " errno=%d", errno);
        init_path = SYSTEMD_INIT;
        argv = systemd_argv;
        logmsg("systemd boot flag present; will exec " SYSTEMD_INIT);
        unlink(SYSTEMD_FLAG);
    }

    mkdir_p(NEWROOT "/proc", 0755);
    mkdir_p(NEWROOT "/sys", 0755);
    mkdir_p(NEWROOT "/dev", 0755);
    mkdir_p(NEWROOT "/dev/pts", 0755);
    mkdir_p(NEWROOT "/run", 0755);
    mkdir_p(NEWROOT "/data", 0755);
    mkdir_p(NEWROOT "/config", 0755);
    mkdir_p(NEWROOT "/sys/fs/cgroup", 0755);

    snprintf(new_init, sizeof(new_init), "%s%s", NEWROOT, SWITCH_INIT);
    unlink(new_init);
    if (copy_file(INIT_SRC, new_init, 0755) != 0)
        die("copy init to %s failed errno=%d", new_init, errno);

    mount_if_needed("tmpfs", NEWROOT "/run", "tmpfs", 0, "mode=0755");
    mount_if_needed("none", "/sys/fs/cgroup", "cgroup2", 0, "");

    clean_lean_processes();

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

    execve(init_path, argv, envp);
    die("exec %s failed errno=%d", init_path, errno);
}
