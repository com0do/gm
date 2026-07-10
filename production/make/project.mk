# SPDX-License-Identifier: MIT
#
# project.mk -- target discovery + implicit lib-level dependency derivation.  Walks
# $(SOURCE_ROOTS) for *.mk files, classifies each by name+siblings,
# and generates depend.mk via DRY_RUN sub-makes.


# User's top-level Makefile can `SOURCE_ROOTS += <extra-dir>` BEFORE the
# `include project.mk` line to scan more; we use `?=` so that assignment takes precedence.
SOURCE_ROOTS ?= $(PROJ_TOP) $(PROJ_TOP)/production/tools/gtest-1.14.0
EXCLUDE_DIR  ?= build .git make production note tools container customization
rwildcard = $(shell find $(1) $(foreach d,$(EXCLUDE_DIR), -path "*/$(d)" -prune -o) \
                  -type f $(foreach ext,$(2),-name "$(ext)") -print 2>/dev/null)
TARGET_ALL_MK := $(strip $(sort $(foreach r,$(SOURCE_ROOTS),$(call rwildcard,$r,*.mk))))
_TARGET_NAME_FROM_MK = $(patsubst %.import,%,$(basename $(notdir $(1))))
TARGET_ALL    := $(foreach mk,$(TARGET_ALL_MK),$(call _TARGET_NAME_FROM_MK,$(mk)))
_TARGET_DUPES := $(shell printf '%s\n' $(TARGET_ALL) | sort | uniq -d)
ifneq ($(_TARGET_DUPES),)
$(error gm: $(_TARGET_DUPES) must be unique.)
endif

# System-lib inventory for the opt-in LDLIB_CHECK.  
_GM_SYS_LIB_PATHS := /usr/lib64 /usr/lib /usr/local/lib64 /usr/local/lib /lib64 /lib
GM_SYS_LIBS := $(if $(filter 1,$(LDLIB_CHECK)),$(call _SCAN_LIB_DIRS,$(_GM_SYS_LIB_PATHS)))

# $(call _CLASSIFY, <name>, <srcdir>, <mkfile>)
_CLASSIFY = $(strip \
    $(if $(filter %.import.mk,$(notdir $(3))),$(if $(filter lib%,$(1)),import-lib,import-exe),\
    $(if $(filter test-%,$(1)),test,\
    $(if $(filter lib%,$(1)),lib,\
    $(if $(wildcard $(2)/go.mod),go,\
    $(if $(shell find $(2) -name '*.java' -print -quit 2>/dev/null),java,\
    $(if $(filter pkg-%,$(1)),pkg,\
    exe)))))))

# $(call _OUT_DIR_FOR, <type>) -> the published-artefact directory.
_OUT_DIR_FOR = $(strip \
    $(if $(filter lib import-lib,$(1)),$(GM_LIB_DIR),\
    $(if $(filter exe test go import-exe,$(1)),$(GM_EXEC_DIR),\
    $(if $(filter pkg,$(1)),$(GM_PKG_DIR),\
    $(if $(filter java,$(1)),$(GM_JAVA_DIR),\
    $(error _OUT_DIR_FOR: unknown TYPE '$(1)'))))))

# $(call SET_TARGET, <name>, <mkfile>, <srcdir>, <relpath>)
define SET_TARGET
$(1)_type    := $(call _CLASSIFY,$(1),$(3),$(2))
$(1)_srcdir  := $(3)
$(1)_relpath := $(4)
$(1)_mkfile  := $(2)
$(1): override TYPE       := $$($(1)_type)
$(1): override SOURCE_DIR := $(3)
$(1): override BUILD_DIR  := $(GM_OUT)/$(4)/$(BUILD_ARCH)/$(BUILD_MODE)
$(1): override OUT_DIR    := $$(call _OUT_DIR_FOR,$$($(1)_type))
$(1): override REL_DIR    := $(GM_RELEASE_DIR)
endef

$(foreach mk,$(TARGET_ALL_MK),$(eval $(call SET_TARGET,$(call _TARGET_NAME_FROM_MK,$(mk)),$(mk),$(abspath $(dir $(mk))),$(patsubst $(PROJ_TOP)/%,%,$(abspath $(dir $(mk)))))))
FILTER_FUNC    = $(sort $(foreach sub,$(TARGET_ALL),$(if $(filter $(1),$($(sub)_type)),$(sub))))
TARGET_LIB        := $(call FILTER_FUNC,lib)
TARGET_EXE        := $(call FILTER_FUNC,exe)
TARGET_GO         := $(call FILTER_FUNC,go)
TARGET_JAVA       := $(call FILTER_FUNC,java)
TARGET_PKG        := $(call FILTER_FUNC,pkg)
TARGET_TEST       := $(call FILTER_FUNC,test)
TARGET_IMPORT_LIB := $(call FILTER_FUNC,import-lib)
TARGET_IMPORT_EXE := $(call FILTER_FUNC,import-exe)

define SET_HEADER_TARGET
$(1)-header: override TYPE       := pkg
$(1)-header: override SOURCE_DIR := $$($(1)_srcdir)
$(1)-header: override BUILD_DIR  := $(GM_OUT)/$$($(1)_relpath)/$(BUILD_ARCH)/$(BUILD_MODE)
$(1)-header: override OUT_DIR    := $(GM_PKG_DIR)
$(1)-header: override REL_DIR    := $(GM_RELEASE_DIR)
endef
$(foreach p,$(TARGET_PKG),$(eval $(call SET_HEADER_TARGET,$(p))))


TARGET_DEP ?= $(GM_DEP_FILE)
.PRECIOUS: $(TARGET_DEP) $(GM_PKG_OF_FILE)
.PHONY: help deps deps-files deps-snap list-targets

help:
	@$(ECHO) 'gm - auto-dep-deduced build framework.  See docs/1-USER_GUIDE.md for the full guide.'
	@$(ECHO) ''
	@$(ECHO) '  make                    build every discovered target'
	@$(ECHO) '  make <target>           build one target'
	@$(ECHO) '  make list-targets       list all discovered targets'
	@$(ECHO) '  make run-<name>         build + execute an exe / test / go target'
	@$(ECHO) '  make test               build + run every test-*'
	@$(ECHO) '  make coverage           gcovr HTML/JSON coverage report'
	@$(ECHO) '  make deps               force-regenerate depend.mk (after rename/delete)'
	@$(ECHO) '  make refresh SINCE=REF  rebuild what git-diff <REF>..HEAD changed'
	@$(ECHO) '  make changes CHANGES=X  print affected targets, no build'
	@$(ECHO) '  make clean              clean every target'
	@$(ECHO) '  make distclean          wipe $$(GM_OUT)'
	@$(ECHO) '  make prereq             one-shot python-deps install'
	@$(ECHO) '  make precheck           local static checks (CI parity)'
	@$(ECHO) ''
	@$(ECHO) '  V=1                     show raw compile commands'
	@$(ECHO) '  -jN                     parallel build'
	@$(ECHO) '  BUILD_MODE=release      release build (default: debug)'
	@$(ECHO) '  DEP_TREE=yes            emit .dep.json sidecars for file-level DAG'


ifneq ($(DRY_RUN),1)
ifeq ($(origin _DEP_DIGEST_NOW),undefined)
_DEP_DIGEST_NOW := $(shell echo $(sort $(TARGET_ALL_MK)) | md5sum | cut -c1-32)
endif

# DRY_RUN scan is intentionally serial + strictly ordered:
#   1. imports FIRST -- write IMPORT_OF_<artefact> := <mk> into
#      $(GM_IMPORT_OF_FILE).  Pkgs need this map to resolve
#      multi-artefact vendor products (pkg.yaml referencing e.g.
#      libvlib_extra.so where the .mk basename is libvlib).
#   2. pkgs SECOND -- read IMPORT_OF_*, write PKG_OF_<lib> := <pkg>
#      into $(GM_PKG_OF_FILE).
#   3. everything else THIRD -- reads both maps to fill in reverse deps.
#
# Serial (not -j) because every DRY_RUN sub-make does `sed -i` on the
# SHARED depend.mk / pkg_of.mk / import_of.mk files; parallel sed on
# one file races and drops DAG edges.  See docs/4-DEBUGGING.md.
$(GM_PKG_OF_FILE):    $(TARGET_DEP) ;
$(GM_IMPORT_OF_FILE): $(TARGET_DEP) ;
$(TARGET_DEP): _CHANGED = $(foreach mk,$?,$(call _TARGET_NAME_FROM_MK,$(mk)))
$(TARGET_DEP): _IMPORT_ALL = $(TARGET_IMPORT_LIB) $(TARGET_IMPORT_EXE)
$(TARGET_DEP): _ORDERED = \
    $(filter $(_IMPORT_ALL),$(_CHANGED)) \
    $(filter $(TARGET_PKG),$(_CHANGED)) \
    $(filter-out $(_IMPORT_ALL) $(TARGET_PKG),$(_CHANGED))
$(TARGET_DEP): $(TARGET_ALL_MK)
	@mkdir -p $(@D)
	@$(call V_DEPS,scanning $(words $(_CHANGED)) target(s))
	@for t in $(_ORDERED) ; do \
	    $(ECHO) "  DEPS    $$t" ; \
	    GM_TREE= $(MAKE) -s DRY_RUN=1 $$t || exit $$? ; \
	 done
	@# Drop target.dry-run.mk's seed blank line, sort + dedupe.
	@sort -u $(GM_PKG_OF_FILE) | grep -v '^[[:space:]]*$$' \
	   > $(GM_PKG_OF_FILE).tmp && mv $(GM_PKG_OF_FILE).tmp $(GM_PKG_OF_FILE) || true
	@sort -u $(GM_IMPORT_OF_FILE) | grep -v '^[[:space:]]*$$' \
	   > $(GM_IMPORT_OF_FILE).tmp && mv $(GM_IMPORT_OF_FILE).tmp $(GM_IMPORT_OF_FILE) || true
	@{ echo '_DEP_DIGEST := $(_DEP_DIGEST_NOW)' ; \
	   grep -Ev '^(_DEP_DIGEST := |[[:space:]]*$$)' $(TARGET_DEP) | sort -u ; } \
	   > $(TARGET_DEP).tmp && mv $(TARGET_DEP).tmp $(TARGET_DEP)
	@$(call V_DEPS,-> $(patsubst $(PROJ_TOP)/%,%,$(TARGET_DEP)) ($$(($$(wc -l < $(TARGET_DEP)) - 1)) edges))
	@$(call V_DEPS,-> $(patsubst $(PROJ_TOP)/%,%,$(GM_PKG_OF_FILE)) ($$(wc -l < $(GM_PKG_OF_FILE)) pkg-of mappings))
	@$(call V_DEPS,-> $(patsubst $(PROJ_TOP)/%,%,$(GM_IMPORT_OF_FILE)) ($$(wc -l < $(GM_IMPORT_OF_FILE)) import-of mappings))

deps:
	@$(RM) $(TARGET_DEP) $(GM_PKG_OF_FILE) $(GM_IMPORT_OF_FILE)
	@GM_TREE= $(MAKE) $(TARGET_DEP)

endif # DRY_RUN != 1

deps-files:
	@python3 $(ADMIN_DIR)/make/scripts/dep_query.py \
	    --build-dir $(GM_OUT) --proj-top $(PROJ_TOP) show

deps-snap: $(GM_FRAMEWORK_JSON)
	@[ -n "$(wildcard $(GM_LIB_DIR)/*.dep.json $(GM_EXEC_DIR)/*.dep.json)" ] || { \
	    $(ECHO) "  DEPS-S  no *.dep.json founded"; exit 1 ; }
	@python3 $(ADMIN_DIR)/make/scripts/dep_query.py \
	    --build-dir $(GM_OUT) --proj-top $(PROJ_TOP) \
	    snapshot --out-dir $(GM_OUT)/deps \
	    $(if $(VERSION),--version '$(VERSION)')

list-targets:
	@printf '%s\n' $(TARGET_ALL)

_RUN_TARGETS := $(patsubst %,run-%,$(TARGET_EXE) $(TARGET_TEST) $(TARGET_GO) $(TARGET_IMPORT_EXE))
.PHONY: $(_RUN_TARGETS)
$(_RUN_TARGETS): run-%: %
	@$(ECHO) "  RUN     $*"
	@"$(GM_EXEC_DIR)/$*" $(RUN_ARGS)

# compile_commands.json
GM_CDB       := $(GM_OUT)/compile_commands.json
GM_CDB_LINK  := $(PROJ_TOP)/compile_commands.json
_CDB_TARGETS := $(TARGET_LIB) $(TARGET_EXE) $(TARGET_TEST) $(TARGET_PKG)
.PHONY: compile_commands
compile_commands: $(GM_CDB)
$(GM_CDB): $(_CDB_TARGETS) | $(GM_OUT)
	@bash $(ADMIN_DIR)/make/scripts/cdb-aggregate.sh $(GM_OUT) $@ $(GM_CDB_LINK) $(PROJ_TOP)
$(GM_OUT):
	@mkdir -p $@

