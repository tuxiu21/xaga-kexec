#include <arpa/inet.h>
#include <errno.h>
#include <netdb.h>
#include <poll.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <unistd.h>

static void die(const char *msg)
{
    perror(msg);
    exit(1);
}

static int parse_port(const char *s)
{
    char *end = NULL;
    long v = strtol(s, &end, 10);
    if (!s[0] || *end || v < 1 || v > 65535) {
        fprintf(stderr, "invalid port: %s\n", s);
        exit(2);
    }
    return (int)v;
}

static int connect_tcp(const char *host, const char *port)
{
    struct addrinfo hints;
    struct addrinfo *res = NULL;
    struct addrinfo *ai;
    int fd = -1;

    memset(&hints, 0, sizeof(hints));
    hints.ai_socktype = SOCK_STREAM;
    hints.ai_family = AF_UNSPEC;

    if (getaddrinfo(host, port, &hints, &res) != 0) {
        return -1;
    }
    for (ai = res; ai; ai = ai->ai_next) {
        fd = socket(ai->ai_family, ai->ai_socktype, ai->ai_protocol);
        if (fd < 0) {
            continue;
        }
        if (connect(fd, ai->ai_addr, ai->ai_addrlen) == 0) {
            break;
        }
        close(fd);
        fd = -1;
    }
    freeaddrinfo(res);
    return fd;
}

static int listen_tcp(const char *host, int port)
{
    int fd;
    int one = 1;
    struct sockaddr_in addr;

    fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) {
        die("socket");
    }
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));

    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_port = htons((unsigned short)port);
    if (inet_pton(AF_INET, host, &addr.sin_addr) != 1) {
        die("inet_pton");
    }
    if (bind(fd, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
        die("bind");
    }
    if (listen(fd, 16) < 0) {
        die("listen");
    }
    return fd;
}

static int read_token(int fd, char *buf, size_t cap)
{
    size_t n = 0;
    while (n + 1 < cap) {
        char c;
        ssize_t r = read(fd, &c, 1);
        if (r <= 0) {
            return -1;
        }
        if (c == '\n') {
            buf[n] = 0;
            return 0;
        }
        buf[n++] = c;
    }
    return -1;
}

static void write_token(int fd, const char *token)
{
    write(fd, token, strlen(token));
    write(fd, "\n", 1);
}

static void bridge(int a, int b)
{
    struct pollfd p[2];
    char buf[8192];

    p[0].fd = a;
    p[0].events = POLLIN;
    p[1].fd = b;
    p[1].events = POLLIN;

    for (;;) {
        int pr = poll(p, 2, -1);
        if (pr <= 0) {
            if (errno == EINTR) {
                continue;
            }
            break;
        }
        for (int i = 0; i < 2; i++) {
            int in = p[i].fd;
            int out = p[1 - i].fd;
            if (!(p[i].revents & (POLLIN | POLLHUP | POLLERR))) {
                continue;
            }
            ssize_t n = read(in, buf, sizeof(buf));
            if (n <= 0) {
                return;
            }
            char *w = buf;
            while (n > 0) {
                ssize_t m = write(out, w, (size_t)n);
                if (m <= 0) {
                    return;
                }
                w += m;
                n -= m;
            }
        }
    }
}

static void reap(int sig)
{
    (void)sig;
    while (waitpid(-1, NULL, WNOHANG) > 0) {
    }
}

static void usage(const char *argv0)
{
    fprintf(stderr,
            "usage:\n"
            "  %s server <public_bind> <public_port> <local_bind> <local_port> <token>\n"
            "  %s client <server_host> <server_port> <target_host> <target_port> <token>\n",
            argv0, argv0);
    exit(2);
}

static int run_server(int argc, char **argv)
{
    int pool_fd;
    int local_fd;
    const char *token;
    int queued = -1;

    if (argc != 7) {
        usage(argv[0]);
    }
    token = argv[6];
    signal(SIGCHLD, reap);
    signal(SIGPIPE, SIG_IGN);

    pool_fd = listen_tcp(argv[2], parse_port(argv[3]));
    local_fd = listen_tcp(argv[4], parse_port(argv[5]));
    fprintf(stderr, "revfwd server pool=%s:%s local=%s:%s\n", argv[2], argv[3], argv[4], argv[5]);

    for (;;) {
        struct pollfd p[2];
        p[0].fd = pool_fd;
        p[0].events = POLLIN;
        p[1].fd = local_fd;
        p[1].events = POLLIN;
        if (poll(p, 2, -1) <= 0) {
            continue;
        }
        if (p[0].revents & POLLIN) {
            char got[256];
            int fd = accept(pool_fd, NULL, NULL);
            if (fd >= 0 && read_token(fd, got, sizeof(got)) == 0 && strcmp(got, token) == 0) {
                if (queued >= 0) {
                    close(queued);
                }
                queued = fd;
            } else if (fd >= 0) {
                close(fd);
            }
        }
        if (p[1].revents & POLLIN) {
            int user = accept(local_fd, NULL, NULL);
            if (user < 0) {
                continue;
            }
            if (queued < 0) {
                close(user);
                continue;
            }
            int remote = queued;
            queued = -1;
            pid_t pid = fork();
            if (pid == 0) {
                close(pool_fd);
                close(local_fd);
                bridge(user, remote);
                close(user);
                close(remote);
                _exit(0);
            }
            close(user);
            close(remote);
        }
    }
}

static int run_client(int argc, char **argv)
{
    if (argc != 7) {
        usage(argv[0]);
    }
    signal(SIGPIPE, SIG_IGN);

    for (;;) {
        int srv = connect_tcp(argv[2], argv[3]);
        int tgt;
        if (srv < 0) {
            sleep(5);
            continue;
        }
        write_token(srv, argv[6]);
        tgt = connect_tcp(argv[4], argv[5]);
        if (tgt < 0) {
            close(srv);
            sleep(5);
            continue;
        }
        bridge(srv, tgt);
        close(srv);
        close(tgt);
        sleep(1);
    }
}

int main(int argc, char **argv)
{
    if (argc < 2) {
        usage(argv[0]);
    }
    if (strcmp(argv[1], "server") == 0) {
        return run_server(argc, argv);
    }
    if (strcmp(argv[1], "client") == 0) {
        return run_client(argc, argv);
    }
    usage(argv[0]);
}
