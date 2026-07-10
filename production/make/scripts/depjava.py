#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""depjava.py -- emit a `{file, deps}` JSON for one Java target.

Java has no `go list -deps` equivalent, so this script builds a
source-level dependency graph by parsing:

    1. `package X.Y.Z;`         → the FQCN prefix a file exposes
    2. `import X.Y.Z.Foo;`      → single-class imports
    3. `import X.Y.Z.*;`        → wildcard imports  (all classes in a pkg)
    4. `import static X.Y.Z.Foo.bar;`  → static single-member import
    5. `import static X.Y.Z.Foo.*;`    → static wildcard import
    6. same-package classes     → implicit (no import required)

Then, given a set of "target sources" (the .java files that comprise
the target being built), for each source we compute its dependency
set as the union of:

    * every source file resolved via imports (1..5), transitively
    * every same-package source (6), transitively

`java.*` / `javax.*` / `sun.*` / `jdk.*` / etc. are treated as JDK
externals and skipped -- they can't be modelled by walking user
source anyway.  Same for anything the class index can't resolve
(external jars on --classpath; those are visible as `.deps: [external:<import>]`
sidebar entries with `--include-unresolved`, off by default).

The final output shape is the same one produced by target.c.mk and
target.go.mk, so dep_query.py handles Java targets uniformly:

    {
      "file": "/abs/path/to/build/java/<target>.jar",
      "deps": [
        "/abs/path/to/example/j1/src/com/example/j1/Foo.java",
        "/abs/path/to/example/j1/src/com/example/j1/Bar.java",
        "/abs/path/to/example/j2/src/com/example/j2/Main.java",
        "/abs/path/to/build/java/j1.jar"     # if declared via --intree-jar
      ]
    }

Regex-based parsing is deliberate.  We could pull in JavaParser or
javalang for a proper AST walk, but:
    * gm's parity target is *simple* javac projects (matches the
      deduction);
    * imports live on line 1 of most .java files, in a stable syntax
      that regex handles fine;
    * a zero-dep script is cheaper to vendor in `production/make/scripts/`
      than a Python package.

If you have to build against a project that generates .java from
templates or does aggressive `@AutoService` reflection, upgrade to
javalang and file a PR.

Usage:
  depjava.py --file <target-artifact-abs-path>            \\
             --src-root <dir> [--src-root <dir> ...]      \\
             [--target-sources <file> ...]                \\
             [--intree-jar <name>=<abs-path> ...]         \\
             [--include-unresolved]                       \\
             [-o <out.json>]

Design cousin of production/make/scripts/depgo.sh -- same output
schema, same `file:` + `deps[]` semantics, same absolute-path
convention.
"""
from __future__ import annotations
import argparse
import json
import os
import re
import sys
from pathlib import Path
from typing import Iterable


# ─────────────────────────────────────────────────────────────────────
# JDK / stdlib packages that user code will import but that we cannot
# resolve from source (they live in rt.jar / modules).  We treat them
# as externals -- silently dropped from `deps[]` unless the user opts
# into `--include-unresolved`.
# ─────────────────────────────────────────────────────────────────────
JDK_PREFIXES = (
    "java.", "javax.",
    "jdk.", "sun.", "com.sun.",
    "org.w3c.", "org.xml.sax.",
    "org.ietf.jgss.", "org.omg.",
)


PACKAGE_RE = re.compile(r"^\s*package\s+([A-Za-z_][A-Za-z0-9_.]*)\s*;", re.M)

# Matches `import [static] X.Y.Z;` where Z is a class name OR `*`.
# Static imports include the trailing member; strip it to reach the class.
IMPORT_RE  = re.compile(
    r"^\s*import\s+(static\s+)?([A-Za-z_][A-Za-z0-9_.]*(?:\.\*)?)\s*;",
    re.M,
)


# ─────────────────────────────────────────────────────────────────────
# Class index -- built once per invocation from --src-root(s).
# ─────────────────────────────────────────────────────────────────────
class ClassIndex:
    """FQCN -> abs source-file path, and package -> {class paths}."""

    def __init__(self):
        # FQCN key like "com.example.j1.Foo"
        self.by_class: dict[str, Path] = {}
        # Package key like "com.example.j1" → list of files in that pkg
        self.by_package: dict[str, list[Path]] = {}
        # Reverse lookup: source-file → FQCN (used when we want to
        # know the "home package" of a target source).
        self.file_pkg: dict[Path, str] = {}

    def add_root(self, root: Path) -> int:
        root = root.resolve()
        added = 0
        if not root.is_dir():
            print(f"depjava: WARN --src-root {root} is not a dir",
                  file=sys.stderr)
            return 0
        for java in root.rglob("*.java"):
            java = java.resolve()
            pkg  = _read_package(java)
            if pkg is None:
                # File has no `package` declaration (default package)
                # -- valid in Java but we can only match it as a
                # bare class name.  Store under "" bucket.
                pkg = ""
            fqcn = f"{pkg}.{java.stem}" if pkg else java.stem
            self.by_class[fqcn] = java
            self.by_package.setdefault(pkg, []).append(java)
            self.file_pkg[java] = pkg
            added += 1
        return added

    def resolve_import(self, import_spec: str) -> list[Path]:
        """`import_spec` is the RHS of `import [static] X;`  -- with or
        without a trailing `.*`.  Returns 0..N source-file paths."""
        if import_spec.endswith(".*"):
            pkg = import_spec[:-2]
            return list(self.by_package.get(pkg, []))
        if import_spec in self.by_class:
            return [self.by_class[import_spec]]
        # Static single-member import: strip trailing `.member`, retry.
        head, dot, _ = import_spec.rpartition(".")
        if dot and head in self.by_class:
            return [self.by_class[head]]
        return []


def _read_package(java: Path) -> str | None:
    try:
        text = java.read_text(encoding="utf-8", errors="replace")
    except OSError:
        return None
    m = PACKAGE_RE.search(text)
    return m.group(1) if m else None


# ─────────────────────────────────────────────────────────────────────
# Dependency walk
# ─────────────────────────────────────────────────────────────────────
def resolve_deps(
    target_sources: list[Path],
    index: ClassIndex,
    include_unresolved: bool = False,
) -> tuple[set[Path], set[str]]:
    """Return (files-this-target-depends-on, unresolved-imports).

    Transitive: every resolved source's own imports are followed until
    the frontier stops growing.  Same-package fan-out (implicit deps)
    is included -- if `Foo.java` and `Bar.java` share a package, using
    `Foo` from `Bar` needs no import, so we conservatively wire Bar's
    package siblings into Bar's dep set.  This is coarse; for large
    projects (100+ classes/pkg) it will over-collect, at which point a
    proper AST walk is warranted (see module docstring)."""
    resolved: set[Path] = set()
    unresolved: set[str] = set()

    frontier = [p.resolve() for p in target_sources if p.is_file()]

    while frontier:
        src = frontier.pop()
        if src in resolved:
            continue
        resolved.add(src)

        text = src.read_text(encoding="utf-8", errors="replace")

        # Explicit imports
        for _static, import_spec in IMPORT_RE.findall(text):
            if any(import_spec.startswith(p) for p in JDK_PREFIXES):
                continue
            hits = index.resolve_import(import_spec)
            if hits:
                for hit in hits:
                    if hit not in resolved:
                        frontier.append(hit)
            else:
                unresolved.add(import_spec)

        # Same-package siblings (implicit deps)
        pkg = index.file_pkg.get(src, "")
        for sibling in index.by_package.get(pkg, ()):
            if sibling != src and sibling not in resolved:
                frontier.append(sibling)

    return resolved, unresolved


# ─────────────────────────────────────────────────────────────────────
# CLI
# ─────────────────────────────────────────────────────────────────────
def parse_intree_jar(spec: str) -> tuple[str, Path]:
    """`--intree-jar name=/abs/path/j1.jar` -> ('name', Path)."""
    if "=" not in spec:
        raise argparse.ArgumentTypeError(
            f"--intree-jar expects NAME=PATH, got {spec!r}")
    name, path = spec.split("=", 1)
    return name, Path(path).resolve()


def main(argv: Iterable[str] | None = None) -> int:
    p = argparse.ArgumentParser(
        prog="depjava.py",
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    p.add_argument("--file", required=True,
                   help="target artefact absolute path (the .jar) -- "
                        "goes into dep.json's `file:` field")
    p.add_argument("--src-root", action="append", default=[], type=Path,
                   metavar="DIR", required=True,
                   help="directory to scan for .java (repeatable). "
                        "Every src-root is walked recursively to build "
                        "the class index.")
    p.add_argument("--target-sources", nargs="*", default=[], type=Path,
                   metavar="FILE",
                   help="the target's own .java files.  If empty, we "
                        "treat every .java under the first --src-root "
                        "as the target set (simple single-project case).")
    p.add_argument("--intree-jar", action="append", default=[], metavar="NAME=PATH",
                   help="add another gm target's .jar as a dep entry, "
                        "even though it isn't a .java file (repeatable). "
                        "This is how `JAR_DEPS := j1` in target.java.mk "
                        "propagates the compile-time classpath into "
                        "dep.json.")
    p.add_argument("--include-unresolved", action="store_true",
                   help="emit `unresolved:<import>` marker entries in "
                        "deps[] for FQCNs we couldn't map to a file "
                        "(external libraries on the classpath).  Off by "
                        "default because they're usually noise.")
    p.add_argument("-o", "--output", default="-",
                   help="output path (default: stdout)")
    args = p.parse_args(list(argv) if argv is not None else None)

    # Build the class index across every --src-root.
    index = ClassIndex()
    total = 0
    for root in args.src_root:
        total += index.add_root(root)
    if total == 0:
        print("depjava: no .java files found under --src-root(s); "
              "emitting empty deps", file=sys.stderr)

    # Decide target sources.
    if args.target_sources:
        target_sources = args.target_sources
    else:
        # Default: every .java under the first --src-root.
        first_root = args.src_root[0].resolve()
        target_sources = list(first_root.rglob("*.java"))

    resolved, unresolved = resolve_deps(
        target_sources,
        index,
        include_unresolved=args.include_unresolved,
    )

    deps: list[str] = sorted(str(p) for p in resolved)
    # Inject intree jar deps -- these establish the DAG edge from a
    # java target to the jars it links against.  dep_query walks them
    # by absolute path just like C/C++ .so's.
    for spec in args.intree_jar:
        _name, path = parse_intree_jar(spec)
        deps.append(str(path))
    if args.include_unresolved and unresolved:
        deps.extend(f"unresolved:{u}" for u in sorted(unresolved))
    # Final dedup+sort so dep.json is stable across runs.
    deps = sorted(set(deps))

    out_obj = {
        "file": os.path.abspath(args.file),
        "deps": deps,
    }
    payload = json.dumps(out_obj, indent=2) + "\n"

    if args.output in ("-", ""):
        sys.stdout.write(payload)
    else:
        Path(args.output).parent.mkdir(parents=True, exist_ok=True)
        Path(args.output).write_text(payload)
    return 0


if __name__ == "__main__":
    sys.exit(main())
