# SPDX-License-Identifier: MIT
#
# target.go.mk -- Go sub-target rules.  Binary = .mk basename.
# Knobs (all optional): GO_PROJ_ROOT (default: MAKEFILE_DIR),
# GO_PROJ_SUBPKG, GO_BUILD_FLAGS (GO_DEFAULT_FLAGS = -buildvcs=false -trimpath -ldflags=-buildid=), LDLIBS (in-tree C libs; cgo picks
# them up via injected CGO_LDFLAGS -- see example/cgo).
# DEP_TREE=yes -> <target>.dep.json via make/scripts/depgo.sh
# (`go list -deps` + jq).


CURRENT_FILE := $(lastword $(abspath $(MAKEFILE_LIST)))
MAKEFILE     := $(lastword $(filter-out $(ADMIN_DIR)/make/% ,$(abspath $(MAKEFILE_LIST))))
TARGET       := $(basename $(notdir $(MAKEFILE)))
MAKEFILE_DIR := $(abspath $(dir $(MAKEFILE)))

GM_FRAMEWORK_MK := $(GM_FRAMEWORK_CORE_MK) \
    $(CURRENT_FILE) \
    $(ADMIN_DIR)/make/scripts/depgo.sh

include $(ADMIN_DIR)/make/target.common.mk


ifeq ($(DRY_RUN),1)
# LDLIBS -> lib<name> like target.c.mk; empty for pure-Go targets.
DRY_DEPS := $(strip $(filter $(patsubst -l%,lib%,$(LDLIBS)),$(TARGET_ALL)))
include $(ADMIN_DIR)/make/target.dry-run.mk
else


GO_PROJ_ROOT   ?= $(MAKEFILE_DIR)
GO_PROJ_SUBPKG ?=
GO_BUILD_FLAGS ?=
# no VCS stamp (binary changes with every commit / dirty tree), no build paths, no build id
# (Go's id hashes the cgo flags, i.e. the checkout path).  A -ldflags of your own replaces this one.
GO_DEFAULT_FLAGS ?= -buildvcs=false -trimpath -ldflags=-buildid=
GO_BUILD_PKG   := $(if $(GO_PROJ_SUBPKG),./$(GO_PROJ_SUBPKG),.)

ifeq ($(wildcard $(GO_PROJ_ROOT)/go.mod),)
$(error target.go.mk: GO_PROJ_ROOT=$(GO_PROJ_ROOT) has no go.mod -- declare it in $(MAKEFILE))
endif

ifneq ($(strip $(BIN_NAME)),)
$(error $(MAKEFILE): BIN_NAME is removed.  The binary is always named after the .mk file.  Rename it instead: `git mv $(notdir $(MAKEFILE)) $(strip $(BIN_NAME)).mk`)
endif

TARGET_BIN   := $(BUILD_DIR)/$(TARGET)
TARGET_PATH  := $(OUT_DIR)/$(TARGET)


ifeq ($(DEP_TREE),yes)
DEP_JSON_LINK := $(OUT_DIR)/$(TARGET).dep.json
DEP_JSON_ALL  := $(DEP_JSON_LINK)
else
DEP_JSON_ALL  :=
endif


$(TARGET) :: $(TARGET_PATH) $(DEP_JSON_ALL);

# The sources `go list` resolves, cached (_CACHE, env.mk): rebuilt when one of them, a directory
# holding them (a file added / removed), go.mod / go.sum or the go env file changes.
_GO_MODS       := $(wildcard $(GO_PROJ_ROOT)/go.mod $(GO_PROJ_ROOT)/go.sum)
_GO_SRCS_KEY   := $(GO) $(GO_PROJ_ROOT) $(GO_BUILD_PKG) $(GOFLAGS) $(GOOS) $(GOARCH) $(CGO_ENABLED)
_GO_SRCS_DEPS   = $(_GO_SRCS) $(patsubst %/,%,$(sort $(dir $(_GO_SRCS)))) $(_GO_MODS) \
    $(wildcard $(or $(GOENV),$(or $(XDG_CONFIG_HOME),$(HOME)/.config)/go/env))
_GO_SRCS_CMD    = cd $(GO_PROJ_ROOT) 2>/dev/null && \
    $(GO) list -buildvcs=false -deps -f \
        '{{if not .Standard}}{{.Dir}} {{.GoFiles}} {{.CgoFiles}} {{.CFiles}} {{.HFiles}} {{.SFiles}}{{end}}' \
        $(GO_BUILD_PKG) 2>/dev/null | \
    awk 'NF { dir=$$1; for (i=2; i<=NF; i++) { gsub(/\[|\]|,/, "", $$i); if ($$i) print dir "/" $$i } }' | \
    sort -u
$(eval $(call _CACHE,_GO_SRCS,$(BUILD_DIR)/.$(TARGET).gosrcs.mk))
# A source deleted since the cache was written must not stop the build (cf. gcc -MP).
ifneq ($(strip $(_GO_SRCS)),)
$(_GO_SRCS):
endif
ifneq ($(MAKECMDGOALS),clean)
ifneq ($(MAKE_RESTARTS),)
ifeq ($(strip $(_GO_SRCS)),)
$(warning $(MAKEFILE): `go list` found no sources (offline? broken module?): edits to the Go sources will not trigger a rebuild)
endif
endif
endif
_GO_LDLIB_PATHS := $(foreach _l,$(patsubst -l%,lib%,$(LDLIBS)),\
                     $(wildcard $(GM_LIB_DIR)/$(_l).a $(GM_LIB_DIR)/$(_l).so))

_GO_FLAGS_STAMP := $(BUILD_DIR)/.$(TARGET).goflags.stamp
_GO_FLAGS_SIG   := $(GO)|$(GO_DEFAULT_FLAGS)|$(GO_BUILD_FLAGS)|$(GO_PROJ_SUBPKG)|$(LDLIBS)|$(GM_LIB_DIR)|$(GM_GEN_DIR)|$(C_PATH)|$(CC_PATH)
$(eval $(call _FLAG_STAMP,$(_GO_FLAGS_STAMP),_GO_FLAGS_SIG,go/cgo flags changed))

_GO_CGO_LDFLAGS := -L$(GM_LIB_DIR) -Wl,-rpath,$(_GM_RPATH_LIB) \
    $(if $(_COV),-lgcov)

# cgo: same compiler (C_PATH / CC_PATH) and sanitizer flags as the in-tree C libs;
# `go build -asan` is Go's ASan interop (USER_GUIDE 3.12).
_GO_ASAN    := $(if $(filter address,$(_SAN_LIST)),-asan)
_GO_CGO_SAN := $(if $(_SAN_LIST),$(SANITIZE_FLAGS))

$(TARGET_BIN): $(_GO_SRCS) $(_GO_MODS) $(_GO_LDLIB_PATHS) $(GM_FRAMEWORK_MK) $(_GO_FLAGS_STAMP) | $(BUILD_DIR)
	$(V_GO)
	$(Q)cd $(GO_PROJ_ROOT) && \
	    CGO_CFLAGS="-I$(GM_GEN_DIR) $(_GO_CGO_SAN) $${CGO_CFLAGS}" \
	    CGO_LDFLAGS="$(_GO_CGO_LDFLAGS) $(_GO_CGO_SAN) $${CGO_LDFLAGS}" \
	    CC='$(C_PATH)' CXX='$(CC_PATH)' \
	    $(GO) build $(_GO_ASAN) $(GO_DEFAULT_FLAGS) $(GO_BUILD_FLAGS) -o $(TARGET_BIN) $(GO_BUILD_PKG)

$(TARGET_PATH) : $(TARGET_BIN) | $(OUT_DIR)
	$(V_LN)
	$(Q)$(LN) $(TARGET_BIN) $@

.PRECIOUS: %/$(GM_MODE_DIR)
%/$(GM_MODE_DIR):
	$(Q)$(MKDIR) $@


$(DEP_JSON_LINK): $(TARGET_BIN) $(GM_FRAMEWORK_MK)
	$(V_JSON)
	$(Q)GO='$(GO)' $(ADMIN_DIR)/make/scripts/depgo.sh \
	    -p $(GO_PROJ_ROOT) \
	    $(if $(GO_PROJ_SUBPKG),-s $(GO_PROJ_SUBPKG)) \
	    -t $(TARGET_PATH) \
	    -o $@.tmp
	@# Fold in what `go list` cannot see (as link_dep_json.jq does in target.c.mk): the in-tree C
	@# libraries cgo links (LDLIBS), this .mk and the framework files.  Kept in a jq post-pass
	@# so depgo.sh stays flag-clean.
	$(Q)jq --arg EXTRA "$(_GO_LDLIB_PATHS) $(MAKEFILE) $(GM_FRAMEWORK_MK)" \
	    '.deps = ((.deps + ($$EXTRA | split(" ") | map(select(length > 0)))) | unique | sort)' \
	    $@.tmp > $@ && $(RM) $@.tmp


clean:
	$(Q)$(RM) $(TARGET_PATH) $(TARGET_BIN) $(DEP_JSON_LINK)
	$(Q)$(RM) $(_GO_FLAGS_STAMP)
	$(V_CLEAN)

GM_SHOW_FIELDS := output module package links run
SHOW_output    = $(call _rel,$(TARGET_PATH))
SHOW_module    = $(word 2,$(file <$(GO_PROJ_ROOT)/go.mod)) ($(call _rel,$(GO_PROJ_ROOT)))
SHOW_package   = $(GO_BUILD_PKG)
SHOW_links     = $(or $(filter -l%,$(LDLIBS)),-)
SHOW_run       = make run-$(TARGET) RUN_ARGS=...


endif # DRY_RUN
