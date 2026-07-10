"""Emit `<image-name>.dep.json` -- consumed by gm's dep_query.py.

Schema (aligned with the reference dep.json layout*.dep.json):

    {
      "img":   "<image-name>",
      "rpms":  [["name","ver","rel","arch"], ...],
      "deps":  ["<absolute path>", ...],
      "extra": {
        "base_image_url":     "<base-image-ref>",
        "version":            "<image-version>",
        "tag":                "<image-tag>",
        "image_id":           "sha256:..."        # if built
      }
    }

Path policy for `deps[]`: every entry is **absolute** (via
`os.path.abspath`, no symlink following).  This matches gm's
build-time policy in `production/make/scripts/pkgdeps.py::_abs()` --
emit fast + minimal, resolve symlinks (`readlink -f` /
`os.path.realpath`) at load/aggregation time in
`production/tools/pydep/dag.py`.  So the raw sidecars may show
OUT_DIR-view paths (`build/lib/…/libt2.so`), and consumers that go
through DepGraph.load() see the resolved BUILD_DIR forms.

`deps` is built from four sources, all abspath'd then deduped and
sorted:
  1. The manifest file itself + its referenced dockerfile + install_file
  2. Every entry in manifest.extras
  3. The hook JSONL trace's `sources[]` (every file copied into the
     build context via dep-hooks.sh-instrumented cp)
  4. Any explicit extra_deps passed in
"""

from __future__ import annotations
import json
import os
from dataclasses import dataclass
from pathlib import Path

from .manifest    import Manifest
from .rpms        import RpmInfo
from .json_pretty import dumps as pretty_dumps


def _abs(p: str | Path) -> str:
    """Absolute path string, WITHOUT symlink resolution -- see the
    module docstring for the "emit fast, resolve at load" policy.
    Matches gm's `_abs()` in production/make/scripts/pkgdeps.py so
    both toolchains emit the same shape."""
    s = str(p)
    if not s:
        return s
    return os.path.abspath(s)


@dataclass
class DepJson:
    manifest:    Manifest
    rpms:        list[RpmInfo]
    hooks_log:   Path | None    = None
    image_id:    str | None     = None
    proj_top:    Path | None    = None       # not used for path mangling;
                                             # kept for backward-compat
    extra_deps:  list[Path]     = None       # type: ignore[assignment]
    cmd:         str | None     = None       # full build command line

    def build(self) -> dict:
        # Collect every dep path, canonicalise via _abs (see
        # module docstring for the source-of-truth policy).  File
        # extras go straight into deps.  Directory extras don't --
        # their leaf files enter the trace via `dep_add` inside
        # BuildContext._hooked_copy_extras, so the hook-log parse
        # below picks them up automatically.
        abs_deps: set[str] = set()
        abs_deps.add(_abs(self.manifest.path))
        if self.manifest.dockerfile:
            abs_deps.add(_abs(self.manifest.dockerfile))
        if self.manifest.installer:
            abs_deps.add(_abs(self.manifest.installer))
        if self.manifest.install_file:
            abs_deps.add(_abs(self.manifest.install_file))
        if self.manifest.rpm_lock and self.manifest.rpm_lock.override:
            abs_deps.add(_abs(self.manifest.rpm_lock.override))
        for e in self.manifest.extras:
            if e.src.is_file():
                abs_deps.add(_abs(e.src))
        if self.hooks_log and self.hooks_log.is_file():
            abs_deps.update(_abs(p) for p in self._parse_hook_log(self.hooks_log))
        for d in self.extra_deps or []:
            abs_deps.add(_abs(d))

        # Filter out directory-only entries -- when a whole dir was
        # hook-cp'd, both the directory and its leaf files show up
        # in the trace; leaves are what matter for change tracking
        # (git diff shows individual files, not directories).
        deps = sorted(p for p in abs_deps if not Path(p).is_dir())

        # 3. Schema: img / rpms / deps / extra (in that order).
        #    `extra` mixes our standard metadata with any pass-through
        #    keys the manifest declared -- manifest values lose to ours
        #    on conflict because the framework needs the build-time
        #    metadata to be authoritative.
        #
        #    `extra.cmd` and `extra.repos` are the container counterparts
        #    of reg_container_tooling's `cmd` and `version_string` --
        #    every reg extra field has a shape-preserving equivalent
        #    here so dep_query.py can consume either format.
        extra: dict = dict(self.manifest.extra)
        extra["base_image_url"] = self.manifest.base
        extra["version"]        = self.manifest.version
        extra["tag"]            = self.manifest.tag or self.manifest.version
        if self.cmd:
            extra["cmd"] = self.cmd
        if self.manifest.repos:
            extra["repos"] = self._resolved_repos()
        if self.image_id:
            extra["image_id"]   = self.image_id

        return {
            "img":   self.manifest.name,
            "rpms":  [list(r.as_tuple()) for r in self.rpms],
            "deps":  deps,
            "extra": extra,
        }

    def _resolved_repos(self) -> dict[str, str]:
        """Substitute manifest.vars into each repo URL.

        This is the container counterpart of reg's `version_string:` --
        a human-readable snapshot of which upstream repo + version fed
        into this image build.  Sorted by priority (matches how they
        get written into the yum.repo file).
        """
        m = self.manifest
        ordered = sorted(m.repos.values(), key=lambda r: (r.priority, r.key))
        return {r.key: m.substitute(r.url) for r in ordered}

    def write_to(self, path: Path) -> Path:
        path.parent.mkdir(parents=True, exist_ok=True)
        # Compact-inner / indented-outer -- rpms[] rows collapse to
        # one line each (["name","ver","rel","arch"]), dict + long
        # list structure stays readable.
        path.write_text(pretty_dumps(self.build(), indent=2, max_line_length=120) + "\n")
        return path

    # ------------------------------------------------------------------
    @staticmethod
    def _parse_hook_log(jsonl: Path) -> set[str]:
        """Extract every `sources[]` entry from a hook trace."""
        out: set[str] = set()
        for line in jsonl.read_text().splitlines():
            line = line.strip()
            if not line:
                continue
            try:
                rec = json.loads(line)
            except json.JSONDecodeError:
                continue
            if not isinstance(rec, dict):
                continue
            for s in rec.get("sources") or []:
                if isinstance(s, str) and s:
                    out.add(s)
        return out
