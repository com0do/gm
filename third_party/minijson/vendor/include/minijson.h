/* minijson -- a streaming JSON writer.  Third-party code with its own Makefile. */
#ifndef MINIJSON_H
#define MINIJSON_H

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

#define MJ_MAX_DEPTH 32

typedef struct mj_writer {
    char  *buf;
    size_t len, cap;
    int    depth;
    int    count[MJ_MAX_DEPTH]; /* values written at each level, for the commas */
    int    after_key;
    int    error;
} mj_writer;

void mj_init(mj_writer *w);
void mj_free(mj_writer *w);

void mj_object_begin(mj_writer *w);
void mj_object_end(mj_writer *w);
void mj_array_begin(mj_writer *w);
void mj_array_end(mj_writer *w);
void mj_key(mj_writer *w, const char *key);
void mj_string(mj_writer *w, const char *s);
void mj_number(mj_writer *w, double v); /* NaN and infinities become null */
void mj_integer(mj_writer *w, long long v);

/* The document so far, NUL-terminated; NULL after an error (nesting too deep, out of memory). */
const char *mj_result(const mj_writer *w);

#ifdef __cplusplus
}
#endif

#endif
