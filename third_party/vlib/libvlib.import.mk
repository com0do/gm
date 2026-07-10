# libvlib.import.mk -- gm-side wrapper for a vendored 3rd-party lib
# whose source tree has its OWN build system (Makefile/CMake/etc.).
#
# Classification: `.import.mk` suffix + `lib*` prefix -> import-lib
# (used for DRY_RUN loop ordering + `run-<name>` availability, NOT
# for per-artefact routing -- see target.import.mk).  Actual staging
# dir is decided per-artefact by suffix.
#
# Vendor is a BLACK BOX.  We do NOT enumerate vendor's sources with
# `find` -- that would second-guess vendor's own dep logic (missed
# generated files, transitive includes, etc.).  Instead a phony
# anchor runs vendor's build unconditionally under `make -q`; if
# vendor has nothing to do, gm stays silent; if vendor produces a
# new artefact, gm sees the fresh mtime and re-stages the symlink.
#
# Demoed here (all four in one mk):
#   libvlib.so        -> $(GM_LIB_DIR)  (main shared lib)
#   libvlib.a         -> $(GM_LIB_DIR)  (same basename as .so, static)
#   libvlib_extra.so  -> $(GM_LIB_DIR)  (extra shared, different basename)
#   vtool2            -> $(GM_EXEC_DIR) (exec, per-suffix routing wins)

VENDOR          := $(CURDIR)/vendor
IMPORT_ARTIFACT := $(VENDOR)/build/libvlib.so \
                   $(VENDOR)/build/libvlib.a  \
                   $(VENDOR)/build/libvlib_extra.so \
                   $(VENDOR)/build/vtool2

.PHONY: _vendor_build
_vendor_build:
	@$(MAKE) -qC $(VENDOR) 2>/dev/null && exit 0 ; \
	 $(ECHO) "  VENDOR  $(TARGET) (via $(notdir $(VENDOR))/Makefile)" ; \
	 $(MAKE) -sC $(VENDOR)

$(IMPORT_ARTIFACT): _vendor_build
