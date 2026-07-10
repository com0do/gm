"""Manual RPM version overrides -- the `override.rpm.info` concept.

Two sources, applied in this order (later overrides earlier):
  1. Manifest's inline `override_rpms:` block (per-image)
  2. (future) a project-global override file pointed to by env var

Each entry is `[name, version, release, arch]`.  When the resolver
encounters a name that has an override, it skips the yum query for
that name and uses the override directly.
"""

from __future__ import annotations
from dataclasses import dataclass
from typing import TYPE_CHECKING

from .manifest import Manifest

# `RpmInfo` is only needed for the type annotation on `.table` below.
# At runtime `from __future__ import annotations` keeps every hint a
# lazy string, so we don't need the symbol -- but static analysers
# (ruff, mypy) do.  A TYPE_CHECKING import satisfies them without
# reintroducing the rpms.py <-> overrides.py circular import that the
# original forward-ref string was hiding from.
if TYPE_CHECKING:
    from .rpms import RpmInfo


@dataclass
class OverrideTable:
    """name -> RpmInfo override."""
    table: dict[str, RpmInfo]

    @classmethod
    def from_manifest(cls, m: Manifest) -> "OverrideTable":
        from .rpms import RpmInfo
        table: dict[str, RpmInfo] = {}
        for name, ver, rel, arch in m.override_rpms:
            table[name] = RpmInfo(name=name, version=ver, release=rel, arch=arch)
        return cls(table=table)

    def get(self, name: str):
        return self.table.get(name)
