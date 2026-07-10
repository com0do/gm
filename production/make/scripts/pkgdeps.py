#!/usr/bin/env python3
"""
pkgdeps.py - unified dep aggregator for RPM targets.

Aggregates rpmbuild log + pkg.yaml into a {pkg, rpms, deps} dep.json
shape that dep_query.py loads for tree-wide queries.  Extends the
plain {pkg, rpms, deps} shape with gm's `target.pkg.mk` needs:

  * `--file`     inject the top-level `file` field (absolute path to the
                 built .rpm) so dep_query.py's DepGraph loader can key
                 on the artifact path.  Optional.
  * `--mk-file`  add the child .mk file to `deps[]` (a source-code edit
                 of the .mk should propagate through the DAG).
  * `--rpm-dep`  repeatable manual `rpms[]` entry.  Used by plain-spec
                 pkgs (mode A of target.pkg.mk) that set
                 `PKG_RPM_DEPS := foo bar` in the child .mk instead of
                 declaring them in a pkg.yaml.
  * YAML input   in YAML mode (mode B), a pkg.yaml's `rpm_deps:` list
                 becomes `rpms[]`, and the yaml file's own absolute path
                 becomes a `deps[]` entry (a pkg.yaml edit is a real
                 dep edge that must trigger a rebuild).

Input formats accepted (autodetected by extension / filename):
  * .jsonl              cp/install hook trace (dep-hooks.sh output)
  * .json               intermediate dep sidecar (e.g. link.dep.json,
                        <foo>_java.dep.json).  Expanded through its own
                        `deps[]` in pkg mode; passthrough in deploy mode.
  * .yaml / .yml        pkg.yaml: `rpm_deps:` list feeds `rpms[]`; the
                        file's realpath is added to `deps[]`.
  * *_rpmbuild.log      the tee'd `rpmbuild -bb` output.  Every `+ install`
                        / `+ cp` line inside the Executing(%install)
                        section is parsed, absolute-path args (except the
                        destination) become deps[].

Output shape (pkg mode -- the default):
  {
    "file":   "/abs/.../pkg-<name>-<ver>-<rel>.<dist>.<arch>.rpm",  # if --file
    "pkg":    "<PackageName>",
    "rpms":   ["<rpm-dep>", ...],       # sorted
    "deps":   ["/abs/path/to/source", ...] # sorted, absolute paths only
  }

All `deps[]` paths are guaranteed absolute (realpath'd where possible).
"""

from __future__ import annotations

import argparse
import json
import os
import sys
from enum import Enum, unique
from pathlib import Path
from typing import Dict, List, Optional, Set

try:
    import yaml  # type: ignore[import-untyped]
except ImportError:
    in_venv = sys.prefix != sys.base_prefix
    tail = " (inside your active venv; do NOT use --user)" if in_venv \
           else " --user  (or without --user for system-wide)"
    print(f"pkgdeps: missing Python dep 'yaml'.\n"
          f"    fix:  {sys.executable} -m pip install PyYAML{tail}",
          file=sys.stderr)
    sys.exit(2)


@unique
class PkgMode(str, Enum):
    # No `: str` annotations on the members -- typing.Enum's runtime
    # already infers the value type from `str` in the base class, and
    # mypy actively rejects annotated enum members per the typing
    # spec.  The `str` mixin is what makes `PkgMode.PKG == "pkg"`.
    PKG    = "pkg"
    DEPLOY = "deploy"


########################################################################
# Path canonicalisation
########################################################################

def _abs(p: str) -> str:
    """Absolute-path canonicalisation WITHOUT following symlinks
    (`os.path.abspath`).

    Design contract: emit-time dep.json paths are absolute-but-
    possibly-symlinked; final `readlink -f` resolution happens at
    load/aggregation time in `production/tools/pydep/dag.py`.  Keeps
    build recipes fast + short.  Preserves a trailing '/' on
    directory-like inputs (source-root marker convention)."""
    if not p:
        return p
    trailing = "/" if p.endswith("/") else ""
    return os.path.abspath(p) + trailing


########################################################################
# Collector
########################################################################

class DependencyCollector:
    def __init__(self, mode: PkgMode, package_name: str):
        self.mode = mode
        self.package_name = package_name
        self.file_dependencies: Set[str] = set()
        self.rpm_dependencies:  Set[str] = set()
        self.dep_cache: Dict[str, List[str]] = {}   # for json expansion in pkg mode

    # ---- JSONL (dep-hooks trace) --------------------------------------
    def process_jsonl(self, filepath: Path) -> None:
        try:
            with open(filepath, "r", encoding="utf-8") as f:
                for line_num, line in enumerate(f):
                    line = line.strip()
                    if not line:
                        continue
                    try:
                        record = json.loads(line)
                    except json.JSONDecodeError as e:
                        print(f"warn: invalid jsonl {filepath}:{line_num}: {e}",
                              file=sys.stderr)
                        continue
                    if record.get("session") == "init":
                        continue
                    for src in record.get("sources", []) or []:
                        if src and isinstance(src, str):
                            self.file_dependencies.add(_abs(src))
        except FileNotFoundError:
            print(f"warn: not found: {filepath}", file=sys.stderr)

    # ---- JSON sidecar --------------------------------------------------
    def _expand_classpath(self, deps: List[str]) -> List[str]:
        """Expand classpath directory entries to their contained jars
        (deploy mode only).  All paths flow through `_abs()` for full
        symlink resolution -- see `_abs`'s docstring."""
        result: List[str] = []
        for dep in deps:
            if not dep or not isinstance(dep, str):
                continue
            p = Path(dep.rstrip("/"))
            if p.is_dir():
                jars = list(p.rglob("*.jar"))
                if jars:
                    result.extend(_abs(str(j)) for j in jars)
                else:
                    result.append(_abs(str(p) + "/"))
            elif p.exists():
                result.append(_abs(str(p)))
            else:
                result.append(dep)
        return result

    def process_json(self, filepath: Path) -> None:
        """Cache the sidecar's `deps[]` for post-jsonl expansion.  If
        the sidecar's `file` key shows up as a dep in some other input,
        we'll substitute that with the sidecar's deps -- see
        expand_json_deps()."""
        try:
            with open(filepath, "r", encoding="utf-8") as f:
                data = json.load(f)
        except FileNotFoundError:
            print(f"warn: not found: {filepath}", file=sys.stderr)
            return
        except json.JSONDecodeError as e:
            print(f"error: invalid json in {filepath}: {e}", file=sys.stderr)
            return

        file_key = data.get("file", "")
        deps = data.get("deps", [])
        if not file_key or not deps:
            return
        deps = [_abs(d) for d in deps if d and isinstance(d, str)]
        if self.mode == PkgMode.DEPLOY:
            deps = self._expand_classpath(deps)
        self.dep_cache[_abs(file_key)] = deps

    # ---- YAML pkg spec (pkg.yaml) --------------------------------------
    def process_yaml(self, filepath: Path) -> None:
        """Extract `rpm_deps:` entries into rpms[] and add the yaml
        file itself to deps[] (a pkg-spec edit must trigger a rebuild)."""
        try:
            with open(filepath, "r", encoding="utf-8") as f:
                data = yaml.safe_load(f)
        except FileNotFoundError:
            print(f"warn: not found: {filepath}", file=sys.stderr)
            return
        except yaml.YAMLError as e:
            print(f"error: invalid yaml in {filepath}: {e}", file=sys.stderr)
            return
        if not isinstance(data, dict):
            print(f"warn: {filepath}: not a mapping at top level", file=sys.stderr)
            return

        # Sanity: bail if the yaml's `pkg:` disagrees with what the
        # caller told us we're building (rare in practice, but catches
        # copy-paste mistakes where the wrong pkg.yaml is wired in).
        yaml_pkg_name = data.get("pkg")
        if yaml_pkg_name and self.package_name and yaml_pkg_name != self.package_name:
            print(f"warn: package name mismatch in {filepath} "
                  f"({yaml_pkg_name} vs {self.package_name})", file=sys.stderr)

        for dep in data.get("rpm_deps") or []:
            if isinstance(dep, str) and dep:
                self.rpm_dependencies.add(dep)

        # The yaml file itself is a source input of the .rpm.
        self.file_dependencies.add(_abs(str(filepath)))

    # ---- rpmbuild -bb log ---------------------------------------------
    def process_rpmbuild_log(self, filepath: Path) -> None:
        """Parse `+ install ...` / `+ cp ...` lines inside the
        Executing(%install) section.  Every absolute-path arg except
        the destination is treated as a source dep."""
        try:
            fh = open(filepath, "r", encoding="utf-8", errors="ignore")
        except FileNotFoundError:
            print(f"warn: not found: {filepath}", file=sys.stderr)
            return

        with fh as f:
            in_install = False
            for line in f:
                s = line.rstrip()
                if "Executing(%install):" in s:
                    in_install = True
                    continue
                if not in_install:
                    continue
                # Any other Executing(...) section, or the "Processing
                # files:" phase, closes %install.
                if s.startswith("Executing(") or s.startswith("Processing files:"):
                    in_install = False
                    continue
                # Only lines emitted by the -x shell trace start with
                # a `+ ` -- so this is a coarse filter for
                # install/cp invocations.
                if not (s.startswith("+ install ")
                        or s.startswith("+ cp ")
                        or s.startswith("+ /usr/bin/install ")
                        or s.startswith("+ /bin/cp ")):
                    continue
                parts = s.split()
                if len(parts) < 3:
                    continue
                abs_args: List[str] = []
                for arg in parts[1:]:
                    if arg.startswith("-") or arg.startswith("$"):
                        continue
                    if arg.startswith("/"):
                        abs_args.append(arg)
                # Last arg is the destination (rpmbuild `%{buildroot}/...`),
                # everything before it is a source.
                for src in abs_args[:-1]:
                    self.file_dependencies.add(_abs(src))

    # ---- Dispatch ------------------------------------------------------
    def process_file(self, filepath: str) -> None:
        p = Path(filepath)
        if not p.exists():
            print(f"warn: not found: {filepath}", file=sys.stderr)
            return
        name_low = p.name.lower()
        suffix   = p.suffix.lower()
        if name_low.endswith("_rpmbuild.log") or name_low.endswith(".rpmbuild.log"):
            self.process_rpmbuild_log(p)
        elif suffix == ".jsonl":
            self.process_jsonl(p)
        elif suffix == ".json":
            self.process_json(p)
        elif suffix in (".yaml", ".yml"):
            self.process_yaml(p)
        else:
            # Unknown extension -- try JSON parse as a last resort.
            print(f"warn: unknown file type {filepath}, trying json...",
                  file=sys.stderr)
            self.process_json(p)

    def expand_json_deps(self) -> None:
        """If a JSON sidecar's `file` key appears in file_dependencies
        (e.g. someone else's link.dep.json listed it), replace that
        entry with the sidecar's own deps -- gives a full transitive
        expansion in one shot."""
        if self.mode == PkgMode.DEPLOY and len(self.dep_cache) != 1:
            raise SystemExit("pkgdeps: only one .json allowed in deploy mode")
        for file_key, deps in self.dep_cache.items():
            if file_key in self.file_dependencies:
                self.file_dependencies.discard(file_key)
                self.file_dependencies.update(deps)
            elif self.mode == PkgMode.DEPLOY:
                self.file_dependencies.update(deps)
            else:
                # Not referenced elsewhere; keep the sidecar file
                # itself as a dep so a link.dep.json edit re-propagates.
                self.file_dependencies.add(file_key)

    # ---- Output --------------------------------------------------------
    def save_json(
        self,
        output_path: str,
        source_path: Optional[str],
        file_field: Optional[str] = None,
        mk_file: Optional[str] = None,
        extra_deps: Optional[List[str]] = None,
        indent: int = 2,
    ) -> None:
        out = Path(output_path)
        out.parent.mkdir(parents=True, exist_ok=True)

        # --source: reference convention -- add the source root as a
        # directory-marker dep entry (path with trailing slash).
        if source_path:
            sp = Path(source_path)
            if sp.exists():
                self.file_dependencies.add(_abs(str(sp) + "/"))

        if mk_file:
            self.file_dependencies.add(_abs(mk_file))

        for e in extra_deps or []:
            if e:
                self.file_dependencies.add(_abs(e))

        if self.mode == PkgMode.PKG:
            result: Dict[str, object] = {}
            if file_field:
                result["file"] = _abs(file_field)
            result["pkg"]  = self.package_name
            result["rpms"] = sorted(self.rpm_dependencies)
            result["deps"] = sorted(self.file_dependencies)
        else:  # DEPLOY
            result = {
                "file": next(iter(self.dep_cache.keys()), ""),
                "deps": sorted(self.file_dependencies),
            }

        out.write_text(json.dumps(result, indent=indent, ensure_ascii=False),
                       encoding="utf-8")


########################################################################
# CLI
########################################################################

def _parse_args(argv: Optional[List[str]] = None) -> argparse.Namespace:
    p = argparse.ArgumentParser(
        description="Aggregate rpm-build dependency artefacts into one .dep.json.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=(
            "Examples:\n"
            "  # YAML-driven pkg (log-based capture):\n"
            "  %(prog)s -p pkg-foo -o out.dep.json --file /abs/foo.rpm "
            "--mk-file foo.mk foo_rpmbuild.log deployment/pkg.yaml\n\n"
            "  # Plain-spec pkg (hook-based capture):\n"
            "  %(prog)s -p pkg-foo -o out.dep.json --file /abs/foo.rpm "
            "--mk-file foo.mk --rpm-dep foo-common foo.hooks.jsonl\n"
        ),
    )
    p.add_argument("-m", "--mode", choices=[m.value for m in PkgMode],
                   default=PkgMode.PKG.value, help="output shape (default: pkg)")
    p.add_argument("-p", "--package", help="package name (required in pkg mode)")
    p.add_argument("-s", "--source",
                   help="source root; added as a directory-marker dep entry")
    p.add_argument("-o", "--output", required=True, help="output .dep.json path")
    p.add_argument("--file", dest="file_field",
                   help="value for the top-level `file` field (usually the "
                        "absolute .rpm path).  Omit to keep the plain "
                        "`{pkg, rpms, deps}` shape.")
    p.add_argument("--mk-file", help="child .mk file to add to deps[]")
    p.add_argument("--rpm-dep", action="append", default=[],
                   help="manual rpms[] entry (repeatable).  Complements "
                        "`rpm_deps:` extracted from pkg.yaml inputs; "
                        "required for plain-spec mode.")
    p.add_argument("--extra-dep", action="append", default=[],
                   help="extra deps[] entry (repeatable, absolute path).")
    p.add_argument("inputs", nargs="*",
                   help="input files (*.jsonl, *.json, *.yaml, *_rpmbuild.log)")
    return p.parse_args(argv)


def main(argv: Optional[List[str]] = None) -> int:
    args = _parse_args(argv)
    mode = PkgMode(args.mode)
    if mode == PkgMode.PKG and not args.package:
        raise SystemExit("pkgdeps: --package is required in pkg mode")

    collector = DependencyCollector(mode, args.package or "")

    # Order matters: process .yaml + .jsonl + logs first (they write
    # directly to file_dependencies + rpm_dependencies), .json sidecars
    # last (they cache-only, then get expanded via expand_json_deps).
    all_files    = list(args.inputs)
    json_files   = [f for f in all_files if f.endswith(".json")]
    non_json     = [f for f in all_files if not f.endswith(".json")]
    for f in non_json:
        collector.process_file(f)
    for f in json_files:
        collector.process_file(f)
    collector.expand_json_deps()

    # Manual rpm-level deps (plain-spec mode).
    for r in args.rpm_dep:
        if r:
            collector.rpm_dependencies.add(r)

    collector.save_json(
        output_path=args.output,
        source_path=args.source,
        file_field=args.file_field,
        mk_file=args.mk_file,
        extra_deps=args.extra_dep,
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
