# RPM target -- YAML-driven.
#
# Setting PKG_YAML flips target.pkg.mk to YAML mode: the .spec is
# auto-generated from the pkg.yaml (see deployment/pkg.yaml) which is
# validated against production/make/schemas/pkg.schema.yaml.  Each
# `files[].src` becomes a staged source; the install location + mode /
# owner / group come from filegroup_map[<filegroup>] (schema default,
# or override via PKG_FILEGROUP_MAP).  `rpm_deps:` in the yaml becomes
# `Requires:` lines in the spec AND `rpms[]` in the emitted .dep.json.
#
# The yaml is the single source of truth for what gets bundled: any
# `src: $GM_LIB_DIR/... ` / `src: $GM_EXEC_DIR/...` entry is auto-
# detected during the make dry-run pass and recorded in build/depend.mk,
# so `make pkg-p2` on a cold clone first builds `t3` / `libt2` before
# packaging -- no need to repeat them in PKG_FILES.

PKG_VERSION := 1.0
PKG_RELEASE := 1
PKG_YAML    := deployment/pkg.yaml
