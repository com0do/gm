// alarms_demo -- consumes pkg-p2's auto-generated alarm library.
// Prints the whole alarm table + shows enum access by name.
#include <cstdio>
#include <pkg-p2/alarms.h>

int main() {
    using namespace gm_alarms_pkg_p2;

    printf("pkg-p2 has %zu alarm(s):\n", alarms_count);
    for (size_t i = 0; i < alarms_count; ++i) {
        printf("  [%u] %-24s type=%-13s sev=%s\n",
               alarms[i].number, alarms[i].name,
               alarms[i].type, alarms[i].severity);
    }
    printf("\nenum access: kP2ConfigMissing=%u  kP2BackendUnreachable=%u\n",
           kP2ConfigMissing, kP2BackendUnreachable);
    return 0;
}
