# libtmalarms -- pkg-tmd's alarm table, generated from the `alarms:` list of its pkg.yaml
# (_pkg_alarm.mk writes alarms.h and alarms.cxx under build/gen).  Static: linked into tmd.
#
# Shows: code generated from packaging data, and the explicit form of PKG_HEADERS: this library
# is not in the package's files, so `yes` would find no package; _pkg_alarm.mk names pkg-tmd.

LIB_KIND        := static
_ALARM_PKG      := pkg-tmd
_ALARM_PKG_YAML := $(dir $(lastword $(MAKEFILE_LIST)))../deploy/pkg.yaml
include $(ADMIN_DIR)/make/_pkg_alarm.mk
