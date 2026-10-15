# test-tmstats -- unit tests for libtmstats.  ../include is on the include path by itself;
# tm/stats.hpp includes libtmcore's header, so that directory is added here.

CXXSOURCE += test_tmstats.cxx
CCFLAGS   += -I$(PROJ_TOP)/example/core/include
LDLIBS    += -ltmstats
