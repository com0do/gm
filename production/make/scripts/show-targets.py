#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""show-targets.py -- print what gm derived: targets, their type and the dependency edges.

Reads the target table the top-level make writes (``name|type|dir|mk|skipped``, one per line),
the derived graph (depend.mk, pkg_of.mk) and, for the targets asked about, the facts their own
sub-make printed (``<info-dir>/<name>``: ``field TAB value`` lines, `_gm_show`).  No arguments:
one line per target, in build order.  ``--type T``: the targets of one type with its facts as
columns.  Target names: the details of each.  `make show` / `make show-<type>` /
`make show-<name>` / `gm show [<name>...]` call it.
"""

from __future__ import annotations

import argparse
import re
import sys
from dataclasses import dataclass, field
from pathlib import Path


@dataclass
class Target:
    name: str
    type: str
    dir: str
    mk: str
    skipped: str
    deps: list[str] = field(default_factory=list)


def _read_meta(path: Path) -> dict[str, Target]:
    targets: dict[str, Target] = {}
    for line in path.read_text(encoding="utf-8").splitlines():
        parts = line.strip().split("|")
        if len(parts) != 5:
            continue
        name, type_, dir_, mk, skipped = parts
        targets[name] = Target(name, type_, dir_, mk, skipped)
    return targets


def _read_depend(path: Path, targets: dict[str, Target]) -> None:
    if not path.is_file():
        return
    for line in path.read_text(encoding="utf-8").splitlines():
        if ":" not in line or line.startswith("_DEP_DIGEST"):
            continue
        head, _, tail = line.partition(":")
        t = targets.get(head.strip())
        if t is not None:
            t.deps = tail.split()


def _read_assignments(path: Path, prefix: str) -> dict[str, list[str]]:
    """`<prefix>_<key> := v1 v2` lines -> {key: [v1, v2]}."""
    out: dict[str, list[str]] = {}
    if not path.is_file():
        return out
    pat = re.compile(rf"^{prefix}_(\S+)\s*:=\s*(.*)$")
    for line in path.read_text(encoding="utf-8").splitlines():
        m = pat.match(line.strip())
        if m:
            out[m.group(1)] = m.group(2).split()
    return out


def _read_facts(info_dir: Path, name: str) -> list[tuple[str, str]]:
    path = info_dir / name
    if not path.is_file():
        return []
    facts = []
    for line in path.read_text(encoding="utf-8").splitlines():
        field_, sep, value = line.partition("\t")
        if sep:
            facts.append((field_, value))
    return facts


def _label(dep: str) -> str:
    return f"{dep[:-len('-header')]} (component.h)" if dep.endswith("-header") else dep


def _build_order(targets: dict[str, Target], roots: list[str]) -> list[str]:
    """Depth-first post-order from `roots`: every target after what it depends on."""
    order: list[str] = []
    seen: set[str] = set()

    def visit(name: str) -> None:
        if name in seen:
            return
        seen.add(name)
        t = targets.get(name)
        for d in sorted(t.deps) if t else []:
            if not d.endswith("-header"):
                visit(d)
        order.append(name)

    for r in roots:
        visit(r)
    return order


def _table(targets: dict[str, Target]) -> None:
    order = _build_order(targets, sorted(targets))
    w_name = max([len("TARGET")] + [len(n) for n in order])
    w_type = max([len("TYPE")] + [len(targets[n].type) for n in order])
    w_dir = max([len("DIR")] + [len(targets[n].dir) for n in order])
    print(f"{'TARGET':<{w_name}}  {'TYPE':<{w_type}}  {'DIR':<{w_dir}}  DEPENDS ON")
    for n in order:
        t = targets[n]
        deps = "skipped: " + t.skipped if t.skipped else " ".join(_label(d) for d in t.deps) or "-"
        print(f"{n:<{w_name}}  {t.type:<{w_type}}  {t.dir:<{w_dir}}  {deps}")
    print(f"\n{len(order)} targets, build order (each after what it depends on).  "
          "Per type: make show-<type>.  Details: make show-<target>.")


def _type_table(type_: str, targets: dict[str, Target], info_dir: Path) -> None:
    names = [n for n in _build_order(targets, sorted(targets)) if targets[n].type == type_]
    if not names:
        print(f"no {type_} targets")
        return
    facts = {n: dict(_read_facts(info_dir, n)) for n in names}
    fields: list[str] = []
    for n in names:
        for f in facts[n]:
            if f not in fields and f != "run":
                fields.append(f)
    head = ["TARGET", "DIR"] + [f.upper() for f in fields] + ["DEPENDS ON"]
    rows = []
    for n in names:
        t = targets[n]
        if t.skipped:
            rows.append([n, t.dir] + ["-"] * len(fields) + ["skipped: " + t.skipped])
            continue
        rows.append([n, t.dir] + [facts[n].get(f, "-") for f in fields]
                    + [" ".join(_label(d) for d in t.deps) or "-"])
    widths = [max(len(r[i]) for r in [head] + rows) for i in range(len(head) - 1)]
    for r in [head] + rows:
        print("  ".join(c.ljust(w) for c, w in zip(r, widths)) + "  " + r[-1])
    print(f"\n{len(names)} {type_} target(s), build order.  Details: make show-<target>.")


def _details(name: str, targets: dict[str, Target], pkg_of: dict[str, list[str]],
             info_dir: Path) -> None:
    t = targets[name]
    users = sorted([u.name for u in targets.values() if name in u.deps]
                   + [f"{u.name} (component.h)" for u in targets.values()
                      if f"{name}-header" in u.deps])
    rows: list[tuple[str, str]] = [(".mk", t.mk)]
    if t.skipped:
        rows.append(("skipped", t.skipped))
    rows.append(("depends on", " ".join(_label(d) for d in t.deps) or "-"))
    closure = [n for n in _build_order(targets, [name]) if n != name]
    if sorted(closure) != sorted(d for d in t.deps if not d.endswith("-header")):
        rows.append(("all deps", " ".join(closure) or "-"))
    rows.append(("used by", " ".join(users) or "-"))
    if pkg_of.get(name):
        rows.append(("shipped in", " ".join(pkg_of[name])))
    rows += _read_facts(info_dir, name)
    print(f"{name}  ({t.type}, {t.dir})")
    for k, v in rows:
        print(f"  {k:<11} {v}")
    print()


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--meta", type=Path, required=True)
    ap.add_argument("--depend", type=Path, required=True)
    ap.add_argument("--pkg-of", type=Path, required=True)
    ap.add_argument("--info-dir", type=Path, required=True)
    ap.add_argument("--type")
    ap.add_argument("names", nargs="*")
    args = ap.parse_args(argv)

    targets = _read_meta(args.meta)
    _read_depend(args.depend, targets)
    if args.type:
        _type_table(args.type, targets, args.info_dir)
        return 0
    if not args.names:
        _table(targets)
        return 0
    pkg_of = _read_assignments(args.pkg_of, "PKG_OF")
    unknown = [n for n in args.names if n not in targets]
    if unknown:
        print(f"show: unknown target(s): {' '.join(unknown)} (make list)",
              file=sys.stderr)
        return 2
    for n in args.names:
        _details(n, targets, pkg_of, args.info_dir)
    return 0


if __name__ == "__main__":
    sys.exit(main())
