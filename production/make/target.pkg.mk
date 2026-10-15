# SPDX-License-Identifier: MIT
#
# target.pkg.mk -- RPM packaging rules.  Two modes:
#   MODE A (plain) -- PKG_SPEC is a hand-written .spec; PKG_FILES /
#                     PKG_EXTRA_FILES stage via cp+dep-hooks into
#                     rpmbuild's SOURCES/, hooks.jsonl captures src.
#   MODE B (YAML)  -- PKG_YAML activates; pkg-build.py validates the
#                     yaml against production/make/schemas/pkg.schema.yaml,
#                     emits manifest.json + generated .spec that installs
#                     from absolute src paths; rpmbuild log parsed by
#                     pkgdeps.py for the dep.json.
# Auto-generated specs have NO %build section -- make owns the build
# phase.  See the PKG_HEADERS auto-inherit block below for how a lib's
# pkg-identity #defines get wired in.


CURRENT_FILE := $(lastword $(abspath $(MAKEFILE_LIST)))
MAKEFILE     := $(lastword $(filter-out $(ADMIN_DIR)/make/% ,$(abspath $(MAKEFILE_LIST))))
TARGET       := $(basename $(notdir $(MAKEFILE)))
MAKEFILE_DIR := $(abspath $(dir $(MAKEFILE)))

GM_FRAMEWORK_MK := $(GM_FRAMEWORK_CORE_MK) \
    $(CURRENT_FILE) \
    $(ADMIN_DIR)/make/scripts/pkgdeps.py \
    $(ADMIN_DIR)/make/scripts/pkg-build.py \
    $(ADMIN_DIR)/make/scripts/pkg-debuginfo.spec.inc \
    $(ADMIN_DIR)/make/scripts/elf-rpath.py \
    $(ADMIN_DIR)/make/scripts/strip-deterministic \
    $(ADMIN_DIR)/make/schemas/pkg.schema.yaml \
    $(ADMIN_DIR)/tools/dep-hooks.sh

include $(ADMIN_DIR)/make/target.common.mk


# Shared defaults + YAML helpers.  Live before the DRY_RUN branch
# because dry-run also inspects PKG_YAML to derive in-tree targets.
PKG_VERSION       ?= 0.1.0
PKG_RELEASE       ?= 1
PKG_FILES         ?=
PKG_EXTRA_FILES   ?=
PKG_SPEC          ?= $(TARGET).spec
PKG_RPM_DEPS      ?=
PKG_YAML          ?=
PKG_YAML_VARS     ?=
PKG_INSTALL_ROOT  ?=
PKG_FILEGROUP_MAP ?=

# Sanitizer RPMs: release tag + Requires of the runtime (USER_GUIDE 3.12).
# component.h keeps the plain release: $(GM_GEN_DIR) is shared by all variants.
_PKG_RELEASE_BASE := $(PKG_RELEASE)
ifneq ($(strip $(_VAR_TAGS)),)
PKG_RELEASE       := $(PKG_RELEASE).$(subst $(_space),.,$(sort $(_VAR_TAGS)))
PKG_RPM_DEPS      += $(foreach s,$(_SAN_LIST),$(_SAN_RPM_$(s)))
_PKG_SAN_DEP_ARGS := $(foreach s,$(_SAN_LIST),--rpm-dep $(_SAN_RPM_$(s)))
endif

# Resolve child-.mk relative paths (MAKEFILE_DIR unset there yet).
_abs              = $(if $(filter /%,$(1)),$(1),$(MAKEFILE_DIR)/$(1))
PKG_YAML_ABS          := $(if $(PKG_YAML),$(call _abs,$(PKG_YAML)))
PKG_FILEGROUP_MAP_ABS := $(if $(PKG_FILEGROUP_MAP),$(call _abs,$(PKG_FILEGROUP_MAP)))
RPM_LIB_DIR   := $(GM_LIB_DIR)
RPM_EXEC_DIR  := $(GM_EXEC_DIR)
_PKG_AUTO_VARS := \
    PROJ_TOP=$(PROJ_TOP) \
    BUILD_ARCH=$(BUILD_ARCH) \
    BUILD_MODE=$(BUILD_MODE) \
    OUT_DIR=$(OUT_DIR) \
    GM_OUT=$(GM_OUT) \
    GM_LIB_DIR=$(GM_LIB_DIR) \
    GM_EXEC_DIR=$(GM_EXEC_DIR) \
    GM_PKG_DIR=$(GM_PKG_DIR)
_PKG_VARS_ALL := $(_PKG_AUTO_VARS) $(PKG_YAML_VARS)
_PKG_INSTALL_ROOT_ARG := $(if $(PKG_INSTALL_ROOT),--install-root $(PKG_INSTALL_ROOT))


# _YAML_INTREE: artefact basenames pkg-build.py derived from pkg.yaml `files`.
ifneq ($(PKG_YAML_ABS),)
_PYDEP_ERR := $(shell python3 -c 'import importlib.util as u,sys; \
    sys.exit(0 if u.find_spec("yaml") and u.find_spec("jsonschema") else 1)' \
    >/dev/null 2>&1 || echo missing)
ifneq ($(_PYDEP_ERR),)
$(error pkg $(TARGET) needs PyYAML + jsonschema.  \
Install:  python3 -m pip install -r $(GM_PYDEP_REQS))
endif
_YAML_INTREE := $(shell python3 $(ADMIN_DIR)/make/scripts/pkg-build.py \
    --pkg $(PKG_YAML_ABS) \
    $(foreach kv,$(_PKG_VARS_ALL),--vars $(kv)) \
    $(_PKG_INSTALL_ROOT_ARG) \
    --print-intree-targets $(RPM_LIB_DIR),$(RPM_EXEC_DIR))
else
_YAML_INTREE :=
endif

ifeq ($(DRY_RUN),1)
_YAML_INTREE_DIRECT   := $(filter     $(TARGET_ALL),$(_YAML_INTREE))
_YAML_INTREE_INDIRECT := $(filter-out $(TARGET_ALL),$(_YAML_INTREE))
_YAML_INTREE_MISSING  := $(strip $(foreach n,$(_YAML_INTREE_INDIRECT),\
    $(if $(IMPORT_OF_$(n)),,$(n))))
ifneq ($(_YAML_INTREE_MISSING),)
$(error pkg $(TARGET): pkg.yaml files reference artefacts with no owning \
.mk / IMPORT_OF_<name> mapping: $(_YAML_INTREE_MISSING).  \
Fix: add these artefacts to some .import.mk's IMPORT_ARTIFACT list, or \
correct the pkg.yaml src paths.)
endif
_YAML_INTREE_RESOLVED := $(_YAML_INTREE_DIRECT) \
    $(foreach n,$(_YAML_INTREE_INDIRECT),$(IMPORT_OF_$(n)))
DRY_DEPS := $(strip $(filter $(PKG_FILES) $(_YAML_INTREE_RESOLVED),$(TARGET_ALL)))

ifneq ($(PKG_YAML_ABS),)
DRY_REVERSE_PREFIX := PKG_OF
DRY_REVERSE_FILE   := $(GM_PKG_OF_FILE)
endif
include $(ADMIN_DIR)/make/target.dry-run.mk

# ---- DRY_RUN ends here ------------------------------------------------
else

PKG_SPEC_ABS         := $(call _abs,$(PKG_SPEC))
PKG_EXTRA_FILES_ABS  := $(foreach f,$(PKG_EXTRA_FILES),$(call _abs,$(f)))

RPM_TARGET_ARCH   ?= $(shell uname -m)
PKG_SPEC_VARS     ?=
PKG_SPEC_VARS     += PKG_VERSION PKG_RELEASE TARGET BUILD_ARCH BUILD_MODE RPM_TARGET_ARCH PKG_RPM_DEPS_REQ
PKG_RPM_DEPS_REQ := $(if $(strip $(PKG_RPM_DEPS)),$(shell echo "$(PKG_RPM_DEPS)" | tr -s ' ' ',' | sed 's/^,//;s/,$$//'))

RPMBUILD_DIR  := $(BUILD_DIR)/rpmbuild
SOURCES_DIR   := $(RPMBUILD_DIR)/SOURCES
BUILDROOT_DIR := $(RPMBUILD_DIR)/BUILDROOT
SPECS_DIR     := $(RPMBUILD_DIR)/SPECS

# %{?dist} (e.g. ".el8") is auto-appended when the spec references it;
# ask rpm so the filename we expect matches what rpmbuild produces.
PKG_DIST_TAG  := $(shell rpm --eval '%{?dist}' 2>/dev/null)
GEN_SPEC      := $(SPECS_DIR)/$(TARGET).spec
PKG_FILENAME  := $(TARGET)-$(PKG_VERSION)-$(PKG_RELEASE)$(PKG_DIST_TAG).$(RPM_TARGET_ARCH).rpm
PKG_OUT       := $(OUT_DIR)/$(PKG_FILENAME)
# rpmbuild also emits <name>-debuginfo (pkg-debuginfo.spec.inc); published next to the main RPM.
PKG_DBG_FILENAME := $(TARGET)-debuginfo-$(PKG_VERSION)-$(PKG_RELEASE)$(PKG_DIST_TAG).$(RPM_TARGET_ARCH).rpm
PKG_DBG_OUT   := $(OUT_DIR)/$(PKG_DBG_FILENAME)
PKG_DEBUGINFO_INC := $(ADMIN_DIR)/make/scripts/pkg-debuginfo.spec.inc
# Packaged exes carry the build tree's relative RPATH: repoint it at the libs in the RPM.
_PKG_RPATH_FIX := python3 $(ADMIN_DIR)/make/scripts/elf-rpath.py --buildroot %{buildroot} --marker $(patsubst $(GM_OUT)/%,%,$(GM_LIB_DIR)) --marker $(GM_OUT)
PKG_HOOKS_LOG := $(BUILD_DIR)/$(TARGET).hooks.jsonl
PKG_BUILD_LOG := $(BUILD_DIR)/$(TARGET)_rpmbuild.log
PKG_DEP_JSON  := $(OUT_DIR)/$(TARGET).dep.json
PKG_MANIFEST  := $(BUILD_DIR)/$(TARGET).manifest.json
PKG_COMPONENT_HDR := $(GM_GEN_DIR)/$(TARGET)/component.h
PKG_COMPONENT_DIR := $(dir $(PKG_COMPONENT_HDR))


ifneq ($(MAKECMDGOALS),clean)
_pkg_resolve = $(firstword $(wildcard \
                   $(RPM_EXEC_DIR)/$(1) \
                   $(RPM_LIB_DIR)/$(1).so \
                   $(RPM_LIB_DIR)/$(1).a))
_PKG_UNRESOLVED := $(strip $(foreach f,$(PKG_FILES),\
    $(if $(strip $(call _pkg_resolve,$(f))),,$(f))))
ifneq ($(_PKG_UNRESOLVED),)
$(error pkg $(TARGET): PKG_FILES entries not found under $(RPM_EXEC_DIR) or $(RPM_LIB_DIR): $(_PKG_UNRESOLVED). )
endif

_PKG_STAGE_FILES := $(foreach f,$(PKG_FILES),$(call _pkg_resolve,$(f))) \
                    $(PKG_EXTRA_FILES_ABS)
endif


ifneq ($(PKG_YAML),)
PKG_YAML_MODE := 1
else
PKG_YAML_MODE := 0
endif

_PKG_FG_MAP_ARG := $(if $(PKG_FILEGROUP_MAP_ABS),--filegroup-map $(PKG_FILEGROUP_MAP_ABS))
# --rpm-dep only meaningful in plain mode; YAML mode reads `rpm_deps:`.
_PKG_RPM_DEP_ARGS := $(foreach r,$(PKG_RPM_DEPS),--rpm-dep $(r))


ifeq ($(DEP_TREE),yes)
DEP_JSON_ALL := $(PKG_DEP_JSON)
else
DEP_JSON_ALL :=
endif

$(TARGET) :: $(PKG_OUT) $(DEP_JSON_ALL) ;


ifeq ($(PKG_YAML_MODE),0)

# MODE A: plain (hand-written .spec + hook-based src capture).
$(PKG_OUT): $(_PKG_STAGE_FILES) $(PKG_SPEC_ABS) $(GM_FRAMEWORK_MK) | $(OUT_DIR)
	$(V_RPM)
	$(Q)mkdir -p $(SOURCES_DIR) $(SPECS_DIR) $(BUILDROOT_DIR) $(BUILD_DIR)
	$(Q): > $(PKG_HOOKS_LOG)
	$(Q)DEP_TREE=$(DEP_TREE) DEP_TRACK_FILE=$(PKG_HOOKS_LOG) bash -c '. $(ADMIN_DIR)/tools/dep-hooks.sh && cp -fL $(_PKG_STAGE_FILES) $(SOURCES_DIR)/'
	$(Q)sed $(foreach v,$(PKG_SPEC_VARS),-e 's|@$(v)@|$(subst |,\|,$($(v)))|g') $(PKG_SPEC_ABS) > $(GEN_SPEC)
	$(Q)grep -q debug_package $(GEN_SPEC) || { \
	    awk -v inc='$(PKG_DEBUGINFO_INC)' -v fix='$(_PKG_RPATH_FIX)' 'BEGIN { while ((getline l < inc) > 0) blk = blk l "\n" } \
	        /^%install/ && !d { printf "%s\n", blk; d = 1; ins = 1; print; next } \
	        ins && /^%[a-z]+/ { print "chmod -R u+w %{buildroot}\n" fix "\n"; ins = 0 } { print }' \
	        $(GEN_SPEC) > $(GEN_SPEC).tmp && mv $(GEN_SPEC).tmp $(GEN_SPEC) ; }
	$(Q): > $(PKG_BUILD_LOG)
	$(Q)rpmbuild \
	          --define '_topdir $(RPMBUILD_DIR)' \
	          --define '_sourcedir $(SOURCES_DIR)' \
	          --define '_specdir $(SPECS_DIR)' \
	          --define '_builddir $(RPMBUILD_DIR)/BUILD' \
	          --define '_rpmdir $(RPMBUILD_DIR)/RPMS' \
	          --define '_srcrpmdir $(RPMBUILD_DIR)/SRPMS' \
	          --define '_buildrootdir $(BUILDROOT_DIR)' \
	          --define 'clamp_mtime_to_source_date_epoch 1' \
	          --define 'use_source_date_epoch_as_buildtime 1' \
	          --define '__strip $(ADMIN_DIR)/make/scripts/strip-deterministic' \
	          --target $(RPM_TARGET_ARCH) -bb $(GEN_SPEC) >>$(PKG_BUILD_LOG) 2>&1 \
	    || { echo "pkg $(TARGET): rpmbuild failed (see $(PKG_BUILD_LOG))" >&2 ; exit 1 ; }
	$(Q)cp -f $(RPMBUILD_DIR)/RPMS/$(RPM_TARGET_ARCH)/$(PKG_FILENAME) $@
	$(Q)$(RM) $(OUT_DIR)/$(TARGET)-debuginfo-*.rpm
	$(Q)if [ -f $(RPMBUILD_DIR)/RPMS/$(RPM_TARGET_ARCH)/$(PKG_DBG_FILENAME) ]; then \
	    cp -f $(RPMBUILD_DIR)/RPMS/$(RPM_TARGET_ARCH)/$(PKG_DBG_FILENAME) $(PKG_DBG_OUT) ; fi


# Plain-mode dep.json: hooks.jsonl is the src-path authority (rpmbuild's
# log only sees %{_sourcedir}/<basename>).
$(PKG_DEP_JSON): $(PKG_OUT) $(GM_FRAMEWORK_MK)
	$(V_JSON)
	$(Q)python3 $(ADMIN_DIR)/make/scripts/pkgdeps.py \
	    --package $(TARGET) \
	    --output $@ \
	    --file $(PKG_OUT) \
	    --mk-file $(MAKEFILE) \
	    --extra-dep $(PKG_SPEC_ABS) \
	    $(foreach f,$(GM_FRAMEWORK_MK),--extra-dep $(f)) \
	    $(_PKG_RPM_DEP_ARGS) \
	    $(PKG_HOOKS_LOG)

else # PKG_YAML_MODE = 1

# MODE B: YAML-driven (auto-generated .spec + rpmbuild-log src capture).
# Log's `+ install /abs/src /buildroot/dst` lines feed pkgdeps.py; no
# dep-hooks shell block needed.
_YAML_STAGE_PATHS := $(sort $(foreach n,$(_YAML_INTREE),\
    $(wildcard \
        $(GM_LIB_DIR)/$(n).so \
        $(GM_LIB_DIR)/$(n).a  \
        $(GM_EXEC_DIR)/$(n))))

$(PKG_OUT): $(PKG_YAML_ABS) $(_YAML_STAGE_PATHS) $(PKG_FILEGROUP_MAP_ABS) $(GM_FRAMEWORK_MK) | $(OUT_DIR)
	$(V_RPM)
	$(Q)mkdir -p $(SPECS_DIR) $(BUILDROOT_DIR) $(BUILD_DIR)
	$(Q)python3 $(ADMIN_DIR)/make/scripts/pkg-build.py \
	    --pkg $(PKG_YAML_ABS) \
	    $(foreach kv,$(_PKG_VARS_ALL),--vars $(kv)) \
	    $(_PKG_INSTALL_ROOT_ARG) \
	    --version $(PKG_VERSION) --release $(PKG_RELEASE) \
	    --arch $(RPM_TARGET_ARCH) \
	    $(_PKG_FG_MAP_ARG) $(_PKG_SAN_DEP_ARGS) --install-post '$(_PKG_RPATH_FIX)' \
	    --manifest-out $(PKG_MANIFEST) \
	    --spec-out $(GEN_SPEC) >/dev/null
	$(Q): > $(PKG_BUILD_LOG)
	$(Q)rpmbuild \
	          --define '_topdir $(RPMBUILD_DIR)' \
	          --define '_specdir $(SPECS_DIR)' \
	          --define '_builddir $(RPMBUILD_DIR)/BUILD' \
	          --define '_rpmdir $(RPMBUILD_DIR)/RPMS' \
	          --define '_srcrpmdir $(RPMBUILD_DIR)/SRPMS' \
	          --define '_buildrootdir $(BUILDROOT_DIR)' \
	          --define 'clamp_mtime_to_source_date_epoch 1' \
	          --define 'use_source_date_epoch_as_buildtime 1' \
	          --define '__strip $(ADMIN_DIR)/make/scripts/strip-deterministic' \
	          --target $(RPM_TARGET_ARCH) -bb $(GEN_SPEC) >>$(PKG_BUILD_LOG) 2>&1 \
	    || { echo "pkg $(TARGET): rpmbuild failed (see $(PKG_BUILD_LOG))" >&2 ; exit 1 ; }
	$(Q)cp -f $(RPMBUILD_DIR)/RPMS/$(RPM_TARGET_ARCH)/$(PKG_FILENAME) $@
	$(Q)$(RM) $(OUT_DIR)/$(TARGET)-debuginfo-*.rpm
	$(Q)if [ -f $(RPMBUILD_DIR)/RPMS/$(RPM_TARGET_ARCH)/$(PKG_DBG_FILENAME) ]; then \
	    cp -f $(RPMBUILD_DIR)/RPMS/$(RPM_TARGET_ARCH)/$(PKG_DBG_FILENAME) $(PKG_DBG_OUT) ; fi


# Standalone component-header target -- depends only on pkg.yaml
$(PKG_COMPONENT_HDR): $(PKG_YAML_ABS) | $(PKG_COMPONENT_DIR)
	$(V_GEN)
	$(Q)python3 $(ADMIN_DIR)/make/scripts/pkg-build.py \
	    --pkg $(PKG_YAML_ABS) \
	    $(foreach kv,$(_PKG_VARS_ALL),--vars $(kv)) \
	    $(_PKG_INSTALL_ROOT_ARG) \
	    --version $(PKG_VERSION) --release $(_PKG_RELEASE_BASE) \
	    --header-out $@ >/dev/null

$(PKG_COMPONENT_DIR):
	$(Q)mkdir -p $@

# `<pkg>-header` sub-goal for the dispatcher; header refresh is driven
# by consumer libs via depend.mk's `<lib>: <pkg>-header` edges.
.PHONY: header $(TARGET)-header
header $(TARGET)-header: $(PKG_COMPONENT_HDR)

$(GM_GEN_DIR):
	$(Q)mkdir -p $@


# YAML-mode dep.json: deps[] from `+ install ...` log lines; rpms[]
# from pkg.yaml's `rpm_deps:`; pkg.yaml itself is added to deps[].
$(PKG_DEP_JSON): $(PKG_OUT) $(GM_FRAMEWORK_MK)
	$(V_JSON)
	$(Q)python3 $(ADMIN_DIR)/make/scripts/pkgdeps.py \
	    --package $(TARGET) \
	    --output $@ \
	    --file $(PKG_OUT) \
	    --mk-file $(MAKEFILE) \
	    --source $(MAKEFILE_DIR) \
	    $(foreach f,$(GM_FRAMEWORK_MK),--extra-dep $(f)) \
	    $(_PKG_RPM_DEP_ARGS) \
	    $(PKG_BUILD_LOG) \
	    $(PKG_YAML_ABS)

endif # PKG_YAML_MODE

%/$(GM_MODE_DIR):
	@$(MKDIR) $@

clean:
	$(Q)$(RM) -r $(RPMBUILD_DIR)
	$(Q)$(RM) $(PKG_OUT) $(PKG_HOOKS_LOG) $(PKG_BUILD_LOG) $(PKG_DEP_JSON) $(PKG_MANIFEST)
	$(Q)$(RM) $(OUT_DIR)/$(TARGET)-debuginfo-*.rpm
	$(V_CLEAN)


endif # DRY_RUN
