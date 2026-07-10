# SPDX-License-Identifier: MIT
#
# target.import.mk -- prebuilt-artefact import path.
#
# Dispatched to (by project.mk's _CLASSIFY) for any `.import.mk`
# file.  gm skips compile+link entirely and just symlinks the
# vendor-produced artefact(s) into the right output dir.
#
# `IMPORT_ARTIFACT` is one or MORE vendor product paths (space-
# separated).  The recipe that BUILDS them is on the user -- typically
# `$(MAKE) -C vendor` or `cmake --build vendor/build`.  Treat vendor
# as a BLACK BOX; don't enumerate its sources for gm mtime tracking.
# See third_party/vlib (mixed: libvlib.so + libvlib_extra.so) and
# third_party/vtool (exe).
#
# Per-artefact routing (below): `.so` / `.a` -> $(GM_LIB_DIR), else
# -> $(GM_EXEC_DIR).  One .mk can freely mix libs + exes; the
# import-lib / import-exe classification (from `lib*.import.mk`
# naming) only decides DRY_RUN loop order and `run-<name>`
# availability, NOT where individual artefacts land.
#
# Reverse lookup (pkg.yaml referencing an artefact -> owning .mk) is
# written to $(GM_IMPORT_OF_FILE) in DRY_RUN below.


CURRENT_FILE := $(lastword $(abspath $(MAKEFILE_LIST)))
MAKEFILE     := $(lastword $(filter-out $(ADMIN_DIR)/make/% ,$(abspath $(MAKEFILE_LIST))))
TARGET       := $(patsubst %.import,%,$(basename $(notdir $(MAKEFILE))))
MAKEFILE_DIR := $(abspath $(dir $(MAKEFILE)))
include $(ADMIN_DIR)/make/target.common.mk

_IMPORT_NAME = $(strip $(patsubst %.a,%,$(patsubst %.so,%,$(notdir $(1)))))
_IMPORT_DIR = $(strip \
    $(if $(filter %.so %.a,$(notdir $(1))),$(GM_LIB_DIR),$(GM_EXEC_DIR)))

ifeq ($(DRY_RUN),1)
$(shell mkdir -p $(dir $(GM_IMPORT_OF_FILE)) ; touch $(GM_IMPORT_OF_FILE))
$(shell sed -i '/:= $(TARGET)$$/d' $(GM_IMPORT_OF_FILE))
$(foreach a,$(IMPORT_ARTIFACT), \
    $(shell printf 'IMPORT_OF_%s := %s\n' '$(call _IMPORT_NAME,$(a))' '$(TARGET)' \
            >> $(GM_IMPORT_OF_FILE)))
DRY_DEPS := $(strip \
    $(filter $(patsubst -l%,lib%,$(LDLIBS)),$(TARGET_ALL)) \
    $(patsubst %,%-header,$(filter $(PKG_HEADERS),$(TARGET_ALL))))
include $(ADMIN_DIR)/make/target.dry-run.mk

else # real build --------------------------------------------------

ifeq ($(strip $(IMPORT_ARTIFACT)),)
$(error $(MAKEFILE): target.import.mk requires IMPORT_ARTIFACT to be set)
endif

# Vendor source-tree roots for dep-tracking hints.  Since vendor is a
# BLACK BOX (we don't `find` its sources), user declares which
# directories dep_query.py should treat as "any change under here
# invalidates my artefact".  Default: $(VENDOR) if set -- that's the
# convention in third_party/vlib/*.import.mk.  pydep uses filesystem
# `is_dir()` at load time to identify directory deps; trailing `/`
# is optional (and NOT normalized here).
IMPORT_SRC_DIRS ?= $(VENDOR)

# Each artefact gets its own dest via _IMPORT_DIR (suffix-routed).
_TARGET_PATHS := $(foreach a,$(IMPORT_ARTIFACT),$(call _IMPORT_DIR,$(a))/$(notdir $(a)))

# DEP_TREE=yes: emit a .dep.json for the import target so dep_query.py
# can propagate vendor-source changes to downstream consumers.  The
# json lists (1) the .import.mk file itself, (2) IMPORT_SRC_DIRS as
# directory-prefix deps (pydep expands "path/" to mean "any file under
# path/"), (3) every IMPORT_ARTIFACT.  `file:` is the phony's primary
# artefact staging path (first entry in _TARGET_PATHS).
ifeq ($(DEP_TREE),yes)
DEP_JSON_LINK  := $(OUT_DIR)/$(TARGET).dep.json
DEP_JSON_ALL   := $(DEP_JSON_LINK)
_DEP_JSON_ITEMS := $(MAKEFILE) $(IMPORT_SRC_DIRS) $(_TARGET_PATHS)
else
DEP_JSON_LINK  :=
DEP_JSON_ALL   :=
endif

$(TARGET) :: $(_TARGET_PATHS) $(DEP_JSON_ALL) ;

define _import_rule
$(call _IMPORT_DIR,$(1))/$(notdir $(1)): $(1) | $(call _IMPORT_DIR,$(1))
	@$$(ECHO) "  IMPORT  $$(notdir $$@)  ($$(patsubst $$(PROJ_TOP)/%,%,$$(dir $(1))))"
	$$(Q)$$(LN) $(1) $$@
endef
$(foreach a,$(IMPORT_ARTIFACT),$(eval $(call _import_rule,$(a))))

ifeq ($(DEP_TREE),yes)
$(DEP_JSON_LINK): $(_TARGET_PATHS) $(GM_FRAMEWORK_MK) | $(OUT_DIR)
	$(V_JSON)
	$(Q)printf '%s\n' $(_DEP_JSON_ITEMS) \
	    | jq -R . | jq -s --arg f '$(firstword $(_TARGET_PATHS))' \
	                     '{file: $$f, deps: .}' > $@
endif

# Both output dirs may be created by a mixed-artefact import.
# ($(OUT_DIR) intentionally omitted -- dispatcher passes it as one of
#  $(GM_LIB_DIR)/$(GM_EXEC_DIR), so mentioning it again here would
#  fire GNU make's "target given more than once in the same rule"
#  warning at every idle build.)
$(GM_LIB_DIR) $(GM_EXEC_DIR):
	$(Q)$(MKDIR) $@

clean:
	$(Q)$(RM) $(_TARGET_PATHS) $(DEP_JSON_LINK)
	$(V_CLEAN)


endif # DRY_RUN
