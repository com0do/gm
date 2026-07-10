"""installGuide.in DSL parser.

Same grammar as the legacy framework -- a line-based, block-oriented
declarative installer that the in-container interpreter
(`templates/appDockerInstaller.sh`) executes at image-build time.

Grammar
-------

    [START]                  marks the active region; lines before
                             [START] are ignored
    [RPMINSTALL]             subsequent lines until next `[...]` are
                             RPM names to `yum install -y`
    [RPMUNINSTALL]           ... `yum remove`
    [RUN]                    ... shell commands `eval`-ed
    [STOP]                   ends interpretation

    # comment-line   /   *comment-line   - skipped by interpreter
    (blank lines)                        - skipped

This module is pure parsing -- the actual execution lives in the
in-container bash interpreter.  We use the parsed blocks to:
  - enumerate `rpms()` for the resolver
  - compute file deps for `dep.json`
"""

from __future__ import annotations
import re
from dataclasses import dataclass
from pathlib import Path

from .manifest import InstallBlock, Manifest


_HEADER_RE = re.compile(r"^\s*\[([A-Z_]+)\]\s*$")


@dataclass
class InstallerDSL:
    blocks: list[InstallBlock]
    source: Path | None = None    # file the DSL was loaded from, if any

    # ------------------------------------------------------------------
    # Loaders
    # ------------------------------------------------------------------
    @classmethod
    def from_text(cls, text: str, source: Path | None = None) -> "InstallerDSL":
        blocks: list[InstallBlock] = []
        current: InstallBlock | None = None
        active = False

        for raw in text.splitlines():
            line = raw.strip()
            if not line or line.startswith("#") or line.startswith("*"):
                continue
            m = _HEADER_RE.match(line)
            if m:
                tag = m.group(1)
                if tag == "START":
                    active = True
                    current = None
                    continue
                if tag == "STOP":
                    active = False
                    current = None
                    continue
                if not active:
                    continue
                current = InstallBlock(type=tag, items=[])
                blocks.append(current)
                continue
            if active and current is not None:
                current.items.append(line)
        return cls(blocks=blocks, source=source)

    @classmethod
    def from_file(cls, path: Path) -> "InstallerDSL":
        return cls.from_text(Path(path).read_text(), source=Path(path))

    @classmethod
    def from_manifest(cls, m: Manifest) -> "InstallerDSL":
        if m.install_file:
            return cls.from_file(m.install_file)
        return cls(blocks=list(m.install_blocks))

    # ------------------------------------------------------------------
    # Queries
    # ------------------------------------------------------------------
    def rpms(self) -> list[str]:
        """RPM names referenced by [RPMINSTALL] blocks (unique, declaration order)."""
        seen: dict[str, None] = {}
        for blk in self.blocks:
            if blk.type == "RPMINSTALL":
                for item in blk.items:
                    # an item may be `pkgA pkgB` whitespace-separated
                    for tok in item.split():
                        if tok and tok not in seen:
                            seen[tok] = None
        return list(seen)

    def runs(self) -> list[str]:
        """Shell commands referenced by [RUN] blocks (declaration order)."""
        out: list[str] = []
        for blk in self.blocks:
            if blk.type == "RUN":
                out.extend(blk.items)
        return out

    def serialize(self) -> str:
        """Render back to text form (e.g. for in-container consumption)."""
        out: list[str] = ["[START]"]
        for blk in self.blocks:
            out.append(f"[{blk.type}]")
            out.extend(blk.items)
        out.append("[STOP]")
        return "\n".join(out) + "\n"
