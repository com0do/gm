# _pkg_alarm.mk - alarm-lib boilerplate.  Emits `alarms.h` + `alarms.cxx`
# under $(GM_GEN_DIR)/$(_ALARM_PKG)/ from the pkg's `alarms:` YAML.
# Usage in a consumer .mk (typically `<pkg-srcdir>/alarms/libNAME.mk`):
#     _ALARM_PKG      := pkg-p2
#     _ALARM_PKG_YAML := $(dir $(lastword $(MAKEFILE_LIST)))../deployment/pkg.yaml
#     include $(ADMIN_DIR)/make/_pkg_alarm.mk

ifeq ($(strip $(_ALARM_PKG)),)
$(error _pkg_alarm.mk: _ALARM_PKG must be set (e.g. `_ALARM_PKG := pkg-p2`))
endif
ifeq ($(strip $(_ALARM_PKG_YAML)),)
$(error _pkg_alarm.mk: _ALARM_PKG_YAML must be set (path to the pkg's pkg.yaml))
endif

_ALARM_OUT_DIR := $(GM_GEN_DIR)/$(_ALARM_PKG)
_ALARM_CXX     := $(_ALARM_OUT_DIR)/alarms.cxx
_ALARM_H       := $(_ALARM_OUT_DIR)/alarms.h

CXX_STD     ?= c++17
# The alarms lib is auto-generated FROM $(_ALARM_PKG)'s yaml but
# isn't necessarily listed in that pkg's files[], so `yes` (which
# reads pkg_of.mk) can't be used -- name the pkg explicitly.
PKG_HEADERS := $(_ALARM_PKG)
CXXSOURCE   += $(notdir $(_ALARM_CXX))

vpath %.cxx $(_ALARM_OUT_DIR)

# One pkg-build.py call emits both files; the header is a co-product
# via an empty-recipe rule (avoids requiring GNU make 4.3+ `&:`).
$(_ALARM_CXX): $(_ALARM_PKG_YAML) $(ADMIN_DIR)/make/scripts/pkg-build.py \
               $(ADMIN_DIR)/make/schemas/pkg.schema.yaml
	$(V_GEN)
	$(Q)python3 $(ADMIN_DIR)/make/scripts/pkg-build.py \
	    --pkg        $(_ALARM_PKG_YAML) \
	    --alarms-out $(_ALARM_OUT_DIR) >/dev/null

$(_ALARM_H): $(_ALARM_CXX) ;
