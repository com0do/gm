#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""dep_query -- DAG-driven answer to "which images need rebuilding?"

The dependency DAG has IMAGES as its terminal roots -- every file
change eventually propagates through libs -> exes -> pkgs -> images.
This tool loads every `.dep.json` under a build directory, walks
bottom-up from a change set, and reports the image envelope that
needs re-building.

Subcommands
-----------
  changes    given a list of changed files, print affected images
  since      same, but source the change list from `git diff <ref>..HEAD`
  sources    inverse query: given an image, print every file it needs
  rpms       print the rpms[] tuples cached in an image's dep.json
  show       dump the loaded DAG (debug)
  cache      cache management: `create <ver>`, `list`, `validate <ver>`
  snapshot   aggregate + clean raw *.dep.json into project-relative form

Every image-rooted query is served by `lib.image_walk.ImageWalker`.
"""

from __future__ import annotations
import argparse
import sys
from pathlib import Path

# `production/tools/pydep/` -- shared Python lib (moved out of
# `production/make/scripts/lib/` so container/ can import from the
# same source of truth via a sys.path shim; see container/imageBuild.py).
HERE     = Path(__file__).resolve().parent
GM_TOOLS = HERE.parent.parent / "tools"
sys.path.insert(0, str(GM_TOOLS))

from pydep import (
    Kind, ImageWalker, DepGraph, DepCache,
    ChangeSource, dumps as pretty_dumps, snapshot as pydep_snapshot,
)


# ------------------------------------------------------------------
# Helpers
# ------------------------------------------------------------------

def _proj_top(args: argparse.Namespace) -> Path:
    return (args.proj_top or args.build_dir.parent).resolve()


def _render_report(report, fmt: str) -> str:
    if fmt == "targets":
        # Image-rooted: images first, other tiers only if user asked JSON.
        return " ".join(sorted(report.images))
    if fmt == "files":
        # Every affected artifact across tiers, one per line.
        rows: list[str] = []
        for kind, arts in sorted(report.artifacts_by_kind.items()):
            for a in sorted(arts):
                rows.append(f"{kind}\t{a}")
        return "\n".join(rows)
    return pretty_dumps(report.as_dict(), indent=2, max_line_length=120)


# ------------------------------------------------------------------
# Subcommands
# ------------------------------------------------------------------

def cmd_changes(args: argparse.Namespace) -> int:
    proj_top = _proj_top(args)
    src      = ChangeSource.from_paths(args.changes)
    if args.gitignore:
        src.drop_ignored(proj_top)
    walker = ImageWalker.from_build_dir(args.build_dir, proj_top)
    print(_render_report(walker.affected_by(src), args.format))
    return 0


def cmd_since(args: argparse.Namespace) -> int:
    proj_top = _proj_top(args)
    src      = ChangeSource.from_git(proj_top, args.ref)
    if args.gitignore:
        src.drop_ignored(proj_top)
    walker = ImageWalker.from_build_dir(args.build_dir, proj_top)
    print(_render_report(walker.affected_by(src), args.format))
    return 0


def cmd_sources(args: argparse.Namespace) -> int:
    walker = ImageWalker.from_build_dir(args.build_dir, _proj_top(args))
    sources = walker.sources_of(args.image)
    if args.format == "json":
        print(pretty_dumps(
            {"image": args.image, "sources": sorted(sources)},
            indent=2, max_line_length=120,
        ))
    else:
        for s in sorted(sources):
            print(s)
    return 0


def cmd_rpms(args: argparse.Namespace) -> int:
    walker = ImageWalker.from_build_dir(args.build_dir, _proj_top(args))
    rpms   = walker.rpms_of(args.image)
    print(pretty_dumps(
        {"image": args.image, "rpms": rpms},
        indent=2, max_line_length=120,
    ))
    return 0


def cmd_show(args: argparse.Namespace) -> int:
    graph = DepGraph(args.build_dir, _proj_top(args)).load()
    if args.format == "json":
        print(pretty_dumps({
            "artifacts": graph.artifacts,
            "edges":     {k: sorted(v) for k, v in graph.consumers.items()},
        }, indent=2, max_line_length=120))
        return 0
    # tree-ish text
    for kind in (Kind.IMG, Kind.PKG, Kind.EXE, Kind.LIB, Kind.JAVA, Kind.OBJ):
        by = sorted(a for a, info in graph.artifacts.items() if info["kind"] == kind)
        if not by:
            continue
        print(f"[{kind}]")
        for a in by:
            print(f"  {a}")
    return 0


def cmd_snapshot(args: argparse.Namespace) -> int:
    """Aggregate + clean raw dep.json into project-relative form."""
    proj_top = _proj_top(args)
    out_dir  = args.out_dir or (args.build_dir / "deps")
    counts   = pydep_snapshot(args.build_dir, proj_top, out_dir,
                              version=args.version)
    if not args.quiet:
        summary = ", ".join(f"{v} {k}" for k, v in counts.items() if v)
        try:
            shown = out_dir.relative_to(proj_top)
        except ValueError:
            shown = out_dir
        ver_line = (out_dir / "version").read_text(encoding="utf-8").splitlines()
        tag  = ver_line[0] if ver_line else "?"
        dig8 = ver_line[1][:8] if len(ver_line) > 1 else ""
        print(f"  DEPS-S  {shown}/  ({summary})  [{tag} {dig8}]")
    return 0


def cmd_cache(args: argparse.Namespace) -> int:
    root = args.cache_root

    if args.action == "list":
        if not root.exists():
            print(f"(cache root does not exist: {root})")
            return 0
        for v in sorted(root.iterdir()):
            if not v.is_dir():
                continue
            cache = DepCache(root=root, version=v.name)
            print(f"{v.name}  ({len(cache.digests())} dep.json)")
        return 0

    if args.action == "create":
        if not args.version:
            print("error: cache create needs a <version>", file=sys.stderr)
            return 2
        if not args.build_dir.exists():
            print(f"error: build dir {args.build_dir} does not exist", file=sys.stderr)
            return 2
        cache = DepCache(root=root, version=args.version)
        sources = [p for p in sorted(args.build_dir.rglob("*.dep.json"))
                   if p.name != "digest.dep.json"]
        digests = cache.create(sources)
        print(f"cached {len(digests)} dep.json into {cache.dir}")
        return 0

    if args.action == "validate":
        if not args.version:
            print("error: cache validate needs a <version>", file=sys.stderr)
            return 2
        cache = DepCache(root=root, version=args.version)
        ok, tampered = cache.validate()
        print(f"cache: {cache.dir}")
        print(f"  ok       : {len(ok)}")
        print(f"  tampered : {len(tampered)}")
        for n in tampered:
            print(f"    ! {n}")
        return 0 if not tampered else 1

    print(f"error: unknown cache action {args.action!r}", file=sys.stderr)
    return 2


# ------------------------------------------------------------------
# CLI
# ------------------------------------------------------------------

def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(
        prog        = "dep_query",
        description = __doc__,
        formatter_class = argparse.RawDescriptionHelpFormatter,
    )
    p.add_argument("--build-dir", type=Path,
                   default=Path.cwd() / "build",
                   help="build/ root containing .dep.json files (default: ./build)")
    p.add_argument("--proj-top",  type=Path, default=None,
                   help="project top (defaults to parent of --build-dir)")

    sub = p.add_subparsers(dest="cmd", required=True)

    # changes
    c = sub.add_parser("changes", help=cmd_changes.__doc__)
    c.add_argument("changes", nargs="+", help="paths that changed")
    c.add_argument("--format", choices=("targets", "files", "json"),
                   default="targets")
    c.add_argument("--gitignore", action="store_true",
                   help="drop git-ignored paths from the change set")
    c.set_defaults(fn=cmd_changes)

    # since
    s = sub.add_parser("since", help=cmd_since.__doc__)
    s.add_argument("ref", help="git ref -- runs `git diff <ref>..HEAD`")
    s.add_argument("--format", choices=("targets", "files", "json"),
                   default="targets")
    s.add_argument("--gitignore", action="store_true",
                   help="drop git-ignored paths from the change set")
    s.set_defaults(fn=cmd_since)

    # sources
    ss = sub.add_parser("sources", help=cmd_sources.__doc__)
    ss.add_argument("image", help="image target name")
    ss.add_argument("--format", choices=("plain", "json"), default="plain")
    ss.set_defaults(fn=cmd_sources)

    # rpms
    r = sub.add_parser("rpms", help=cmd_rpms.__doc__)
    r.add_argument("image", help="image target name")
    r.set_defaults(fn=cmd_rpms)

    # show
    sh = sub.add_parser("show", help=cmd_show.__doc__)
    sh.add_argument("--format", choices=("tree", "json"), default="tree")
    sh.set_defaults(fn=cmd_show)

    # snapshot
    sn = sub.add_parser("snapshot", help=cmd_snapshot.__doc__)
    sn.add_argument("--out-dir", type=Path, default=None,
                    help="output dir (default: <build-dir>/deps)")
    sn.add_argument("--version", default=None,
                    help="version tag (default: `git describe --always "
                         "--dirty` or `unversioned`)")
    sn.add_argument("--quiet", action="store_true",
                    help="suppress the summary line")
    sn.set_defaults(fn=cmd_snapshot)

    # cache
    ca = sub.add_parser("cache", help=cmd_cache.__doc__)
    ca.add_argument("action", choices=("list", "create", "validate"))
    ca.add_argument("version", nargs="?", default=None,
                    help="version tag (required for create/validate)")
    ca.add_argument("--cache-root", type=Path, default=DepCache.default_root(),
                    help="cache root dir "
                         "(default: $DEPCACHE_DIR or ~/.cache/gm-dep/)")
    ca.set_defaults(fn=cmd_cache)

    return p


def main(argv=None) -> int:
    args = build_parser().parse_args(argv)
    return args.fn(args)


if __name__ == "__main__":
    sys.exit(main())
