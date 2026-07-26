#define _GNU_SOURCE

#include <errno.h>
#include <limits.h>
#include <sched.h>
#include <stdio.h>
#include <string.h>
#include <sys/mount.h>
#include <unistd.h>

static int bind_account_file(const char *rescue_dir, const char *name)
{
    char source[PATH_MAX];
    char target[PATH_MAX];

    if (snprintf(source, sizeof(source), "%s/%s", rescue_dir, name) >=
        (int)sizeof(source) ||
        snprintf(target, sizeof(target), "/etc/%s", name) >=
        (int)sizeof(target)) {
        fprintf(stderr, "dropbear-ns: path too long for %s\n", name);
        return -1;
    }

    if (access(target, F_OK) != 0) {
        return 0;
    }
    if (mount(source, target, NULL, MS_BIND, NULL) != 0) {
        fprintf(stderr, "dropbear-ns: bind %s to %s failed: %s\n",
                source, target, strerror(errno));
        return -1;
    }
    return 0;
}

int main(int argc, char **argv)
{
    const char *rescue_dir;

    if (argc < 3) {
        fprintf(stderr,
                "usage: dropbear-ns RESCUE_DIR COMMAND [ARG ...]\n");
        return 2;
    }
    rescue_dir = argv[1];

    if (unshare(CLONE_NEWNS) != 0) {
        fprintf(stderr, "dropbear-ns: unshare failed: %s\n",
                strerror(errno));
        return 1;
    }
    if (mount(NULL, "/", NULL, MS_REC | MS_PRIVATE, NULL) != 0) {
        fprintf(stderr, "dropbear-ns: make mounts private failed: %s\n",
                strerror(errno));
        return 1;
    }
    if (bind_account_file(rescue_dir, "passwd") != 0 ||
        bind_account_file(rescue_dir, "group") != 0) {
        return 1;
    }

    execv(argv[2], &argv[2]);
    fprintf(stderr, "dropbear-ns: exec %s failed: %s\n",
            argv[2], strerror(errno));
    return 1;
}
