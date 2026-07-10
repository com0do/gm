
# GoogleTest as a gm-managed shared library.  Any `test-*` target
# links against it automatically via target.c.mk's test branch
# (`LDLIBS += -lgtest -lgtest_main -lpthread`).
#
# Type-classification is filename-driven:
#   * .mk basename `libgtest.mk` -> target name `libgtest`
#     (framework derives the library name from the filename)
#   * No AR_NAME assignment -> shared-only .so (target.c.mk's lib
#     branch defaults to shared when no static knob is set)
#
# Include-path / vpath boilerplate is auto-provided by target.c.mk's
# src/include convention:
#   * `src/gtest-all.cpp` picked up by the sibling-src vpath
#   * `include/` auto-added to -I via CONV_INC_DIR
#   * `-I$(MAKEFILE_DIR)` always in the include path
#     (so gtest-all.cpp's `#include "src/gtest-xxx.cc"` resolves)
#
# The `.cc` -> `.cpp` rename: gm's target.c.mk accepts .cxx or .cpp
# extensions but not .cc.  Renaming gtest-all.cc to gtest-all.cpp
# keeps it in scope of the standard convention without a third
# source extension carve-out.  Semantically identical.

CPPSOURCE += gtest-all.cpp
CCFLAGS   += -pthread -Wno-unused-parameter
LDFLAGS   += -pthread
