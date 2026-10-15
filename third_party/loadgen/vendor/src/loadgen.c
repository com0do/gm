/* loadgen -- print `metric value` lines: noise around a base value with occasional spikes.
 *
 *   loadgen METRIC BASE [COUNT [SEED]]
 *
 * The same seed gives the same lines, so a run can be reproduced. */
#include <stdio.h>
#include <stdlib.h>

static unsigned long state;

static double next_unit(void) /* [0, 1) */
{
    state = state * 6364136223846793005UL + 1442695040888963407UL;
    return (double)(state >> 11) / 9007199254740992.0;
}

int main(int argc, char **argv)
{
    double base;
    long count = 200;

    if (argc < 3 || argc > 5) {
        fputs("usage: loadgen METRIC BASE [COUNT [SEED]]\n", stderr);
        return 2;
    }
    base = atof(argv[2]);
    if (argc >= 4)
        count = atol(argv[3]);
    state = argc == 5 ? strtoul(argv[4], NULL, 10) : 42;

    for (long i = 0; i < count; i++) {
        double v = base * (0.8 + 0.4 * next_unit());
        if (next_unit() < 0.03) /* a spike now and then */
            v = base * (1.8 + next_unit());
        printf("%s %.4f\n", argv[1], v);
    }
    return 0;
}
