# SPDX-License-Identifier: MIT
#
# target.go.mk -- Go sub-target rules.  Binary = .mk basename.
# Knobs (all optional): GO_PROJ_ROOT (default: MAKEFILE_DIR),
# GO_PROJ_SUBPKG, GO_BUILD_FLAGS, LDLIBS (in-tree C libs; cgo picks
# them up via injected CGO_LDFLAGS -- see example/gcgo).
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

_GO_SRCS       := $(shell cd $(GO_PROJ_ROOT) 2>/dev/null && \
    $(GO) list -deps -f \
        '{{if not .Standard}}{{.Dir}} {{.GoFiles}} {{.CgoFiles}} {{.CFiles}} {{.HFiles}} {{.SFiles}}{{end}}' \
        $(GO_BUILD_PKG) 2>/dev/null | \
    awk 'NF { dir=$$1; for (i=2; i<=NF; i++) { gsub(/\[|\]|,/, "", $$i); if ($$i) print dir "/" $$i } }' | \
    sort -u)
_GO_MODS       := $(wildcard $(GO_PROJ_ROOT)/go.mod $(GO_PROJ_ROOT)/go.sum)
_GO_LDLIB_PATHS := $(foreach _l,$(patsubst -l%,lib%,$(LDLIBS)),\
                     $(wildcard $(GM_LIB_DIR)/$(_l).a $(GM_LIB_DIR)/$(_l).so))

_GO_FLAGS_STAMP := $(BUILD_DIR)/.$(TARGET).goflags.stamp
_GO_FLAGS_SIG   := $(GO)|$(GO_BUILD_FLAGS)|$(GO_PROJ_SUBPKG)|$(LDLIBS)|$(GM_LIB_DIR)|$(GM_GEN_DIR)
.PHONY: _go_flags_force
_go_flags_force: ;
$(_GO_FLAGS_STAMP): _go_flags_force | $(BUILD_DIR)
	@sig='$(_GO_FLAGS_SIG)' ; \
	 [ "$$sig" = "$$(cat $@ 2>/dev/null || true)" ] && exit 0 ; \
	 had=$$( [ -f $@ ] && echo 1 ) ; \
	 printf '%s' "$$sig" > $@ ; \
	 [ -n "$$had" ] && $(ECHO) "  FLAGS   $(TARGET): go/cgo flags changed" ; \
	 exit 0

_GO_CGO_LDFLAGS := -L$(GM_LIB_DIR) -Wl,-rpath,$(GM_LIB_DIR) \
    $(if $(filter coverage,$(BUILD_MODE)),-lgcov,)

$(TARGET_BIN): $(_GO_SRCS) $(_GO_MODS) $(_GO_LDLIB_PATHS) $(GM_FRAMEWORK_MK) $(_GO_FLAGS_STAMP) | $(BUILD_DIR)
	$(V_GO)
	$(Q)cd $(GO_PROJ_ROOT) && \
	    CGO_CFLAGS="-I$(GM_GEN_DIR) $${CGO_CFLAGS}" \
	    CGO_LDFLAGS="$(_GO_CGO_LDFLAGS) $${CGO_LDFLAGS}" \
	    $(GO) build $(GO_BUILD_FLAGS) -o $(TARGET_BIN) $(GO_BUILD_PKG)

$(TARGET_PATH) : $(TARGET_BIN) | $(OUT_DIR)
	$(V_LN)
	$(Q)$(LN) $(TARGET_BIN) $@

.PRECIOUS: %/$(BUILD_MODE)
%/$(BUILD_MODE):
	$(Q)$(MKDIR) $@


$(DEP_JSON_LINK): $(TARGET_BIN) $(GM_FRAMEWORK_MK)
	$(V_JSON)
	$(Q)GO='$(GO)' $(ADMIN_DIR)/make/scripts/depgo.sh \
	    -p $(GO_PROJ_ROOT) \
	    $(if $(GO_PROJ_SUBPKG),-s $(GO_PROJ_SUBPKG)) \
	    -t $(TARGET_PATH) \
	    -o $@.tmp
	@# Fold framework files into deps[] (parallel to link_dep_json.jq
	@# in target.c.mk).  Kept in a jq post-pass so depgo.sh stays flag-clean.
	$(Q)jq --arg FRAMEWORK "$(GM_FRAMEWORK_MK)" \
	    '.deps = ((.deps + ($$FRAMEWORK | split(" ") | map(select(length > 0)))) | unique | sort)' \
	    $@.tmp > $@ && $(RM) $@.tmp


clean:
	$(Q)$(RM) $(TARGET_PATH) $(TARGET_BIN) $(DEP_JSON_LINK)
	$(Q)$(RM) $(_GO_FLAGS_STAMP)
	$(V_CLEAN)


endif # DRY_RUN
