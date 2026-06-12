#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/sysmacros.h>
#include <unistd.h>

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
        dprintf(fd, "kexec-watchdog-feeder: %s\n", buf);
        close(fd);
    }
}

static int read_major_minor(const char *path, unsigned int *major, unsigned int *minor)
{
    char buf[64];
    int fd;
    ssize_t n;

    fd = open(path, O_RDONLY | O_CLOEXEC);
    if (fd < 0) {
        return -1;
    }

    n = read(fd, buf, sizeof(buf) - 1);
    close(fd);
    if (n <= 0) {
        return -1;
    }

    buf[n] = '\0';
    return sscanf(buf, "%u:%u", major, minor) == 2 ? 0 : -1;
}

static void ensure_watchdog0(void)
{
    unsigned int major, minor;

    if (access("/dev/watchdog0", F_OK) == 0) {
        return;
    }

    if (read_major_minor("/sys/class/watchdog/watchdog0/dev", &major, &minor) != 0) {
        return;
    }

    if (mknod("/dev/watchdog0", S_IFCHR | 0600, makedev(major, minor)) == 0) {
        logmsg("created /dev/watchdog0 major=%u minor=%u", major, minor);
    } else {
        logmsg("mknod /dev/watchdog0 failed errno=%d", errno);
    }
}

static int open_watchdog(const char **chosen)
{
    static const char *candidates[] = {
        "/dev/watchdog0",
        "/dev/watchdog",
        NULL,
    };
    const char **p;
    int fd;

    ensure_watchdog0();

    for (p = candidates; *p; p++) {
        fd = open(*p, O_WRONLY | O_CLOEXEC);
        if (fd >= 0) {
            *chosen = *p;
            return fd;
        }
        logmsg("open %s failed errno=%d", *p, errno);
    }

    return -1;
}

int main(int argc, char **argv)
{
    const char *chosen = NULL;
    unsigned int interval = 5;
    int fd;
    unsigned long count = 0;
    const char kick = 'K';

    if (argc > 1 && argv[1][0] >= '1' && argv[1][0] <= '9') {
        interval = (unsigned int)atoi(argv[1]);
    }

    fd = open_watchdog(&chosen);
    if (fd < 0) {
        logmsg("no watchdog device available; exiting");
        return 1;
    }

    logmsg("started fd feeder on %s interval=%us", chosen, interval);

    for (;;) {
        if (write(fd, &kick, 1) != 1) {
            logmsg("write %s failed errno=%d; reopening", chosen, errno);
            close(fd);
            sleep(1);
            fd = open_watchdog(&chosen);
            if (fd < 0) {
                logmsg("reopen failed; retrying");
                sleep(interval);
                continue;
            }
            logmsg("reopened %s", chosen);
        } else if ((count++ % 12) == 0) {
            logmsg("kicked %s", chosen);
        }
        sleep(interval);
    }
}
