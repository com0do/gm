/* tmctl -- command-line companion of tmd.
 *
 *   tmctl crc FILE...                 CRC-32 of each file, with libtmcore
 *   tmctl wave METRIC N [AMPLITUDE]   N samples of a sine wave around 50, for feeding tmd
 *   tmctl version                     the libtmcore it was built with
 */
#include <tm/core.h>

#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int usage(void)
{
    fputs("usage: tmctl crc FILE...\n"
          "       tmctl wave METRIC N [AMPLITUDE]\n"
          "       tmctl version\n",
          stderr);
    return 2;
}

static int crc_file(const char *path)
{
    unsigned char buf[65536];
    uint32_t crc = 0;
    size_t n;
    FILE *f = fopen(path, "rb");

    if (!f) {
        perror(path);
        return 1;
    }
    while ((n = fread(buf, 1, sizeof buf, f)) > 0)
        crc = tm_crc32_update(crc, buf, n);
    if (ferror(f)) {
        perror(path);
        fclose(f);
        return 1;
    }
    fclose(f);
    printf("%08x  %s\n", (unsigned)crc, path);
    return 0;
}

static int wave(const char *metric, long n, double amplitude)
{
    const double pi = 3.14159265358979323846;

    for (long i = 0; i < n; i++)
        printf("%s %.3f\n", metric, 50.0 + amplitude * sin(2 * pi * (double)i / 60.0));
    return 0;
}

int main(int argc, char **argv)
{
    if (argc >= 3 && strcmp(argv[1], "crc") == 0) {
        int rc = 0;
        for (int i = 2; i < argc; i++)
            rc |= crc_file(argv[i]);
        return rc;
    }
    if ((argc == 4 || argc == 5) && strcmp(argv[1], "wave") == 0) {
        char *end;
        long n = strtol(argv[3], &end, 10);
        if (*end || n < 0)
            return usage();
        return wave(argv[2], n, argc == 5 ? atof(argv[4]) : 40.0);
    }
    if (argc == 2 && strcmp(argv[1], "version") == 0) {
        puts(tm_core_version());
        return 0;
    }
    return usage();
}
