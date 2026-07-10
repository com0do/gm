# container

A standalone container-image build subsystem.  Designed to plug into
gm's file-level DAG (`make/scripts/dep_query.py`) by emitting
`.dep.json` sidecars, but **otherwise decoupled from gm** -- the rest
of gm (target.c.mk, deps lock-file, etc.) is not a prerequisite.

## What it gives you

1. **One entry point** -- `container build <manifest.yaml>` builds any image
2. **Dynamic runtime construction** -- a small DSL (`installGuide.in`)
   declares what to install / run inside the container; an interpreter
   runs the DSL at container-build time
3. **Dynamic yum.repo generation** -- `{var}` templates in repo URLs
   are resolved at stage-time from manifest.vars + CLI overrides
4. **Dynamic rpm versionlock** -- per-image lock file auto-generated
   from `override.rpm.info` + yum lookups, honoured in-container
   via `yum-plugin-versionlock`
5. **Remote-RPM discovery** -- ad-hoc `container query` looks up RPMs
   in a `*.repo` file, a base image, or a built image (dev-facing
   tool for security-driven update workflows)
6. **Hook-tracked file deps** -- a sourced `dep-hooks.sh` overlays
   `cp` / `install` and logs every staged file to a JSONL trace,
   parsed into the image's `deps[]` list
7. **Swappable Dockerfile + installer** -- both point at
   framework-shipped defaults, override per manifest for images that
   need bespoke runtime construction

## Architecture

```
┌─ Stage 1: entry (content static, params dynamic) ────────────────┐
│                                                                  │
│   container [--var K=V | --vars <file>] [--rpm-lock <file>]       │
│            build <manifest.yaml>                                 │
│                                                                  │
│   • static part = command + manifest (git-committed)             │
│   • dynamic part = --var / --vars / --rpm-lock (CI injects)      │
└──────────────────────────────────────────────────────────────────┘
                            ↓
┌─ Stage 2: prepare container runtime (host-side staging) ─────────┐
│                                                                  │
│   BuildContext.stage()                                           │
│     ├ render installGuide.in ---------> context/installGuide.in  │
│     ├ render *.repo ------------------> context/container.repo    │
│     ├ stage installer script ---------> context/appDockerInstaller.sh
│     ├ stage prerequisites -----------> context/prerequisites.list│
│     ├ auto-generate versionlock ------> context/versionlock.list │
│     ├ copy extras: (files + dirs)                                │
│     │    ├ single file:  cp -fL <src> <ctx>/<dst>                │
│     │    └ directory  :  cp -rfL <src>/. <ctx>/<dst>/            │
│     │                     + dep_add each leaf file               │
│     └ every cp/install goes through dep-hooks.sh ---> JSONL trace│
│                                                                  │
│   DockerfileRenderer.render() ---------> context/Dockerfile      │
│     (@VAR@ / __VAR__ substitution from manifest.vars + defaults) │
└──────────────────────────────────────────────────────────────────┘
                            ↓
┌─ Stage 3: docker build + in-container runtime ───────────────────┐
│                                                                  │
│   docker build --iidfile <name>.id <context>                     │
│     ↓                                                            │
│   inside container:                                              │
│     appDockerInstaller.sh                                        │
│       ├ picks PM (yum / dnf / microdnf)                          │
│       ├ loads context/container.repo -> /etc/yum.repos.d/         │
│       ├ if versionlock.list: enable yum-plugin-versionlock       │
│       ├ install prerequisites.list                                │
│       └ read installGuide.in:                                    │
│           [RPMINSTALL]   -> $PM install -y                       │
│           [RPMUNINSTALL] -> $PM remove  -y                       │
│           [RUN]          -> eval <cmd>                           │
│           [STOP]         -> cleanup + exit                       │
└──────────────────────────────────────────────────────────────────┘
                            ↓
┌─ Stage 4: dep.json emission ─────────────────────────────────────┐
│                                                                  │
│   RpmRuntimeResolver -- docker run --entrypoint /bin/rpm ... -qa │
│     ↓ filter declared (prereqs + installGuide + Dockerfile yum)  │
│   DepJson.write_to(build/container/<name>/<name>.dep.json)        │
│                                                                  │
│   Schema (aligned with the reference dep.json layout):           │
│     {                                                            │
│       "img":   "<name>",                                         │
│       "rpms":  [["name","ver","rel","arch"], ...],               │
│       "deps":  ["<repo-relative path>", ...],                    │
│       "extra": { base_image_url, version, tag, cmd, image_id,    │
│                  repos, ...pass-through }                        │
│     }                                                            │
└──────────────────────────────────────────────────────────────────┘
```

## Manifest reference

```yaml
name:        hello                    # required
version:     1.0.0                    # default "0.1.0"
tag:         1.0.0                    # default = version
base:        <base-image ref>         # required
registry:    localhost                # default "localhost"
entrypoint:  /usr/local/bin/hello.sh  # container ENTRYPOINT

# Optional custom Dockerfile template (@VAR@ / __VAR__ substituted).
# Defaults to templates/Dockerfile.standard.tmpl.
dockerfile:  Dockerfile.tmpl

# Optional custom in-container DSL interpreter.  Defaults to
# templates/appDockerInstaller.sh.  Set to `null` to skip staging
# one entirely (Dockerfile must not reference it then).
installer:   my-project/customInstaller.sh

# Runtime prerequisites -- installed BEFORE installGuide.in blocks run.
prerequisites:
  - python3
  - tar
  - findutils

# Vars used by:
#   - {var} substitution in repos[].url
#   - @VAR@ / __VAR__ substitution in the Dockerfile template
# CLI (`--var K=V`, `--vars <file>`) merges on top.
vars:
  aps_ver: "26.7-2"

# Yum repos.  URLs may contain {var} placeholders.  Rendered into
# context/container.repo, sorted by priority ascending.
repos:
  app:
    url:      https://repo.example.com/{aps_ver}/x86_64/
    priority: 5
    gpgcheck: false

# installGuide.in DSL -- either external file OR inline blocks.
install:
  file: installGuide.in
  # OR
  # blocks:
  #   - { type: RPMINSTALL, items: [vim-minimal, gzip] }
  #   - { type: RUN,        items: ["sh /root/container/setup.sh"] }

# Files AND directories staged into the build context.  Two forms:
#   - "path"                          (dst = basename)
#   - {src: "path", dst: "renamed"}   (rename during stage)
extras:
  - hello.sh                          # simple, dst = hello.sh
  - src: scripts/                     # directory
    dst: runtime-scripts/             #   renamed on the way in
  - src: ../shared/lib.tar            # cross-dir source
    dst: lib/shared.tar               #   layered dst

# Manual RPM version pins.  Feed into the lock generator below.
override_rpms:
  - [openssl, "1.1.1k", "14.el8_10", x86_64]

# Optional: auto-generate versionlock at build-time.  When present,
# `container build` runs the lock generator inline and stages the
# result as context/versionlock.list -- no need for --rpm-lock CLI.
rpm_lock:
  override: override.rpm.info         # relative to manifest.dir
  auto:     true                      # default

# Pass-through metadata.  Merged into dep.json's `extra:` object
# alongside our framework-provided keys.
extra:
  docker_source_path: ./
  version_string:     hello/1.0.0

# ---- reg_container_tooling alignment knobs ---------------------------

# `docker build` flags applied verbatim.  Default: ["--no-cache=true",
# "--rm"] matching reg/buildAppDockerImage.sh.  Set to [] or null to
# let docker use its own defaults.
build_flags:
  - "--no-cache=true"
  - "--rm"

# Extra `--label K=V` pairs.  BUILDTIME is auto-injected as YYYYMMDD;
# declaring BUILDTIME here overrides it.
labels:
  MAINTAINER:  team@example.com
  # BUILDTIME: 20260703                # override the auto one if you must

# Additional docker tags applied on top of the always-emitted
#   <registry>/<name>:<tag>    (canonical)
#   <name>:<tag>               (short form)
# Useful for cutting `:latest` or extra branch tags alongside a build.
extra_tags:
  - reg.internal.example/hello:latest

# Optional: tar a directory into `context/install.tar` before build.
# Matches reg's `tar -cvf dockercontext/install.tar install/` step.
# Tarball contents are relative-to-src (no wrapper dir).
install_tar: install/

# Optional: dump manifest.vars into `context/version_info` as
# `key: value` lines.  reg's format is `<repo> APS: <rel>: <ver>`
# which is specific to their per-repo release model; for the exact
# reg layout, hand-write the file and reference it via `extras:`.
emit_version_info: true
```

### base image URL / tarball

When `base:` is an http(s) URL to a tarball (`.tar`, `.tgz`,
`.tar.gz`) or a local tarball path with those suffixes, `container
build` downloads it (urllib) and runs `docker load -i` to import the
archive.  The `Loaded image: <ref>` output tells us the resulting
local tag, which then substitutes into the rendered Dockerfile's
`FROM` line.  Matches reg's `downloadBaseImage()` shell helper.
The original URL is preserved in `dep.json`'s
`extra.base_image_url_original` for provenance.

## Module layout

```
container/
├── imageBuild.py                   CLI entry (Python, executable)
├── buildTools/                     general catch-all for build-support scripts
│   └── pybuild/                    Python impl of the image-build pipeline
│       ├── manifest.py             Parse image.yaml + validate
│       ├── installer.py            Parse installGuide.in DSL → blocks
│       ├── repos.py                Render *.repo from manifest.repos:
│       ├── rpms.py                 Manifest-scoped yum-repo RPM resolver
│       ├── yum_query.py            Ad-hoc yum queries (dev-facing `query`)
│       ├── rpm_query.py            Post-build `rpm -qa` in built image
│       ├── rpm_update.py           RpmUpdateChecker: poll upstream yum
│       ├── overrides.py            Apply manifest.override_rpms + files
│       ├── lock.py                 Generate <image>.rpm.info versionlock
│       ├── context.py              Stage build context, source hooks
│       ├── dockerfile.py           Render Dockerfile.tmpl (@VAR@ subst)
│       ├── docker.py               docker build/load wrapper
│       ├── dep_json.py             Emit dep.json
│       └── json_pretty.py          SHIM -> production/tools/pydep/pretty.py
├── templates/
│   ├── Dockerfile.standard.tmpl   2-stage scratch (the 80% case)
│   └── appDockerInstaller.sh      DSL interpreter (runs in container)
└── examples/
    ├── hello/                     working public-base-image example
    └── i1/                        legacy Dockerfile.tmpl reference
```

## Repo separation status

`container/` currently lives inside the `gm` repo.  It is
**structurally self-contained** but **reads two files from
`production/tools/` at runtime** so there is exactly one copy of
each shared asset.  Concretely:

| Shared asset | Single source of truth | Where container uses it |
|---|---|---|
| `pretty.py` (`ShortListJSONEncoder`) | `production/tools/pydep/pretty.py` | via `container/buildTools/pybuild/json_pretty.py` shim (`from pydep.pretty import ...`) |
| `dep-hooks.sh` (cp/install JSONL trace) | `production/tools/dep-hooks.sh` | `container/buildTools/pybuild/context.py` sources it directly, with a fallback to a vendored path |

Both use a "sys.path shim" pattern set up **exactly once** at the
top of `container/imageBuild.py`:
`sys.path.insert(0, <gm>/production/tools)`.  Container's own
modules never see gm's layout beyond this bootstrap.

**Spinout playbook** (when container/ moves to its own repo, all
small and mechanical):

1. `cp production/tools/pydep/pretty.py container/buildTools/pybuild/json_pretty.py`
   -- replaces the shim with the full implementation.
2. `mkdir container/hooks && cp production/tools/dep-hooks.sh container/hooks/`
   -- gives context.py its vendored fallback (already the second
   branch of the file-existence check, so no code change needed).
3. Drop the `GM_TOOLS` line from `imageBuild.py`'s sys.path setup.
4. Move `production/tools/pydep/image_walk.py`'s image-inverse
   methods (`sources_of`, `rpms_of`) into a new `container/buildTools/pybuild/dag_query.py`
   so container can answer "given an image name, what does it need?"
   without a gm import (they're the only image-specific bits still
   sitting in gm's pydep).
5. Add a small top-level `README.md` pointing back at this section
   for lineage; strip the "lives inside gm" prose.
6. Add `requirements.txt` pinning `PyYAML` (the only third-party runtime
   dep -- in-repo we don't pin).

## Subcommand cheatsheet

```bash
imageBuild.py build   <manifest> [...]  # full pipeline: stage + build + dep.json
imageBuild.py render  <manifest>        # print rendered Dockerfile (no build)
imageBuild.py rpms    <manifest>        # resolve + print RPM versions (no build)
imageBuild.py deps    <manifest> [...]  # stage + emit dep.json (no docker build)
imageBuild.py context <manifest>        # stage the build context (for debugging)
imageBuild.py query   <rpm> [...]       # ad-hoc RPM version lookup:
                                   #   --yum <repo-file>
                                   #   --base-image <ref>   (extract repos)
                                   #   --image <ref>        (rpm -qa inside)
imageBuild.py lock    <manifest> [...]  # generate <image>.rpm.info versionlock
                                   #   --override <file>
                                   #   -o <out-dir>
imageBuild.py check-rpm-update          # poll yum for upstream RPM updates
                                   #   --dep-json-dir <dir>
                                   #   --image <name>    (repeatable)
                                   #   --format text|json
                                   #   --exit-on-updates

# Global flags (apply to any subcommand)
  --var  KEY=VALUE     inject one manifest.vars entry (repeatable)
  --vars <file.yaml>   merge a mapping file into manifest.vars
  --out-root <dir>     override the default `build/container/` root
  --proj-top <dir>     repo root for relativizing deps[] paths
  --no-rpms            skip RPM version resolution
  --rpm-lock <file>    stage this versionlock.list into the context
```

## Local testing

Every test below assumes you're in `~/code/gm/` (or wherever you
checked out this tree).  The example `container/examples/hello/`
uses a public base image (`ubi8/ubi-minimal:8.10`) so it works
without Nokia-internal Artifactory.

### One-command sanity check

```bash
cd ~/code/gm
container/test.sh
```

This runs the full battery below in ~1 minute (plus first-time
image pull).  Exit code non-zero if anything fails.

### Step-by-step walkthrough

```bash
cd ~/code/gm

# 1. render Dockerfile only (offline, no docker daemon needed)
container/imageBuild.py render container/examples/hello/image.yaml

# 2. stage the build context (no docker build; observe what got staged)
container/imageBuild.py --no-rpms context container/examples/hello/image.yaml
find build/container/hello/context -maxdepth 3 -type f | sort
cat  build/container/hello/hello.hooks.jsonl

# 3. emit dep.json without building (still needs stage 2 first)
container/imageBuild.py --no-rpms --proj-top . deps container/examples/hello/image.yaml
cat  build/container/hello/hello.dep.json

# 4. full build (requires docker/podman)
container/imageBuild.py --proj-top . build container/examples/hello/image.yaml
docker run --rm localhost/hello:1.0.0

# 5. observe post-build dep.json (rpms[] populated from `rpm -qa`)
jq . build/container/hello/hello.dep.json

# 6. dynamic vars: same manifest, different repo URL
container/imageBuild.py --var aps_ver=99.9 --no-rpms deps container/examples/hello/image.yaml
jq '.extra.repos' build/container/hello/hello.dep.json

# 7. ad-hoc RPM query -- what's in the built image?
container/imageBuild.py query --image localhost/hello:1.0.0 vim-minimal gzip

# 8. ad-hoc RPM query -- extract yum repos from a base image, query
container/imageBuild.py query --base-image registry.access.redhat.com/ubi8/ubi-minimal:8.10 openssl

# 9. per-image versionlock: override.rpm.info -> <name>.rpm.info
cat > /tmp/override.rpm.info <<'EOF'
vim-minimal 8.0.1763 21.el8_10 x86_64
EOF
container/imageBuild.py lock --override /tmp/override.rpm.info \
                       container/examples/hello/image.yaml
cat build/container/lock/hello.rpm.info

# 10. re-build with the lock file staged into the context
container/imageBuild.py --proj-top . --rpm-lock build/container/lock/hello.rpm.info \
                  build container/examples/hello/image.yaml

# 11. check for upstream RPM updates across every cached dep.json
container/imageBuild.py check-rpm-update --dep-json-dir build/container/
# or gate CI on it:
container/imageBuild.py check-rpm-update --exit-on-updates --format json
```

### Feature-by-feature test targets

| feature | fastest verification |
|---|---|
| yaml manifest parses | `container render <manifest>` |
| dynamic `{var}` in repo URLs | `container --var K=V deps` then `jq '.extra.repos'` |
| dynamic vars from file | `container --vars <file.yaml> deps` |
| extras: with rename | see `context/` after `container context <manifest>` |
| extras: directory | same as above; `find context/` shows the tree |
| prerequisites | grep `context/prerequisites.list` and `.dep.json .rpms` |
| swappable installer | set `installer: ../custom.sh`; check `context/appDockerInstaller.sh` |
| auto-lock | `rpm_lock: {override: ..., auto: true}` in manifest → `context/versionlock.list` |
| hook trace | `cat <name>.hooks.jsonl` after any staging step |
| dep.json shape | `jq keys build/container/hello/hello.dep.json` -> `["img","rpms","deps","extra"]` |
| query --image | `container query --image <ref> [rpm ...]` |
| query --yum | `container query --yum /etc/yum.repos.d/foo.repo openssl` |
| query --base-image | `container query --base-image <ref> openssl` (needs docker) |
| lock generation | `container lock --override <file> <manifest>` |
| check-rpm-update (text) | `container check-rpm-update --dep-json-dir <dir>` |
| check-rpm-update (json) | `container check-rpm-update --format json` |

## Why redesign vs. extending the existing telecom framework

The existing `reg_container_tooling` framework is mature and
production-tested.  This subsystem is meant to:

1. Be **language-agnostic at the manifest layer** (no PodDescriptor
   schema dependence -- just plain YAML per image)
2. Be **public-base-image friendly** (works with Rocky/Fedora/UBI
   without needing Nokia-internal Artifactory)
3. Keep the **good ideas** -- the DSL, hook tracking, remote-RPM
   capture, manual override -- as named, testable modules
4. Slot into gm's `dep_query.py` natively (no wrapper)

It's not a replacement; it's a cleaner re-expression of the same
design pillars in a portable form.

## Alignment status vs. `appDockerImageBuild.py`

Reference: an internal container-build toolchain that pairs
`appDockerImageBuild.py` with a shell driver `buildAppDockerImage.sh`.

**Covered / functionally equivalent:**

| Feature | reg tool | container | Notes |
|---|---|---|---|
| Single-image manifest | `PodDescriptor.yaml` (extracted per container) | `image.yaml` | Different scope -- see "deliberately different" below |
| Version-string injection | External `version_info` file (`repo APS: rel: ver`) | `vars:` + `--var K=V` / `--vars <file>` | Same intent, cleaner serialization |
| `version_info` file into context | `printf '%s APS: %s: %s' ...` written into `dockercontext/version_info` | `emit_version_info: true` -> `context/version_info` with `key: value` lines from manifest.vars | ✓ Gate on manifest flag |
| `[RPMINSTALL]` DSL | INI section parser | Full DSL (`RPMINSTALL` / `RPMUNINSTALL` / `RUN` / `STOP`) | Superset |
| Dockerfile `yum install ...` pkg discovery | Regex over `RUN yum install` lines | Same (`parse_dockerfile_yum`) | ✓ |
| Yum repo config generation | `buildInputs/4g.in` template + version substitution | `repos:` in manifest with `{var}` placeholders | Same, cleaner locality |
| RPM versionlock (auto) | External `rpm_version_lock.list` | `override_rpms:` + auto-gen via `LockGenerator` | Superset |
| RPM versionlock (external file) | `--rpm-version-lock <file>` CLI arg | `--rpm-lock <file>` CLI arg (staged as `context/versionlock.list`) | ✓ Same knob, renamed |
| Multi-tag build | `docker build -t IMG:TAG -t REGISTRY/IMG:TAG` | `manifest.all_tags` -> `-t <registry>/<name>:<tag> -t <name>:<tag>` (+ any `extra_tags:` entries) | ✓ |
| `BUILDTIME` label | `docker build --label BUILDTIME=YYYYMMDD` | Auto-injected `BUILDTIME=$(date +%Y%m%d)`; `labels:` in manifest can add / override | ✓ |
| `--no-cache` / `--rm` build flags | Hardcoded on | `build_flags: ["--no-cache=true", "--rm"]` in manifest (this IS the default; set to `[]` to disable) | ✓ Same defaults, opt-out available |
| Base image URL / tarball auto-load | `wget URL.tgz && docker load` when `base:` is http(s) URL | `DockerBuild.resolve_base_image()`: if `base:` is `http(s)://…` OR a local `*.tar/*.tgz`, urllib-download + `docker load -i` and use the loaded tag | ✓ Also handles local tar paths |
| `install.tar` bundle | `tar -cvf dockercontext/install.tar install/` after per-image copies | `install_tar: <dir>` in manifest -> `tar -cf context/install.tar -C <dir> .` | ✓ Skips wrapper dir, tarball contents relative-to-src |
| `.dep.json` emission | `{img, rpms, deps, extra}` -> `ims_do/img/<img>.dep.json` | Same schema -> `build/container/<name>/<name>.dep.json` | ✓ Schema-compatible |
| Runtime `rpm -qa` inspection | `docker run --entrypoint /bin/rpm ...` | `RpmRuntimeResolver` (same call shape) | ✓ |
| dep-hooks JSONL trace | `parse_hooks_info` | `production/tools/dep-hooks.sh` (same jsonl format, shared with gm) | ✓ |
| Per-image special files | Hardcoded if/elif for cnsbasidecar / lcmhook / debugassist / ... | Generic `extras:` list (files + dirs, rename support) | container more general |

**Not implemented (out of scope):**

| Gap | reg tool | Why not | Where to build it |
|---|---|---|---|
| Multi-image driver from a pod-level manifest | Yes (walks each container in `PodDescriptor.POD[].container[]`) | Deliberately out of scope; keeps container focused on one image | Layer a separate `podbuild` tool that fans out to `container build image.yaml` per container in a `PodDescriptor` |

**Deliberately different:**

- **Manifest scope**: container is single-image on purpose (each `image.yaml`
  is self-describing).  Pod-level orchestration should live in a *higher*
  tool that calls `container build` per container -- keeps container focused
  on the one thing it does well.
- **Dockerfile placeholder syntax**: container accepts both `@VAR@` and
  `__VAR__` for compatibility, but recommends `@VAR@` (matches gm's
  header-generation convention).
- **Manifest location for extras**: container's `extras:` is
  intentionally uniform ("copy this file/dir into context") -- no
  per-image hardcoded logic like the shell's `copyCnsbasidecarProcess`
  / `copyLcmhookRequireFiles` / etc.  Users express the same intent
  via the manifest, per-image logic stays in the manifest, not in the
  build tool.

