#ifndef NET_TLS_SHIM_H
#define NET_TLS_SHIM_H

enum {
    NET_TLS_WANT_READ = -2,
    NET_TLS_WANT_WRITE = -3,
    NET_TLS_CLOSED = -4,
    NET_TLS_SHUTDOWN_SENT = -5,
    NET_TLS_ERROR = -1,
};

#endif
