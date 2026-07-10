#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""imageBuild.py -- standalone container image build tool.

Layout is `container/imageBuild.py`; run as
    python3 container/imageBuild.py <subcommand> ...
    # or, when PATH-added:
    imageBuild.py build image.yaml

Subcommands:
  build    <manifest.yaml> [...]    full pipeline: stage + docker build + dep.json
  render   <manifest.yaml>          print rendered Dockerfile (no build)
  rpms     <manifest.yaml>          resolve + print RPM versions only (no build)
  deps     <manifest.yaml> [...]    stage context + emit dep.json (no docker build)
  context  <manifest.yaml>          stage the build context only (for debugging)
  query    <rpm> [...]              ad-hoc RPM version lookup:
                                      --yum <repo>          from a .repo file
                                      --base-image <ref>    extract from a docker image
                                      --image <ref>         rpm -qa inside a built image
  lock     <manifest.yaml>          produce a per-image versionlock file
                                    (override.rpm.info + yum + declared rpms)

Global flags for variable injection (Q2):
  --var KEY=VALUE      inject a single manifest.vars entry (may repeat)
  --vars <file.yaml>   inject a mapping of vars from a YAML file

Conventions:
  output dir defaults to `<cwd>/build/container/<name>/`
  the dep.json lands at `<output_root>/<name>.dep.json`
"""

from __future__ import annotations
import argparse
import os
import sys
from pathlib import Path

# --- sys.path bootstrap ---
#
# Two additions:
#   1. BUILD_TOOLS -> so `from pybuild.*` finds this tool's own modules
#      (container/buildTools/pybuild/).  buildTools/ is a general
#      catch-all for future scripts (shell, other lang) that don't
#      belong under pybuild specifically.
#   2. GM_TOOLS    -> so `from pydep.pretty import ...` (used by
#      container/buildTools/pybuild/json_pretty.py's shim) finds the
#      shared ShortListJSONEncoder at production/tools/pydep/pretty.py.
#
# Spinout note: when container/ moves to its own repo the pydep
# shim is replaced by a vendored copy (see json_pretty.py); drop
# the GM_TOOLS line at that time.
HERE        = Path(__file__).resolve().parent
BUILD_TOOLS = HERE / "buildTools"
GM_TOOLS    = HERE.parent / "production" / "tools"    # <-- pydep lives here
sys.path.insert(0, str(BUILD_TOOLS))
if GM_TOOLS.is_dir():
    sys.path.insert(0, str(GM_TOOLS))

from pybuild import (
    Manifest, BuildContext, DockerfileRenderer, DockerBuild,
    RpmResolver, RpmRuntimeResolver, query_installed_rpms,
    parse_dockerfile_yum,
    OverrideTable, DepJson,
)
from pybuild.yum_query   import YumQuery
from pybuild.lock        import LockGenerator
from pybuild.rpm_update  import RpmUpdateChecker


# ----------------------------------------------------------------------
# Path conventions
# ----------------------------------------------------------------------

def default_out_root() -> Path:
    return Path(os.environ.get("CONTAINER_OUT", Path.cwd() / "build" / "container")).resolve()


def out_dir_for(manifest: Manifest, root: Path | None = None) -> Path:
    root = root or default_out_root()
    return root / manifest.name


def default_proj_top() -> Path:
    """The repo root used to relativize paths in dep.json.

    Defaults to env var CONTAINER_PROJ_TOP if set, else the current
    working directory.  Keeps dep.json entries git-diff-friendly.
    """
    return Path(os.environ.get("CONTAINER_PROJ_TOP", Path.cwd())).resolve()


# ----------------------------------------------------------------------
# Variable injection (Q2 fix)
# ----------------------------------------------------------------------

def apply_var_overrides(m: Manifest, args: argparse.Namespace) -> None:
    """Merge CLI-supplied vars into manifest.vars.

    Precedence (later wins):
      1. manifest.yaml's `vars:` block  (baked-in defaults)
      2. `--vars <file>`                 (per-build defaults from CI)
      3. `--var KEY=VALUE`               (interactive overrides)

    Lets you keep one manifest per image and drive the varying bits
    (aps_ver, aps_rel, etc.) from outside -- equivalent to reg's
    PodDescriptor + version_info split.
    """
    if getattr(args, "vars_file", None) and args.vars_file.is_file():
        try:
            import yaml
            raw = yaml.safe_load(args.vars_file.read_text()) or {}
            for k, v in raw.items():
                m.vars[str(k)] = str(v)
        except Exception as e:
            print(f"container: warning: could not load --vars {args.vars_file}: {e}",
                  file=sys.stderr)
    for spec in getattr(args, "var", None) or []:
        if "=" not in spec:
            print(f"container: --var expects KEY=VALUE, got {spec!r}",
                  file=sys.stderr)
            continue
        k, v = spec.split("=", 1)
        m.vars[k.strip()] = v.strip()


# ----------------------------------------------------------------------
# Subcommands
# ----------------------------------------------------------------------

def cmd_build(args: argparse.Namespace) -> int:
    for path in args.manifest:
        m       = Manifest.load(path)
        apply_var_overrides(m, args)
        out     = out_dir_for(m, args.out_root)
        out.mkdir(parents=True, exist_ok=True)
        iid_path = out / f"{m.name}.id"

        # 0. Resolve URL / tarball base image BEFORE staging.  When
        #    `manifest.base` looks like http(s)://.../foo.tar or a local
        #    *.tar/*.tgz, DockerBuild will `docker load` it and give us
        #    a proper local image tag; that resolved tag is what the
        #    Dockerfile's FROM should reference (and what dep.json
        #    should record).  Skip when the base is already a plain
        #    docker ref.
        builder = DockerBuild(
            manifest = m,
            context  = out,               # placeholder, overwritten below
            iid_file = iid_path,
        )
        resolved = builder.resolve_base_image()
        if resolved != m.base:
            m.extra["base_image_url_original"] = m.base
            m.base = resolved   # so Dockerfile FROM + dep.json see the loaded tag

        # 1. stage context (with hooks tracking, optional lock file)
        ctx = BuildContext(
            manifest   = m,
            out_dir    = out,
            track_deps = True,
            lock_file  = args.rpm_lock,
        ).stage()

        # 2. render Dockerfile into context
        dockerfile_dst = ctx.staged[-1] / "Dockerfile"
        rendered_df    = DockerfileRenderer(m).render()
        dockerfile_dst.write_text(rendered_df)

        # 3. docker build
        builder.context = ctx.staged[-1]
        image_id = builder.run()

        # 4. Resolve RPM versions.  Prefer post-build query (rpm -qa
        #    inside the built image) -- that's what actually got
        #    installed.  Fall back to yum-repo query when the container
        #    lacks /bin/rpm (e.g. distroless / FROM scratch).
        rpms = _resolve_rpms(m, image_id) if args.resolve_rpms else []

        # 5. Emit dep.json
        dep_path = out / f"{m.name}.dep.json"
        DepJson(
            manifest  = m,
            rpms      = rpms,
            hooks_log = ctx.hooks_log,
            image_id  = image_id,
            proj_top  = args.proj_top,
            cmd       = _reconstruct_cmd(m, ctx.staged[-1], iid_path),
        ).write_to(dep_path)

        print(f"\nimage   : {m.image_ref}")
        print(f"id      : {image_id}")
        print(f"context : {ctx.staged[-1]}")
        print(f"dep.json: {dep_path}")
    return 0


def _declared_rpms(m: Manifest, dockerfile_text: str) -> set[str]:
    """Every RPM name the manifest asks for -- three sources:
       1. `prerequisites:` (installed before installGuide.in blocks)
       2. installGuide.in [RPMINSTALL] blocks
       3. `yum install X` in the rendered Dockerfile

    Used as the filter set for the post-build `rpm -qa` query so we
    return only what the manifest actually declared (not every rpm the
    base image happens to bundle).
    """
    names: set[str] = set(m.prerequisites)
    names.update(m.rpms_to_install)
    names.update(parse_dockerfile_yum(dockerfile_text))
    return names


def _resolve_rpms(m: Manifest, image_id: str):
    """Post-build resolution: query the actual built image + fall back
    to yum for anything missing.  Overrides win over both sources."""
    from pybuild.rpms import RpmInfo

    # Read the rendered Dockerfile back to catch `yum install X` in RUN.
    df_text = ""
    df_path = default_out_root() / m.name / "context" / "Dockerfile"
    if df_path.is_file():
        df_text = df_path.read_text()
    declared = _declared_rpms(m, df_text)

    # Runtime-in-image observation (authoritative for what's installed).
    observed: dict[str, RpmInfo] = {}
    if declared:
        try:
            observed = {
                r.name: r
                for r in RpmRuntimeResolver(m.image_ref, declared).resolve()
            }
        except Exception:
            observed = {}

    # Yum-repo query for anything the container didn't answer for.
    missing = [n for n in declared if n not in observed]
    from_yum: dict[str, RpmInfo] = {}
    if missing and m.repos:
        for r in RpmResolver(manifest=m).resolve():
            if r.name in missing and r.version != "NOT_FOUND":
                from_yum[r.name] = r

    # Overrides take precedence over both.
    overrides = OverrideTable.from_manifest(m).table

    resolved: list[RpmInfo] = []
    for name in sorted(declared):
        if name in overrides:
            resolved.append(overrides[name])
        elif name in observed:
            resolved.append(observed[name])
        elif name in from_yum:
            resolved.append(from_yum[name])
    return resolved


def _reconstruct_cmd(m: Manifest, ctx: Path, iid_file: Path) -> str:
    """The docker command that produced this image.  Aligned with reg's
    `extra.cmd` (full command string for reproducibility)."""
    return " ".join([
        "docker", "build",
        "-t", m.image_ref,
        "--iidfile", str(iid_file),
        str(ctx),
    ])


def cmd_render(args: argparse.Namespace) -> int:
    m = Manifest.load(args.manifest[0])
    apply_var_overrides(m, args)
    print(DockerfileRenderer(m).render(), end="")
    return 0


def cmd_rpms(args: argparse.Namespace) -> int:
    m    = Manifest.load(args.manifest[0])
    apply_var_overrides(m, args)
    rpms = RpmResolver(manifest=m).resolve()
    for r in rpms:
        print(f"{r.name:<30s} {r.version:<20s} {r.release:<20s} {r.arch}")
    return 0


def cmd_deps(args: argparse.Namespace) -> int:
    for path in args.manifest:
        m       = Manifest.load(path)
        apply_var_overrides(m, args)
        out     = out_dir_for(m, args.out_root)
        out.mkdir(parents=True, exist_ok=True)
        ctx     = BuildContext(manifest=m, out_dir=out, track_deps=True).stage()
        rpms    = RpmResolver(manifest=m).resolve() if args.resolve_rpms else []
        dep     = out / f"{m.name}.dep.json"
        DepJson(
            manifest  = m,
            rpms      = rpms,
            hooks_log = ctx.hooks_log,
            image_id  = None,
            proj_top  = args.proj_top,
        ).write_to(dep)
        print(f"{m.name}: {dep}")
    return 0


def cmd_context(args: argparse.Namespace) -> int:
    m   = Manifest.load(args.manifest[0])
    apply_var_overrides(m, args)
    out = out_dir_for(m, args.out_root)
    out.mkdir(parents=True, exist_ok=True)
    ctx = BuildContext(manifest=m, out_dir=out, track_deps=True).stage()
    DockerfileRenderer(m).write_to(ctx.staged[-1] / "Dockerfile")
    print(ctx.staged[-1])
    return 0


# ----------------------------------------------------------------------
# Q1: RPM version discovery for security-driven updates.
# ----------------------------------------------------------------------

def cmd_query(args: argparse.Namespace) -> int:
    """Ad-hoc RPM version query.

    Three modes, exactly one required:
      --yum <repo-file>   query the repos in this *.repo file
      --base-image <ref>  extract yum repos from this docker image, then query
      --image <ref>       query RPMs INSTALLED in this built image (rpm -qa)
    """
    if not (args.yum or args.base_image or args.image):
        print("container query: need one of --yum / --base-image / --image",
              file=sys.stderr)
        return 2

    names = args.rpm_names

    if args.image:
        # In-image inventory: rpm -qa inside the container.
        installed = query_installed_rpms(args.image)
        wanted    = set(names)
        rows = [r for r in installed if r.name in wanted] if wanted else installed
        for r in sorted(rows, key=lambda r: r.name):
            print(f"{r.name} {r.version} {r.release} {r.arch}")
        return 0

    # Yum-repo lookup (from file, or from base-image extraction, or both).
    q = YumQuery(
        repo_file   = args.yum,
        base_image  = args.base_image,
        extra_repos = args.extra_repo or [],
        arch_filter = args.arch,
    )
    for r in q.query(names):
        print(f"{r.name} {r.version} {r.release} {r.arch}")
    return 0


def cmd_check_rpm_update(args: argparse.Namespace) -> int:
    """Scan cached dep.json files and report images whose upstream
    RPMs have newer versions available.

    Reads:
      - dep.json files under --dep-json-dir (default: build/container/)
      - Each dep.json's `extra.repos` (the resolved yum URLs it was
        built against)

    For each image, queries the same yum repos for CURRENT versions
    of the RPMs listed in its `rpms[]`; any name whose current
    version > cached is reported as an update.
    """
    checker = RpmUpdateChecker(
        dep_json_dir = args.dep_json_dir,
        only_images  = args.image or None,
        arch_filter  = args.arch,
    )
    reports = checker.check_all()
    print(checker.render(reports, fmt=args.format), end="")

    # Non-zero exit when any image has updates -- lets CI gate on it.
    return 1 if any(r.has_updates for r in reports) and args.exit_on_updates else 0


def cmd_lock(args: argparse.Namespace) -> int:
    """Produce per-image versionlock file.

    Reads:
      - manifest's declared RPMs (installGuide.in + Dockerfile yum)
      - --override <file>          override.rpm.info-style manual pins
    Resolves any not-overridden RPMs against the manifest's yum repos.
    Writes plain-text `<name> <ver> <rel> <arch>` lines suitable for
    `container build --rpm-lock <out>`.
    """
    for path in args.manifest:
        m = Manifest.load(path)
        apply_var_overrides(m, args)

        out_dir = args.out_dir or (default_out_root() / "lock")
        out_dir.mkdir(parents=True, exist_ok=True)
        out_file = out_dir / f"{m.name}.rpm.info"

        LockGenerator(manifest=m, override=args.override).write_to(out_file)
        print(f"{m.name}: {out_file}")
    return 0


# ----------------------------------------------------------------------
# Main
# ----------------------------------------------------------------------

def main() -> int:
    p = argparse.ArgumentParser(prog="imageBuild.py", description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--out-root", type=Path, default=None,
                   help="output directory root (default $CONTAINER_OUT or ./build/container/)")
    p.add_argument("--proj-top", type=Path, default=default_proj_top(),
                   help="repo root used to relativize paths in dep.json "
                        "(default $CONTAINER_PROJ_TOP or cwd)")
    p.add_argument("--no-rpms", dest="resolve_rpms", action="store_false",
                   help="skip RPM version resolution (in-image + yum-repo query)")
    p.add_argument("--rpm-lock", type=Path, default=None,
                   help="per-image versionlock.list file staged into "
                        "the build context (honoured by yum inside the "
                        "container to pin RPM versions)")
    p.add_argument("--var", action="append", default=[], metavar="KEY=VALUE",
                   help="inject a single manifest.vars entry (may repeat)")
    p.add_argument("--vars", dest="vars_file", type=Path, default=None,
                   metavar="FILE.yaml",
                   help="YAML file whose top-level mapping merges into manifest.vars")
    p.set_defaults(resolve_rpms=True)

    sub = p.add_subparsers(dest="cmd", required=True)

    # Manifest-taking subcommands
    for name, fn in [("build",   cmd_build),
                     ("render",  cmd_render),
                     ("rpms",    cmd_rpms),
                     ("deps",    cmd_deps),
                     ("context", cmd_context)]:
        s = sub.add_parser(name, help=fn.__doc__)
        s.add_argument("manifest", nargs="+", type=Path)
        s.set_defaults(fn=fn)

    # `query <rpm> [<rpm> ...]` -- ad-hoc RPM lookup
    q = sub.add_parser("query", help=cmd_query.__doc__)
    q.add_argument("rpm_names", nargs="*", metavar="RPM",
                   help="RPM names to look up (omit to dump full inventory in --image mode)")
    src = q.add_argument_group("source (exactly one required)")
    src.add_argument("--yum",        type=Path, help="explicit *.repo file")
    src.add_argument("--base-image", dest="base_image",
                     help="docker image to extract /etc/yum.repos.d/ from")
    src.add_argument("--image",      help="docker image to query with rpm -qa")
    q.add_argument("--extra-repo",   type=Path, action="append",
                   help="additional *.repo file (may repeat)")
    q.add_argument("--arch",         choices=["x86_64", "i686", "noarch"],
                   default=None,
                   help="restrict to this architecture (default: prefer x86_64 > i686 > noarch)")
    q.set_defaults(fn=cmd_query)

    # `lock <manifest>` -- generate per-image versionlock file
    lk = sub.add_parser("lock", help=cmd_lock.__doc__)
    lk.add_argument("manifest", nargs="+", type=Path)
    lk.add_argument("--override", type=Path, default=None,
                    help="override.rpm.info file (RPMs listed here win over yum)")
    lk.add_argument("-o", "--out-dir", type=Path, default=None,
                    help="output directory (default: build/container/lock/)")
    lk.set_defaults(fn=cmd_lock)

    # `check-rpm-update` -- poll upstream yum for RPM updates
    cu = sub.add_parser("check-rpm-update", help=cmd_check_rpm_update.__doc__)
    cu.add_argument("--dep-json-dir", type=Path,
                    default=default_out_root(),
                    help="directory of *.dep.json files (default: $CONTAINER_OUT "
                         "or ./build/container/)")
    cu.add_argument("--image", action="append", default=[], metavar="NAME",
                    help="restrict check to this image name (repeatable)")
    cu.add_argument("--arch", choices=["x86_64", "i686", "noarch"], default=None,
                    help="restrict yum queries to this architecture")
    cu.add_argument("--format", choices=["text", "json"], default="text",
                    help="report output format (default: text)")
    cu.add_argument("--exit-on-updates", action="store_true",
                    help="exit non-zero when any image has updates (CI gate)")
    cu.set_defaults(fn=cmd_check_rpm_update)

    args = p.parse_args()
    return args.fn(args)


if __name__ == "__main__":
    sys.exit(main())
