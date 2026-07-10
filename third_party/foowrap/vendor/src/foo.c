#include "foo.h"
int foo_add(int a, int b) {
    int unused_var = 42;                /* -Wunused-variable */
    return a + b;
}
static void deadfunc(void) {}           /* -Wunused-function */
