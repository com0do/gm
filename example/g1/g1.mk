
# Go target.  project.mk sees the sibling go.mod and routes this
# through target.go.mk.  Knobs:
#   GO_PROJ_ROOT    Go module root (where go.mod lives).
#                   Default: this .mk's directory.
#   GO_PROJ_SUBPKG  optional sub-package to build (e.g. `cmd/server`).
#                   Default: empty = build the module root's main pkg.

GO_PROJ_ROOT   := $(PROJ_TOP)/example/g1
GO_PROJ_SUBPKG :=
