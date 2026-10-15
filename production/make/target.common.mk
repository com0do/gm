# target.common.mk - shared bootstrap for every target.<type>.mk.
# Pins .DEFAULT_GOAL to $(TARGET).  env.mk is NO LONGER included here:
# the dispatcher loads it BEFORE the user's .mk so user knobs like
# `CFLAGS := $(filter-out -Werror,$(CFLAGS))` see the framework's
# real flag values (previously the user's .mk parsed while CFLAGS was
# still empty -> filter-out was a no-op).  Load order is now:
#   -f env.mk        (framework defaults + tool paths + flags.mk)
#   -f <user>.mk     (per-target customization; visible framework state)
#   -f target.<type>.mk  (rules; uses final flags)

.DEFAULT_GOAL := $(TARGET)

# RPATH of exes / cgo binaries: relative to their real dir (USER_GUIDE 3.14);
# `\$$ORIGIN` reaches the linker as a literal $ORIGIN.
_GM_UPS := $(subst $(_space),/,$(foreach c,$(subst /, ,$(patsubst $(GM_OUT)/%,%,$(BUILD_DIR))),..))
_GM_RPATH_LIB := $(if $(filter $(GM_OUT)/%,$(BUILD_DIR)),\$$ORIGIN/$(_GM_UPS)/$(patsubst $(GM_OUT)/%,%,$(GM_LIB_DIR)),$(GM_LIB_DIR))

# `_gm_show` (make show-<type|name>): what this target's type knows, one `<field> TAB <value>`
# line per field.  Each target.<type>.mk sets GM_SHOW_FIELDS and SHOW_<field> (recursive: they
# are read when the recipe runs, after the whole file is parsed).
_rel = $(patsubst $(PROJ_TOP)/%,%,$(1))
.PHONY: _gm_show
_gm_show:
	@$(foreach f,$(GM_SHOW_FIELDS),printf '%s\t%s\n' $(call _sq,$(f)) $(call _sq,$(strip $(SHOW_$(f)))) ;) :
