# SPDX-License-Identifier: MIT
#
# Framework entry point.  User-facing cmd reference: docs/1-USER_GUIDE.md §4.

.DEFAULT_GOAL := all
ifneq ($(strip $(GM_TREE)),)
$(error gm cannot be nested. GM_TREE is gm internal variable, \
do not set it on the command line.)
endif

# Include order matters.
include $(CURDIR)/production/make/env.mk
include $(CURDIR)/production/make/project.mk
include $(CURDIR)/production/make/incremental.mk
include $(CURDIR)/production/make/coverage.mk
include $(CURDIR)/production/make/test.mk

ifneq ($(DRY_RUN),1)
include $(TARGET_DEP)
ifneq ($(_DEP_DIGEST),$(_DEP_DIGEST_NOW))
$(shell $(RM) $(TARGET_DEP) $(GM_PKG_OF_FILE))
endif
endif

.PHONY: all clean distclean precheck prereq
all:   $(TARGET_ALL) compile_commands
clean: SUB_TARGET := clean
clean: $(TARGET_ALL)

distclean:
	@$(RM) -r $(GM_OUT)
	@$(ECHO) "... distclean: removed $(GM_OUT)"

precheck:
	@bash $(ADMIN_DIR)/tools/precheck.sh $(if $(FIX),--fix) $(if $(FAST),--fast)

prereq:
	@py=$$(command -v python3 || command -v python) ; \
	[ -n "$$py" ] || { echo "gm: no python3 in PATH" >&2 ; exit 1 ; } ; \
	in_venv=$$("$$py" -c 'import sys; print(1 if sys.prefix!=sys.base_prefix else 0)') ; \
	option= ; [ ! "$$in_venv" = 1 ] && option=--user ; \
	$(if $(V),set -x,echo "+ $$py -m pip install --disable-pip-version-check $$option -r $(GM_PYDEP_REQS)") ; \
	"$$py" -m pip install --disable-pip-version-check $$option -r $(GM_PYDEP_REQS)


TARGET_RULES_FOR = $(strip \
    $(if $(filter exe lib test,$(1)),      $(ADMIN_DIR)/make/target.c.mk,\
    $(if $(filter go,$(1)),                $(ADMIN_DIR)/make/target.go.mk,\
    $(if $(filter java,$(1)),              $(ADMIN_DIR)/make/target.java.mk,\
    $(if $(filter pkg,$(1)),               $(ADMIN_DIR)/make/target.pkg.mk,\
    $(if $(filter import-lib import-exe,$(1)),$(ADMIN_DIR)/make/target.import.mk,\
    $(error No recipe file for target type "$(1)")))))))

_GM_CMDLINE_ROOT := PROJ_TOP='$(PROJ_TOP)' ADMIN_DIR='$(ADMIN_DIR)' \
                    BUILD_ARCH='$(BUILD_ARCH)' BUILD_MODE='$(BUILD_MODE)' \
                    GM_OUT='$(GM_OUT)' DEP_TREE='$(DEP_TREE)'
_GM_CMDLINE_PROJ  = GM_SYS_LIBS='$(GM_SYS_LIBS)' \
                    TARGET_ALL='$(TARGET_ALL)' TARGET_DEP='$(TARGET_DEP)'
_GM_CMDLINE = $(_GM_CMDLINE_ROOT) $(_GM_CMDLINE_PROJ)

$(TARGET_ALL):
	@$(MAKE) -C $(SOURCE_DIR) -f $(ADMIN_DIR)/make/env.mk \
	    -f $($@_mkfile) -f $(call TARGET_RULES_FOR,$(TYPE)) $(_GM_CMDLINE) \
	    BUILD_DIR='$(BUILD_DIR)' OUT_DIR='$(OUT_DIR)' SOURCE_DIR='$(SOURCE_DIR)' \
	    REL_DIR='$(REL_DIR)' TYPE='$(TYPE)' $(SUB_TARGET)


_PKG_HEADER_TARGETS := $(patsubst %,%-header,$(TARGET_PKG))
.PHONY: $(_PKG_HEADER_TARGETS)
$(_PKG_HEADER_TARGETS): %-header:
	@$(MAKE) -C $(SOURCE_DIR) \
	    -f $(ADMIN_DIR)/make/env.mk \
	    -f $($*_mkfile) \
	    -f $(ADMIN_DIR)/make/target.pkg.mk \
	    $(_GM_CMDLINE) \
	    BUILD_DIR='$(BUILD_DIR)' OUT_DIR='$(OUT_DIR)' SOURCE_DIR='$(SOURCE_DIR)' \
	    REL_DIR='$(REL_DIR)' TYPE='$(TYPE)' header


