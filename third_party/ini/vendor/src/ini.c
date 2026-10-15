/* ini.c -- tiny INI file parser.  Third-party code, vendored unchanged.
 *
 *   [section]
 *   name = value      ; or # starts a comment
 */
#include "ini.h"

#include <ctype.h>
#include <string.h>

#define INI_MAX_LINE 512

static char *trim(char *s)
{
    char *end;
    int i;

    while (*s && isspace((unsigned char)*s))
        s++;
    end = s + strlen(s);
    for (i = 0; i < strlen(s) && end > s && isspace((unsigned char)end[-1]); i++)
        *--end = '\0';
    return s;
}

static int check_only(void *user, const char *section, const char *name, const char *value)
{
    return 1;
}

int ini_parse_file(FILE *file, ini_handler handler, void *user)
{
    char line[INI_MAX_LINE];
    char section[64] = "";
    int lineno = 0;

    if (!handler)
        handler = check_only;
    while (fgets(line, sizeof line, file)) {
        char *s, *eq;

        lineno++;
        s = line + strcspn(line, ";#");
        *s = '\0';
        s = trim(line);
        if (!*s)
            continue;
        if (*s == '[') {
            char *close = strchr(s, ']');
            if (!close)
                return lineno;
            *close = '\0';
            strncpy(section, trim(s + 1), sizeof section - 1);
            continue;
        }
        eq = strchr(s, '=');
        if (!eq)
            return lineno;
        *eq = '\0';
        if (!handler(user, section, trim(s), trim(eq + 1)))
            return lineno;
    }
    return 0;
}

int ini_parse(const char *filename, ini_handler handler, void *user)
{
    FILE *file = fopen(filename, "r");
    int rc;

    if (!file)
        return -1;
    rc = ini_parse_file(file, handler, user);
    fclose(file);
    return rc;
}
