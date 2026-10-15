/* minijson_file -- write a finished minijson document to a file (libminijson_file). */
#ifndef MINIJSON_FILE_H
#define MINIJSON_FILE_H

#include "minijson.h"

#ifdef __cplusplus
extern "C" {
#endif

/* Writes the document and a newline to path through path.tmp, so readers never see half a
 * file.  "-" is standard output.  0 on success, -1 with errno set. */
int mj_write_file(const mj_writer *w, const char *path);

#ifdef __cplusplus
}
#endif

#endif
