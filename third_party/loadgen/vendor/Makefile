# loadgen's own build.  gm does not touch this file.
CC     ?= cc
CFLAGS ?= -O2 -Wall

BUILDDIR := $(CURDIR)/build
BIN      := $(BUILDDIR)/loadgen

.PHONY: all clean
all: $(BIN)

$(BIN): src/loadgen.c | $(BUILDDIR)
	$(CC) $(CFLAGS) -o $@ $<

$(BUILDDIR):
	mkdir -p $@

clean:
	rm -rf $(BUILDDIR)
