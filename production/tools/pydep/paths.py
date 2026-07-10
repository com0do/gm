"""Path canonicalisation helpers used by every DAG consumer.

`normalize(path, proj_top)` gives every dep entry the same absolute
key so `.dep.json` files written with mixed relative/absolute paths
still cross-reference cleanly.

`rel(abs_path, proj_top)` produces the repo-relative form used for
user-facing output -- keeps git-diff-friendly paths in reports.
"""

from __future__ import annotations
import os
from pathlib import Path


def normalize(path: str, proj_top: Path) -> str:
    """Return an **absolute, realpath'd** canonical form of `path`.

    This is the DAG's aggregation-time canonicalisation point (see
    the split policy in production/make/scripts/pkgdeps.py::_abs()
    and dep-hooks.sh's header): build recipes emit absolute paths
    WITHOUT following symlinks (fast, minimal), and every consumer
    running through DepGraph.load() -> normalize() collapses OUT_DIR
    views to their BUILD_DIR realpath here.  Result: every artefact
    key in the loaded graph is a real disk path, so a lib's dep.json
    (`file: OUT_DIR/libt2.so`) and its consumer's deps[]
    (`deps: [... OUT_DIR/libt2.so ...]`) both hash to the SAME
    BUILD_DIR key, and adjacency lookups just work.

    Relative paths become absolute via `proj_top` first; then
    `os.path.realpath(..., strict=False)` resolves symlinks as far as
    the filesystem exists (missing paths pass through unchanged so
    the graph tolerates dead/unbuilt entries).
    """
    p = Path(path)
    if not p.is_absolute():
        p = proj_top / p
    return os.path.realpath(str(p), strict=False)


def rel(abs_path: str, proj_top: Path) -> str:
    """Return `abs_path` relative to `proj_top` if under it; else as-is."""
    top = proj_top.resolve()
    p   = Path(abs_path)
    try:
        return str(p.relative_to(top))
    except ValueError:
        return str(p)
