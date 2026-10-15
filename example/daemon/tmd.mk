# tmd -- the telemetry daemon.  Reads `metric value` lines, keeps a window per metric, raises an
# alarm when a metric crosses its threshold, and writes JSON snapshots.
#
# Shows how far one .mk goes:
#   LDLIBS       an in-tree C++ library, a third-party library gm compiles, one a vendor's
#                Makefile builds (libminijson_file is one of its artefacts), and a library
#                generated from pkg.yaml.  gm derives each edge (make show-tmd) and builds them
#                first; headers are not inherited, so the -I flags are spelled out.
#   PKG_HEADERS  `yes`: the component.h of every package that ships tmd -- gm finds pkg-tmd --
#                and a versionstamp in the binary: strings tmd | grep GM_VERSIONSTAMP

CXXSOURCE   += main.cxx config.cxx report.cxx
CCFLAGS     += -I$(PROJ_TOP)/example/core/include \
               -I$(PROJ_TOP)/example/stats/include \
               -I$(PROJ_TOP)/third_party/ini/vendor/include \
               -I$(PROJ_TOP)/third_party/minijson/vendor/include
LDLIBS      += -ltmstats -ltmalarms -lini -lminijson -lminijson_file -ltmcore
PKG_HEADERS := yes
