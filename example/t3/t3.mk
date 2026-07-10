
# Cross-target includes (other libs' include/ trees) -- explicit.
# Local sources sit in MAKEFILE_DIR and are auto-vpath'd.
CCFLAGS   += -I$(PROJ_TOP)/example/t1/include \
             -I$(PROJ_TOP)/example/t2/include \
             -DBASE64_WITH_INITIALIZATION

CXXSOURCE += t3.cxx
LDLIBS    += -lcrypto -lt1 -lt2

# -L for in-tree libs is added centrally by flags.mk (-L$(GM_LIB_DIR)).
# No need to re-add it here.
