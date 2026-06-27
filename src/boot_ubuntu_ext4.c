#define _GNU_SOURCE
#include <errno.h>
#include <dirent.h>
#include <fcntl.h>
#include <signal.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mount.h>
#include <sys/reboot.h>
#include <sys/stat.h>
#include <sys/statfs.h>
#include <sys/sysmacros.h>
#include <sys/wait.h>
#include <unistd.h>

#ifndef MS_MOVE
#define MS_MOVE 8192
#endif

#define LOG_FILE "/data/kexec/boot_ubuntu_ext4.log"
#define IMAGE "/data/kexec/ubuntu.ext4"
#define INIT_SRC "/data/kexec/ubuntu_phase_a_init.sh"
#define NEWROOT "/tmp/newroot"
#define SWITCH_INIT "/phase_a_init"

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
        dprintf(fd, "boot-ubuntu-ext4: %s\n", msg);
        close(fd);
    }

    fd = open(LOG_FILE, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0644);
    if (fd >= 0) {
        dprintf(fd, "boot-ubuntu-ext4: %s\n", msg);
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
        write(fd, "1\n", 2);
        close(fd);
    }
    fd = open("/proc/sysrq-trigger", O_WRONLY | O_CLOEXEC);
    if (fd >= 0) {
        write(fd, "c\n", 2);
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

static int read_major_minor(const char *path, unsigned int *major, unsigned int *minor)
{
    char buf[64];
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
    return sscanf(buf, "%u:%u", major, minor) == 2 ? 0 : -1;
}

static int make_node(const char *sysfs, const char *node, mode_t mode, mode_t type)
{
    unsigned int major, minor;

    if (access(node, F_OK) == 0)
        return 0;
    if (read_major_minor(sysfs, &major, &minor) != 0)
        return -1;

    mkdir_p(strrchr(node, '/') == node ? "/" : "/dev", 0755);
    if (mknod(node, type | mode, makedev(major, minor)) != 0 && errno != EEXIST)
        return -1;
    chmod(node, mode);
    return 0;
}

static void prepare_loop_nodes(void)
{
    char sysfs[64];
    char node[32];
    int i;

    make_node("/sys/class/misc/loop-control/dev", "/dev/loop-control", 0600, S_IFCHR);
    for (i = 0; i < 8; i++) {
        snprintf(sysfs, sizeof(sysfs), "/sys/class/block/loop%d/dev", i);
        snprintf(node, sizeof(node), "/dev/loop%d", i);
        make_node(sysfs, node, 0600, S_IFBLK);
    }
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

static const char *find_loop(void)
{
    static char node[32];
    int i, fd;

    for (i = 0; i < 8; i++) {
        snprintf(node, sizeof(node), "/dev/loop%d", i);
        fd = open(node, O_RDONLY | O_CLOEXEC);
        if (fd < 0)
            continue;
        close(fd);
        return node;
    }
    return NULL;
}

static void attach_loop_with_busybox(const char *loop)
{
    pid_t pid;
    int status;

    pid = fork();
    if (pid < 0)
        die("fork losetup failed errno=%d", errno);
    if (pid == 0) {
        execl("/data/kexec/busybox", "busybox", "losetup", loop, IMAGE, (char *)NULL);
        _exit(127);
    }
    if (waitpid(pid, &status, 0) < 0)
        die("wait losetup failed errno=%d", errno);
    if (!WIFEXITED(status) || WEXITSTATUS(status) != 0)
        die("losetup failed status=0x%x", status);
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

static void reap_children(void)
{
    int status;

    while (waitpid(-1, &status, WNOHANG) > 0)
        ;
}

static void kick_watchdog_once(void)
{
    static const char *nodes[] = {
        "/dev/watchdog0",
        "/dev/watchdog",
        NULL,
    };
    const char **node;
    const char kick = 'K';
    int fd;

    for (node = nodes; *node; node++) {
        fd = open(*node, O_WRONLY | O_CLOEXEC);
        if (fd < 0)
            continue;
        if (write(fd, &kick, 1) == 1)
            logmsg("kicked watchdog via %s", *node);
        else
            logmsg("watchdog kick via %s failed errno=%d", *node, errno);
        close(fd);
        return;
    }
    logmsg("warning: no watchdog node available for final kick");
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
    if (!dir) {
        logmsg("warning: opendir /proc failed errno=%d", errno);
        return;
    }

    while ((de = readdir(dir)) != NULL) {
        if (parse_pid(de->d_name, &pid) != 0)
            continue;
        if (pid == self)
            continue;
        if (!process_has_cmdline(pid))
            continue;
        if (kill(pid, sig) == 0) {
            (*sent)++;
        } else if (errno != ESRCH) {
            (*failed)++;
        }
    }

    closedir(dir);
}

static void kill_lean_processes(void)
{
    int term_sent = 0, term_failed = 0;
    int kill_sent = 0, kill_failed = 0;
    int fd;

    logmsg("cleaning lean userspace before Ubuntu handoff");
    fd = open("/config/usb_gadget/g1/UDC", O_WRONLY | O_CLOEXEC);
    if (fd >= 0) {
        if (write(fd, "\n", 1) == 1)
            logmsg("unbound lean USB gadget");
        else
            logmsg("warning: failed to unbind lean USB gadget errno=%d", errno);
        close(fd);
    } else {
        logmsg("warning: no lean USB gadget UDC node errno=%d", errno);
    }
    kick_watchdog_once();

    signal_other_processes(SIGTERM, &term_sent, &term_failed);
    logmsg("sent SIGTERM to %d processes (%d failed)", term_sent, term_failed);
    sleep(1);
    reap_children();

    kick_watchdog_once();
    signal_other_processes(SIGKILL, &kill_sent, &kill_failed);
    logmsg("sent SIGKILL to %d remaining processes (%d failed)", kill_sent, kill_failed);
    sleep(1);
    reap_children();

    kick_watchdog_once();
}

int main(void)
{
    const char *loop;
    char new_init[256];
    char *argv[] = { SWITCH_INIT, NULL };
    char *envp[] = {
        "HOME=/root",
        "TERM=linux",
        "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
        NULL,
    };

    logmsg("begin image=%s newroot=%s init=%s", IMAGE, NEWROOT, INIT_SRC);

    mount_if_needed("proc", "/proc", "proc", 0, "");
    mount_if_needed("sysfs", "/sys", "sysfs", 0, "");
    mount_if_needed("devtmpfs", "/dev", "devtmpfs", 0, "mode=0755");
    mount_if_needed("devpts", "/dev/pts", "devpts", 0, "mode=0620,ptmxmode=0666");
    mount_if_needed("tmpfs", "/tmp", "tmpfs", 0, "mode=1777");

    if (access(IMAGE, R_OK) != 0)
        die("missing image %s errno=%d", IMAGE, errno);
    if (access(INIT_SRC, X_OK) != 0)
        die("missing init %s errno=%d", INIT_SRC, errno);

    prepare_loop_nodes();
    loop = find_loop();
    if (!loop)
        die("no loop device available");
    logmsg("using loop=%s", loop);
    attach_loop_with_busybox(loop);

    mkdir_p(NEWROOT, 0755);
    if (mount(loop, NEWROOT, "ext4", MS_NOATIME, "") != 0)
        die("mount %s on %s failed errno=%d", loop, NEWROOT, errno);
    logmsg("mounted %s on %s", loop, NEWROOT);

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

    kill_lean_processes();

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

    logmsg("exec %s", SWITCH_INIT);
    execve(SWITCH_INIT, argv, envp);
    die("exec %s failed errno=%d", SWITCH_INIT, errno);
}
