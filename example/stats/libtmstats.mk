# libtmstats -- summary statistics over a sliding window (C++, shared library).
#
# Shows:
#   - a shared library (the default LIB_KIND) built on a static one: `-ltmcore` is all it takes.
#     gm reads it, records `libtmstats: libtmcore` (make show-libtmstats) and builds libtmcore
#     first.  Headers are not inherited: the -I below is spelled out.
#   - PKG_HEADERS := yes: two packages ship this library (pkg-tmd and pkg-tm-devel); gm finds
#     both and puts their generated component.h on the include path (see src/window.cxx).

CXXSOURCE   += summary.cxx window.cxx
CCFLAGS     += -I$(PROJ_TOP)/example/core/include
LDLIBS      += -ltmcore
PKG_HEADERS := yes
