# pkg-p3.mk -- multi-pkg demo.  Also packages libt2 alongside pkg-p2.
# Demonstrates:
#   - a single lib bundled by TWO pkgs (see PKG_OF_libt2 in build/pkg_of.mk)
#   - both pkgs' component.h wired into libt2's compile (path-qualified)
#   - versionstamp embeds BOTH pkg identities (grep GM_VERSIONSTAMP:)
PKG_YAML     := pkg-p3.yaml
PKG_VERSION  := 2.5.0
PKG_RELEASE  := 7
