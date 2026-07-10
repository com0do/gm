# SPDX-License-Identifier: MIT
"""Aggregate + clean the raw ``build/**/*.dep.json`` files into a
git-check-in-friendly cache under ``<build>/deps/``.

Raw dep.json files carry absolute paths (they must, for local make's
mtime comparisons to work).  For CI caches, cross-checkout tooling,
and change2target-style downstream analysis you want paths relative
to the project root instead.

`snapshot()` scans the raw tree, classifies each artefact by the
``lib/`` / ``exec/`` / ``pkg/`` / ``java/`` subtree it lives under,
rewrites every path relative to ``proj_top`` (dropping paths outside
it, so the cache is purely internal), and writes one file per
artefact to ``<out_dir>/<type>/<target>.dep.json``.  Idempotent:
the output dir is truncated at the start of each run.

Two extras that mirror change2target's `create_cache`:

* **Framework extraction** -- deps that appear in EVERY artefact are
  factored into a single ``<out_dir>/gm.dep.json`` (semantic name
  ``gm-framework``).  Each artefact's own ``deps`` then keeps only
  its target-specific entries plus a single ``"gm-framework"`` marker
  pointing at the extracted file.  A change to any framework file
  seeds ``gm.dep.json`` in the DAG, whose consumers are all
  artefacts -- exact same walk semantics, ~5 fewer lines per file.

* **Version + digest** -- a two-line ``<out_dir>/version`` records
  a caller-supplied (or git-derived) version string and the SHA256
  of every cleaned ``.dep.json`` content, sorted by relative path.
  Same shape as change2target's cache-version file so downstream
  tooling can share the validation code.

Called from ``dep_query.py snapshot`` (see ``deps-snap`` in
project.mk).
"""
from __future__ import annotations

import hashlib
import json
import subprocess
from pathlib import Path
from typing import Any

from .paths import rel


# Synthetic artefact name for the extracted framework dep.  Chosen so
# it can never clash with a real file (hyphen isn't in target names).
# Must match the `file:` field written by env.mk's `gm.dep.json` rule.
FRAMEWORK_NAME = "gm-framework"


# Build subdirectory -> artefact-type bucket.  Keep in sync with the
# GM_LIB_DIR / GM_EXEC_DIR / GM_PKG_DIR / GM_JAVA_DIR layout in
# env.mk.  A .dep.json under any of these subtrees goes into that
# bucket in the snapshot; anything else (e.g. per-object dep.json
# under `build/<relpath>/<arch>/<mode>/`) is silently skipped.
TYPE_DIRS = {
    "lib":  "lib",
    "exec": "exec",
    "pkg":  "pkg",
    "java": "java",
}


def _classify(dep_json: Path, build_dir: Path) -> str | None:
    """Return the artefact-type bucket for a raw dep.json, or None
    if it doesn't sit under one of the known type subtrees."""
    try:
        rel_path = dep_json.relative_to(build_dir)
    except ValueError:
        return None
    head = rel_path.parts[0] if rel_path.parts else ""
    for name, sub in TYPE_DIRS.items():
        if head == sub:
            return name
    return None


def _target_name(data: dict[str, Any], dep_json: Path) -> str:
    """Derive the canonical target name for the snapshot filename.

    Precedence:
      1. `pkg` / `img` field  -- semantic label from the source data.
      2. `file` field basename minus `.so` / `.a` / `.jar` (`libt2.so`
         -> `libt2`; `t3` -> `t3`).  Preferred over the raw dep.json
         filename because some target types add an internal
         disambiguation tag (`t3.exe.dep.json` when a target and its
         `.o` share the same basename -- see target.c.mk's
         `_DEP_JSON_TAG` logic).
      3. Fallback: dep.json filename minus the two trailing extensions.
    """
    if data.get("pkg"):
        return str(data["pkg"])
    if data.get("img"):
        return str(data["img"])
    file_field = data.get("file")
    if isinstance(file_field, str) and file_field:
        name = Path(file_field).name
        for suf in (".so", ".a", ".jar"):
            if name.endswith(suf):
                return name[: -len(suf)]
        return name
    stem = dep_json.name
    for _ in range(2):
        if "." in stem:
            stem = stem.rsplit(".", 1)[0]
    return stem


def _clean_one(dep_json: Path, proj_top: Path) -> dict[str, Any] | None:
    """Parse one raw dep.json; return the cleaned dict (paths rewritten
    project-relative, external paths dropped) or None if unusable."""
    try:
        data = json.loads(dep_json.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return None
    if not isinstance(data, dict):
        return None

    out: dict[str, Any] = {}
    if "file" in data and isinstance(data["file"], str):
        r = _rel_or_drop(data["file"], proj_top)
        if r is not None:
            out["file"] = r
    for key in ("pkg", "img"):
        if key in data:
            out[key] = data[key]

    seen: set[str] = set()
    deps_out: list[str] = []
    for d in data.get("deps") or []:
        if not isinstance(d, str):
            continue
        r = _rel_or_drop(d, proj_top)
        if r and r not in seen:
            seen.add(r)
            deps_out.append(r)
    out["deps"] = sorted(deps_out)

    if data.get("rpms"):
        out["rpms"] = data["rpms"]

    return out


def _rel_or_drop(path: str, proj_top: Path) -> str | None:
    """Turn an absolute path into a proj_top-relative one; return None
    for paths that don't live under proj_top (system headers etc.).

    Wraps `pydep.paths.rel()` which uses `Path.relative_to()`;
    external absolute paths are surfaced by comparing the result to
    the input -- if identical, the path wasn't under proj_top."""
    if not path:
        return None
    p = Path(path)
    if not p.is_absolute():
        s = str(p)
    else:
        s = rel(str(p), proj_top)
        if s == str(p):
            return None
    return None if s in ("", ".") else s


def _derive_version(proj_top: Path) -> str:
    """`git describe --always --dirty` if this is a git checkout,
    else ``"unversioned"``.  Kept side-effect-free (never mutates
    anything, honours GIT_* env vars automatically via subprocess)."""
    try:
        out = subprocess.run(
            ["git", "-C", str(proj_top), "describe", "--always", "--dirty"],
            capture_output=True, text=True, check=True, timeout=5,
        ).stdout.strip()
        return out or "unversioned"
    except (FileNotFoundError, subprocess.CalledProcessError,
            subprocess.TimeoutExpired):
        return "unversioned"


def _load_framework_list(build_dir: Path, proj_top: Path) -> list[str]:
    """Return the framework file list from `<build_dir>/gm.dep.json`,
    with paths made project-relative.  Empty list if the file is
    missing / unparseable -- snapshot then skips the extraction and
    every artefact keeps its full framework listing.

    Single source of truth is env.mk's `GM_FRAMEWORK_CORE_MK`; the
    rule at `env.mk`'s bottom writes it here as absolute paths."""
    gm_json = build_dir / "gm.dep.json"
    if not gm_json.is_file():
        return []
    try:
        data = json.loads(gm_json.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return []
    out: set[str] = set()
    for d in data.get("deps") or []:
        if not isinstance(d, str):
            continue
        r = _rel_or_drop(d, proj_top)
        if r:
            out.add(r)
    return sorted(out)


def snapshot(build_dir: Path, proj_top: Path, out_dir: Path,
             version: str | None = None) -> dict[str, int]:
    """Produce the cleaned snapshot under `out_dir`.  Returns a
    ``{"lib": N, "exec": N, ..., "framework": N}`` count per type.
    See module docstring for the full contract.

    Extra keys in the return value:
      * ``framework`` -- 1 iff a `gm.dep.json` was written (deps that
                          are common to all artefacts got extracted).

    Writes ``<out_dir>/version`` with two lines:
        <version-or-git-describe>
        <sha256 of all cleaned dep.json contents, sorted by name>
    """
    build_dir = build_dir.resolve()
    proj_top  = proj_top.resolve()
    out_dir   = out_dir.resolve()

    if not build_dir.is_dir():
        raise FileNotFoundError(f"snapshot: --build-dir does not exist: {build_dir}")

    # Wipe stale outputs so a target dropped upstream doesn't linger.
    if out_dir.exists():
        for f in out_dir.rglob("*.dep.json"):
            f.unlink()
        v = out_dir / "version"
        if v.is_file():
            v.unlink()
    for sub in TYPE_DIRS:
        (out_dir / sub).mkdir(parents=True, exist_ok=True)

    # Pass 1: collect cleaned artefacts in memory.  We can't write yet
    # because the framework-extraction pass needs to see every artefact
    # to compute the intersection.
    artefacts: dict[str, list[tuple[Path, dict]]] = {k: [] for k in TYPE_DIRS}
    for dep_json in sorted(build_dir.rglob("*.dep.json")):
        try:
            dep_json.relative_to(out_dir)
            continue                                # inside the cleaned tree
        except ValueError:
            pass
        kind = _classify(dep_json, build_dir)
        if kind is None:
            continue
        cleaned = _clean_one(dep_json, proj_top)
        if cleaned is None:
            continue
        artefacts[kind].append((dep_json, cleaned))

    flat = [item for group in artefacts.values() for item in group]
    framework_deps = _load_framework_list(build_dir, proj_top)

    # Pass 2: strip framework deps from every artefact whose deps
    # touched at least one of them, then add a single "gm-framework"
    # marker back (points at <out>/gm.dep.json in the DAG).
    # Artefacts with no framework overlap (e.g. .import.mk targets
    # that only list vendor paths + the .import.mk itself) are left
    # untouched -- no spurious "gm-framework" edge for them.
    counts: dict[str, int] = {k: 0 for k in TYPE_DIRS}
    counts["framework"] = 0
    if framework_deps:
        fw_set = set(framework_deps)
        for _, data in flat:
            existing = data.get("deps") or []
            touched = [d for d in existing if d in fw_set]
            if not touched:
                continue
            data["deps"] = sorted(
                [d for d in existing if d not in fw_set] + [FRAMEWORK_NAME]
            )
        (out_dir / "gm.dep.json").write_text(
            json.dumps({"file": FRAMEWORK_NAME, "deps": framework_deps},
                       indent=2, ensure_ascii=False) + "\n",
            encoding="utf-8",
        )
        counts["framework"] = 1

    # Pass 3: write out cleaned artefacts.
    for kind, group in artefacts.items():
        for dep_json, data in group:
            target = _target_name(data, dep_json)
            (out_dir / kind / f"{target}.dep.json").write_text(
                json.dumps(data, indent=2, ensure_ascii=False) + "\n",
                encoding="utf-8",
            )
            counts[kind] += 1

    # Version + digest.  Digest is deterministic across identical
    # inputs, so re-running with the same tree emits the same hash
    # (CI-cache-friendly).
    written = sorted(out_dir.rglob("*.dep.json"))
    digest = hashlib.sha256()
    for p in written:
        digest.update(p.relative_to(out_dir).as_posix().encode("utf-8"))
        digest.update(b"\0")
        digest.update(p.read_bytes())
    ver = version or _derive_version(proj_top)
    (out_dir / "version").write_text(
        f"{ver}\n{digest.hexdigest()}\n", encoding="utf-8",
    )
    return counts
