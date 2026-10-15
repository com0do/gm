# minijson's own build.  gm does not touch this file.
CC     ?= cc
AR     ?= ar
CFLAGS ?= -O2 -fPIC -Wall

BUILDDIR := $(CURDIR)/build
LIB_SO   := $(BUILDDIR)/libminijson.so
LIB_A    := $(BUILDDIR)/libminijson.a
FILE_SO  := $(BUILDDIR)/libminijson_file.so
JSONPP   := $(BUILDDIR)/jsonpp

.PHONY: all clean
all: $(LIB_SO) $(LIB_A) $(FILE_SO) $(JSONPP)

$(BUILDDIR)/minijson.o: src/minijson.c include/minijson.h | $(BUILDDIR)
	$(CC) $(CFLAGS) -Iinclude -c -o $@ $<

$(LIB_SO): $(BUILDDIR)/minijson.o
	$(CC) -shared -Wl,-soname,libminijson.so -o $@ $^ -lm

$(LIB_A): $(BUILDDIR)/minijson.o
	$(AR) rcsD $@ $^

# Installed next to libminijson.so, so it finds it through $ORIGIN.
$(FILE_SO): src/minijson_file.c include/minijson_file.h $(LIB_SO)
	$(CC) $(CFLAGS) -Iinclude -shared -Wl,-soname,libminijson_file.so -Wl,-rpath,'$$ORIGIN' \
	    -o $@ $< -L$(BUILDDIR) -lminijson

$(JSONPP): src/jsonpp.c | $(BUILDDIR)
	$(CC) $(CFLAGS) -o $@ $<

$(BUILDDIR):
	mkdir -p $@

clean:
	rm -rf $(BUILDDIR)
