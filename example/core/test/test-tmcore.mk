# test-tmcore -- unit tests for libtmcore.
#
# Shows: a test target.  The test- prefix makes it a gtest executable: gm links gtest and
# gtest_main and puts the library's include/ (../include) on the include path, so the .mk only
# names its source and the library under test.  `make test` builds and runs every test;
# `make test TESTS=test-tmcore` just this one.

CXXSOURCE += test_tmcore.cxx
LDLIBS    += -ltmcore
