# SPDX-License-Identifier: MIT
#
# project.mk -- target discovery.  Walks $(SOURCE_ROOTS) for *.mk files and classifies each
# by name+siblings; graph.mk derives the dependency graph between them.


# User's top-level Makefile can `SOURCE_ROOTS += <extra-dir>` BEFORE the
# `include project.mk` line to scan more; we use `?=` so that assignment takes precedence.
SOURCE_ROOTS ?= $(PROJ_TOP) $(ADMIN_DIR)/tools/gtest-1.14.0
EXCLUDE_DIR  ?= build .git make production note tools container customization
GM_SELF      := $(if $(filter Y,$(SINGLE_REPO)),,$(abspath $(ADMIN_DIR)/..))
rwildcard = $(shell find $(1) $(if $(GM_SELF),-path "$(GM_SELF)" -prune -o) \
                  -path "$(abspath $(GM_OUT))" -prune -o \
                  $(foreach d,$(EXCLUDE_DIR), -path "*/$(d)" -prune -o) \
                  -type f $(foreach ext,$(2),-name "$(ext)") -print 2>/dev/null)
TARGET_ALL_MK := $(strip $(sort $(foreach r,$(SOURCE_ROOTS),$(call rwildcard,$r,*.mk))))
_TARGET_NAME_FROM_MK = $(patsubst %.java,%,$(patsubst %.import,%,$(basename $(notdir $(1)))))
TARGET_ALL    := $(foreach mk,$(TARGET_ALL_MK),$(call _TARGET_NAME_FROM_MK,$(mk)))
_TARGET_DUPES := $(sort $(foreach t,$(TARGET_ALL),$(if $(word 2,$(filter $(t),$(TARGET_ALL))),$(t))))
ifneq ($(_TARGET_DUPES),)
$(error gm: $(_TARGET_DUPES) must be unique.)
endif
# gm's own goals.  A target named like one of them (or show-<t> / run-<t> of another target)
# would be shadowed by it.  _GM_GOALS_ALONE build no target in this make -- they read files, or
# start a make of their own -- so this make loads no dependency graph for them (graph.mk).  A
# new goal goes in one of the two lists; left out of _GM_GOALS_ALONE it gets the graph: always
# correct, only slower.
_GM_TYPES       := lib exe test go java pkg import-lib import-exe
_GM_GOALS_ALONE := clean distclean deps deps-files deps-snap help list run test-list \
                   coverage coverage-lcov coverage-diff changes changes-since incremental refresh \
                   precheck prereq
_GM_GOALS       := all show test compile_commands $(_GM_GOALS_ALONE) $(_GM_TYPES)
_TARGET_CLASH := $(filter $(_GM_GOALS) $(addprefix show-,$(TARGET_ALL)) $(addprefix run-,$(TARGET_ALL)),$(TARGET_ALL))
ifneq ($(_TARGET_CLASH),)
$(error gm: target name(s) $(_TARGET_CLASH) clash with gm's own goals; rename the .mk file(s))
endif

# System-lib inventory for the opt-in LDLIB_CHECK.  
_GM_SYS_LIB_PATHS := /usr/lib64 /usr/lib /usr/local/lib64 /usr/local/lib /lib64 /lib \
    $(wildcard /usr/lib/*-linux-gnu /usr/local/lib/*-linux-gnu /lib/*-linux-gnu)
GM_SYS_LIBS := $(if $(filter 1,$(LDLIB_CHECK)),$(call _SCAN_LIB_DIRS,$(_GM_SYS_LIB_PATHS)))

# $(call _CLASSIFY, <name>, <srcdir>, <mkfile>)
_CLASSIFY = $(strip \
    $(if $(filter %.java.mk,$(notdir $(3))),java,\
    $(if $(filter %.import.mk,$(notdir $(3))),$(if $(filter lib%,$(1)),import-lib,import-exe),\
    $(if $(filter test-%,$(1)),test,\
    $(if $(filter lib%,$(1)),lib,\
    $(if $(wildcard $(2)/go.mod),go,\
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
$(1) _info-$(1): override TYPE       := $$($(1)_type)
$(1) _info-$(1): override SOURCE_DIR := $(3)
$(1) _info-$(1): override BUILD_DIR  := $(GM_OUT)/$(4)/$(BUILD_ARCH)/$(GM_MODE_DIR)
$(1) _info-$(1): override OUT_DIR    := $$(call _OUT_DIR_FOR,$$($(1)_type))
$(1) _info-$(1): override REL_DIR    := $(GM_RELEASE_DIR)
endef

$(foreach mk,$(TARGET_ALL_MK),$(eval $(call SET_TARGET,$(call _TARGET_NAME_FROM_MK,$(mk)),$(mk),$(abspath $(dir $(mk))),$(patsubst $(PROJ_TOP)/%,%,$(abspath $(dir $(mk)))))))

FILTER_FUNC    = $(sort $(foreach sub,$(TARGET_ALL),$(if $(filter $(1),$($(sub)_type)),$(sub))))

# Toolchain gating, once.  go and java are the only types with an optional toolchain: when its
# tool is missing the whole type leaves the target set here, so every list derived below (and every
# flow built on them) never sees it.  (pkg stays: libs need its component header; only its rpm
# step needs rpmbuild, see target.pkg.mk.)
_GM_NO_GO     := $(if $(call _have,$(GO)),,$(call FILTER_FUNC,go))
_GM_NO_JAVA   := $(if $(and $(call _have,$(JAVAC)),$(call _have,$(JAR))),,$(call FILTER_FUNC,java))
TARGET_ALL    := $(filter-out $(_GM_NO_GO) $(_GM_NO_JAVA),$(TARGET_ALL))
TARGET_ALL_MK := $(foreach t,$(TARGET_ALL),$($(t)_mkfile))

.PHONY: _skip_go _skip_java $(_GM_NO_GO) $(_GM_NO_JAVA)
_skip_go:
	+@$(call V_SKIP,$(_GM_NO_GO)  (go not found))
_skip_java:
	+@$(call V_SKIP,$(_GM_NO_JAVA)  (javac/jar not found))
$(_GM_NO_GO):
	@$(ECHO) "gm: $@ is not built here: go not found" >&2 ; exit 1
$(_GM_NO_JAVA):
	@$(ECHO) "gm: $@ is not built here: javac/jar not found" >&2 ; exit 1

TARGET_LIB        := $(call FILTER_FUNC,lib)
TARGET_EXE        := $(call FILTER_FUNC,exe)
TARGET_GO         := $(call FILTER_FUNC,go)
TARGET_JAVA       := $(call FILTER_FUNC,java)
TARGET_PKG        := $(call FILTER_FUNC,pkg)
TARGET_TEST       := $(call FILTER_FUNC,test)
TARGET_IMPORT_LIB := $(call FILTER_FUNC,import-lib)
TARGET_IMPORT_EXE := $(call FILTER_FUNC,import-exe)

# The DRY_RUN sub-makes read the target list from a file (env.mk, GM_DRY_VARS_FILE).  Written
# only when its content changes: the dependency scan re-enters this make once per target.
_GM_DRY_VARS := TARGET_ALL := $(TARGET_ALL)$(_NL)GM_SYS_LIBS := $(GM_SYS_LIBS)
ifeq ($(DRY_RUN),1)
ifneq ($(strip $(file <$(GM_DRY_VARS_FILE))),$(strip $(_GM_DRY_VARS)))
$(if $(wildcard $(GM_OUT)),,$(shell mkdir -p $(GM_OUT)))
$(file >$(GM_DRY_VARS_FILE),$(_GM_DRY_VARS))
endif
endif

define SET_HEADER_TARGET
$(1)-header: override TYPE       := pkg
$(1)-header: override SOURCE_DIR := $$($(1)_srcdir)
$(1)-header: override BUILD_DIR  := $(GM_OUT)/$$($(1)_relpath)/$(BUILD_ARCH)/$(GM_MODE_DIR)
$(1)-header: override OUT_DIR    := $(GM_PKG_DIR)
$(1)-header: override REL_DIR    := $(GM_RELEASE_DIR)
endef
$(foreach p,$(TARGET_PKG),$(eval $(call SET_HEADER_TARGET,$(p))))

# rpm's %{?dist} (e.g. ".el8") for the pkg file names (target.pkg.mk).  Cached (_CACHE, env.mk):
# rpm takes longer to start than the rest of this file to parse.  The "d" keeps an empty dist
# (Debian / Ubuntu) a non-empty, cacheable value.  The dependency scan (DRY_RUN) names no rpm.
ifneq ($(and $(TARGET_PKG),$(_GM_RPMBUILD),$(if $(filter 1,$(DRY_RUN)),,y)),)
_GM_RPM_DIST_RAW_KEY  := $(_GM_RPMBUILD)
_GM_RPM_DIST_RAW_DEPS := $(_GM_RPMBUILD) $(wildcard /usr/lib/rpm/macros.d/* /etc/rpm/* $(HOME)/.rpmmacros)
_GM_RPM_DIST_RAW_CMD   = printf 'd%s' "$$(rpm --eval '%{?dist}' 2>/dev/null)"
$(eval $(call _CACHE,_GM_RPM_DIST_RAW,$(GM_OUT)/.rpm-dist.mk))
endif
_GM_RPM_DIST := $(patsubst d%,%,$(_GM_RPM_DIST_RAW))



.PHONY: help deps-files deps-snap list show

help:
	@$(ECHO) 'gm - auto-dep-deduced build framework.  See docs/1-USER_GUIDE.md for the full guide.'
	@$(ECHO) ''
	@$(ECHO) '  make                    build every discovered target'
	@$(ECHO) '  make <target>           build one target'
	@$(ECHO) '  make list               list all discovered targets'
	@$(ECHO) '  make show               every target: type, dir, what it depends on (build order)'
	@$(ECHO) '  make show-<type>        targets of one type (lib exe test go java pkg import-lib import-exe)'
	@$(ECHO) '  make show-<name>        one target: deps, users, pkgs + what its type knows'
	@$(ECHO) '  make run                list what make run-<name> can run'
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
	@$(ECHO) '  SANITIZE=address       AddressSanitizer on any BUILD_MODE (also undefined, thread)'
	@$(ECHO) '  COVERAGE=1             gcov instrumentation on any BUILD_MODE (make coverage uses it)'
	@$(ECHO) '  DEP_TREE=yes            emit .dep.json sidecars for file-level DAG'


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

list:
	@printf '%s\n' $(TARGET_ALL)

# What gm derived: `make show` (every target: type, dir, direct deps, build order),
# `make show-<type>` (the targets of one type, with what that type knows: output, sources, rpm,
# ...) and `make show-<name>` (one target: deps, transitive deps, users, pkgs, type facts).  The
# type facts come from the target's own sub-make (`_gm_show`, target.common.mk), one file per
# target under $(GM_OUT)/.show; the target table goes through a file too (a command line would
# not hold a large tree).
_SHOW_ALL   := $(TARGET_ALL) $(_GM_NO_GO) $(_GM_NO_JAVA)
_SHOW_GOALS := $(addprefix show-,$(_SHOW_ALL) $(_GM_TYPES))
_SHOW_META  := $(GM_OUT)/.targets.meta
_SHOW_INFO  := $(GM_OUT)/.show
.PHONY: show $(_SHOW_GOALS) $(addprefix _info-,$(TARGET_ALL))
$(addprefix _info-,$(TARGET_ALL)): _info-%: | $(GM_OUT)
	@mkdir -p $(_SHOW_INFO) && $(call _GM_SUBMAKE,$*,-s _gm_show) > $(_SHOW_INFO)/$*
$(foreach t,$(TARGET_ALL),$(eval show-$(t): _info-$(t)))
$(foreach y,$(_GM_TYPES),$(eval show-$(y): $(addprefix _info-,$(call FILTER_FUNC,$(y)))))
# Written once per make, whatever number of show goals run in parallel.
$(_SHOW_META): _gm_force | $(GM_OUT)
	$(file >$@,$(foreach t,$(_SHOW_ALL),$(t)|$($(t)_type)|$($(t)_relpath)|$(patsubst $(PROJ_TOP)/%,%,$($(t)_mkfile))|$(if $(filter $(t),$(_GM_NO_GO)),go not found,$(if $(filter $(t),$(_GM_NO_JAVA)),javac/jar not found))$(_NL)))
show $(_SHOW_GOALS): $(_SHOW_META)
	@python3 $(ADMIN_DIR)/make/scripts/show-targets.py --meta $(_SHOW_META) --depend $(TARGET_DEP) \
	    --pkg-of $(GM_PKG_OF_FILE) --info-dir $(_SHOW_INFO) \
	    $(if $(filter $(patsubst show-%,%,$@),$(_GM_TYPES)),--type $(patsubst show-%,%,$@),$(patsubst show-%,%,$(filter-out show,$@)))

_RUNNABLE := $(sort $(TARGET_EXE) $(TARGET_TEST) $(TARGET_GO) $(TARGET_IMPORT_EXE))
.PHONY: run $(addprefix run-,$(_RUNNABLE))
$(addprefix run-,$(_RUNNABLE)): run-%: %
	@$(ECHO) "  RUN     $*"
	@"$(GM_EXEC_DIR)/$*" $(RUN_ARGS)
# Not "run them all": exes are servers, daemons, tools that need arguments -- only tests are
# self-checking (make test).
run:
	@$(ECHO) 'make run-<name> [RUN_ARGS=...] builds and runs one of:'
	@printf '  %s\n' $(_RUNNABLE)
	@$(ECHO) 'make test [TESTS=...] runs the tests and checks they pass.'

# compile_commands.json
GM_CDB       := $(GM_OUT)/compile_commands.json
GM_CDB_LINK  := $(PROJ_TOP)/compile_commands.json
_CDB_TARGETS := $(TARGET_LIB) $(TARGET_EXE) $(TARGET_TEST) $(TARGET_PKG)
.PHONY: compile_commands
compile_commands: $(GM_CDB)
# The targets are phony, so this recipe always runs; the script tells whether the DB is stale.
# Under make -q that answer is the result: `+` runs the line even in question mode.
$(GM_CDB): $(_CDB_TARGETS) | $(GM_OUT)
	$(if $(_GM_MAKE_Q),+)@bash $(ADMIN_DIR)/make/scripts/cdb-aggregate.sh $(if $(_GM_MAKE_Q),--check) \
	    $(GM_OUT) $@ $(GM_CDB_LINK) $(PROJ_TOP)
$(GM_OUT):
	@mkdir -p $@

