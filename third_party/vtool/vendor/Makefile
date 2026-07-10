CC ?= gcc
BUILDDIR := $(CURDIR)/build
BIN := $(BUILDDIR)/vtool

.PHONY: all clean
all: $(BIN)

$(BIN): src/vtool.c | $(BUILDDIR)
	$(CC) -O2 -Wall -o $@ $<

$(BUILDDIR):
	mkdir -p $@

clean: ; rm -rf $(BUILDDIR)
