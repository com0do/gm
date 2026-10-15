/* ini.h -- tiny INI file parser.  Third-party code, vendored unchanged. */
#ifndef INI_H
#define INI_H

#include <stdio.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Called for each `name = value`.  Return non-zero to go on, zero to stop with an error. */
typedef int (*ini_handler)(void *user, const char *section, const char *name, const char *value);

/* 0 on success, the number of the first bad line, or -1 when the file cannot be opened.
 * A NULL handler only checks the syntax. */
int ini_parse(const char *filename, ini_handler handler, void *user);
int ini_parse_file(FILE *file, ini_handler handler, void *user);

#ifdef __cplusplus
}
#endif

#endif
