#include <assert.h>
#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>

#include <openssl/ssl.h>

void *net_tls_context_server(const char *, const char *, const char *);
void net_tls_context_free(void *);
void *net_tls_connection_new(void *, int);
void net_tls_connection_free(void *);
int net_tls_handshake(void *);
int net_tls_read(void *, unsigned char *, size_t);
int net_tls_write(void *, const unsigned char *, size_t);
int net_tls_selected_alpn(void *, unsigned char *, size_t);

static int is_would_block(int result) {
    return result == -2 || result == -3;
}

int main(int argc, char **argv) {
    assert(argc == 3);
    void *server_context = net_tls_context_server(argv[1], argv[2], "http/1.1");
    assert(server_context != NULL);

    int fds[2];
    assert(socketpair(AF_UNIX, SOCK_STREAM, 0, fds) == 0);
    for (int i = 0; i < 2; i++) {
        int flags = fcntl(fds[i], F_GETFL, 0);
        assert(flags >= 0);
        assert(fcntl(fds[i], F_SETFL, flags | O_NONBLOCK) == 0);
    }

    void *server = net_tls_connection_new(server_context, fds[0]);
    assert(server != NULL);
    SSL_CTX *client_context = SSL_CTX_new(TLS_client_method());
    assert(client_context != NULL);
    SSL *client = SSL_new(client_context);
    assert(client != NULL);
    assert(SSL_set_fd(client, fds[1]) == 1);
    SSL_set_connect_state(client);
    const unsigned char alpn[] = {8, 'h', 't', 't', 'p', '/', '1', '.', '1'};
    assert(SSL_set_alpn_protos(client, alpn, sizeof(alpn)) == 0);

    int client_ready = 0;
    int server_ready = 0;
    for (int i = 0; i < 16 && (!client_ready || !server_ready); i++) {
        if (!client_ready) {
            int result = SSL_do_handshake(client);
            if (result == 1) {
                client_ready = 1;
            } else {
                int error = SSL_get_error(client, result);
                assert(error == SSL_ERROR_WANT_READ || error == SSL_ERROR_WANT_WRITE);
            }
        }
        if (!server_ready) {
            int result = net_tls_handshake(server);
            if (result == 1) {
                server_ready = 1;
            } else {
                assert(is_would_block(result));
            }
        }
    }
    assert(client_ready && server_ready);

    unsigned char selected[16];
    int selected_length = net_tls_selected_alpn(server, selected, sizeof(selected));
    assert(selected_length == 8);
    assert(memcmp(selected, "http/1.1", 8) == 0);

    const unsigned char response[] = "hello";
    int written = net_tls_write(server, response, sizeof(response) - 1);
    assert(written == (int)(sizeof(response) - 1));
    unsigned char received[16];
    size_t received_length = 0;
    assert(SSL_read_ex(client, received, sizeof(received), &received_length) == 1);
    assert(received_length == sizeof(response) - 1);
    assert(memcmp(received, response, received_length) == 0);

    const unsigned char request[] = "ping";
    size_t client_written = 0;
    assert(SSL_write_ex(client, request, sizeof(request) - 1, &client_written) == 1);
    assert(client_written == sizeof(request) - 1);
    int read_result = net_tls_read(server, received, sizeof(received));
    assert(read_result == (int)(sizeof(request) - 1));
    assert(memcmp(received, request, sizeof(request) - 1) == 0);

    SSL_free(client);
    SSL_CTX_free(client_context);
    net_tls_connection_free(server);
    net_tls_context_free(server_context);
    close(fds[0]);
    close(fds[1]);
    puts("TLS shim roundtrip succeeded");
    return 0;
}
