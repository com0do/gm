# Vendor's own build system.  gm does NOT touch this file.
CC ?= gcc
AR ?= ar
CFLAGS ?= -O2 -fPIC -Wall

BUILDDIR := $(CURDIR)/build

# vlib ships in BOTH shared and static form -- same basename
# (`libvlib`), different suffix.  Used as a stress test for gm's
# multi-artefact import handling (`.so` + `.a` under one .import.mk;
# per-artefact routing keeps them both under $(GM_LIB_DIR); the
# reverse-lookup map `IMPORT_OF_libvlib := libvlib` gets written
# twice from the same value, harmless once sort -u dedupes).
LIB_SO   := $(BUILDDIR)/libvlib.so
LIB_A    := $(BUILDDIR)/libvlib.a
EXTRA_SO := $(BUILDDIR)/libvlib_extra.so
VTOOL2   := $(BUILDDIR)/vtool2

.PHONY: all clean
all: $(LIB_SO) $(LIB_A) $(EXTRA_SO) $(VTOOL2)


$(LIB_SO): src/vlib.c include/vlib.h | $(BUILDDIR)
	$(CC) $(CFLAGS) -Iinclude -shared -Wl,-soname,libvlib.so -o $@ $<

$(LIB_A): src/vlib.c include/vlib.h | $(BUILDDIR)
	$(CC) $(CFLAGS) -Iinclude -c -o $(BUILDDIR)/vlib.o $<
	$(AR) rcs $@ $(BUILDDIR)/vlib.o

$(EXTRA_SO): src/vlib_extra.c include/vlib.h $(LIB_SO) | $(BUILDDIR)
	$(CC) $(CFLAGS) -Iinclude -shared -Wl,-soname,libvlib_extra.so -o $@ $< -L$(BUILDDIR) -Wl,-rpath,$(BUILDDIR) -lvlib

$(VTOOL2): src/vtool2.c | $(BUILDDIR)
	$(CC) -O2 -Wall -o $@ $<

$(BUILDDIR):
	mkdir -p $@

clean:
	rm -rf $(BUILDDIR)
