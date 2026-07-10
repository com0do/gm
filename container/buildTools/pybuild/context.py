"""Stage the docker build context for an image.

Responsibilities:
  - Make a clean per-image staging directory.
  - Copy the manifest's `extras[]`, the rendered installGuide.in (if
    declared), and the rendered *.repo into the context.
  - When DEP_TREE=yes is set in the env, source `dep-hooks.sh` around
    every `cp`/`install` so the trace JSONL captures the full file
    dependency graph.  The hooks live at `production/tools/dep-hooks.sh`
    (single source of truth shared with gm's pkg staging) with a fallback
    to a vendored `container/hooks/dep-hooks.sh` for post-spinout use.

The staging dir, the hook trace, and the rendered repo file are all
returned so the next pipeline stage (dockerfile + docker build) can
consume them.
"""

from __future__ import annotations
import os
import shlex
import shutil
import subprocess
from dataclasses import dataclass, field
from pathlib import Path

from .manifest  import Manifest
from .installer import InstallerDSL
from .repos     import RepoRenderer


@dataclass
class BuildContext:
    manifest:   Manifest
    out_dir:    Path                       # where to stage (caller-owned)
    track_deps: bool = True                # source dep-hooks.sh
    lock_file:  Path | None = None         # optional RPM version-lock list
    staged:     list[Path] = field(default_factory=list)
    hooks_log:  Path | None = None
    repo_file:  Path | None = None
    install_dst: Path | None = None

    def stage(self) -> "BuildContext":
        ctx = self.out_dir / "context"
        if ctx.exists():
            shutil.rmtree(ctx)
        ctx.mkdir(parents=True)

        # Hook trace -- truncate any prior content before this run.
        self.hooks_log = self.out_dir / f"{self.manifest.name}.hooks.jsonl"
        self.hooks_log.write_text("")

        # 1. Render derived files directly into the context.  These
        #    are GENERATED (not user-supplied sources), so we don't
        #    need to "cp" them via hooks -- they have no useful
        #    source-side path to track.
        dsl = InstallerDSL.from_manifest(self.manifest)
        if dsl.blocks:
            self.install_dst = ctx / "installGuide.in"
            self.install_dst.write_text(dsl.serialize())

        # Only write container.repo when the manifest actually declares
        # repos.  An empty file would clobber the base image's default
        # repo config with nothing useful.
        if self.manifest.repos:
            self.repo_file = ctx / "container.repo"
            RepoRenderer(self.manifest).write_to(self.repo_file)

        # 2. Stage the in-container DSL interpreter -- either the
        #    framework's shared templates/appDockerInstaller.sh or a
        #    per-image custom script the manifest points at.  Always
        #    staged with the well-known name `appDockerInstaller.sh`
        #    so the Dockerfile can invoke it unconditionally.
        if self.manifest.installer and self.manifest.installer.is_file():
            shutil.copy2(self.manifest.installer, ctx / "appDockerInstaller.sh")

        # 2b. Runtime prerequisites -- installed BEFORE the user's
        #     installGuide.in blocks run.  Empty means the user is
        #     fully responsible for [RPMINSTALL].
        if self.manifest.prerequisites:
            (ctx / "prerequisites.list").write_text(
                "\n".join(self.manifest.prerequisites) + "\n"
            )

        # 2c. Auto-generated versionlock.list (from manifest.rpm_lock).
        #     External `container build --rpm-lock <file>` still takes
        #     precedence via self.lock_file below.
        self._maybe_auto_lock(ctx)

        # 3. Copy user-declared `extras:` via the hook-tracked shell.
        #    This is the bit that lets dep-hooks.sh observe and log
        #    every actual SOURCE file that ends up in the image.  The
        #    JSONL trace flows into dep.json's deps[] list.  Each
        #    Extra has a `dst` (context-relative path) so renames
        #    work uniformly for files and directories.
        if self.manifest.extras:
            self._hooked_copy_extras(self.manifest.extras, ctx)

        # 3b. Optional per-image RPM version-lock list
        #     (`container build --rpm-lock <file>`) -- honoured by
        #     appDockerInstaller.sh via yum-plugin-versionlock.  The
        #     manifest's rpm_lock (auto-gen) already wrote a
        #     versionlock.list via _maybe_auto_lock; an external
        #     `--rpm-lock <file>` overrides that.
        if self.lock_file and self.lock_file.is_file():
            shutil.copy2(self.lock_file, ctx / "versionlock.list")

        # 3c. Optional install.tar bundle (reg alignment).  When the
        #     manifest declares `install_tar: <dir>`, we tar that dir
        #     into `context/install.tar` so the Dockerfile can
        #     `ADD install.tar /install/` or similar.  Matches reg's
        #     `tar -cvf dockercontext/install.tar install/` step in
        #     buildAppDockerImage.sh.
        if self.manifest.install_tar and self.manifest.install_tar.is_dir():
            self._make_install_tar(self.manifest.install_tar, ctx / "install.tar")

        # 3d. Optional version_info file (reg alignment).  When
        #     `emit_version_info: true`, dump every manifest.vars entry
        #     into `context/version_info` as `key: value` lines.  reg's
        #     format is `<repo> APS: <rel>: <ver>` -- specific to their
        #     yum-repo-per-component model; ours is a generic map.
        #     Users who need the exact reg layout can declare an
        #     `extras: [version_info]` entry pointing at a hand-written
        #     file instead.
        if self.manifest.emit_version_info and self.manifest.vars:
            lines = [f"{k}: {v}" for k, v in sorted(self.manifest.vars.items())]
            (ctx / "version_info").write_text("\n".join(lines) + "\n")

        # 4. Manifest itself + dockerfile + install_file + extras paths
        #    are added to dep.json by DepJson.build() independently;
        #    nothing to track here.

        self.staged.append(ctx)
        return self

    # ------------------------------------------------------------------
    def _make_install_tar(self, src_dir: Path, out_tar: Path) -> None:
        """`tar -cf <out_tar> -C <src_dir> .` -- bundle the directory
        contents (not the dir itself) into a tarball inside the context.
        Uses tar's `-C` chdir + `.` to keep the archive relative to
        src_dir's contents, matching reg's convention where the tar
        expands under `/install/` in the container without an extra
        wrapping directory."""
        subprocess.run(
            ["tar", "-cf", str(out_tar), "-C", str(src_dir), "."],
            check=True,
        )

    # ------------------------------------------------------------------
    def _hooked_copy_extras(self, extras, ctx_dir: Path) -> None:
        """Copy each Extra into ctx_dir/<extra.dst> with dep-hooks sourced.

        Files:  `cp -fL <src> <ctx_dir>/<dst>`             (with optional rename)
        Dirs :  `cp -rfL <src>/. <ctx_dir>/<dst>/`         (contents merge into <dst>/)
                + `dep_add` each leaf file recursively so the hook trace
                records every source-side path (mirrors reg's `cp -rf
                $SOURCEPATH/*` bulk copy that ends up contributing
                individual file entries to dep.json).

        When hooks are unavailable, falls back to plain shutil.
        """
        # dep-hooks.sh lives at `production/tools/dep-hooks.sh` (single
        # source of truth shared with gm's pkg staging).  For post-spinout
        # standalone deployment, vendor it into container/hooks/dep-hooks.sh
        # and update this path -- same playbook as json_pretty.py.
        # From container/buildTools/pybuild/context.py:
        #   parents[3] = <project-root>  -> production/tools/dep-hooks.sh
        #   parents[2] = container/       -> container/hooks/dep-hooks.sh   (post-spinout)
        gm_shared = Path(__file__).resolve().parents[3] / "production" / "tools" / "dep-hooks.sh"
        vendored  = Path(__file__).resolve().parents[2] / "hooks" / "dep-hooks.sh"
        hooks     = gm_shared if gm_shared.is_file() else vendored

        # Ensure sub-dirs of dst exist ahead of time (`cp` can't
        # auto-create intermediate directories).
        for ex in extras:
            (ctx_dir / ex.dst).parent.mkdir(parents=True, exist_ok=True)

        if not hooks.is_file():
            for ex in extras:
                target = ctx_dir / ex.dst
                if ex.src.is_dir():
                    shutil.copytree(ex.src, target, dirs_exist_ok=True)
                else:
                    shutil.copy2(ex.src, target)
            return

        env = os.environ.copy()
        if self.track_deps:
            env["DEP_TREE"] = "yes"
            env["DEP_TRACK_FILE"] = str(self.hooks_log)
        else:
            env.pop("DEP_TREE", None)
            env.pop("DEP_TRACK_FILE", None)

        cmds: list[str] = [f". {shlex.quote(str(hooks))}"]
        for ex in extras:
            target = ctx_dir / ex.dst
            if ex.src.is_dir():
                # `cp -rfL <src>/. <target>/` merges the source's
                # contents INTO target/ (target dir may or may not
                # exist; we ensured above).
                cmds.append(f"mkdir -p {shlex.quote(str(target))}")
                cmds.append(
                    f"cp -rfL {shlex.quote(str(ex.src) + '/.')} "
                    f"{shlex.quote(str(target) + '/')}"
                )
                for leaf in sorted(ex.src.rglob("*")):
                    if leaf.is_file():
                        cmds.append(f"dep_add {shlex.quote(str(leaf))}")
            else:
                cmds.append(
                    f"cp -fL {shlex.quote(str(ex.src))} {shlex.quote(str(target))}"
                )
        subprocess.run(["bash", "-c", " && ".join(cmds)], check=True, env=env)

    def _maybe_auto_lock(self, ctx_dir: Path) -> None:
        """If manifest.rpm_lock declares auto-generation, produce the
        lock file inline and stage it as versionlock.list."""
        m = self.manifest
        if not (m.rpm_lock and m.rpm_lock.auto):
            return
        # Import here to avoid circular deps
        from .lock import LockGenerator
        try:
            gen = LockGenerator(manifest=m, override=m.rpm_lock.override)
            gen.write_to(ctx_dir / "versionlock.list")
        except Exception as e:
            # Auto-lock is best-effort; explicit --rpm-lock CLI still
            # available if this fails (e.g. no network to query yum).
            print(f"container: auto-lock skipped: {e}", file=__import__("sys").stderr)
