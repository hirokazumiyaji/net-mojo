#define _GNU_SOURCE
#include <dlfcn.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static atomic_uint_fast64_t malloc_calls;
static atomic_uint_fast64_t calloc_calls;
static atomic_uint_fast64_t realloc_calls;
static atomic_uint_fast64_t aligned_calls;
static atomic_uint_fast64_t posix_memalign_calls;
static atomic_uint_fast64_t memalign_calls;
static atomic_uint_fast64_t free_calls;
static atomic_uint_fast64_t malloc_bytes;
static atomic_uint_fast64_t calloc_bytes;
static atomic_uint_fast64_t realloc_bytes;
static atomic_uint_fast64_t aligned_bytes;
static atomic_uint_fast64_t posix_memalign_bytes;
static atomic_uint_fast64_t memalign_bytes;

typedef void *(*malloc_fn)(size_t);
typedef void *(*calloc_fn)(size_t, size_t);
typedef void *(*realloc_fn)(void *, size_t);
typedef void *(*aligned_alloc_fn)(size_t, size_t);
typedef int (*posix_memalign_fn)(void **, size_t, size_t);
typedef void *(*memalign_fn)(size_t, size_t);
typedef void (*free_fn)(void *);

static malloc_fn real_malloc;
static calloc_fn real_calloc;
static realloc_fn real_realloc;
static aligned_alloc_fn real_aligned_alloc;
static posix_memalign_fn real_posix_memalign;
static memalign_fn real_memalign;
static free_fn real_free;

static char bootstrap_buf[65536];
static size_t bootstrap_off;
static int in_init;

static void *bootstrap_alloc(size_t n) {
    size_t aligned = (n + 15) & ~(size_t)15;
    if (bootstrap_off + aligned > sizeof bootstrap_buf) {
        return NULL;
    }
    void *p = bootstrap_buf + bootstrap_off;
    bootstrap_off += aligned;
    return p;
}

static int bootstrap_owned(const void *p) {
    const char *c = (const char *)p;
    return c >= bootstrap_buf && c < bootstrap_buf + sizeof bootstrap_buf;
}

static void resolve(void) {
    if (in_init) return;
    in_init = 1;
    real_malloc = (malloc_fn)dlsym(RTLD_NEXT, "malloc");
    real_calloc = (calloc_fn)dlsym(RTLD_NEXT, "calloc");
    real_realloc = (realloc_fn)dlsym(RTLD_NEXT, "realloc");
    real_aligned_alloc = (aligned_alloc_fn)dlsym(RTLD_NEXT, "aligned_alloc");
    real_posix_memalign = (posix_memalign_fn)dlsym(RTLD_NEXT, "posix_memalign");
    real_memalign = (memalign_fn)dlsym(RTLD_NEXT, "memalign");
    real_free = (free_fn)dlsym(RTLD_NEXT, "free");
    in_init = 0;
}

void *malloc(size_t size) {
    if (!real_malloc) {
        if (in_init) return bootstrap_alloc(size);
        resolve();
        if (!real_malloc) return bootstrap_alloc(size);
    }
    void *p = real_malloc(size);
    if (p) {
        atomic_fetch_add_explicit(&malloc_calls, 1, memory_order_relaxed);
        atomic_fetch_add_explicit(&malloc_bytes, size, memory_order_relaxed);
    }
    return p;
}

void *calloc(size_t n, size_t size) {
    if (!real_calloc) {
        if (in_init) {
            size_t total = n * size;
            void *p = bootstrap_alloc(total);
            if (p) memset(p, 0, total);
            return p;
        }
        resolve();
        if (!real_calloc) {
            size_t total = n * size;
            void *p = bootstrap_alloc(total);
            if (p) memset(p, 0, total);
            return p;
        }
    }
    void *p = real_calloc(n, size);
    if (p) {
        atomic_fetch_add_explicit(&calloc_calls, 1, memory_order_relaxed);
        atomic_fetch_add_explicit(&calloc_bytes, n * size, memory_order_relaxed);
    }
    return p;
}

void *realloc(void *p, size_t size) {
    if (!real_realloc) {
        resolve();
    }
    void *np = real_realloc(p, size);
    if (np) {
        atomic_fetch_add_explicit(&realloc_calls, 1, memory_order_relaxed);
        atomic_fetch_add_explicit(&realloc_bytes, size, memory_order_relaxed);
    }
    return np;
}

void *aligned_alloc(size_t alignment, size_t size) {
    if (!real_aligned_alloc) {
        resolve();
    }
    void *p = real_aligned_alloc(alignment, size);
    if (p) {
        atomic_fetch_add_explicit(&aligned_calls, 1, memory_order_relaxed);
        atomic_fetch_add_explicit(&aligned_bytes, size, memory_order_relaxed);
    }
    return p;
}

int posix_memalign(void **out, size_t alignment, size_t size) {
    if (!real_posix_memalign) {
        resolve();
    }
    int rc = real_posix_memalign(out, alignment, size);
    if (rc == 0) {
        atomic_fetch_add_explicit(&posix_memalign_calls, 1, memory_order_relaxed);
        atomic_fetch_add_explicit(&posix_memalign_bytes, size, memory_order_relaxed);
    }
    return rc;
}

void *memalign(size_t alignment, size_t size) {
    if (!real_memalign) {
        resolve();
    }
    void *p = real_memalign(alignment, size);
    if (p) {
        atomic_fetch_add_explicit(&memalign_calls, 1, memory_order_relaxed);
        atomic_fetch_add_explicit(&memalign_bytes, size, memory_order_relaxed);
    }
    return p;
}

void free(void *p) {
    if (!p) return;
    if (bootstrap_owned(p)) return;
    if (!real_free) {
        resolve();
    }
    atomic_fetch_add_explicit(&free_calls, 1, memory_order_relaxed);
    real_free(p);
}

static void dump_counts(void) {
    const char *path = getenv("MALLOC_COUNT_OUTPUT");
    if (!path || !*path) {
        return;
    }
    FILE *f = fopen(path, "w");
    if (!f) return;
    fprintf(f,
        "{\n"
        "  \"pid\": %d,\n"
        "  \"malloc_calls\": %llu,\n"
        "  \"calloc_calls\": %llu,\n"
        "  \"realloc_calls\": %llu,\n"
        "  \"aligned_alloc_calls\": %llu,\n"
        "  \"posix_memalign_calls\": %llu,\n"
        "  \"memalign_calls\": %llu,\n"
        "  \"free_calls\": %llu,\n"
        "  \"malloc_bytes\": %llu,\n"
        "  \"calloc_bytes\": %llu,\n"
        "  \"realloc_bytes\": %llu,\n"
        "  \"aligned_alloc_bytes\": %llu,\n"
        "  \"posix_memalign_bytes\": %llu,\n"
        "  \"memalign_bytes\": %llu\n"
        "}\n",
        (int)getpid(),
        (unsigned long long)atomic_load_explicit(&malloc_calls, memory_order_relaxed),
        (unsigned long long)atomic_load_explicit(&calloc_calls, memory_order_relaxed),
        (unsigned long long)atomic_load_explicit(&realloc_calls, memory_order_relaxed),
        (unsigned long long)atomic_load_explicit(&aligned_calls, memory_order_relaxed),
        (unsigned long long)atomic_load_explicit(&posix_memalign_calls, memory_order_relaxed),
        (unsigned long long)atomic_load_explicit(&memalign_calls, memory_order_relaxed),
        (unsigned long long)atomic_load_explicit(&free_calls, memory_order_relaxed),
        (unsigned long long)atomic_load_explicit(&malloc_bytes, memory_order_relaxed),
        (unsigned long long)atomic_load_explicit(&calloc_bytes, memory_order_relaxed),
        (unsigned long long)atomic_load_explicit(&realloc_bytes, memory_order_relaxed),
        (unsigned long long)atomic_load_explicit(&aligned_bytes, memory_order_relaxed),
        (unsigned long long)atomic_load_explicit(&posix_memalign_bytes, memory_order_relaxed),
        (unsigned long long)atomic_load_explicit(&memalign_bytes, memory_order_relaxed));
    fclose(f);
}

__attribute__((constructor)) static void init(void) {
    resolve();
    atexit(dump_counts);
}
