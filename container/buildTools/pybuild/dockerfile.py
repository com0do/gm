"""Render a Dockerfile.tmpl into the staged context.

Substitutes `@VAR@` placeholders against:
  - manifest core fields:  NAME, VERSION, TAG, BASE, ENTRYPOINT
  - manifest.vars:         every user-declared var (UPPER-CASED key
                           also accepted: `@APS_VER@` finds `aps_ver`)
  - well-known synthetics: BUILD_DATE, BUILD_HOST

Unknown placeholders are left intact (the rendered Dockerfile may
contain literal `@something@` if the template uses non-substitutable
text -- intentional, we don't want to silently lose content).

The renderer also performs `__VAR__` (double-underscore) substitution
for legacy compatibility with templates inherited from
`reg_container_tooling` (e.g. `__URL_OF_MIDDLEWARE_BASE_IMAGE__`,
`__ENTRYPOINT__`).
"""

from __future__ import annotations
import datetime
import os
import re
from dataclasses import dataclass
from pathlib import Path

from .manifest import Manifest


_AT_PLACEHOLDER  = re.compile(r"@([A-Za-z_][A-Za-z0-9_]*)@")
_DUNDER_PLACEHOLDER = re.compile(r"__([A-Z_][A-Z0-9_]*)__")


@dataclass
class DockerfileRenderer:
    manifest: Manifest

    def render(self) -> str:
        if not self.manifest.dockerfile:
            raise ValueError("manifest has no dockerfile")
        text = self.manifest.dockerfile.read_text()
        env  = self._env()
        return self._subst(text, env)

    def write_to(self, path: Path) -> Path:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(self.render())
        return path

    # ------------------------------------------------------------------
    def _env(self) -> dict[str, str]:
        m   = self.manifest
        env: dict[str, str] = {
            "NAME":        m.name,
            "VERSION":     m.version,
            "TAG":         m.tag or m.version,
            "BASE":        m.base,
            "ENTRYPOINT":  m.entrypoint,
            "BUILD_DATE":  datetime.datetime.utcnow().strftime("%Y-%m-%dT%H:%M:%SZ"),
            "BUILD_HOST":  os.uname().nodename,
        }
        # Manifest.vars override everything else (user intent wins).
        for k, v in m.vars.items():
            env[k] = v
            env[k.upper()] = v

        # Legacy reg_container_tooling double-underscore tokens.
        env.setdefault("URL_OF_MIDDLEWARE_BASE_IMAGE", m.base)
        env.setdefault("NAME_OF_IMAGE",  m.name)
        env.setdefault("IMAGE_OWNER_NAME",    "")
        env.setdefault("IMAGE_OWNER_EMAILID", "")
        return env

    @staticmethod
    def _subst(text: str, env: dict[str, str]) -> str:
        def sub_at(m: re.Match) -> str:
            k = m.group(1)
            return env.get(k, env.get(k.upper(), m.group(0)))
        text = _AT_PLACEHOLDER.sub(sub_at, text)
        text = _DUNDER_PLACEHOLDER.sub(sub_at, text)
        return text
