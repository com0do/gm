#include "vlib.h"

/* Small companion routine shipped alongside libvlib.so.  Exists to
 * demonstrate a vendor Makefile producing multiple in-tree artefacts
 * from one .import.mk -- see third_party/vlib/libvlib.import.mk's
 * `IMPORT_ARTIFACT := ... libvlib.so ... libvlib_extra.so` and how
 * pkg-p3.yaml references libvlib_extra.so directly (the DAG resolves
 * it back to `libvlib` via IMPORT_OF_<name>, so the pkg still lists
 * `libvlib` as its dep). */
int vlib_extra(int n) { return vlib_calc(n, 42); }
