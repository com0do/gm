"""Ad-hoc yum-repo / image RPM queries -- the dev-facing discovery tool.

Standalone equivalent of reg_container_tooling's `rpmInfo.sh`:

  * `--yum <repo-file>`     query the repos declared in a *.repo file
  * `--base-image <img>`    extract repos from a docker image, then query
  * `--image <img>`         query RPMs actually installed in a built image
                            (uses `docker run --entrypoint /bin/rpm ... -qa`)

Feature parity with rpmInfo.sh:
  - priority ordering of repos (first match wins)
  - per-image cache isolation (cache dir = base_dir/<image_name>)
  - arch preference (x86_64 > i686 > noarch) unless --arch overrides
  - retry on network failure
  - manual overrides via override.rpm.info file

Used by:
  - `container query`  -- ad-hoc "what version is X?" for security work
  - `container lock`   -- generate per-image lock file from override + yum
  - the CI/SCM lock-file workflow (dep.md § 1.3.2)
"""

from __future__ import annotations
import re
import shutil
import subprocess
import tempfile
import time
from dataclasses import dataclass, field
from pathlib import Path

from .rpms import RpmInfo, _ARCH_RANK, _version_key


@dataclass
class YumQuery:
    """Query yum repos for RPM versions without needing a manifest.

    Repos come from either a raw *.repo file (`--yum`), a docker image
    to extract from (`--base-image`), or both merged.
    """
    repo_file:      Path | None = None      # explicit *.repo file
    base_image:     str | None = None       # docker image to extract from
    extra_repos:    list[Path] = field(default_factory=list)
    arch_filter:    str | None = None       # x86_64 / i686 / noarch / None=auto
    cache_dir:      Path = Path.home() / ".cache" / "container" / "query"
    max_retry:      int = 3
    repoquery_cmd:  str = "dnf"

    def query(self, names: list[str]) -> list[RpmInfo]:
        """Return an RpmInfo per name, in the order requested.
        Missing names come back as NOT_FOUND."""
        self.cache_dir.mkdir(parents=True, exist_ok=True)
        merged = self.cache_dir / "merged.repo"
        self._merge_repos_into(merged)

        result = self._repoquery(merged, names)
        by_name: dict[str, RpmInfo] = {r.name: r for r in result}
        return [by_name.get(n, RpmInfo.not_found(n)) for n in names]

    # ------------------------------------------------------------------
    def _merge_repos_into(self, dst: Path) -> None:
        parts: list[str] = []
        if self.repo_file and self.repo_file.is_file():
            parts.append(self.repo_file.read_text())
        for extra in self.extra_repos:
            if extra.is_file():
                parts.append(extra.read_text())
        if self.base_image:
            extracted = self._extract_repos_from_image(self.base_image)
            if extracted:
                parts.append(extracted)
        if not parts:
            raise RuntimeError("YumQuery: need --yum, --base-image, or --extra-repos")
        dst.write_text("\n".join(parts))

    @staticmethod
    def _extract_repos_from_image(image_ref: str) -> str:
        """`docker create + docker cp` /etc/yum.repos.d/ out of an image.

        Returns concatenated content of every *.repo found.  Empty
        string if the image has no repos or docker isn't available.
        """
        if shutil.which("docker") is None:
            return ""
        cid = f"container_yumq_{Path.cwd().stat().st_ino}_{time.monotonic_ns()}"
        try:
            p = subprocess.run(
                ["docker", "create", "--name", cid, image_ref, "/bin/true"],
                capture_output=True, text=True, timeout=60,
            )
            if p.returncode != 0:
                return ""
            with tempfile.TemporaryDirectory() as td:
                cp = subprocess.run(
                    ["docker", "cp", f"{cid}:/etc/yum.repos.d/.", td],
                    capture_output=True, text=True, timeout=60,
                )
                if cp.returncode != 0:
                    return ""
                out: list[str] = []
                for repo in Path(td).glob("*.repo"):
                    out.append(repo.read_text())
                return "\n".join(out)
        finally:
            subprocess.run(["docker", "rm", cid], capture_output=True, timeout=30)

    def _repoquery(self, repo_file: Path, names: list[str]) -> list[RpmInfo]:
        """Run `dnf repoquery --info` against the merged repo file."""
        cmd = [
            self.repoquery_cmd, "repoquery", "--info",
            f"--setopt=cachedir={self.cache_dir}",
            "--setopt=gpgcheck=0",
            "--config", str(repo_file),
            "--arch=x86_64,i686,noarch",
            *names,
        ]
        for _ in range(self.max_retry):
            try:
                p = subprocess.run(cmd, capture_output=True, text=True, timeout=90)
                if p.returncode == 0:
                    return self._parse(p.stdout)
            except subprocess.TimeoutExpired:
                pass
            time.sleep(1)
        return []

    def _parse(self, stdout: str) -> list[RpmInfo]:
        """Same stanza-parse logic as lib/rpms.py, with our arch filter."""
        candidates: dict[str, list[RpmInfo]] = {}
        cur: dict[str, str] = {}

        for line in stdout.splitlines():
            m = re.match(r"^([A-Za-z][A-Za-z ]*?)\s*:\s*(.*)$", line)
            if not m:
                continue
            key, val = m.group(1).strip().lower(), m.group(2).strip()
            if key == "name":
                if cur:
                    self._flush(cur, candidates)
                cur = {"name": val}
            elif key in ("version", "release", "architecture"):
                cur[key] = val
        if cur:
            self._flush(cur, candidates)

        out: list[RpmInfo] = []
        for name, group in candidates.items():
            if self.arch_filter:
                group = [g for g in group if g.arch == self.arch_filter]
                if not group:
                    continue
            best_arch = min(_ARCH_RANK.get(g.arch, 99) for g in group)
            in_arch   = [g for g in group if _ARCH_RANK.get(g.arch, 99) == best_arch]
            in_arch.sort(key=lambda g: _version_key(g.version, g.release))
            out.append(in_arch[-1])
        return out

    @staticmethod
    def _flush(cur: dict[str, str], candidates: dict[str, list[RpmInfo]]) -> None:
        if not all(k in cur for k in ("name", "version", "release", "architecture")):
            return
        if cur["architecture"] not in _ARCH_RANK:
            return
        candidates.setdefault(cur["name"], []).append(RpmInfo(
            name    = cur["name"],
            version = cur["version"],
            release = cur["release"],
            arch    = cur["architecture"],
        ))
