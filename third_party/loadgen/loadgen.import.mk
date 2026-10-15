# loadgen -- a load generator from another team, built by its own Makefile.
#
# Shows: an import that is an executable (the name has no lib prefix): it lands in
# $(GM_EXEC_DIR) and `make run-loadgen RUN_ARGS='cpu.load 0.5'` works like for any exe.

VENDOR          := $(CURDIR)/vendor
IMPORT_ARTIFACT := $(VENDOR)/build/loadgen

.PHONY: _vendor_build
_vendor_build:
	@$(MAKE) -qC $(VENDOR) 2>/dev/null && exit 0 ; \
	 $(ECHO) "  VENDOR  $(TARGET) (via $(notdir $(VENDOR))/Makefile)" ; \
	 $(MAKE) -sC $(VENDOR)

$(IMPORT_ARTIFACT): _vendor_build
