# libp2alarms -- pkg-p2's alarm library.  Source (.cxx) and public
# header (.h) are auto-generated from the pkg's `alarms:` in pkg.yaml
# by the shared shim below; the artefact is a normal shared lib built
# by target.c.mk.  Other modules link `-lp2alarms` and
# `#include <pkg-p2/alarms.h>` for the alarm enum + data table.
_ALARM_PKG      := pkg-p2
_ALARM_PKG_YAML := $(dir $(lastword $(MAKEFILE_LIST)))../deployment/pkg.yaml
include $(ADMIN_DIR)/make/_pkg_alarm.mk
