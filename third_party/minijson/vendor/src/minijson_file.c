/* minijson_file.c -- write a finished document to a file, atomically. */
#include "minijson_file.h"

#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

int mj_write_file(const mj_writer *w, const char *path)
{
    const char *doc = mj_result(w);
    char *tmp;
    FILE *f;
    int rc = 0;

    if (!doc) {
        errno = EINVAL;
        return -1;
    }
    if (strcmp(path, "-") == 0)
        return (fputs(doc, stdout) < 0 || fputc('\n', stdout) == EOF) ? -1 : 0;

    tmp = malloc(strlen(path) + 5);
    if (!tmp)
        return -1;
    strcpy(tmp, path);
    strcat(tmp, ".tmp");
    f = fopen(tmp, "w");
    if (!f) {
        free(tmp);
        return -1;
    }
    if (fputs(doc, f) < 0 || fputc('\n', f) == EOF)
        rc = -1;
    if (fclose(f) != 0)
        rc = -1;
    if (rc == 0 && rename(tmp, path) != 0)
        rc = -1;
    if (rc != 0)
        remove(tmp);
    free(tmp);
    return rc;
}
