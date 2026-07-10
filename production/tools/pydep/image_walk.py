"""Image-rooted DAG traversal.

The whole point of the dep DAG is answering: **which IMAGES need
rebuilding when this set of files changes?**  Everything below an
image (pkg / exe / lib / obj) is intermediate; images are the
terminal roots.

The image tier's `.dep.json` files are produced by the standalone
`container/` tool (repo-root sibling of gm), not by gm's make dispatch
-- gm's own build stops at the RPM tier.  `dep_query.py` still walks
image-rooted queries because container deliberately emits `.dep.json`
sidecars in the same shape gm's other tiers do; see
`container/README.md` for the split rationale.

`ImageWalker` is the primary query interface:

    walker = ImageWalker.from_build_dir(build_dir, proj_top)
    report = walker.affected_by(["src/foo.cxx", "src/bar.h"])
    # report.images  -> {"img-app1", "img-i1", ...}
    # report.pkgs    -> intermediate packages touched
    # report.exes    -> intermediate binaries touched
    # report.libs    -> intermediate libraries touched

Two other query flavours:
    walker.sources_of(image)       -- files this image transitively needs
    walker.rpms_of(image)          -- upstream RPMs installed in this image
"""

from __future__ import annotations
from collections import defaultdict
from dataclasses import dataclass, field
from pathlib import Path
from typing import Dict, Iterable, List, Set

from .artifact import Kind
from .dag      import DepGraph
from .paths    import normalize


@dataclass
class AffectedReport:
    """Result of `ImageWalker.affected_by(changes)`.

    Every set holds canonical absolute paths (artifacts) or target
    names (targets).  `render_relative(proj_top)` gives repo-relative
    forms for human/CI output.

    The `javas` bucket was added when target.java.mk landed --
    following the same shape as libs/exes/pkgs so downstream tooling
    (make refresh, PR bot) can iterate every artifact tier
    uniformly.  If you add a new language tier, add its bucket here.
    """
    changed:  List[str]           = field(default_factory=list)   # normalised input
    images:   Set[str]            = field(default_factory=set)    # image target names
    pkgs:     Set[str]            = field(default_factory=set)
    exes:     Set[str]            = field(default_factory=set)
    libs:     Set[str]            = field(default_factory=set)
    javas:    Set[str]            = field(default_factory=set)

    # raw artifact paths, keyed by kind -- for callers that need paths
    artifacts_by_kind: Dict[str, Set[str]] = field(default_factory=lambda: defaultdict(set))

    def as_dict(self) -> dict:
        return {
            "changed": sorted(self.changed),
            "images":  sorted(self.images),
            "pkgs":    sorted(self.pkgs),
            "exes":    sorted(self.exes),
            "libs":    sorted(self.libs),
            "javas":   sorted(self.javas),
        }


@dataclass
class ImageWalker:
    """Answer image-rooted DAG queries against a loaded DepGraph."""
    graph: DepGraph

    # -- constructors ---------------------------------------------------
    @classmethod
    def from_build_dir(cls, build_dir: Path, proj_top: Path) -> "ImageWalker":
        return cls(graph=DepGraph(build_dir=build_dir, proj_top=proj_top).load())

    # -- primary query --------------------------------------------------
    def affected_by(self, changes: Iterable[str]) -> AffectedReport:
        """Return the image-tier affect envelope of `changes`.

        Walks bottom-up (consumers direction) from each changed leaf;
        every reached artifact contributes to the tier bucket
        matching its kind.  Terminal images end up in `report.images`.
        """
        proj_top = self.graph.proj_top
        seeds: Set[str] = set()
        raw_changed: List[str] = []
        for c in changes:
            raw_changed.append(c)
            # Accept relative or absolute forms -- normalize both.
            seeds.add(c)
            seeds.add(normalize(c, proj_top))

        visited = self.graph.walk(seeds) - seeds
        report  = AffectedReport(changed=raw_changed)

        for artifact in sorted(visited):
            info = self.graph.artifacts.get(artifact)
            if info is None:
                continue
            kind, target = info["kind"], info["target"]
            report.artifacts_by_kind[kind].add(artifact)
            if not target:
                continue
            if   kind == Kind.IMG:  report.images.add(target)
            elif kind == Kind.PKG:  report.pkgs.add(target)
            elif kind == Kind.EXE:  report.exes.add(target)
            elif kind == Kind.LIB:  report.libs.add(target)
            elif kind == Kind.JAVA: report.javas.add(target)
        return report

    # -- inverse queries (image -> its transitive deps) -----------------
    def sources_of(self, image_target: str) -> Set[str]:
        """Every file this image (transitively) depends on."""
        art = self._find_image_artifact(image_target)
        if not art:
            return set()
        return self._descend(art) - {art}

    def rpms_of(self, image_target: str) -> List[list]:
        """The rpms[] tuples embedded in the image's dep.json."""
        art = self._find_image_artifact(image_target)
        if not art:
            return []
        return list(self.graph.artifacts[art].get("rpms") or [])

    # -- helpers --------------------------------------------------------
    def _find_image_artifact(self, target: str) -> str | None:
        for a, info in self.graph.artifacts.items():
            if info["kind"] == Kind.IMG and info["target"] == target:
                return a
        return None

    def _descend(self, root: str) -> Set[str]:
        """Forward walk `deps` (not consumers) -- i.e. what does this
        root need to be built?  Used for `sources_of()`."""
        visited: Set[str] = set()
        stack = [root]
        while stack:
            node = stack.pop()
            if node in visited:
                continue
            visited.add(node)
            info = self.graph.artifacts.get(node)
            if info:
                for d in info["deps"]:
                    if d not in visited:
                        stack.append(d)
        return visited
