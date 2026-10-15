# SPDX-License-Identifier: MIT
#
# Framework entry point.  User-facing cmd reference: docs/1-USER_GUIDE.md §4.

.DEFAULT_GOAL := all
# GM_TREE comes from the environment: empty here, unless a gm make started us (env.mk exports
# GM_TREE=1 to everything it runs; gm's own re-entries clear it with `GM_TREE= $(MAKE)`).  On the
# command line it would beat env.mk's assignment and switch the guard off for every sub-make.
ifneq ($(strip $(GM_TREE)),)
$(error gm cannot be nested. GM_TREE is gm internal variable, \
do not set it on the command line.)
endif
ifeq ($(origin GM_TREE),command line)
$(error GM_TREE is gm internal: do not set it on the command line)
endif

# The tree is the working directory: `make -f <tree>/Makefile` elsewhere would find no framework.
ifeq ($(wildcard $(CURDIR)/production/make/env.mk),)
$(error gm: $(CURDIR) is not a gm tree (no production/make/env.mk).  Run make in the tree, or make -C <tree>)
endif

# Include order matters.
include $(CURDIR)/production/make/env.mk
include $(CURDIR)/production/make/project.mk
include $(CURDIR)/production/make/incremental.mk
include $(CURDIR)/production/make/coverage.mk
include $(CURDIR)/production/make/test.mk
include $(CURDIR)/production/make/graph.mk

.PHONY: all clean distclean precheck prereq $(TARGET_ALL)
all:   $(TARGET_ALL) compile_commands $(if $(_GM_NO_GO),_skip_go) $(if $(_GM_NO_JAVA),_skip_java)
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

_GM_SUBMAKE = $(MAKE) -C $(SOURCE_DIR) -f $(ADMIN_DIR)/make/env.mk \
    -f $($(1)_mkfile) -f $(call TARGET_RULES_FOR,$(TYPE)) \
    $(foreach v,$(_GM_SUBMAKE_VARS) $(_GM_SUBMAKE_VARS_$(TYPE)),$(v)=$(call _sq,$($(v)))) $(2)
$(TARGET_ALL):
	+@$(call _GM_SUBMAKE,$@,$(SUB_TARGET))


_PKG_HEADER_TARGETS := $(patsubst %,%-header,$(TARGET_PKG))
.PHONY: $(_PKG_HEADER_TARGETS)
$(_PKG_HEADER_TARGETS): %-header:
	+@$(call _GM_SUBMAKE,$*,header)


