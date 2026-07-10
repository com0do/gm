# SPDX-License-Identifier: MIT
#
# env.mk -- build environment.  Loaded by the top-level Makefile and by every
# sub-make (via target.common.mk).  Pulls in flags.mk.  Kills GNU
# make's builtin rules/variables so the explicit assignments below
# are the single source of truth.

SINGLE_REPO := Y
ifeq ($(SINGLE_REPO),Y)
PROJ_TOP    ?= $(CURDIR)
ADMIN_DIR   ?= $(PROJ_TOP)/production
else
PROJ_TOP    ?= $(dir $(CURDIR))
ADMIN_DIR   ?= $(CURDIR)
endif

MAKEFILE     := $(lastword $(filter-out $(ADMIN_DIR)/make/% ,$(abspath $(MAKEFILE_LIST))))
MAKEFILE_DIR := $(abspath $(dir $(MAKEFILE)))
MAKEFLAGS += --no-builtin-rules --no-builtin-variables --no-print-directory


MKDIR    := /usr/bin/mkdir -p
RM       := /usr/bin/rm -f
TOUCH    := /usr/bin/touch
FIND     := /usr/bin/find
XARGS    := /usr/bin/xargs
AWK      := /bin/awk
BASENAME := /bin/basename
CAT      := /bin/cat
CHMOD    := /bin/chmod
CMP      := /bin/cmp
CP       := /bin/cp
CUT      := /bin/cut
DIFF     := /bin/diff
ECHO     := /bin/echo
EGREP    := /bin/egrep
FGREP    := /bin/fgrep
GREP     := /bin/grep
GZIP     := /bin/gzip
HOSTNAME := /bin/hostname
LN       := /bin/ln -fs
MV       := /bin/mv
NAWK     := /bin/nawk
PRINTF   := /bin/printf
PKGMK    := /usr/bin/pkgmk
PKGTRANS := /usr/bin/pkgtrans
RMDIR    := /bin/rmdir
RSH      := /bin/rsh
SED      := /bin/sed
SHELL    := /bin/bash
SLEEP    := /bin/sleep
SORT     := /bin/sort
TAR      := /bin/tar
UNAME    := /bin/uname

AR       := /usr/bin/ar
ARFLAGS  := -rcs

GO       ?= $(firstword $(wildcard $(GOROOT)/bin/go) $(shell command -v go 2>/dev/null) go)


CONFIG_MODE  := MK
BUILD_MODE   ?= debug

ifeq ($(BUILD_ARCH),)
ifeq ($(shell uname -s),Linux)
BUILD_ARCH   := rhlinux
else
BUILD_ARCH   := $(shell uname -s | tr A-Z a-z)
endif
endif

# gm-nesting marker.  Top-level Makefile refuses cmdline / foreign
# GM_TREE before env.mk loads; own re-entry sites clear it via
# `GM_TREE= $(MAKE) ...` so the entry check sees empty.  See
# exception surface for the nested-make guard.
export GM_TREE := 1

# SUB_TARGET dispatches a per-target sub-goal into the child make.
# Currently only `clean` is supported.
SUB_TARGET       ?=
SUB_TARGET_VALID := clean
ifneq ($(strip $(o)),)
SUB_TARGET := $(strip $(o))
endif
ifneq ($(strip $(SUB_TARGET)),)
ifeq ($(filter $(SUB_TARGET),$(SUB_TARGET_VALID)),)
$(error SUB_TARGET='$(SUB_TARGET)' is not a valid sub-goal.  Valid: $(SUB_TARGET_VALID))
endif
endif

# Set `GM_VALID_MODES += <name>` in your top-level Makefile before including env.mk to add your own.
GM_VALID_MODES ?= debug release coverage
ifeq ($(filter $(BUILD_MODE),$(GM_VALID_MODES)),)
$(error BUILD_MODE='$(BUILD_MODE)' is not in {$(GM_VALID_MODES)}.  )
endif

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

GM_LIB_DIR        := $(GM_OUT)/lib/$(BUILD_ARCH)/$(BUILD_MODE)
GM_EXEC_DIR       := $(GM_OUT)/exec/$(BUILD_ARCH)/$(BUILD_MODE)
GM_PKG_DIR        := $(GM_OUT)/pkg/$(BUILD_ARCH)/$(BUILD_MODE)
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
GM_FRAMEWORK_CORE_MK := \
    $(PROJ_TOP)/Makefile                     \
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

LDLIB_CHECK ?= 0
_SCAN_LIB_DIRS = $(shell \
    for p in $(1); do \
        [ -d "$$p" ] && ls "$$p" 2>/dev/null ; \
    done | sed -nE 's/^lib([^./]+)\.(so|a).*/\1/p' | sort -u)

include $(ADMIN_DIR)/make/flags.mk
-include $(GM_PKG_OF_FILE)
-include $(GM_IMPORT_OF_FILE)
