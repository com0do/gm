# tmctl -- the command-line tool (C).
#
# Shows: a C executable on a static in-tree library plus a system library.  -lm (sin) comes with
# the C library's development package, so the example needs nothing beyond the compiler.

CSOURCE += tmctl.c
CFLAGS  += -I$(PROJ_TOP)/example/core/include
LDLIBS  += -ltmcore -lm
