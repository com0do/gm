
# LIB_KIND selects the artefact form; `shared` is the default so a
# plain lib .mk needs no knob at all.  The artefact is always named
# after this file (libt1.a) -- gm has no rename knob, see
# target.c.mk's "artifact name is NOT configurable" block.
LIB_KIND := static

# Header generation: any *.h.in under this dir becomes a .h in BUILD_DIR.
# Default substitutions cover TARGET / BUILD_MODE / BUILD_ARCH / BUILD_DATE
# / BUILD_HOST; declare custom ones by adding to HEADER_GEN_VARS.
HEADER_GEN_VARS += PROJECT_VERSION VENDOR
PROJECT_VERSION := 1.0.0
VENDOR          := cyrus

# vpath into a non-conventional sibling directory; <srcdir>/src is
# auto-wired by target.c.mk, only spell out the cross-target one.
vpath %.cxx $(PROJ_TOP)/example/vpath/src
vpath %.c   $(PROJ_TOP)/example/vpath/src

CCFLAGS   += -DBASE64_WITH_INITIALIZATION

CXXSOURCE += t1.cxx
CSOURCE   += t11.c
LDLIBS    += -lcrypto

LDFLAGS   += -L$(PROJ_TOP)/tools/rhlinux/usr/lib64
