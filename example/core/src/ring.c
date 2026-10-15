/* ring.c -- the sample ring behind every metric window. */
#include <tm/core.h>

int tm_ring_init(tm_ring *r, size_t capacity)
{
    if (capacity == 0 || capacity > TM_RING_MAX)
        return -1;
    r->capacity = capacity;
    r->count = 0;
    r->head = 0;
    r->total = 0;
    return 0;
}

void tm_ring_push(tm_ring *r, double v)
{
    r->values[r->head] = v;
    r->head = (r->head + 1) % r->capacity;
    if (r->count < r->capacity)
        r->count++;
    r->total++;
}

size_t tm_ring_copy(const tm_ring *r, double *out, size_t n)
{
    size_t take = r->count < n ? r->count : n;
    size_t start = (r->head - take + r->capacity) % r->capacity;

    for (size_t i = 0; i < take; i++)
        out[i] = r->values[(start + i) % r->capacity];
    return take;
}
