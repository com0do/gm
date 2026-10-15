/* jsonpp -- pretty-print JSON from standard input, two spaces per level. */
#include <stdio.h>

static void newline(int depth)
{
    putchar('\n');
    for (int i = 0; i < depth; i++)
        fputs("  ", stdout);
}

int main(void)
{
    int c, depth = 0, in_string = 0, escaped = 0;

    while ((c = getchar()) != EOF) {
        if (in_string) {
            putchar(c);
            if (escaped)
                escaped = 0;
            else if (c == '\\')
                escaped = 1;
            else if (c == '"')
                in_string = 0;
            continue;
        }
        switch (c) {
        case '"':
            in_string = 1;
            putchar(c);
            break;
        case '{':
        case '[':
            putchar(c);
            newline(++depth);
            break;
        case '}':
        case ']':
            newline(--depth);
            putchar(c);
            break;
        case ',':
            putchar(c);
            newline(depth);
            break;
        case ':':
            fputs(": ", stdout);
            break;
        case ' ':
        case '\t':
        case '\n':
        case '\r':
            break;
        default:
            putchar(c);
        }
    }
    putchar('\n');
    return 0;
}
