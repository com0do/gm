"""Versioned snapshot of dep.json files with SHA256 digests.

Ported from `production/py/change2target.py::DependencyDAG.create_cache`
+ `_cache_digest`.  Purpose: bookmark the current dep.json state at a
specific version tag so later runs can compare against a KNOWN
baseline.

Layout:
    <root>/
      <version>/
        <name1>.dep.json   (copies of the source files)
        <name2>.dep.json
        ...
        digest.dep.json    { version, created, digests: {name: sha256} }
"""

from __future__ import annotations
import datetime
import hashlib
import json
import os
import shutil
from dataclasses import dataclass
from pathlib import Path
from typing import Dict, Iterable, List, Tuple


@dataclass
class DepCache:
    root:    Path
    version: str

    # --------------------------------------------------------------
    @property
    def dir(self) -> Path:
        return self.root / self.version

    @property
    def digest_file(self) -> Path:
        return self.dir / "digest.dep.json"

    # --------------------------------------------------------------
    def create(self, source_dep_files: Iterable[Path]) -> Dict[str, str]:
        """Copy every source dep.json into the cache dir + record SHA256
        digests.  Returns {name: digest}."""
        self.dir.mkdir(parents=True, exist_ok=True)
        digests: Dict[str, str] = {}
        for src in source_dep_files:
            src = Path(src)
            if not src.is_file():
                continue
            dst = self.dir / src.name
            shutil.copy2(src, dst)
            digests[src.name] = self._digest_file(dst)
        payload = {
            "version": self.version,
            "created": datetime.datetime.now(datetime.timezone.utc).isoformat(),
            "digests": digests,
        }
        self.digest_file.write_text(json.dumps(payload, indent=2) + "\n")
        return digests

    def entries(self) -> Dict[str, dict]:
        """Load every cached dep.json (excluding digest.dep.json)."""
        out: Dict[str, dict] = {}
        if not self.dir.exists():
            return out
        for f in sorted(self.dir.glob("*.dep.json")):
            if f.name == self.digest_file.name:
                continue
            try:
                out[f.name] = json.loads(f.read_text())
            except json.JSONDecodeError:
                continue
        return out

    def digests(self) -> Dict[str, str]:
        if not self.digest_file.is_file():
            return {}
        try:
            return json.loads(self.digest_file.read_text()).get("digests", {})
        except json.JSONDecodeError:
            return {}

    def validate(self) -> Tuple[List[str], List[str]]:
        """Recompute each cached file's digest.  Returns (ok, tampered)."""
        recorded = self.digests()
        ok, tampered = [], []
        for name, expected in recorded.items():
            fp = self.dir / name
            if not fp.is_file() or self._digest_file(fp) != expected:
                tampered.append(name)
            else:
                ok.append(name)
        return ok, tampered

    # --------------------------------------------------------------
    @staticmethod
    def default_root() -> Path:
        env = os.environ.get("DEPCACHE_DIR")
        return Path(env) if env else (Path.home() / ".cache" / "gm-dep")

    @staticmethod
    def _digest_file(fp: Path) -> str:
        h = hashlib.sha256()
        with fp.open("rb") as f:
            for chunk in iter(lambda: f.read(65536), b""):
                h.update(chunk)
        return h.hexdigest()
