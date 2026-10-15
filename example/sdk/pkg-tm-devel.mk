# pkg-tm-devel -- the SDK rpm: headers and libraries for programs that use libtmstats.
#
# Shows:
#   - a library in two packages: libtmstats is in pkg-tmd too (build/pkg_of.mk lists both, and
#     libtmstats' PKG_HEADERS := yes gets both component.h)
#   - PKG_FILEGROUP_MAP: filegroups of its own (Headers, Static_Libraries) on top of the schema's
#   - rpm_deps on an in-tree package: gm builds pkg-tmd before this one

PKG_VERSION       := 1.4.0
PKG_RELEASE       := 1
PKG_YAML          := pkg.yaml
PKG_FILEGROUP_MAP := filegroup_map.json
