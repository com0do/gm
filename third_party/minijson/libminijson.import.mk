# libminijson -- a third-party JSON writer with its own Makefile.  gm does not look inside
# vendor/: it runs the vendor's make and publishes what comes out.
#
# Shows: one .import.mk exporting several artefacts, each routed by its suffix:
#   libminijson.so, libminijson.a  -> $(GM_LIB_DIR)   (shared and static, one name)
#   libminijson_file.so            -> $(GM_LIB_DIR)   (another name: pkg-tmd ships it, and gm
#                                                      maps it back to this target, build/import_of.mk)
#   jsonpp                         -> $(GM_EXEC_DIR)  (a tool)
# Consumers link it like an in-tree library: `LDLIBS += -lminijson` builds them after it.  The
# vendor's make gets gm's compiler as CC, and none of gm's own variables.

VENDOR          := $(CURDIR)/vendor
IMPORT_ARTIFACT := $(VENDOR)/build/libminijson.so \
                   $(VENDOR)/build/libminijson.a \
                   $(VENDOR)/build/libminijson_file.so \
                   $(VENDOR)/build/jsonpp

# The vendor's make decides what is out of date: `make -q` asks it, a real run only when needed.
.PHONY: _vendor_build
_vendor_build:
	@$(MAKE) -qC $(VENDOR) 2>/dev/null && exit 0 ; \
	 $(ECHO) "  VENDOR  $(TARGET) (via $(notdir $(VENDOR))/Makefile)" ; \
	 $(MAKE) -sC $(VENDOR)

$(IMPORT_ARTIFACT): _vendor_build
