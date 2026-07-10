"""Per-image RPM version-lock file generation.

Equivalent of reg_container_tooling's `change2target.py --lock-rpm
override.rpm.info` workflow (dependency.md § 2.1.5).

Combines three inputs:

  1. RPMs declared in the manifest (installGuide.in + dockerfile yum)
  2. Manual overrides from `override.rpm.info` (per-project shared file)
  3. Current versions resolved via yum repos in the manifest

Rules:
  - Override wins over yum-resolved (dev intent > repo state)
  - Missing overrides fall back to yum
  - Missing yum answers are recorded as NOT_FOUND

Output format matches reg (plain text, one line per RPM):

    openssl 1.1.1k 14.el8_10 x86_64
    glibc   2.28   189.el8    x86_64

This file is then passed to `container build --rpm-lock <file>` which
stages it into the build context as `versionlock.list`; the
in-container installer feeds it to yum-plugin-versionlock so the
subsequent `yum install` uses the exact versions.
"""

from __future__ import annotations
import re
from dataclasses import dataclass
from pathlib import Path

from .manifest  import Manifest
from .rpms      import RpmInfo, RpmResolver
from .rpm_query import parse_dockerfile_yum


_OVERRIDE_LINE_RE = re.compile(r"^\s*(\S+)\s+(\S+)\s+(\S+)\s+(\S+)\s*$")


def parse_override_file(path: Path) -> dict[str, RpmInfo]:
    """Parse an override.rpm.info file.

    Format (comments start with #, blank lines skipped):
        name version release arch
    """
    out: dict[str, RpmInfo] = {}
    if not path.is_file():
        return out
    for line in path.read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        m = _OVERRIDE_LINE_RE.match(line)
        if not m:
            continue
        name, ver, rel, arch = m.groups()
        out[name] = RpmInfo(name=name, version=ver, release=rel, arch=arch)
    return out


@dataclass
class LockGenerator:
    manifest:  Manifest
    override:  Path | None = None       # override.rpm.info file (optional)

    def generate(self) -> list[RpmInfo]:
        """Return the resolved lock rows in declaration order."""
        # 1. Declared RPMs = prerequisites + installGuide + dockerfile yum
        declared: list[str] = list(self.manifest.prerequisites)
        for n in self.manifest.rpms_to_install:
            if n not in declared:
                declared.append(n)
        if self.manifest.dockerfile and self.manifest.dockerfile.is_file():
            for n in parse_dockerfile_yum(self.manifest.dockerfile.read_text()):
                if n not in declared:
                    declared.append(n)

        # 2. Override file (external) overrides manifest.override_rpms
        overrides: dict[str, RpmInfo] = {}
        for name, ver, rel, arch in self.manifest.override_rpms:
            overrides[name] = RpmInfo(name=name, version=ver,
                                      release=rel, arch=arch)
        if self.override:
            overrides.update(parse_override_file(self.override))

        # 3. Yum-repo lookup for anything not overridden.
        missing = [n for n in declared if n not in overrides]
        yum_resolved: dict[str, RpmInfo] = {}
        if missing and self.manifest.repos:
            # RpmResolver iterates installer's RPMs -- restrict via
            # a temporary manifest install-block override.
            for r in RpmResolver(manifest=self.manifest).resolve():
                if r.name in missing and r.version != "NOT_FOUND":
                    yum_resolved[r.name] = r

        # 4. Merge in declaration order.
        out: list[RpmInfo] = []
        for n in declared:
            if n in overrides:
                out.append(overrides[n])
            elif n in yum_resolved:
                out.append(yum_resolved[n])
            else:
                out.append(RpmInfo.not_found(n))
        return out

    def write_to(self, path: Path) -> Path:
        rows = self.generate()
        path.parent.mkdir(parents=True, exist_ok=True)
        with path.open("w") as f:
            for r in rows:
                f.write(f"{r.name} {r.version} {r.release} {r.arch}\n")
        return path
