/* Small companion CLI shipped by vlib's vendor build.  Purpose is
 * purely demonstrative: a single .import.mk (libvlib.import.mk) is
 * shown here exporting a MIX of artefacts -- libvlib.so /
 * libvlib_extra.so (shared libs) + vtool2 (an executable) -- so gm's
 * per-artefact routing in target.import.mk lands each in the right
 * output directory (GM_LIB_DIR vs GM_EXEC_DIR) despite them coming
 * from the same mk.  See docs/1-USER_GUIDE.md §3.10. */
#include <stdio.h>

int main(void) {
    printf("vtool2 -- companion CLI to libvlib, "
           "packaged alongside via the same .import.mk\n");
    return 0;
}
