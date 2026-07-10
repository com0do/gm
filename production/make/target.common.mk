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
