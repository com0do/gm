# libini -- a small third-party INI parser, vendored as pristine sources under vendor/ and
# compiled by gm (no .mk inside vendor/: an upstream update is a plain copy).
#
# Shows: building sources that live in another directory (vpath), and relaxing gm's strict
# warnings for this one target.  The product keeps -Werror; upstream code is not ours to fix.
# $(CURDIR) is this .mk's directory (the sub-make runs there).

LIB_KIND := static
VENDORED := $(CURDIR)/vendor
vpath %.c $(VENDORED)/src

CSOURCE  += ini.c
CFLAGS   += -I$(VENDORED)/include
CFLAGS   := $(filter-out -Werror,$(CFLAGS))
CFLAGS   += -Wno-unused-parameter -Wno-sign-compare
