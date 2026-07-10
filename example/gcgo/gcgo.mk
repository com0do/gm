# gcgo -- Go binary using cgo to call an in-tree C library (libt1).
#
# LDLIBS declares the in-tree dep the same way a C target would;
# project.mk builds libt1 first, and target.go.mk exports
# `CGO_LDFLAGS=-L$(GM_LIB_DIR) -Wl,-rpath,$(GM_LIB_DIR)` so the `#cgo
# LDFLAGS: -lt1` in main.go resolves against the freshly-built
# libt1.a.  The `-I$${SRCDIR}/../t1/include` in the .go source
# points cgo at libt1's public header.
GO_PROJ_ROOT := $(PROJ_TOP)/example/gcgo
LDLIBS       += -lt1
