


#pragma once

/* Header is included from both C++ TUs (t1_cxx) and cgo's C
 * preprocessor (example/gcgo).  Guard extern "C" so the C side
 * sees a plain declaration. */
#ifdef __cplusplus
int t1_cxx(int a);
/* One-shot demo of HEADER_GEN_VARS: prints the T1_* macros substituted
 * from t1_buildinfo.h.in.  Called by t3's main() only -- library
 * consumers (incl. tests) don't invoke this, so t1_cxx() stays pure. */
void t1_dump_buildinfo();
extern "C" {
#endif

int t1_c(int a);

#ifdef __cplusplus
}
#endif
