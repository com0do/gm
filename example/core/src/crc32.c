/* crc32.c -- CRC-32, the IEEE 802.3 polynomial in reflected form (as zlib, gzip and PNG). */
#include <tm/core.h>

uint32_t tm_crc32_update(uint32_t crc, const void *data, size_t len)
{
    const unsigned char *p = data;

    crc = ~crc;
    while (len--) {
        crc ^= *p++;
        for (int bit = 0; bit < 8; bit++)
            crc = (crc >> 1) ^ ((crc & 1u) ? 0xEDB88320u : 0u);
    }
    return ~crc;
}

uint32_t tm_crc32(const void *data, size_t len)
{
    return tm_crc32_update(0, data, len);
}
