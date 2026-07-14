#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <unistd.h>
#include <signal.h>
#include <errno.h>
#include <time.h>
#include <arpa/inet.h>
#include <sys/socket.h>
#include <netinet/in.h>

#define BUFSZ (256*1024)
static char buf[BUFSZ];
static volatile sig_atomic_t running = 1;
static long long total_bytes = 0;

static void on_signal(int sig) {
    (void)sig;
    running = 0;
}

int main(int argc, char *argv[]) {
    if (argc < 3) {
        fprintf(stderr, "Uso: %s <ip_servidor> <porta> [duracao_s]\n", argv[0]);
        return 1;
    }

    const char *server_ip = argv[1];
    int port = atoi(argv[2]);
    int duration = (argc > 3) ? atoi(argv[3]) : 0; /* 0 = sem limite, encerra com Ctrl+C */

    struct sigaction sa = {0};
    sa.sa_handler = on_signal; /* sem SA_RESTART: send() bloqueado deve retornar EINTR, nao reiniciar */
    sigaction(SIGINT, &sa, NULL);
    sigaction(SIGTERM, &sa, NULL);

    memset(buf, 'A', BUFSZ);

    int sockfd = socket(AF_INET, SOCK_STREAM, 0);
    if (sockfd < 0) {
        perror("socket");
        return 1;
    }

    struct sockaddr_in addr = {0};
    addr.sin_family = AF_INET;
    addr.sin_port = htons(port);
    if (inet_pton(AF_INET, server_ip, &addr.sin_addr) != 1) {
        fprintf(stderr, "IP invalido: %s\n", server_ip);
        close(sockfd);
        return 1;
    }

    if (connect(sockfd, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
        perror("connect");
        close(sockfd);
        return 1;
    }

    printf("Conectado a %s:%d. Enviando trafego...\n", server_ip, port);

    time_t start = time(NULL);
    time_t last_report = start;

    while (running) {
        ssize_t sent = send(sockfd, buf, BUFSZ, 0);
        if (sent < 0) {
            if (errno != EINTR) {
                perror("send");
            }
            break;
        }
        total_bytes += sent;

        time_t now = time(NULL);
        if (now != last_report) {
            printf("Total enviado: %.2f MB\n", total_bytes / (1024.0 * 1024.0));
            last_report = now;
        }
        if (duration > 0 && (now - start) >= duration) {
            break;
        }
    }

    printf("Encerrando. Total enviado: %lld bytes (%.2f MB)\n",
           total_bytes, total_bytes / (1024.0 * 1024.0));

    close(sockfd);
    return 0;
}
