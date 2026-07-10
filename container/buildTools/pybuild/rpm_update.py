"""Check which images have upstream RPM updates available.

Ported from reg_container_tooling's `change2target.py::_check_rpm_updates`
(line 1082) with a cleaner class-based API.  Given a directory of
`<name>.dep.json` files (produced by `container build`), for each image:

  1. Extract the cached `rpms[]` tuples
  2. Extract the resolved yum repo URLs from `extra.repos`
  3. Query those repos for the CURRENT (name, ver, rel, arch)
  4. Diff cached vs current, report images that have updates

Two output modes:
  - text : human-readable per-line diff summary
  - json : structured, feeds directly into a CI update-detection
           pipeline
"""

from __future__ import annotations
import json
import tempfile
from dataclasses import dataclass, field
from pathlib import Path
from typing import Iterator

from .rpms       import RpmInfo, _version_key
from .yum_query  import YumQuery
from .json_pretty import dumps as pretty_dumps


# ------------------------------------------------------------------
# Data model
# ------------------------------------------------------------------

@dataclass
class ImageCache:
    """One image's cached state loaded from a dep.json file."""
    path:  Path                                       # <name>.dep.json
    img:   str                                        # image name
    rpms:  list[tuple[str, str, str, str]]            # cached tuples
    repos: dict[str, str]                             # resolved yum URLs

    @classmethod
    def load(cls, dep_json: Path) -> "ImageCache | None":
        try:
            data = json.loads(dep_json.read_text())
        except (OSError, json.JSONDecodeError):
            return None
        img = data.get("img")
        if not img:
            return None
        rpms = [tuple(r) for r in (data.get("rpms") or []) if len(r) == 4]  # type: ignore[misc]
        repos = (data.get("extra") or {}).get("repos") or {}
        return cls(path=dep_json, img=img, rpms=rpms, repos=repos)


@dataclass
class RpmUpdate:
    """One RPM that has a newer version available."""
    image:   str
    name:    str
    arch:    str
    cached:  tuple[str, str]      # (version, release) as of dep.json
    current: tuple[str, str]      # (version, release) as of yum today

    def as_dict(self) -> dict:
        return {
            "image":   self.image,
            "name":    self.name,
            "arch":    self.arch,
            "cached":  list(self.cached),
            "current": list(self.current),
        }


@dataclass
class ImageReport:
    """Aggregate view for one image."""
    img:      str
    updates:  list[RpmUpdate] = field(default_factory=list)
    missing:  list[str]       = field(default_factory=list)   # names not resolved
    checked:  int             = 0                              # rpms actually queried
    skipped:  bool            = False                          # true when no repos

    @property
    def has_updates(self) -> bool:
        return bool(self.updates)

    def as_dict(self) -> dict:
        return {
            "img":      self.img,
            "checked":  self.checked,
            "updates":  [u.as_dict() for u in self.updates],
            "missing":  list(self.missing),
            "skipped":  self.skipped,
        }


# ------------------------------------------------------------------
# Checker
# ------------------------------------------------------------------

@dataclass
class RpmUpdateChecker:
    """Scan a directory of *.dep.json and report images with upstream
    RPM updates.

    Attributes:
      dep_json_dir  where to look for `<name>.dep.json` files
      only_images   restrict to these image names (default: all found)
      arch_filter   restrict yum queries to this arch (x86_64 / i686 / noarch)
    """
    dep_json_dir: Path
    only_images:  list[str] | None = None
    arch_filter:  str | None       = None

    # --------------------------------------------------------------
    # Discovery
    # --------------------------------------------------------------
    def images(self) -> Iterator[ImageCache]:
        """Yield an ImageCache per discovered <name>.dep.json.

        Recursively scans dep_json_dir so both flat layouts
        (`build/container/*.dep.json`) and per-image ones
        (`build/container/<name>/<name>.dep.json`) work.
        """
        if not self.dep_json_dir.exists():
            return
        # Prefer <dir>/*/<name>.dep.json (container's per-image layout),
        # fall back to a flat <dir>/*.dep.json (reg's ims_do/img/).
        seen: set[Path] = set()
        for cand in sorted(self.dep_json_dir.rglob("*.dep.json")):
            if cand.name in ("digest.dep.json",):
                continue
            if cand in seen:
                continue
            seen.add(cand)
            ic = ImageCache.load(cand)
            if ic is None:
                continue
            if self.only_images and ic.img not in self.only_images:
                continue
            yield ic

    # --------------------------------------------------------------
    # Per-image check
    # --------------------------------------------------------------
    def check_one(self, ic: ImageCache) -> ImageReport:
        report = ImageReport(img=ic.img)
        if not ic.repos:
            report.skipped = True
            return report
        if not ic.rpms:
            return report

        # Materialise the resolved repo URLs into a temp *.repo file
        # so we can hand it to YumQuery unchanged.
        repo_file = self._materialise_repo(ic.img, ic.repos)
        names     = [r[0] for r in ic.rpms]
        current   = YumQuery(
            repo_file   = repo_file,
            arch_filter = self.arch_filter,
        ).query(names)
        report.checked = len(current)

        # Index current by name for quick lookup.
        idx: dict[str, RpmInfo] = {r.name: r for r in current}

        for cached_name, cached_ver, cached_rel, cached_arch in ic.rpms:
            info = idx.get(cached_name)
            if info is None or info.version == "NOT_FOUND":
                report.missing.append(cached_name)
                continue
            # Compare (version, release) numerically-aware -- ignore
            # arch shifts (rare, and we usually keep to one arch).
            if self._is_newer(info.version, info.release, cached_ver, cached_rel):
                report.updates.append(RpmUpdate(
                    image   = ic.img,
                    name    = cached_name,
                    arch    = cached_arch,
                    cached  = (cached_ver,   cached_rel),
                    current = (info.version, info.release),
                ))
        return report

    def check_all(self) -> list[ImageReport]:
        return [self.check_one(ic) for ic in self.images()]

    # --------------------------------------------------------------
    # Report rendering
    # --------------------------------------------------------------
    def render(self, reports: list[ImageReport], fmt: str = "text") -> str:
        if fmt == "json":
            payload = {
                "checked": sum(r.checked for r in reports),
                "images":  [r.as_dict() for r in reports],
            }
            return pretty_dumps(payload, indent=2, max_line_length=120)

        # Text mode: brief image-by-image dump.
        lines: list[str] = []
        for r in reports:
            if r.skipped:
                lines.append(f"[SKIP] {r.img}: no repos declared in dep.json")
                continue
            if not r.updates and not r.missing:
                lines.append(f"[OK]   {r.img}: {r.checked} rpms, no updates")
                continue
            head = f"[UPD]  {r.img}:"
            if r.updates:
                head += f" {len(r.updates)} updates"
            if r.missing:
                head += f", {len(r.missing)} missing"
            lines.append(head)
            for u in r.updates:
                lines.append(
                    f"       {u.name} {u.arch}: "
                    f"{u.cached[0]}-{u.cached[1]}  ->  "
                    f"{u.current[0]}-{u.current[1]}"
                )
            for name in r.missing:
                lines.append(f"       {name}: NOT FOUND in yum")
        return "\n".join(lines) + ("\n" if lines else "")

    # --------------------------------------------------------------
    # Helpers
    # --------------------------------------------------------------
    @staticmethod
    def _materialise_repo(image_name: str, repos: dict[str, str]) -> Path:
        """Write resolved yum URLs to a temp file, one stanza each."""
        # Priority preserved: dict insertion order == RepoRenderer order
        lines: list[str] = []
        for i, (key, url) in enumerate(repos.items(), start=1):
            lines += [
                f"[{key}]",
                f"name={key}",
                f"baseurl={url}",
                "gpgcheck=0",
                "enabled=1",
                f"priority={i}",
                "",
            ]
        fd, path = tempfile.mkstemp(prefix=f"container_upd_{image_name}_", suffix=".repo")
        Path(path).write_text("\n".join(lines))
        return Path(path)

    @staticmethod
    def _is_newer(v1: str, r1: str, v2: str, r2: str) -> bool:
        """True when (v1, r1) > (v2, r2) under numeric-aware comparison."""
        return _version_key(v1, r1) > _version_key(v2, r2)
