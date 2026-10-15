/* tm/core.h -- telemetry core: a fixed-size ring of samples and CRC-32.
 *
 * Plain C: used by the C++ statistics library, the C command-line tool and, through cgo, by Go. */
#ifndef TM_CORE_H
#define TM_CORE_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define TM_RING_MAX 4096

/* The last `capacity` samples of one metric; a new sample overwrites the oldest. */
typedef struct tm_ring {
    double   values[TM_RING_MAX];
    size_t   capacity;
    size_t   count; /* samples held, at most capacity */
    size_t   head;  /* where the next sample goes */
    uint64_t total; /* samples ever pushed */
} tm_ring;

/* 0, or -1 when capacity is 0 or larger than TM_RING_MAX. */
int  tm_ring_init(tm_ring *r, size_t capacity);
void tm_ring_push(tm_ring *r, double v);
/* Copies the newest min(n, count) samples into out, oldest first; returns how many. */
size_t tm_ring_copy(const tm_ring *r, double *out, size_t n);

/* CRC-32 as in zlib, gzip and PNG.  _update continues a running value (start from 0). */
uint32_t tm_crc32(const void *data, size_t len);
uint32_t tm_crc32_update(uint32_t crc, const void *data, size_t len);

/* "libtmcore 1.4.0 (debug, built 2026-10-20T03:00:00Z on buildhost)" */
const char *tm_core_version(void);

#ifdef __cplusplus
}
#endif

#endif
