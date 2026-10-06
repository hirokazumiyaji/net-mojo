#define _POSIX_C_SOURCE 200809L
#include <arpa/inet.h>
#include <assert.h>
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdio.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>

#include "net/tls/shim.h"

#ifndef __linux__
#error "This SIGPIPE regression exercises the Linux socket BIO path"
#endif

void *net_tls_context_server(const char *, const char *, const char *);
void net_tls_context_free(void *);
void *net_tls_connection_new(void *, int);
void net_tls_connection_free(void *);
int net_tls_handshake(void *);
int net_tls_write(void *, const unsigned char *, size_t);

static void check_signal_policy(const struct sigaction *expected,
                                const sigset_t *expected_mask) {
    struct sigaction current;
    sigset_t current_mask;
    assert(sigaction(SIGPIPE, NULL, &current) == 0);
    assert(sigprocmask(SIG_SETMASK, NULL, &current_mask) == 0);
    assert(current.sa_handler == expected->sa_handler);
    assert(current.sa_flags == expected->sa_flags);
    for (int number = 1; number <= SIGRTMAX; number++) {
        assert(sigismember(&current.sa_mask, number) ==
               sigismember(&expected->sa_mask, number));
        assert(sigismember(&current_mask, number) ==
               sigismember(expected_mask, number));
    }
}

int main(int argc, char **argv) {
    assert(argc == 3);
    alarm(20);
    struct sigaction default_action;
    memset(&default_action, 0, sizeof(default_action));
    default_action.sa_handler = SIG_DFL;
    assert(sigemptyset(&default_action.sa_mask) == 0);
    assert(sigaction(SIGPIPE, &default_action, NULL) == 0);
    sigset_t pipe_signal;
    assert(sigemptyset(&pipe_signal) == 0);
    assert(sigaddset(&pipe_signal, SIGPIPE) == 0);
    assert(sigprocmask(SIG_UNBLOCK, &pipe_signal, NULL) == 0);
    struct sigaction expected_action;
    sigset_t expected_mask;
    assert(sigaction(SIGPIPE, NULL, &expected_action) == 0);
    assert(sigprocmask(SIG_SETMASK, NULL, &expected_mask) == 0);

    void *context = net_tls_context_server(argv[1], argv[2], "h2,http/1.1");
    assert(context != NULL);
    check_signal_policy(&expected_action, &expected_mask);
    int listener = socket(AF_INET, SOCK_STREAM, 0);
    assert(listener >= 0);
    struct sockaddr_in address;
    memset(&address, 0, sizeof(address));
    address.sin_family = AF_INET;
    address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    assert(bind(listener, (struct sockaddr *)&address, sizeof(address)) == 0);
    assert(listen(listener, 1) == 0);
    socklen_t address_length = sizeof(address);
    assert(getsockname(listener, (struct sockaddr *)&address,
                       &address_length) == 0);
    printf("READY port=%u pid=%ld\n", ntohs(address.sin_port), (long)getpid());
    fflush(stdout);

    int fd = accept(listener, NULL, NULL);
    assert(fd >= 0);
    void *connection = net_tls_connection_new(context, fd);
    assert(connection != NULL);
    assert(net_tls_handshake(connection) == 1);
    net_tls_context_free(context);
    check_signal_policy(&expected_action, &expected_mask);
    puts("HANDSHAKE policy=default-unblocked context-owner=dropped");
    fflush(stdout);

    unsigned char byte;
    errno = 0;
    ssize_t peeked = recv(fd, &byte, 1, MSG_PEEK);
    int reset_error = errno;
    printf("PEER_RESET recv=%ld errno=%d\n", (long)peeked, reset_error);
    fflush(stdout);
    assert(peeked == -1 && reset_error == ECONNRESET);
    check_signal_policy(&expected_action, &expected_mask);
    const unsigned char response[] = "response after peer reset";
    int result = net_tls_write(connection, response, sizeof(response) - 1);
    int write_error = errno;
    printf("TLS_WRITE result=%d errno=%d\n", result, write_error);
    fflush(stdout);
    assert(result == NET_TLS_ERROR);
    check_signal_policy(&expected_action, &expected_mask);
    net_tls_connection_free(connection);
    assert(fcntl(fd, F_GETFD) != -1);
    check_signal_policy(&expected_action, &expected_mask);
    assert(close(fd) == 0);
    assert(close(listener) == 0);
    puts("PASS policy=unchanged socket-owner=preserved");
    return 0;
}
