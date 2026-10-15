# SPDX-License-Identifier: MIT
#
# env.mk -- build environment.  Loaded by the top-level Makefile and by every
# sub-make (via target.common.mk).  Pulls in flags.mk.  Kills GNU
# make's builtin rules/variables so the explicit assignments below
# are the single source of truth.

# Layout.  SINGLE_REPO=Y (default): gm is vendored in the project -- make runs in the project
# root and the framework is <project>/production.  SINGLE_REPO=N: gm is its own checkout next to
# the project repo(s) -- make runs in the gm checkout and PROJ_TOP is the directory holding both
# (USER_GUIDE 7.4).  Either way PROJ_TOP / ADMIN_DIR can be set explicitly.
SINGLE_REPO ?= Y
ifeq ($(SINGLE_REPO),Y)
PROJ_TOP    ?= $(CURDIR)
ADMIN_DIR   ?= $(PROJ_TOP)/production
else
PROJ_TOP    ?= $(abspath $(CURDIR)/..)
ADMIN_DIR   ?= $(CURDIR)/production
endif

MAKEFILE     := $(lastword $(filter-out $(ADMIN_DIR)/make/% ,$(abspath $(MAKEFILE_LIST))))
MAKEFILE_DIR := $(abspath $(dir $(MAKEFILE)))
MAKEFLAGS += --no-builtin-rules --no-builtin-variables --no-print-directory
# MAKEFLAGS' first word holds the one-letter flags
_GM_MAKE_N := $(findstring n,$(firstword -$(MAKEFLAGS)))
_GM_MAKE_Q := $(findstring q,$(firstword -$(MAKEFLAGS)))


SHELL    := /bin/bash
ECHO     := echo
RM       := rm -f
MKDIR    := mkdir -p
LN       := ln -fs
FIND     := find
AR       ?= ar
ARFLAGS  := -rcsD
BUILD_MODE   ?= debug

ifeq ($(BUILD_ARCH),)
ifeq ($(shell uname -s),Linux)
BUILD_ARCH   := rhlinux
else
BUILD_ARCH   := $(shell uname -s | tr A-Z a-z)
endif
endif

# A recipe that fails (or is interrupted) must not leave a half-written file behind:
# a truncated .d would break every later parse, a truncated .o would pass for up to date.
.DELETE_ON_ERROR:

# env.mk runs in two kinds of make: the top-level one (started by the user, or one of gm's own
# re-entries `GM_TREE= $(MAKE) ...`) and the sub-make of one target (started by the
# dispatcher).  _GM_TOP = 1 in the first.  It is read from GM_TREE before the `export GM_TREE
# := 1` below, which sets GM_TREE to 1 in both kinds and so no longer tells them apart.
_GM_TOP := $(if $(strip $(GM_TREE)),,1)

# Probes of the build host run once per tree: the top-level make computes them, every sub-make
# gets the values on its command line (_GM_SUBMAKE_VARS) instead of forking a shell per probe
# and per target.  A knob set in the environment / on the command line / in the top-level
# Makefile still wins.  GM_TOP_MAKEFILES: the project's own makefiles the top-level make read --
# the one it was started with (gm's Makefile, or yours if you wrote your own) and whatever it
# includes -- i.e. MAKEFILE_LIST without gm's make/ files and what lives under GM_OUT
# (depend.mk, caches).  Recursive: complete only once the top level has parsed everything.
ifeq ($(_GM_TOP),1)
# -e: the environment beats every makefile assignment, in every make of the run.  The knobs reach
# the target makes through the environment (below), so a target's `CXX_STD := c++23` would
# silently build as c++17, and gm's own GM_TREE / MAKEFLAGS settings would be lost.
ifneq ($(findstring e,$(firstword -$(MAKEFLAGS))),)
$(error gm does not support make -e: it would let the environment override what each .mk sets.  \
Set a knob on the command line (make CXX_STD=c++20) or in the environment, without -e)
endif
_GM_PROBE := $(shell for t in go javac jar jq ccache rpmbuild ; do command -v $$t 2>/dev/null || echo - ; done ; \
    uname -m ; \
    $(if $(filter undefined,$(origin BUILD_HOST)),hostname 2>/dev/null || echo unknown,echo -) ; \
    $(if $(filter undefined,$(origin SOURCE_DATE_EPOCH)),git -C $(PROJ_TOP) log -1 --format=%ct 2>/dev/null || echo -,echo -) ; \
    command -v find 2>/dev/null || echo -)
_gm_probe = $(filter-out -,$(word $(1),$(_GM_PROBE)))
# Target discovery lists the *.mk files with find (project.mk): without it the tree looks empty
# and make "succeeds" building nothing.  Minimal images (Rocky 8) do not ship it.
ifeq ($(call _gm_probe,10),)
$(error gm: find not found -- it lists the project's .mk files.  Install findutils)
endif
_GM_GO       := $(firstword $(wildcard $(GOROOT)/bin/go) $(call _gm_probe,1))
_GM_JAVAC    := $(call _gm_probe,2)
_GM_JAR      := $(call _gm_probe,3)
_GM_JQ       := $(call _gm_probe,4)
_GM_CCACHE   := $(call _gm_probe,5)
_GM_RPMBUILD := $(call _gm_probe,6)
_GM_UNAME_M  := $(call _gm_probe,7)
ifeq ($(origin BUILD_HOST),undefined)
BUILD_HOST   := $(call _gm_probe,8)
endif
ifeq ($(origin SOURCE_DATE_EPOCH),undefined)
SOURCE_DATE_EPOCH := $(call _gm_probe,9)
endif
GM_TOP_MAKEFILES = $(wildcard $(filter-out $(ADMIN_DIR)/make/% $(GM_OUT)/%,$(abspath $(MAKEFILE_LIST))))
endif
GO       ?= $(or $(_GM_GO),go)
JAVAC    ?= $(or $(_GM_JAVAC),javac)
JAR      ?= $(or $(_GM_JAR),jar)
RPMBUILD ?= $(or $(_GM_RPMBUILD),rpmbuild)

# gm-nesting marker.  Top-level Makefile refuses cmdline / foreign
# GM_TREE before env.mk loads; own re-entry sites clear it via
# `GM_TREE= $(MAKE) ...` so the entry check sees empty.  See
# exception surface for the nested-make guard.
export GM_TREE := 1

# How values reach a target sub-make -- two channels, by what a target's .mk may do with them:
#  - command line (this list; Makefile, _GM_SUBMAKE): what the top level derived and every
#    sub-make must agree on -- layout, variant axes, dirs, compilers, host probes.  It beats any
#    assignment in the sub-make.  Short values only, never a list that grows with the tree
#    (.dry-run-vars.mk below).  It rides in MAKEFLAGS into every make the sub-make starts:
#    target.import.mk strips it before a vendor's own make runs.
#  - environment (export): project-wide defaults a target's .mk may still change (flags.mk:
#    PROJECT_*, WARN_LEVEL, HARDEN, CXX_STD, PATH_MAP -- a makefile assignment beats the
#    environment), and what tools other than make read (SOURCE_DATE_EPOCH, GM_TREE).
# Target-specific variables (SET_TARGET) never cross a process: they only pick, in the top
# level, the per-target values of this list.
# Every sub-make gets _GM_SUBMAKE_VARS (env.mk / flags.mk run in all of them: layout, variant,
# dirs, compilers, jq for DEP_TREE); a sub-make of type <t> also gets _GM_SUBMAKE_VARS_<t>.
_GM_SUBMAKE_VARS := PROJ_TOP ADMIN_DIR BUILD_ARCH BUILD_MODE SANITIZE COVERAGE GM_MACHINE C_PATH CC_PATH \
                    GM_OUT GM_TOP_MAKEFILES DEP_TREE TARGET_DEP TYPE SOURCE_DIR BUILD_DIR OUT_DIR REL_DIR \
                    _GM_JQ
_GM_SUBMAKE_VARS_lib  := _GM_CCACHE BUILD_HOST
_GM_SUBMAKE_VARS_exe  := _GM_CCACHE BUILD_HOST
_GM_SUBMAKE_VARS_test := _GM_CCACHE BUILD_HOST
_GM_SUBMAKE_VARS_go   := _GM_GO
_GM_SUBMAKE_VARS_java := _GM_JAVAC _GM_JAR
_GM_SUBMAKE_VARS_pkg  := _GM_RPMBUILD _GM_UNAME_M _GM_RPM_DIST BUILD_HOST

# SUB_TARGET dispatches a per-target sub-goal into the child make.
# Currently only `clean` is supported.
SUB_TARGET       ?=
SUB_TARGET_VALID := clean
# Sub-goals that act on the named target alone: the top-level make loads no dependency graph for
# them (graph.mk).  A sub-goal that is not listed here gets the full depend.mk.
SUB_TARGET_ALONE := clean
ifneq ($(strip $(o)),)
SUB_TARGET := $(strip $(o))
endif
ifneq ($(strip $(SUB_TARGET)),)
ifeq ($(filter $(SUB_TARGET),$(SUB_TARGET_VALID)),)
$(error SUB_TARGET='$(SUB_TARGET)' is not a valid sub-goal.  Valid: $(SUB_TARGET_VALID))
endif
endif

# Set `GM_VALID_MODES += <name>` in your top-level Makefile before including env.mk to add your own.
GM_VALID_MODES ?= debug release
ifeq ($(filter $(BUILD_MODE),$(GM_VALID_MODES)),)
$(error BUILD_MODE='$(BUILD_MODE)' is not in {$(GM_VALID_MODES)}.$(if $(filter coverage,$(BUILD_MODE)),  Coverage is now an axis: COVERAGE=1 (or `make coverage`).))
endif

# Instrumentation axes, orthogonal to BUILD_MODE: SANITIZE (comma list of
# address / undefined / thread) and COVERAGE=1.  GM_MODE_DIR names the output
# tree from the sorted tags (release-asan-cov).  USER_GUIDE 3.12.
_comma := ,
_space := $(subst ,, )
SANITIZE ?=
_SAN_VALID         := address thread undefined
_SAN_TAG_address   := asan
_SAN_TAG_thread    := tsan
_SAN_TAG_undefined := ubsan
_SAN_RPM_address   := libasan
_SAN_RPM_thread    := libtsan
_SAN_RPM_undefined := libubsan
_SAN_LIST := $(sort $(subst $(_comma),$(_space),$(SANITIZE)))
ifneq ($(filter-out $(_SAN_VALID),$(_SAN_LIST)),)
$(error SANITIZE='$(SANITIZE)': unknown entr(y/ies) $(filter-out $(_SAN_VALID),$(_SAN_LIST)).  Valid: $(_SAN_VALID) (comma separated).)
endif
ifneq ($(and $(filter address,$(_SAN_LIST)),$(filter thread,$(_SAN_LIST))),)
$(error SANITIZE='$(SANITIZE)': address and thread cannot be combined (separate runtimes).)
endif
COVERAGE ?=
ifneq ($(filter-out 0 no 1 yes,$(COVERAGE)),)
$(error COVERAGE='$(COVERAGE)': use 1 or yes (empty, 0, no = off).)
endif
_COV          := $(filter 1 yes,$(COVERAGE))
_VAR_TAGS_SAN := $(foreach s,$(_SAN_LIST),$(_SAN_TAG_$(s)))
_VAR_TAGS     := $(_VAR_TAGS_SAN) $(if $(_COV),cov)
_gm_dir_for    = $(BUILD_MODE)$(if $(strip $(1)),-$(subst $(_space),-,$(sort $(strip $(1)))))
GM_MODE_DIR   := $(call _gm_dir_for,$(_VAR_TAGS))

# Mixed lib+pkg goals refused outside DRY_RUN (dep regen visits both).
ifneq ($(DRY_RUN),1)
_CHECK_LIB_GOALS := $(filter lib%,$(MAKECMDGOALS))
_CHECK_PKG_GOALS := $(filter pkg%,$(MAKECMDGOALS))
ifneq ($(_CHECK_LIB_GOALS),)
ifneq ($(_CHECK_PKG_GOALS),)
$(error Cannot mix lib and pkg targets in one make invocation. \
lib goals=[$(_CHECK_LIB_GOALS)] pkg goals=[$(_CHECK_PKG_GOALS)].  \
Run them as two separate `make` commands so the ordering is explicit.)
endif
endif
endif


# Override GM_OUT to relocate the whole output tree.
GM_OUT ?= $(PROJ_TOP)/build

# What a DRY_RUN sub-make needs from the whole tree (TARGET_ALL: is <x> an in-tree target?;
# GM_SYS_LIBS for LDLIB_CHECK) comes in a file the top-level make writes (project.mk), not on
# the command line: a large tree's lists would overflow the command line, and through MAKEFLAGS
# the environment of every process the sub-make starts.
GM_DRY_VARS_FILE := $(GM_OUT)/.dry-run-vars.mk
ifeq ($(DRY_RUN):$(_GM_TOP),1:)
include $(GM_DRY_VARS_FILE)
endif

# Reproducible-builds timestamp: the last commit time unless set (probed above).  Exported:
# gcc (__DATE__), BUILD_DATE, jar and rpmbuild all honour it.  USER_GUIDE 3.15.
ifneq ($(strip $(SOURCE_DATE_EPOCH)),)
export SOURCE_DATE_EPOCH
endif

GM_LIB_DIR        := $(GM_OUT)/lib/$(BUILD_ARCH)/$(GM_MODE_DIR)
GM_EXEC_DIR       := $(GM_OUT)/exec/$(BUILD_ARCH)/$(GM_MODE_DIR)
GM_PKG_DIR        := $(GM_OUT)/pkg/$(BUILD_ARCH)/$(GM_MODE_DIR)
GM_JAVA_DIR       := $(GM_OUT)/java
GM_GEN_DIR        := $(GM_OUT)/gen/include/$(BUILD_ARCH)
GM_COVERAGE_DIR   := $(GM_OUT)/coverage
GM_RELEASE_DIR    := $(GM_OUT)/release
GM_DEP_FILE       := $(GM_OUT)/depend.mk
GM_PKG_OF_FILE    := $(GM_OUT)/pkg_of.mk
GM_IMPORT_OF_FILE := $(GM_OUT)/import_of.mk


ifneq ($(VV),)
V := 1
MAKEFLAGS += --trace
endif

GM_ECHO := @$(ECHO)
ifneq ($(V),)
Q :=
else
Q := @
MAKEFLAGS += --silent
endif

V_CC      = $(GM_ECHO) "  CC      $(notdir $<)  ($(TARGET))"
V_CXX     = $(GM_ECHO) "  CXX     $(notdir $<)  ($(TARGET))"
V_DEP     = $(GM_ECHO) "  DEP     $(notdir $<)  ($(TARGET))"
V_LD_EXE  = $(GM_ECHO) "  LD      $(notdir $@)"
V_LD_SO   = $(GM_ECHO) "  SO      $(notdir $@)"
V_AR      = $(GM_ECHO) "  AR      $(notdir $@)"
V_LN      = $(GM_ECHO) "  LN      $(notdir $@)"
V_GEN     = $(GM_ECHO) "  GEN     $(notdir $@)"
V_VER     = $(GM_ECHO) "  VER     $(notdir $@)"
V_JSON    = $(GM_ECHO) "  JSON    $(notdir $@)"
V_DEPS    = $(GM_ECHO) "  DEPS    $(1)"
V_SKIP    = $(GM_ECHO) "  SKIP    $(1)"
V_RPM     = $(GM_ECHO) "  RPM     $(notdir $@)"
V_GO      = $(GM_ECHO) "  GO      $(TARGET)"
V_JAR     = $(GM_ECHO) "  JAR     $(notdir $@)"
V_JAVAC   = $(GM_ECHO) "  JAVAC   $(TARGET)  ($(words $(JAVASOURCE)) src)"
V_TEST    = $(GM_ECHO) "  TEST    $*"
V_CLEAN   = $(GM_ECHO) "  CLEAN   $(TARGET)  ($(BUILD_MODE))"


# Runtime Python-dependency policy: gm assumes the user has run once,
# `python3 -m pip install -r production/requirements.txt`.
GM_PYDEP_REQS := $(ADMIN_DIR)/requirements.txt


# Framework files every target implicitly depends on.  Changes here
# invalidate every downstream artefact (both make's incremental
# rebuild AND dep_query's DAG walk).  Dispatch-only files (coverage,
# test, incremental, target.dry-run) are deliberately excluded -- they
# don't change artefact bytes.
GM_FRAMEWORK_CORE_MK = \
    $(GM_TOP_MAKEFILES)                      \
    $(ADMIN_DIR)/make/env.mk                 \
    $(ADMIN_DIR)/make/flags.mk               \
    $(ADMIN_DIR)/make/project.mk             \
    $(ADMIN_DIR)/make/target.common.mk

GM_FRAMEWORK_JSON := $(GM_OUT)/gm.dep.json
$(GM_FRAMEWORK_JSON): $(GM_FRAMEWORK_CORE_MK) | $(GM_OUT)
	$(V_JSON)
	$(Q)printf '%s\n' $(GM_FRAMEWORK_CORE_MK) | \
	    jq -R . | \
	    jq -s '{file: "gm-framework", deps: .}' > $@


define uniq =
	$(eval seen :=)
	$(foreach _,$1,$(if $(filter $_,$(seen)),,$(eval seen += $_)))
	$(seen)
endef

define _NL


endef

_sq   = '$(subst ','\'',$(1))'

# $(eval $(call _FLAG_STAMP,<stamp>,<signature var>,<message>)): flag-change stamp.  Compared at
# parse time; only a changed signature gets a rule, which rewrites the stamp (not under -n) and so
# rebuilds what depends on it.  An unchanged one forks nothing.
.PHONY: _gm_force
_gm_force: ;
define _FLAG_STAMP
ifneq ($$(strip $$(file <$(1))),$$(strip $$($(2))))
$(1): _gm_force | $$(BUILD_DIR)
	$$(if $$(wildcard $$@),@$$(ECHO) "  FLAGS   $$(TARGET): $(3)")
	$$(if $$(_GM_MAKE_N),,$$(file >$$@,$$(strip $$($(2)))))
endif
endef

# $(eval $(call _CACHE,<VAR>,<file>)): a `<VAR> := $(shell <slow command>)` that is not re-run
# by every make.  The command's output is stored in <file>, a two-line makefile under BUILD_DIR
#     <VAR>_FOR := <the key it was made with>
#     <VAR> := <the output>
# which every make simply includes.  Make itself keeps it fresh: <file> is a target whose
# prerequisites are <VAR>_DEPS, so when one of them is newer (or the stored key differs from
# <VAR>_KEY) make re-runs the command, rewrites <file> and re-reads its makefiles.  Before the
# call define
#   <VAR>_CMD   the command (recursive variable; prints the value)
#   <VAR>_KEY   what else the value depends on (arguments, tool paths, environment)
#   <VAR>_DEPS  the files it depends on (may use $(<VAR>), the cached value)
# Users: `go list` (target.go.mk), the pkg.yaml in-tree list (target.pkg.mk), rpm's %{?dist}
# (project.mk).  An empty value is not trusted (an offline `go list` prints nothing): it is
# recomputed by the next make.  The recipe captures the output first (`out=$(cmd) || exit 1`:
# a failing command fails the build) and then flattens it (`out=$(echo $out)`: one line, single
# spaces -- a multi-line value would not parse as a makefile); one `$(echo $(cmd))` would hide
# the command's exit status behind echo's.  Several makes may rebuild the same file at once under -j (a
# pkg's build and its <pkg>-header both include its cache): each writes its own .tmp.<pid>
# and renames it into place.
define _CACHE
-include $(2)
ifneq ($$(strip $$($(1)_FOR)),$$(strip $$($(1)_KEY)))
ifeq ($$(MAKE_RESTARTS),)
$(2): _gm_force
endif
endif
$(2): $$($(1)_DEPS)
	@mkdir -p $$(@D)
	@out=$$$$($$($(1)_CMD)) || exit 1 ; out=$$$$(echo $$$$out) ; \
	 { [ -z "$$$$out" ] || printf '$(1)_FOR := %s\n' $$(call _sq,$$(subst $$$$,$$$$$$$$,$$(strip $$($(1)_KEY)))) ; \
	   printf '$(1) := %s\n' "$$$$out" ; } > $$@.tmp.$$$$$$$$ && mv $$@.tmp.$$$$$$$$ $$@
endef

# $(call _have,<tool>) -> the tool's path (empty if missing); <tool> may be a path or a PATH name.
_have = $(if $(findstring /,$(1)),$(wildcard $(1)),$(shell command -v $(1) 2>/dev/null))

# jq writes the compile_commands.json fragments and the DEP_TREE sidecars.  Optional: without
# it there is no compile database; DEP_TREE=yes refuses to start.
GM_JQ := $(_GM_JQ)
ifeq ($(DEP_TREE),yes)
ifeq ($(GM_JQ),)
$(error DEP_TREE=yes needs jq (the .dep.json sidecars are written with it))
endif
endif

LDLIB_CHECK ?= 0
_SCAN_LIB_DIRS = $(shell \
    for p in $(1); do \
        [ -d "$$p" ] && ls "$$p" 2>/dev/null ; \
    done | sed -nE 's/^lib([^./]+)\.(so|a).*/\1/p' | sort -u)

include $(ADMIN_DIR)/make/flags.mk
# A target sub-make reads the dependency scan's maps, before the target's .mk (which may use
# them).  Read only: only the top-level make rebuilds them (graph.mk).  The scan runs imports,
# then pkgs, then the rest, so a scan sub-make finds the map its type reads already written.
ifeq ($(_GM_TOP),)
-include $(GM_PKG_OF_FILE) $(GM_IMPORT_OF_FILE)
endif
