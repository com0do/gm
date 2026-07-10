"""Render *.repo file for the image build's yum.

Each repo entry in the manifest:
    repos:
      base:
        url: http://example.com/{aps_ver}/x86_64/
        priority: 1

becomes one stanza in the generated yum.repo:

    [base]
    name=base
    baseurl=http://example.com/26.7.1/x86_64/
    gpgcheck=0
    enabled=1
    priority=1

Substitutions come from manifest.vars (the `{aps_ver}` style).
Stanzas are sorted by priority ascending so the *first* repo with a
match wins -- mirrors the legacy `4g.in` ordering convention.
"""

from __future__ import annotations
from dataclasses import dataclass
from pathlib import Path

from .manifest import Manifest, RepoSpec


@dataclass
class RepoRenderer:
    manifest: Manifest

    def render(self) -> str:
        """Render the full *.repo content as a string."""
        if not self.manifest.repos:
            return ""
        stanzas: list[str] = []
        ordered = sorted(
            self.manifest.repos.values(),
            key=lambda r: (r.priority, r.key),
        )
        for r in ordered:
            url = self.manifest.substitute(r.url)
            stanzas.append(self._stanza(r, url))
        return "\n".join(stanzas) + "\n"

    def write_to(self, path: Path) -> Path:
        """Render and write to `path`.  Returns the path."""
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(self.render())
        return path

    @staticmethod
    def _stanza(r: RepoSpec, url: str) -> str:
        return (
            f"[{r.key}]\n"
            f"name={r.key}\n"
            f"baseurl={url}\n"
            f"gpgcheck={'1' if r.gpgcheck else '0'}\n"
            f"enabled=1\n"
            f"priority={r.priority}\n"
        )
