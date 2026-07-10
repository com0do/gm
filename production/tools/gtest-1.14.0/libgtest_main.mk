
# Default main() for test binaries -- linked automatically by
# target.c.mk's test branch (unless the test declares TEST_HAS_MAIN=1
# to provide its own main).  Just gtest_main.cpp linked against libgtest.
#
# See libgtest.mk for the src/include auto-wiring rationale.

CPPSOURCE += gtest_main.cpp
CCFLAGS   += -pthread -Wno-unused-parameter
LDLIBS    += -lgtest
LDFLAGS   += -pthread
