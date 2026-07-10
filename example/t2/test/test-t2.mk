
# gtest-driven unit test for libt2.  Test targets in gm follow the
# convention:
#
#   * live in a `test/` subdirectory next to the lib under test
#   * `.mk` basename starts with `test-` -> classified TYPE=test
#   * compiled by target.c.mk's test branch -- same CFLAGS, includes,
#     and dep.json machinery as any exe / lib
#
# What `target.c.mk` auto-injects for TYPE=test (so this .mk stays minimal):
#   * `-lgtest -lgtest_main -lpthread`   in LDLIBS
#   * `-I$(GTEST_ROOT)/include`          in CCFLAGS
#   * `-std=c++17`                       (gtest 1.14 requires >= C++14)
#   * `-I<makefile_dir>/../include`      (the lib under test's public headers)
#
# The last bit means we don't have to spell out `-I.../t2/include` here.
# All we need is: what to compile, and what lib to link.

CXXSOURCE += test_t2.cxx
LDLIBS    += -lt2

# Pull in pkg-p2's auto-generated component.h so the test can
# assert on pkg identity (see test_t2.cxx).  A test binary isn't
# packaged, so `PKG_HEADERS := yes` (derive from pkg.yaml) would
# see no pkg for us -- use the explicit-list escape hatch.
PKG_HEADERS := pkg-p2
