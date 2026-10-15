/* minijson.c -- a streaming JSON writer. */
#include "minijson.h"

#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

void mj_init(mj_writer *w)
{
    memset(w, 0, sizeof *w);
}

void mj_free(mj_writer *w)
{
    free(w->buf);
    mj_init(w);
}

static void put(mj_writer *w, const char *s, size_t n)
{
    if (w->error)
        return;
    if (w->len + n + 1 > w->cap) {
        size_t cap = w->cap ? w->cap * 2 : 256;
        char *buf;
        while (cap < w->len + n + 1)
            cap *= 2;
        buf = realloc(w->buf, cap);
        if (!buf) {
            w->error = 1;
            return;
        }
        w->buf = buf;
        w->cap = cap;
    }
    memcpy(w->buf + w->len, s, n);
    w->len += n;
    w->buf[w->len] = '\0';
}

static void puts_(mj_writer *w, const char *s)
{
    put(w, s, strlen(s));
}

/* Separator before a value (or a key) at the current level. */
static void before_value(mj_writer *w)
{
    if (w->after_key) {
        w->after_key = 0;
        return;
    }
    if (w->count[w->depth]++ > 0)
        puts_(w, ",");
}

static void open_(mj_writer *w, const char *c)
{
    before_value(w);
    puts_(w, c);
    if (w->depth + 1 >= MJ_MAX_DEPTH) {
        w->error = 1;
        return;
    }
    w->count[++w->depth] = 0;
}

static void close_(mj_writer *w, const char *c)
{
    puts_(w, c);
    if (w->depth > 0)
        w->depth--;
}

void mj_object_begin(mj_writer *w) { open_(w, "{"); }
void mj_object_end(mj_writer *w) { close_(w, "}"); }
void mj_array_begin(mj_writer *w) { open_(w, "["); }
void mj_array_end(mj_writer *w) { close_(w, "]"); }

static void quoted(mj_writer *w, const char *s)
{
    puts_(w, "\"");
    for (; *s; s++) {
        char esc[8];
        unsigned char c = (unsigned char)*s;
        if (c == '"' || c == '\\') {
            esc[0] = '\\';
            esc[1] = (char)c;
            put(w, esc, 2);
        } else if (c < 0x20) {
            snprintf(esc, sizeof esc, "\\u%04x", c);
            puts_(w, esc);
        } else {
            put(w, s, 1);
        }
    }
    puts_(w, "\"");
}

void mj_key(mj_writer *w, const char *key)
{
    before_value(w);
    quoted(w, key);
    puts_(w, ":");
    w->after_key = 1;
}

void mj_string(mj_writer *w, const char *s)
{
    before_value(w);
    quoted(w, s);
}

void mj_number(mj_writer *w, double v)
{
    char num[32];

    before_value(w);
    if (isnan(v) || isinf(v)) {
        puts_(w, "null");
        return;
    }
    snprintf(num, sizeof num, "%.10g", v);
    puts_(w, num);
}

void mj_integer(mj_writer *w, long long v)
{
    char num[32];

    before_value(w);
    snprintf(num, sizeof num, "%lld", v);
    puts_(w, num);
}

const char *mj_result(const mj_writer *w)
{
    return w->error ? NULL : (w->buf ? w->buf : "");
}
