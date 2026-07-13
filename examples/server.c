#include <stdio.h>
#include <string.h>
#include <stdint.h>
#include <stddef.h>
#include <sys/epoll.h>
#include <sys/ioctl.h>
#include <sys/types.h>
#include <netinet/in.h>
#include <arpa/inet.h>

#include "ff_config.h"
#include "ff_api.h"
#include "ff_epoll.h"

#define BUFSZ (256*1024)
static char buf[BUFSZ];
static long long total_bytes = 0;
static int kq, sockfd;

int loop(void *arg) {
    struct epoll_event events[32];
    int n = ff_epoll_wait(kq, events, 32, 0);
    for (int i = 0; i < n; i++) {
        int fd = events[i].data.fd;
        if (fd == sockfd) {
            int client = ff_accept(fd, NULL, NULL);
            int on = 1;
            ff_ioctl(client, FIONBIO, &on);
            struct epoll_event ev = { .events = EPOLLIN, .data.fd = client };
            ff_epoll_ctl(kq, EPOLL_CTL_ADD, client, &ev);
        } else if (events[i].events & EPOLLIN) {
            ssize_t r;
            while ((r = ff_read(fd, buf, BUFSZ)) > 0) total_bytes += r;
            if (r == 0) { ff_close(fd); }
        }
    }
    return 0;
}

int main(int argc, char *argv[]) {
    ff_init(argc, argv);
    sockfd = ff_socket(AF_INET, SOCK_STREAM, 0);
    struct sockaddr_in addr = {0};
    addr.sin_family = AF_INET;
    addr.sin_port = htons(9999);
    addr.sin_addr.s_addr = htonl(INADDR_ANY);
    ff_bind(sockfd, (struct linux_sockaddr*)&addr, sizeof(addr));
    ff_listen(sockfd, 128);
    int on = 1;
    ff_ioctl(sockfd, FIONBIO, &on);

    kq = ff_epoll_create(0);
    struct epoll_event ev = { .events = EPOLLIN, .data.fd = sockfd };
    ff_epoll_ctl(kq, EPOLL_CTL_ADD, sockfd, &ev);

    ff_run(loop, NULL);
    return 0;
}
