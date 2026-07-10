#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""depUpdate.py -- closed-loop dep-data refresh.

Solidifies the workflow the framework's dep-derivation is designed for:
change set -> dep_query finds affected targets -> rebuild those targets
with DEP_TREE=yes so their .dep.json sidecars refresh -> next dep_query
sees the freshly-updated graph.  Also detects "new" targets (present in
$(TARGET_ALL) but missing a .dep.json) and triggers their first build.

Two phases in one run:

  1. Completeness pass.  Any target listed by `make list-targets` that
     has no `.dep.json` yet gets built with DEP_TREE=yes.  This is
     what `reg_container_tooling/cm_tools/dependency.md` §3 calls
     "check completeness -> fix -> refresh cache" and matches the doc's
     §3.2.2 case 1/2 pattern: adding a new lib/exe/pkg .mk needs an
     explicit first build to populate dep-data.
  2. Change-driven pass.  Explicit `--changes <file>...` (or
     `--since <git-ref>` -> `git diff`) is fed into the ImageWalker.
     Every pkg/exe/lib in the affected report is rebuilt with
     DEP_TREE=yes.

The union is built with a single `make -jN DEP_TREE=yes <targets>`
invocation so make's own scheduling handles inter-target ordering.

Usage:
    depUpdate.py --changes <file> [<file>...]
    depUpdate.py --since <git-ref>
    depUpdate.py                                # completeness-only

Options:
    --dry-run             print the plan, don't run make
    --skip-deps           don't run `make deps` first
    --build-dir <dir>     default: $PROJ_TOP/build
    --proj-top  <dir>     default: cwd
    --jobs N              parallel jobs (default: nproc)

The report at the end distinguishes:
  * completeness-first-build targets  (new .mk / missing dep.json)
  * change-driven rebuilt targets     (affected by --changes / --since)
  * container images                  (out of gm's job -- listed for
                                       the user to run
                                       `container/imageBuild.py deps`
                                       against separately)
"""

from __future__ import annotations
import argparse
import os
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))       # make `pydep` importable

from pydep import (
    ImageWalker, DepGraph, ChangeSource,
)


# ----------------------------------------------------------------------
# Helpers
# ----------------------------------------------------------------------

def known_targets(graph: DepGraph) -> set[str]:
    """Every make target already represented in the dep-graph.  A
    target is "known" when there's an artifact whose `.dep.json` names
    it.  The absent set (`TARGET_ALL - known_targets`) is what phase 1
    rebuilds to close the completeness gap."""
    out: set[str] = set()
    for info in graph.artifacts.values():
        t = info.get("target")
        if t:
            out.add(t)
    return out


def list_all_targets(proj_top: Path) -> list[str]:
    """Ask make what the full target set is (rwildcard-derived
    TARGET_ALL from project.mk).  Requires the `list-targets` phony
    defined in project.mk."""
    result = subprocess.run(
        ["make", "-s", "-C", str(proj_top), "list-targets"],
        capture_output=True, text=True, check=True,
    )
    return [t for t in result.stdout.split() if t]


def resolve_changes(args) -> list[str]:
    """Materialise the change set from CLI flags.  Returns absolute
    paths where possible; ChangeSource normalises the rest."""
    changes: list[str] = []
    if args.changes:
        changes.extend(args.changes)
    if args.since:
        proj_top = args.proj_top.resolve()
        diff = subprocess.run(
            ["git", "-C", str(proj_top),
             "diff", f"{args.since}..HEAD", "--name-only", "--diff-filter=ACMRT"],
            capture_output=True, text=True, check=True,
        ).stdout
        for line in diff.splitlines():
            line = line.strip()
            if line:
                changes.append(str(proj_top / line))
    return changes


def mk_files_touched(changes: list[str]) -> bool:
    """`.mk` in the change set means depend.mk needs regen before
    dep_query walks: rwildcard + `$(TARGET_DEP): $(TARGET_ALL_MK)`
    handles the auto-refresh, but if we're driving a batch we want
    it done up front."""
    return any(c.endswith(".mk") for c in changes)


def run_make(targets: list[str], proj_top: Path, jobs: int,
             extra_env: dict[str, str] | None = None,
             dry_run: bool = False) -> None:
    cmd = ["make", "-C", str(proj_top), f"-j{jobs}"] + targets
    print(">>> " + " ".join(cmd))
    if dry_run:
        return
    env = os.environ.copy()
    if extra_env:
        env.update(extra_env)
    subprocess.run(cmd, check=True, env=env)


# ----------------------------------------------------------------------
# Main
# ----------------------------------------------------------------------

def main(argv=None) -> int:
    ap = argparse.ArgumentParser(prog="depUpdate.py", description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--changes", nargs="+", metavar="FILE",
                    help="explicit list of changed files")
    ap.add_argument("--since",   metavar="GITREF",
                    help="git ref for `git diff <ref>..HEAD` change extraction")
    ap.add_argument("--dry-run", action="store_true",
                    help="print the plan; run neither `make deps` nor the target rebuild")
    ap.add_argument("--skip-deps", action="store_true",
                    help="don't run `make deps` first (assume depend.mk is fresh)")
    ap.add_argument("--build-dir", type=Path, default=None,
                    help="build root (default: $PROJ_TOP/build)")
    ap.add_argument("--proj-top",  type=Path, default=Path.cwd(),
                    help="project top (default: cwd)")
    ap.add_argument("--jobs", type=int, default=os.cpu_count() or 4,
                    help="make -jN (default: nproc)")
    args = ap.parse_args(argv)

    proj_top  = args.proj_top.resolve()
    build_dir = (args.build_dir or (proj_top / "build")).resolve()

    changes = resolve_changes(args)

    # -------- Phase 0: make deps (unless skipped) --------
    # depend.mk auto-regens on any .mk change via the `$(TARGET_DEP):
    # $(TARGET_ALL_MK)` rule, but we force it here so the subsequent
    # graph-load and target-list see the fresh state.  Cheap
    # (sub-second on our example tree).
    if not args.skip_deps:
        print("=== phase 0: refresh depend.mk ===")
        run_make(["deps"], proj_top, args.jobs, dry_run=args.dry_run)

    # -------- Load state --------
    all_targets   = set(list_all_targets(proj_top))
    graph         = DepGraph(build_dir=build_dir, proj_top=proj_top).load() \
                    if build_dir.exists() else DepGraph(build_dir=build_dir, proj_top=proj_top)
    graph_targets = known_targets(graph)

    # -------- Phase 1: completeness (new targets w/o dep.json) --------
    # `TARGET_ALL - known` = targets the build system knows about but
    # the dep-graph doesn't yet.  Typically: user added a new libX.mk /
    # pkg-Y.mk but hasn't built it since.  First build populates
    # dep.json, closing the gap.
    completeness_targets = sorted(all_targets - graph_targets)

    # -------- Phase 2: change-driven --------
    # ImageWalker.affected_by walks the loaded graph from the changed
    # leaves.  Returns AffectedReport with `libs`, `exes`, `pkgs`,
    # `javas`, `images` tiers.  Images are the container tool's job,
    # so we LIST them but don't try to rebuild them ourselves.  Java
    # targets rebuild alongside exes (same phase -- see _bucket).
    change_libs:  set[str] = set()
    change_exes:  set[str] = set()
    change_pkgs:  set[str] = set()
    change_javas: set[str] = set()
    change_imgs:  set[str] = set()
    if changes:
        walker = ImageWalker(graph)
        src    = ChangeSource.from_paths(changes)
        report = walker.affected_by(src)
        change_libs, change_exes, change_pkgs, change_javas, change_imgs = \
            report.libs, report.exes, report.pkgs, report.javas, report.images

    changed_targets = sorted(change_libs | change_exes | change_pkgs | change_javas)

    # -------- Merge and execute --------
    # gm's top-level Makefile refuses to mix `lib*` and `pkg*` targets
    # in one command (defensive guard against accidental user typos --
    # see Makefile's "Do not mix lib and pkg target" $(error).  We
    # split into build-order-respecting phases so `make -jN` still
    # gets parallelism within each phase but the guard is happy.
    def _bucket(t: str) -> str:
        if t.startswith("lib"):
            return "libs"
        if t.startswith("pkg-"):
            return "pkgs"
        return "exes"  # exes, tests, go binaries, etc.

    phases: dict[str, list[str]] = {"libs": [], "exes": [], "pkgs": []}
    for t in sorted(set(completeness_targets) | set(changed_targets)):
        phases[_bucket(t)].append(t)
    total = sum(len(v) for v in phases.values())

    print("\n=== plan ===")
    print(f"completeness first-builds : {len(completeness_targets)}")
    for t in completeness_targets:
        print(f"    + {t}")
    print(f"change-driven rebuilds    : {len(changed_targets)}")
    for t in changed_targets:
        print(f"    * {t}")
    if change_imgs:
        print("\ncontainer images (OUT OF GM'S JOB -- run container/imageBuild.py):")
        for i in sorted(change_imgs):
            print(f"    ! {i}     -- container/imageBuild.py deps <manifest>")

    if not total:
        print("\n(nothing to rebuild)")
        return 0

    # Build order: libs first (leaves), then exes/tests, then pkgs
    # (which consume libs+exes).  Each non-empty phase becomes one
    # `make -jN` invocation with the DEP_TREE=yes env sticky.
    print("\n=== phase 3: rebuild with DEP_TREE=yes ===")
    for phase_name in ("libs", "exes", "pkgs"):
        ts = phases[phase_name]
        if not ts:
            continue
        print(f"\n--- {phase_name} ({len(ts)}) ---")
        run_make(ts, proj_top, args.jobs,
                 extra_env={"DEP_TREE": "yes"},
                 dry_run=args.dry_run)

    print("\n=== done ===")
    print(f"refreshed {total} target(s); dep-graph is now current")
    if change_imgs:
        print(f"NOTE: {len(change_imgs)} container image(s) still need `container/imageBuild.py`")
    return 0


if __name__ == "__main__":
    sys.exit(main())
