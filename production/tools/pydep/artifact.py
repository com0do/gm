"""Artifact classification helpers.

Given a build-output path (`.o`, `.a`, `.so`, binary, `.rpm`, `.id`),
classify it into a tier (`obj / lib / exe / pkg / img`) and derive
the make-invocable target name.  Small, dependency-free helpers so
every dep-loader agrees on how to tag a `.dep.json`.
"""

from __future__ import annotations
import re
from pathlib import Path


# Public tier constants (same string set reg's DepTypes uses).
class Kind:
    OBJ       = "obj"
    LIB       = "lib"
    EXE       = "exe"
    PKG       = "pkg"
    IMG       = "img"
    JAVA      = "java"
    # Synthetic tier for the gm framework manifest (`gm.dep.json`,
    # emitted by env.mk).  Not a build artefact -- carries the
    # framework-file list that dag.py uses for the escape rule.
    FRAMEWORK = "framework"


def classify(artifact: str) -> str:
    """Return one of Kind.* based on the artifact path's shape."""
    name = Path(artifact).name
    if name.endswith(".rpm"):
        return Kind.PKG
    if name.endswith(".id"):             # docker image-id file (container output)
        return Kind.IMG
    if name.endswith((".a", ".so")) or ".so." in name:
        return Kind.LIB
    if name.endswith(".o"):
        return Kind.OBJ
    if name.endswith(".jar"):
        return Kind.JAVA
    return Kind.EXE


def target_name(artifact: str, kind: str | None = None) -> str:
    """
    Reverse the naming convention used by target.{c,go,pkg}.mk
    (plus the .id file emitted by the standalone container tool):

        libfoo.a / libfoo.so           -> `libfoo`
        bar (no suffix)                -> `bar`
        pkg-foo-1.0-1.el8.x86_64.rpm   -> `pkg-foo`
        img-foo.id                     -> `img-foo` (from container)
        obj path                       -> "" (not a build target)
    """
    kind = kind or classify(artifact)
    stem = Path(artifact).name
    if kind == Kind.LIB:
        if stem.endswith(".a"):
            return stem[:-2]
        if stem.endswith(".so"):
            return stem[:-3]
        return stem.split(".so", 1)[0]
    if kind == Kind.PKG:
        m = re.match(r"^([A-Za-z][\w-]*?)-\d+(?:\.\d+)*", stem)
        return m.group(1) if m else stem[:-4]
    if kind == Kind.IMG:
        return stem[:-3]                 # drop `.id`
    if kind == Kind.JAVA:
        return stem[:-4]                 # drop `.jar`
    if kind == Kind.EXE:
        return stem
    return ""
