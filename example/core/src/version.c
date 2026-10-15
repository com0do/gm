/* version.c -- what this build of the library is.  tm_build.h is generated (libtmcore.mk). */
#include <tm/core.h>
#include <tm_build.h>

const char *tm_core_version(void)
{
    return "libtmcore " TM_VERSION " (" TM_BUILD_MODE ", built " TM_BUILD_DATE " on " TM_BUILD_HOST ")";
}
