"""Remote-RPM version resolver.

For every name in the manifest's [RPMINSTALL] blocks, query the
configured yum repos to discover the **exact version + release + arch**
that would be installed.  These tuples become the `rpms[]` field of
the image's `.dep.json` -- changing upstream RPM versions then triggers
image rebuild via `dep_query.py`.

Strategy
--------

1. Build a yum repo file from the manifest's `repos:` (via repos.py).
2. For each repo in priority order, run a single batch
   `dnf repoquery --info ...` that asks for every RPM still unresolved.
3. Parse the output's `Name: / Version: / Release: / Architecture:`
   stanzas, prefer x86_64 > i686 > noarch, prefer higher version.
4. Apply manual overrides (overrides.py) -- these win unconditionally.
5. Cache per-image so repeated runs don't hammer the network.

This is a stripped-down port of the legacy `cm_tools/rpmInfo.sh` --
the key features (priority order, retry, cache, arch preference,
manual override) are preserved; the script's 500+ lines compress to
~200 of structured Python.
"""

from __future__ import annotations
import re
import subprocess
import time
from dataclasses import dataclass
from pathlib import Path

from .manifest  import Manifest
from .repos     import RepoRenderer
from .overrides import OverrideTable


_ARCH_RANK = {"x86_64": 0, "i686": 1, "noarch": 2}


@dataclass(order=True)
class RpmInfo:
    name:    str
    version: str
    release: str
    arch:    str

    @classmethod
    def not_found(cls, name: str) -> "RpmInfo":
        return cls(name=name, version="NOT_FOUND", release="N/A", arch="N/A")

    def as_tuple(self) -> tuple[str, str, str, str]:
        return (self.name, self.version, self.release, self.arch)


@dataclass
class RpmResolver:
    manifest:           Manifest
    cache_dir:          Path = Path.home() / ".cache" / "container"
    max_retry:          int  = 3
    repoquery_cmd:      str  = "dnf"

    def resolve(self) -> list[RpmInfo]:
        """Return one RpmInfo per RPM listed in the manifest's installer DSL."""
        names = self.manifest.rpms_to_install
        if not names:
            return []

        # 1. Manual overrides win.
        overrides = OverrideTable.from_manifest(self.manifest)
        resolved: dict[str, RpmInfo] = {}
        remaining: list[str] = []
        for n in names:
            if (o := overrides.get(n)) is not None:
                resolved[n] = o
            else:
                remaining.append(n)

        if not remaining:
            return [resolved[n] for n in names]

        # 2. If there are no repos declared, we can't auto-resolve -- mark
        #    everything else as NOT_FOUND and continue.  Caller decides
        #    whether to treat this as an error.
        if not self.manifest.repos:
            for n in remaining:
                resolved[n] = RpmInfo.not_found(n)
            return [resolved[n] for n in names]

        # 3. Render the manifest's repos to a temp file and query.
        cache_subdir = self.cache_dir / self.manifest.name
        cache_subdir.mkdir(parents=True, exist_ok=True)
        repo_file = cache_subdir / "container.repo"
        RepoRenderer(self.manifest).write_to(repo_file)

        found = self._query_repos(repo_file, remaining, cache_subdir)
        for n in remaining:
            resolved[n] = found.get(n, RpmInfo.not_found(n))

        return [resolved[n] for n in names]

    # ------------------------------------------------------------------
    # repoquery driver
    # ------------------------------------------------------------------
    def _query_repos(
        self,
        repo_file:    Path,
        names:        list[str],
        cache_subdir: Path,
    ) -> dict[str, RpmInfo]:
        """Query each repo (priority order) and merge results."""
        out: dict[str, RpmInfo] = {}

        # Sort repos by priority (asc); within priority, by key for stable order
        repos = sorted(
            self.manifest.repos.values(),
            key=lambda r: (r.priority, r.key),
        )

        # Repos that satisfy higher-priority lookups short-circuit subsequent
        # lookups for the same name (mirrors legacy rpmInfo.sh).
        for r in repos:
            still_needed = [n for n in names if n not in out]
            if not still_needed:
                break

            url = self.manifest.substitute(r.url)
            result = self._repoquery(r.key, url, still_needed, cache_subdir)
            for info in result:
                # First repo to satisfy wins (priority).
                out.setdefault(info.name, info)

        return out

    def _repoquery(
        self,
        repo_key:     str,
        repo_url:     str,
        names:        list[str],
        cache_subdir: Path,
    ) -> list[RpmInfo]:
        cmd = [
            self.repoquery_cmd, "repoquery", "--info",
            f"--setopt=cachedir={cache_subdir}",
            "--setopt=gpgcheck=0",
            f"--repofrompath={repo_key},{repo_url}",
            f"--repo={repo_key}",
            "--arch=x86_64,i686,noarch",
            *names,
        ]
        for attempt in range(1, self.max_retry + 1):
            try:
                p = subprocess.run(cmd, capture_output=True, text=True, timeout=60)
                if p.returncode == 0:
                    return self._parse_repoquery_output(p.stdout)
            except subprocess.TimeoutExpired:
                pass
            time.sleep(1)
        # Give up silently -- the missing names will be NOT_FOUND.
        return []

    # ------------------------------------------------------------------
    # Output parsing
    # ------------------------------------------------------------------
    @staticmethod
    def _parse_repoquery_output(stdout: str) -> list[RpmInfo]:
        # repoquery --info emits stanzas like:
        #   Name        : openssl
        #   Version     : 1.1.1k
        #   Release     : 14.el8_10
        #   Architecture: x86_64
        #   ...
        # We collect every Name stanza, then for each name pick the
        # best arch + highest version.
        candidates: dict[str, list[RpmInfo]] = {}
        cur: dict[str, str] = {}

        for line in stdout.splitlines():
            m = re.match(r"^([A-Za-z][A-Za-z ]*?)\s*:\s*(.*)$", line)
            if not m:
                continue
            key, val = m.group(1).strip().lower(), m.group(2).strip()
            if key == "name":
                if "name" in cur:
                    RpmResolver._flush(cur, candidates)
                cur = {"name": val}
            elif key in ("version", "release", "architecture"):
                cur[key] = val
        if "name" in cur:
            RpmResolver._flush(cur, candidates)

        # Pick winner per name: lowest arch-rank AND, within that arch,
        # highest (version, release).  Previous WIP left a `best =
        # group[-1]` line that the actual pick then supersedes; ruff
        # flagged the dead assignment (F841) and we clean it up here.
        out: list[RpmInfo] = []
        for _name, group in candidates.items():
            best_arch = min(_ARCH_RANK.get(i.arch, 99) for i in group)
            in_arch   = [i for i in group if _ARCH_RANK.get(i.arch, 99) == best_arch]
            in_arch.sort(key=lambda i: _version_key(i.version, i.release))
            out.append(in_arch[-1])
        return out

    @staticmethod
    def _flush(cur: dict[str, str], candidates: dict[str, list[RpmInfo]]) -> None:
        if not all(k in cur for k in ("name", "version", "release", "architecture")):
            return
        arch = cur["architecture"]
        if arch not in _ARCH_RANK:
            return
        candidates.setdefault(cur["name"], []).append(RpmInfo(
            name    = cur["name"],
            version = cur["version"],
            release = cur["release"],
            arch    = arch,
        ))


def _version_key(version: str, release: str) -> tuple:
    """Sort key for version+release strings -- numeric-aware split."""
    def split(s: str) -> tuple:
        out: list = []
        for tok in re.split(r"[._\-]", s):
            out.append((0, int(tok)) if tok.isdigit() else (1, tok))
        return tuple(out)
    return split(version) + (("|",),) + split(release)
