# tmexport -- turns a tmd snapshot (JSON) into Prometheus text exposition.  Pure Go.
#
# Shows: a Go target.  The go.mod next to this .mk makes it one; the module root defaults to
# this directory, GO_PROJ_SUBPKG picks the main package inside it.  The binary is named after the
# .mk and lands in $(GM_EXEC_DIR); gm rebuilds it when a .go file of the package changes.

GO_PROJ_SUBPKG := cmd/tmexport
