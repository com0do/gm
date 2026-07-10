# libfoowrap.mk -- wraps `vendor/` (a pristine 3rd-party tree).
# No .mk lives inside vendor/; upstream syncs stay clean.
# Pattern:
#   vpath   -> where gm looks up CSOURCE entries
#   -I in CFLAGS/CCFLAGS -> 3rd-party's headers
#   filter-out -Werror + -Wno-* -> relax warnings per-target only
# $(CURDIR) is where the sub-make -C'd to (= this .mk's dir).
# $(MAKEFILE_DIR) is a framework var set later, so unusable here.
VENDORED := $(CURDIR)/vendor

vpath %.c $(VENDORED)/src

CSOURCE += foo.c foo_helper.c

CFLAGS  += -I$(VENDORED)/include
CCFLAGS += -I$(VENDORED)/include

# Product code keeps strict flags; only this wrapper is relaxed.
CFLAGS  := $(filter-out -Werror,$(CFLAGS))
CFLAGS  += -Wno-unused-variable -Wno-unused-function
