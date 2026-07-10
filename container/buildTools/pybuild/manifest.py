"""Image manifest -- the per-image YAML descriptor.

Replaces the legacy framework's
`PodDescriptor + version_info + buildInputs/4g.in` triple by being a
single self-contained YAML per image.  Schema:

    name:        <image-name>                       (required)
    version:     <semver-like>                      (default: "0.1.0")
    tag:         <image-tag>                        (default: $version)
    base:        <base-image-ref or tar.gz URL>     (required)
    registry:    <registry/repo prefix>             (default: "localhost")
    entrypoint:  <container ENTRYPOINT>             (default: from template)

    repos:                                          (optional)
      <repo-key>:
        url:       <URL, may contain {var} placeholders>
        priority:  <int, lower = higher priority>   (default: 99)
        gpgcheck:  <bool>                           (default: false)

    vars:                                           (optional)
      <name>: <value>      # substituted into repos[].url and Dockerfile
      ...

    dockerfile:  <path/to/Dockerfile.tmpl>          (default: templates/Dockerfile.standard.tmpl)

    install:                                        (optional)
      file:  <path/to/installGuide.in>
      # OR
      blocks:
        - { type: RPMINSTALL, items: [openssl, vim-minimal] }
        - { type: RUN,        items: ["sh /root/install/setup.sh"] }

    extras:                                         (optional)
      - <path>            # copied into build context
      - ...

    override_rpms:                                  (optional)
      - [openssl, "1.1.1k", "14.el8_10", x86_64]
      - ...

Resolved paths are stored as absolute under `manifest.dir`.
"""

from __future__ import annotations
import sys
from dataclasses import dataclass, field
from pathlib import Path

try:
    import yaml
except ImportError:
    sys.stderr.write("container: missing PyYAML (pip install --user pyyaml)\n")
    raise


@dataclass
class RepoSpec:
    key:      str
    url:      str       # may contain {var} placeholders
    priority: int = 99
    gpgcheck: bool = False


@dataclass
class InstallBlock:
    type:  str          # RPMINSTALL / RUN / RPMUNINSTALL / START / STOP
    items: list[str]    # one entry per "line" in the block


@dataclass
class RpmLockSpec:
    """Manifest-embedded rpm-lock generation config.

    Setting this in the manifest tells `container build` to
    auto-generate a per-image lock file and stage it as
    versionlock.list -- equivalent of running
    `container lock --override <override>` + `--rpm-lock <out>`
    in one shot.
    """
    override: Path | None = None   # override.rpm.info file
    auto:     bool        = True   # generate + stage during build


@dataclass
class Extra:
    """A single `extras:` entry.

    Two YAML forms in the manifest:
      - `hello.sh`                                        (string; dst == src.name)
      - {src: hello.sh, dst: entrypoint.sh}               (dict; explicit rename)
      - {src: ../shared/scripts/, dst: helpers/}          (dict; dir + rename)
    """
    src: Path
    dst: str            # relative path INSIDE the build context


@dataclass
class Manifest:
    """Validated, path-resolved view of a manifest YAML."""
    path:           Path
    dir:            Path
    name:           str
    version:        str          = "0.1.0"
    tag:            str          = ""    # falls back to version
    base:           str          = ""
    registry:       str          = "localhost"
    entrypoint:     str          = ""
    repos:          dict[str, RepoSpec]   = field(default_factory=dict)
    vars:           dict[str, str]        = field(default_factory=dict)
    dockerfile:     Path | None  = None
    installer:      Path | None  = None
    install_file:   Path | None  = None
    install_blocks: list[InstallBlock]    = field(default_factory=list)
    extras:         list[Extra]           = field(default_factory=list)
    rpm_lock:       "RpmLockSpec | None"  = None
    override_rpms:  list[tuple[str, str, str, str]] = field(default_factory=list)

    # --- Docker CLI knobs (aligned with reg_container_tooling) ---
    #
    # `docker build` flags applied verbatim on the CLI.  Defaults match
    # reg's `buildAppDockerImage.sh` (no-cache + rm) so we get the same
    # deterministic-per-build behaviour out of the box.  Empty list =
    # let docker use its defaults.
    build_flags:    list[str]              = field(default_factory=lambda: ["--no-cache=true", "--rm"])
    # Extra `--label K=V` pairs.  A BUILDTIME label is injected by
    # DockerBuild if not overridden here.
    labels:         dict[str, str]         = field(default_factory=dict)
    # Extra tags beyond the canonical `<registry>/<name>:<tag>` + the
    # short `<name>:<tag>`.  Each entry is a raw docker tag string.
    extra_tags:     list[str]              = field(default_factory=list)
    # Optional: bundle a directory into `context/install.tar` before
    # `docker build`.  Path is relative to manifest.dir.  Matches reg's
    # `tar -cvf dockercontext/install.tar install/` step.
    install_tar:    Path | None            = None
    # Optional: emit `context/version_info` with one `key: value` line
    # per manifest.vars entry.  Matches reg's per-container
    # `version_info` file (their format: `<repo> APS: <rel>: <ver>`).
    # gm's format is simpler (`key: value`) because our vars are a
    # generic map, not per-repo release info -- callers can override
    # by writing their own `extras:` entry named `version_info` if
    # they need the exact reg format.
    emit_version_info: bool                = False

    # Pass-through metadata.  Lands verbatim in dep.json's `extra:` object.
    # Useful for matching reg_container_tooling's reg-style extras
    # (docker_source_path / version_string / rpm_version_lock / ...).
    extra:          dict[str, str] = field(default_factory=dict)

    # RPMs installed **before** the user's installGuide.in blocks run.
    # These are the "prep container runtime" packages -- python3, tar,
    # findutils, etc. -- that the user's [RUN] blocks typically need.
    # Equivalent of reg's hard-coded
    #     yum install tar hostname findutils python3 vim-minimal gzip
    # at the top of appDockerInstaller.sh.  Empty means the user is
    # fully responsible via installGuide.in [RPMINSTALL].
    prerequisites:  list[str]      = field(default_factory=list)

    # ------------------------------------------------------------------
    # Constructor
    # ------------------------------------------------------------------
    @classmethod
    def load(cls, path: str | Path) -> "Manifest":
        path = Path(path).resolve()
        if not path.is_file():
            raise FileNotFoundError(f"manifest not found: {path}")
        raw  = yaml.safe_load(path.read_text()) or {}
        if not isinstance(raw, dict):
            raise ValueError(f"{path}: top-level must be a mapping")

        for required in ("name", "base"):
            if not raw.get(required):
                raise ValueError(f"{path}: '{required}' is required")

        m = cls(path=path, dir=path.parent, name=raw["name"], base=raw["base"])
        m.version    = str(raw.get("version", m.version))
        m.tag        = str(raw.get("tag", m.version))
        m.registry   = str(raw.get("registry", m.registry))
        m.entrypoint = str(raw.get("entrypoint", m.entrypoint))
        m.vars       = {k: str(v) for k, v in (raw.get("vars") or {}).items()}

        # repos -- ordered by priority asc, then declaration order
        for key, spec in (raw.get("repos") or {}).items():
            m.repos[key] = RepoSpec(
                key      = key,
                url      = str(spec["url"]),
                priority = int(spec.get("priority", 99)),
                gpgcheck = bool(spec.get("gpgcheck", False)),
            )

        # dockerfile -- relative to manifest.dir; fall back to standard.
        # `parents[2]` from container/buildTools/pybuild/manifest.py
        # climbs to container/, which holds `templates/`.
        container_root = Path(__file__).resolve().parents[2]
        if "dockerfile" in raw:
            m.dockerfile = (m.dir / raw["dockerfile"]).resolve()
        else:
            m.dockerfile = (container_root / "templates" / "Dockerfile.standard.tmpl").resolve()
        if not m.dockerfile.is_file():
            raise FileNotFoundError(f"dockerfile not found: {m.dockerfile}")

        # installer -- optional custom in-container DSL interpreter.
        # Defaults to the framework's shared templates/appDockerInstaller.sh.
        # Set to `null` in the yaml to skip staging one (Dockerfile
        # must then not reference it).
        if "installer" in raw:
            if raw["installer"] is None or raw["installer"] is False:
                m.installer = None
            else:
                m.installer = (m.dir / raw["installer"]).resolve()
                if not m.installer.is_file():
                    raise FileNotFoundError(f"installer not found: {m.installer}")
        else:
            m.installer = (container_root / "templates" / "appDockerInstaller.sh").resolve()

        # install -- either external file or inline blocks
        install = raw.get("install") or {}
        if "file" in install:
            m.install_file = (m.dir / install["file"]).resolve()
            if not m.install_file.is_file():
                raise FileNotFoundError(f"install file not found: {m.install_file}")
        elif "blocks" in install:
            for blk in install["blocks"]:
                m.install_blocks.append(InstallBlock(
                    type  = str(blk["type"]).upper(),
                    items = [str(x) for x in (blk.get("items") or [])],
                ))

        # extras -- files OR directories copied into build context.
        # Directories are walked recursively at stage-time so every
        # leaf file lands in dep.json's deps[] (mirrors reg's
        # `cp -rf $SOURCEPATH/*` + `cp -rf plugins/*` bulk-copy
        # patterns).  Two YAML forms:
        #   - "path/to/file"                            (str; dst = basename)
        #   - {src: "path", dst: "renamed-name"}        (dict; explicit rename)
        for entry in raw.get("extras") or []:
            src_str: str
            dst_str: str | None
            if isinstance(entry, str):
                src_str, dst_str = entry, None
            elif isinstance(entry, dict):
                # `.get("src")` returns Optional[str]; assert-narrow so
                # both `src_str: str` and mypy stay happy.
                raw_src = entry.get("src")
                if not raw_src:
                    raise ValueError(f"extras dict form must have 'src': {entry!r}")
                src_str = str(raw_src)
                dst_str = entry.get("dst")
            else:
                raise ValueError(f"extras entry must be str or dict, got {type(entry).__name__}: {entry!r}")

            p = (m.dir / src_str).resolve()
            if not p.exists():
                raise FileNotFoundError(f"extras missing (file or dir): {p}")

            # Default dst = basename of src (works for both files and dirs)
            m.extras.append(Extra(src=p, dst=(dst_str or p.name)))

        # override_rpms -- explicit version pins
        for o in raw.get("override_rpms") or []:
            if not (isinstance(o, list) and len(o) == 4):
                raise ValueError(f"override_rpms entry must be [name, ver, rel, arch]: {o!r}")
            m.override_rpms.append(tuple(str(x) for x in o))   # type: ignore[arg-type]

        # rpm_lock -- optional auto-generate + stage config.  When
        # declared, `container build` will run the lock generator with
        # the given override and stage the result as versionlock.list
        # in the build context (no need for --rpm-lock CLI arg).
        if "rpm_lock" in raw and raw["rpm_lock"] is not None:
            lk = raw["rpm_lock"]
            if not isinstance(lk, dict):
                raise ValueError(f"rpm_lock must be a mapping, got {type(lk).__name__}")
            override = None
            if lk.get("override"):
                override = (m.dir / lk["override"]).resolve()
                if not override.is_file():
                    raise FileNotFoundError(f"rpm_lock.override missing: {override}")
            m.rpm_lock = RpmLockSpec(
                override = override,
                auto     = bool(lk.get("auto", True)),
            )

        # Pass-through metadata for dep.json's `extra:` block.
        for k, v in (raw.get("extra") or {}).items():
            m.extra[str(k)] = str(v)

        # Optional per-image runtime prerequisites.
        for pkg in (raw.get("prerequisites") or []):
            m.prerequisites.append(str(pkg))

        # ---- Docker CLI knobs (reg alignment) ----
        # `build_flags:` accepts either a YAML list ["--no-cache=true", "--rm"]
        # or the string "none" / null / [] to disable defaults entirely.
        if "build_flags" in raw:
            bf = raw["build_flags"]
            if bf is None or bf == "none" or bf == []:
                m.build_flags = []
            elif isinstance(bf, list):
                m.build_flags = [str(x) for x in bf]
            else:
                raise ValueError(
                    f"{path}: build_flags must be a list or null, got {type(bf).__name__}")
        for k, v in (raw.get("labels") or {}).items():
            m.labels[str(k)] = str(v)
        for t in (raw.get("extra_tags") or []):
            m.extra_tags.append(str(t))
        if raw.get("install_tar"):
            it = (m.dir / str(raw["install_tar"])).resolve()
            if not it.is_dir():
                raise FileNotFoundError(
                    f"install_tar must be a directory: {it}")
            m.install_tar = it
        m.emit_version_info = bool(raw.get("emit_version_info", False))

        return m

    # ------------------------------------------------------------------
    # Derived
    # ------------------------------------------------------------------
    @property
    def image_ref(self) -> str:
        """The full image name docker writes as `repo:tag`.  This is the
        canonical, registry-qualified form -- e.g. `localhost/hello:1.0.0`
        or `registry.example.com/hello:1.0.0`.  Also referenced by
        dep.json's `extra.image_ref`."""
        repo = f"{self.registry}/{self.name}" if self.registry else self.name
        return f"{repo}:{self.tag or self.version}"

    @property
    def all_tags(self) -> list[str]:
        """Every docker tag this build should apply to the produced image.
        Matches reg's `docker build -t IMG:TAG -t REGISTRY/IMG:TAG` -- we
        emit the registry-qualified form AND the short `name:tag`, plus
        anything the manifest lists under `extra_tags:`.  Deduped,
        order-preserving (registry-qualified first)."""
        tag = self.tag or self.version
        tags: list[str] = [self.image_ref]
        # Short form only if registry actually prefixes the image_ref.
        short = f"{self.name}:{tag}"
        if short != self.image_ref:
            tags.append(short)
        for t in self.extra_tags:
            if t not in tags:
                tags.append(t)
        return tags

    @property
    def rpms_to_install(self) -> list[str]:
        """All RPM names referenced by the install DSL.  Empty if not declared.

        Used by the resolver to query yum repos for resolved versions.
        """
        from .installer import InstallerDSL
        dsl = InstallerDSL.from_manifest(self)
        return dsl.rpms()

    def substitute(self, s: str, extra: dict[str, str] | None = None) -> str:
        """Apply `{var}` substitution against manifest.vars + extras."""
        env = {**self.vars, **(extra or {})}
        # Conservative: only substitute known keys, leave unknown {tokens} alone.
        out = s
        for k, v in env.items():
            out = out.replace("{" + k + "}", v)
        return out
