
# Test target for the libt1 static archive.  See test-t2.mk for the
# convention rundown -- this .mk stays this minimal because
# target.c.mk auto-wires the gtest deps and the parent lib's
# include/ directory.

CXXSOURCE += test_t1.cxx
LDLIBS    += -lt1
