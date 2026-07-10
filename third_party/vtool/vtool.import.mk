# vtool.import.mk -- black-box EXE import.  Basename has no `lib`
# prefix -> classifier -> import-exe -> staged into GM_EXEC_DIR.
VENDOR          := $(CURDIR)/vendor
IMPORT_ARTIFACT := $(VENDOR)/build/vtool

.PHONY: _vendor_build
_vendor_build:
	@$(MAKE) -qC $(VENDOR) 2>/dev/null && exit 0 ; \
	 $(ECHO) "  VENDOR  $(TARGET) (via $(notdir $(VENDOR))/Makefile)" ; \
	 $(MAKE) -sC $(VENDOR)

$(IMPORT_ARTIFACT): _vendor_build
