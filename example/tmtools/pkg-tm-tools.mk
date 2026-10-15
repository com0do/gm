# pkg-tm-tools -- tmctl and its bash completion, packaged with a hand-written .spec.
#
# Shows the plain mode, for an existing .spec:
#   PKG_FILES        in-tree targets (looked up in $(GM_EXEC_DIR) and $(GM_LIB_DIR)); they
#                    become dependencies, so tmctl is built first
#   PKG_EXTRA_FILES  other files, copied into the rpm's SOURCES
#   PKG_SPEC         @VAR@ in it is substituted: TARGET, PKG_VERSION, PKG_RELEASE, BUILD_MODE,
#                    RPM_TARGET_ARCH, PKG_RPM_DEPS_REQ (PKG_RPM_DEPS, comma-joined), ...

PKG_VERSION     := 1.4.0
PKG_RELEASE     := 1
PKG_FILES       := tmctl
PKG_EXTRA_FILES := tmctl.bash
PKG_SPEC        := tm-tools.spec
PKG_RPM_DEPS    := bash
