# pkg-tmd -- the daemon's rpm, described in pkg.yaml (YAML mode: gm generates the .spec).
#
# Shows: whatever pkg.yaml takes from $GM_EXEC_DIR / $GM_LIB_DIR becomes a dependency, so
# `make pkg-tmd` on a clean tree builds tmd and its libraries first; scriptlets, a %config file,
# owned and ghost paths, alarms, and a -debuginfo rpm next to the main one.

PKG_VERSION := 1.4.0
PKG_RELEASE := 1
PKG_YAML    := pkg.yaml
