#include <limits.h>
#include <stddef.h>
#include <stdint.h>
#include <string.h>

#include <openssl/err.h>
#include <openssl/ssl.h>

#if OPENSSL_VERSION_NUMBER < 0x30200000L
#error "net TLS requires OpenSSL 3.2 or newer"
#endif

enum {
    NET_TLS_WANT_READ = -2,
    NET_TLS_WANT_WRITE = -3,
    NET_TLS_CLOSED = -4,
    NET_TLS_ERROR = -1,
};

struct net_tls_context {
    SSL_CTX *ssl;
    unsigned int references;
    unsigned char alpn[255];
    unsigned int alpn_length;
};

struct net_tls_connection {
    struct net_tls_context *context;
    SSL *ssl;
};

static void net_tls_context_release(struct net_tls_context *context) {
    if (--context->references == 0) {
        SSL_CTX_free(context->ssl);
        OPENSSL_free(context);
    }
}

static int net_tls_select_alpn(SSL *ssl, const unsigned char **out,
                               unsigned char *out_length,
                               const unsigned char *input,
                               unsigned int input_length, void *argument) {
    (void)ssl;
    struct net_tls_context *context = argument;
    unsigned char *selected = NULL;
    unsigned char selected_length = 0;
    int result = SSL_select_next_proto(
        &selected, &selected_length, context->alpn, context->alpn_length,
        input, input_length);
    if (result != OPENSSL_NPN_NEGOTIATED) {
        return SSL_TLSEXT_ERR_ALERT_FATAL;
    }
    *out = selected;
    *out_length = selected_length;
    return SSL_TLSEXT_ERR_OK;
}

void *net_tls_context_server(const char *certificate, const char *private_key,
                             const char *protocols) {
    ERR_clear_error();
    struct net_tls_context *context = OPENSSL_zalloc(sizeof(*context));
    if (context == NULL) {
        return NULL;
    }
    context->ssl = SSL_CTX_new(TLS_server_method());
    if (context->ssl == NULL ||
        SSL_CTX_set_min_proto_version(context->ssl, TLS1_2_VERSION) != 1 ||
        SSL_CTX_use_certificate_chain_file(context->ssl, certificate) != 1 ||
        SSL_CTX_use_PrivateKey_file(context->ssl, private_key, SSL_FILETYPE_PEM) != 1 ||
        SSL_CTX_check_private_key(context->ssl) != 1) {
        if (context->ssl != NULL) {
            SSL_CTX_free(context->ssl);
        }
        OPENSSL_free(context);
        return NULL;
    }

    const char *part = protocols;
    while (*part != '\0') {
        const char *end = strchr(part, ',');
        size_t length = end == NULL ? strlen(part) : (size_t)(end - part);
        if (length == 0 || length > UCHAR_MAX ||
            context->alpn_length + length + 1 > sizeof(context->alpn) ||
            (end != NULL && end[1] == '\0')) {
            SSL_CTX_free(context->ssl);
            OPENSSL_free(context);
            return NULL;
        }
        context->alpn[context->alpn_length++] = (unsigned char)length;
        memcpy(context->alpn + context->alpn_length, part, length);
        context->alpn_length += (unsigned int)length;
        if (end == NULL) {
            break;
        }
        part = end + 1;
    }
    if (context->alpn_length == 0) {
        SSL_CTX_free(context->ssl);
        OPENSSL_free(context);
        return NULL;
    }

    context->references = 1;
    SSL_CTX_set_alpn_select_cb(context->ssl, net_tls_select_alpn, context);
    return context;
}

void net_tls_context_free(void *opaque) {
    if (opaque != NULL) {
        net_tls_context_release(opaque);
    }
}

void *net_tls_connection_new(void *opaque, int fd) {
    struct net_tls_context *context = opaque;
    ERR_clear_error();
    struct net_tls_connection *connection = OPENSSL_zalloc(sizeof(*connection));
    if (connection == NULL) {
        return NULL;
    }
    connection->ssl = SSL_new(context->ssl);
    if (connection->ssl == NULL) {
        OPENSSL_free(connection);
        return NULL;
    }
    if (SSL_set_fd(connection->ssl, fd) != 1) {
        SSL_free(connection->ssl);
        OPENSSL_free(connection);
        return NULL;
    }
    context->references++;
    connection->context = context;
    SSL_set_accept_state(connection->ssl);
    return connection;
}

void net_tls_connection_free(void *opaque) {
    if (opaque == NULL) {
        return;
    }
    struct net_tls_connection *connection = opaque;
    SSL_free(connection->ssl);
    net_tls_context_release(connection->context);
    OPENSSL_free(connection);
}

static int net_tls_result(struct net_tls_connection *connection, int result) {
    int error = SSL_get_error(connection->ssl, result);
    if (error == SSL_ERROR_WANT_READ) {
        return NET_TLS_WANT_READ;
    }
    if (error == SSL_ERROR_WANT_WRITE) {
        return NET_TLS_WANT_WRITE;
    }
    if (error == SSL_ERROR_ZERO_RETURN) {
        return NET_TLS_CLOSED;
    }
    return NET_TLS_ERROR;
}

int net_tls_handshake(void *opaque) {
    struct net_tls_connection *connection = opaque;
    ERR_clear_error();
    int result = SSL_do_handshake(connection->ssl);
    return result == 1 ? 1 : net_tls_result(connection, result);
}

int net_tls_read(void *opaque, unsigned char *buffer, size_t length) {
    struct net_tls_connection *connection = opaque;
    ERR_clear_error();
    size_t read_length = 0;
    int result = SSL_read_ex(connection->ssl, buffer, length, &read_length);
    if (result == 1) {
        return read_length > INT_MAX ? NET_TLS_ERROR : (int)read_length;
    }
    return net_tls_result(connection, result);
}

int net_tls_write(void *opaque, const unsigned char *buffer, size_t length) {
    struct net_tls_connection *connection = opaque;
    ERR_clear_error();
    size_t written_length = 0;
    int result = SSL_write_ex(connection->ssl, buffer, length, &written_length);
    if (result == 1) {
        return written_length > INT_MAX ? NET_TLS_ERROR : (int)written_length;
    }
    return net_tls_result(connection, result);
}

int net_tls_selected_alpn(void *opaque, unsigned char *buffer, size_t capacity) {
    struct net_tls_connection *connection = opaque;
    const unsigned char *protocol = NULL;
    unsigned int length = 0;
    SSL_get0_alpn_selected(connection->ssl, &protocol, &length);
    if (length == 0 || length > capacity) {
        return 0;
    }
    memcpy(buffer, protocol, length);
    return (int)length;
}
