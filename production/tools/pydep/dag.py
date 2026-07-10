"""Dependency DAG.

Loads every `.dep.json` under a build directory into an in-memory
graph.  Two adjacency maps:

    artifacts[<abs realpath'd artifact>] = {
        "kind":   "lib" | "exe" | "pkg" | "img" | "obj" | "java",
        "target": <make-invocable name>,
        "deps":   [<abs realpath>, ...],
        "rpms":   [[name, ver, rel, arch], ...]   # img/pkg only
    }
    consumers[<abs realpath dep>] = {<artifact>, ...}      # reverse edges

**Path canonicalisation happens HERE** (not at emit time).  Build
recipes emit absolute-but-possibly-symlinked paths (`OUT_DIR` views
like `build/lib/rhlinux/debug/libt2.so`); `_absorb()` pipes every
entry through `paths.normalize()` which applies `os.path.realpath`
so the in-memory graph is keyed on real disk paths.  Rationale:
keeps DEP_TREE=yes build recipes minimal + fast, resolves once at
load time.  See `paths.normalize()`'s docstring for the full policy.

Semantics: bottom-up walk.  Leaves (source files) sit at the bottom,
images sit at the top.  From a changed leaf, following `consumers`
edges climbs the graph and eventually reaches images -- which are
the terminal "roots" of every rebuild path (see image_walk.ImageWalker).

The dep.json schema is intentionally flexible so we accept:
  * gm-style :  {"file":<path>, "deps":[...]}                (lib/exe/obj)
  * container :  {"img":<name>,  "deps":[...], "rpms":[...]}  (image tier)
  * reg pkg  :  {"pkg":<name>,  "deps":[...], "rpms":[...]}  (package tier)
"""

from __future__ import annotations
import json
import os
import sys
from collections import defaultdict
from dataclasses import dataclass, field
from pathlib import Path
from typing import Dict, Iterable, List, Set

from .artifact import Kind, classify, target_name
from .paths    import normalize


@dataclass
class DepGraph:
    build_dir: Path
    proj_top:  Path

    artifacts: Dict[str, Dict] = field(default_factory=dict)
    consumers: Dict[str, Set[str]] = field(default_factory=lambda: defaultdict(set))
    # Subset of consumer keys that resolve to a real directory at
    # load time, treated as "any file under this directory".  Used
    # by .import.mk targets to advertise their vendor tree as
    # black-box source closure (`IMPORT_SRC_DIRS := $(VENDOR)`).
    # Trailing `/` on the source path is NOT required -- filesystem
    # `is_dir()` decides.  Build is finished by the time dep_query
    # runs, so vendor dirs always exist here.
    dir_deps:  Set[str] = field(default_factory=set)
    _loaded:   bool = False

    # --------------------------------------------------------------
    # Loading
    # --------------------------------------------------------------
    def load(self) -> "DepGraph":
        for dep_file in sorted(self.build_dir.rglob("*.dep.json")):
            self._absorb(dep_file)
        self._bridge_pkg_yaml_to_libs()
        self._apply_framework_escape()
        self._loaded = True
        return self

    def _apply_framework_escape(self) -> None:
        """Framework-escape rule.

        `env.mk` emits `<build>/gm.dep.json` (semantic `file:
        gm-framework`) listing every file in `GM_FRAMEWORK_CORE_MK`.
        A change to any of those files must invalidate EVERY
        downstream artefact -- including "lean" ones like .import.mk
        targets whose per-artefact `.dep.json` doesn't happen to
        list the framework file directly.

        Implementation: for each framework artefact's dep, extend
        that dep's consumer set to ALL non-framework artefacts.  The
        BFS walk then propagates naturally with no special-case
        code.  Zero data-model duplication -- Python never encodes
        the framework list; env.mk is the only source of truth.
        """
        frameworks = [a for a, info in self.artifacts.items()
                      if info.get("kind") == Kind.FRAMEWORK]
        if not frameworks:
            return
        non_fw = {a for a in self.artifacts if a not in frameworks}
        for fw in frameworks:
            for d in self.artifacts[fw]["deps"]:
                self.consumers[d].update(non_fw)

    def _bridge_pkg_yaml_to_libs(self) -> None:
        """Close the DAG gap between `pkg.yaml` and every lib it packages.

        pkg-build.py generates `$(GM_GEN_DIR)/<pkg>/component.h` from
        the pkg's yaml.  Consumer libs list that .h in their dep.json,
        but the .h itself has no dep.json of its own -- so a walk from
        yaml stops at the pkg node and never crosses to the libs.

        pkg.yaml is the source of truth for which libs belong to which
        pkg, so we parse it here and bridge `yaml -> lib` directly.
        No build-recipe changes needed; the yaml is already listed as
        a dep of the pkg artifact.

        Bridge only fires when the lib ACTUALLY consumes THIS pkg's
        `component.h` (i.e. it's in the lib's dep.json's deps[]).
        This respects the `PKG_HEADERS :=` opt-out in a lib's .mk:
        an opted-out lib has no component.h in its deps, so the
        bridge silently skips it -- no false-positive rebuilds.
        """
        try:
            import yaml  # PyYAML; optional at query time
        except ImportError:
            return
        # Pre-index libs by basename for O(1) matching.
        lib_by_name: Dict[str, str] = {}
        for art, info in self.artifacts.items():
            if info["kind"] == Kind.LIB:
                lib_by_name[Path(art).name] = art
        for pkg_art, pkg_info in list(self.artifacts.items()):
            if pkg_info["kind"] != Kind.PKG:
                continue
            for d in pkg_info["deps"]:
                if not d.endswith((".yaml", ".yml")):
                    continue
                if not Path(d).is_file():
                    continue
                try:
                    data = yaml.safe_load(Path(d).read_text())
                except Exception:
                    continue
                if not isinstance(data, dict):
                    continue
                # this pkg's component.h path suffix -- used as an
                # opt-in check on the consumer lib below.
                pkg_id = data.get("pkg", "")
                comp_suffix = f"/{pkg_id}/component.h" if pkg_id else "/component.h"
                for f in (data.get("files") or []):
                    src = f if isinstance(f, str) else (f.get("src") or "")
                    lib_name = Path(src).name  # e.g. "libt2.so"
                    lib_art = lib_by_name.get(lib_name)
                    if not lib_art:
                        continue
                    lib_deps = self.artifacts[lib_art]["deps"]
                    if any(dep.endswith(comp_suffix) for dep in lib_deps):
                        self.consumers[d].add(lib_art)

    def _absorb(self, dep_file: Path) -> None:
        try:
            content = json.loads(dep_file.read_text())
        except (OSError, json.JSONDecodeError) as e:
            print(f"warn: cannot parse {dep_file}: {e}", file=sys.stderr)
            return

        deps = content.get("deps") or []
        rpms = content.get("rpms") or []

        # Schema autodetection.  The artifact KEY (used for adjacency
        # lookups) is always a filesystem path when one is available --
        # `file:` wins over the semantic name-only forms (`img:` /
        # `pkg:`) because other dep.json files reference this artifact
        # by its PATH (an .rpm's file path is what an image's deps[]
        # contains), not by its symbolic name.  The semantic name is
        # kept as the make-invocable `target`.
        file_field = content.get("file")
        img_name   = content.get("img")
        pkg_name   = content.get("pkg")

        if file_field:
            artifact = normalize(file_field, self.proj_top)
            kind     = classify(artifact)
            # Semantic name overrides derived name (schema tells us
            # exactly what it is).
            target   = img_name or pkg_name or target_name(artifact, kind)
            if img_name:
                kind = Kind.IMG
            elif pkg_name:
                kind = Kind.PKG
            elif file_field == "gm-framework" or Path(file_field).name == "gm-framework":
                # env.mk's gm.dep.json manifest -- see
                # `_apply_framework_escape` below.  target must equal
                # the file field verbatim so escape lookups compare
                # `info["kind"] == Kind.FRAMEWORK` cleanly.
                kind   = Kind.FRAMEWORK
                target = "gm-framework"
        elif img_name:
            # Legacy reg-style image dep.json with no file -- synth key.
            artifact = f"IMG:{img_name}"
            kind     = Kind.IMG
            target   = img_name
        elif pkg_name:
            artifact = f"PKG:{pkg_name}"
            kind     = Kind.PKG
            target   = pkg_name
        else:
            return                          # nothing to key on -- skip

        normed_deps = [normalize(d, self.proj_top) for d in deps]

        self.artifacts[artifact] = {
            "kind":   kind,
            "target": target,
            "deps":   normed_deps,
            "rpms":   rpms,
        }
        for d in normed_deps:
            self.consumers[d].add(artifact)
            if Path(d).is_dir():
                self.dir_deps.add(d)

    # --------------------------------------------------------------
    # Introspection
    # --------------------------------------------------------------
    def by_kind(self, kind: str) -> List[str]:
        """All artifacts of a given kind."""
        if not self._loaded:
            self.load()
        return sorted(a for a, info in self.artifacts.items() if info["kind"] == kind)

    def images(self) -> List[str]:
        return self.by_kind(Kind.IMG)

    def walk(self, seeds: Iterable[str]) -> Set[str]:
        """Bottom-up BFS through the `consumers` map from `seeds`.

        Before BFS, expand `seeds` with any `dir_deps` prefix that a
        seed lives under.  This lets a `.import.mk` advertise its
        vendor tree via `IMPORT_SRC_DIRS := $(VENDOR)/` and have any
        change under that dir propagate to the import's consumers --
        the black-box equivalent of `.dep.json` deps for compiled
        artefacts.
        """
        if not self._loaded:
            self.load()
        seeds_set: Set[str] = set(seeds)
        if self.dir_deps:
            # Directory-prefix expansion: a seed under any dir_dep
            # additionally seeds that dir_dep, whose `consumers`
            # entry then propagates to the import target.  Compare
            # with `d + os.sep` so `/foo/bar` doesn't spuriously
            # match dir_dep `/foo/ba`.
            for s in list(seeds_set):
                for d in self.dir_deps:
                    if s.startswith(d + os.sep) or s == d:
                        seeds_set.add(d)
        visited: Set[str] = set()
        frontier: List[str] = list(seeds_set)
        while frontier:
            node = frontier.pop()
            if node in visited:
                continue
            visited.add(node)
            for c in self.consumers.get(node, ()):
                if c not in visited:
                    frontier.append(c)
        return visited
