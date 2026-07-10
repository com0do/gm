
# RPM target.  basename `pkg-*` -> TYPE=pkg -> target.pkg.mk.
#
# PKG_FILES         compiled targets to include -- exes resolve under
#                   $(GM_EXEC_DIR), .so/.a under $(GM_LIB_DIR).  Both
#                   become hard deps in $(TARGET_DEP).
# PKG_EXTRA_FILES   non-target artifacts (configs, scripts, data)
#                   -- tracked dynamically via dep-hooks.sh when
#                   DEP_TREE=yes; appear in <target>.dep.json.
# PKG_RPM_DEPS      rpm-level Requires: entries (space-separated).  The
#                   list is comma-joined into @PKG_RPM_DEPS_REQ@ for the
#                   .spec substitution, AND passed to pkgdeps.py as
#                   --rpm-dep for the emitted dep.json's rpms[] field.

PKG_VERSION     := 1.0.0
PKG_RELEASE     := 1
PKG_FILES       := t3 libt2
PKG_EXTRA_FILES := config/p1.conf
PKG_SPEC        := p1.spec
PKG_RPM_DEPS    := gm-runtime
