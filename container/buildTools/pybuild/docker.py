"""Thin wrapper around `docker build`.

Responsibilities:
  - Invoke docker build against a staged context dir
  - Tag the resulting image with EVERY tag `manifest.all_tags` returns
    (canonical `<registry>/<name>:<tag>` + short `<name>:<tag>` + any
    `extra_tags:` from the manifest -- matches reg's
    `docker build -t IMG:TAG -t REGISTRY/IMG:TAG` convention)
  - Emit build-time labels (BUILDTIME=YYYYMMDD + anything in
    `manifest.labels`)
  - Apply `manifest.build_flags` (default: `--no-cache=true --rm` to
    match reg's `buildAppDockerImage.sh`)
  - Optionally write the image-id (sha256) to `<out_dir>/<name>.id`
  - Optionally sniff a URL/tarball base image and `docker load` it
    before building (matches reg's `downloadBaseImage`)
  - Surface errors with a clear message

Supports podman-as-docker too (the binary is just `docker` either way).
"""

from __future__ import annotations
import datetime
import re
import shutil
import subprocess
import tempfile
import urllib.request
from dataclasses import dataclass
from pathlib import Path

from .manifest import Manifest


@dataclass
class DockerBuild:
    manifest:   Manifest
    context:    Path                                # the staged build context
    iid_file:   Path | None       = None            # write image-id here
    extra_args: list[str] | None  = None            # ad-hoc CLI overrides
    docker_bin: str               = "docker"
    # Optional: mutated by `resolve_base_image()` when the base is a URL
    # or a local tarball we `docker load`-ed.  Kept separate from
    # `manifest.base` so we don't mutate the manifest.
    resolved_base: str | None     = None

    def run(self) -> str:
        """Build the image.  Returns the image id (sha256:...)."""
        if shutil.which(self.docker_bin) is None:
            raise RuntimeError(f"{self.docker_bin} not found in PATH")

        if self.iid_file:
            self.iid_file.parent.mkdir(parents=True, exist_ok=True)

        cmd: list[str] = [self.docker_bin, "build"]

        # Every tag docker should apply to the resulting image.
        for tag in self.manifest.all_tags:
            cmd += ["-t", tag]

        # Labels.  BUILDTIME is auto-injected (reg convention:
        # `--label BUILDTIME=${TIMESTAMP}` where TIMESTAMP=$(date +%Y%m%d)).
        # User-supplied labels win if BUILDTIME is redeclared.
        labels: dict[str, str] = {"BUILDTIME": datetime.date.today().strftime("%Y%m%d")}
        labels.update(self.manifest.labels)
        for k, v in labels.items():
            cmd += ["--label", f"{k}={v}"]

        # iidfile: docker writes `sha256:<hex>` to this path.
        if self.iid_file:
            cmd += ["--iidfile", str(self.iid_file)]

        # Manifest-declared build flags (default: --no-cache=true --rm),
        # then ad-hoc CLI flags (typically empty -- reserved for tests).
        cmd += list(self.manifest.build_flags)
        cmd += (self.extra_args or [])

        cmd += [str(self.context)]

        subprocess.run(cmd, check=True)

        return self.iid_file.read_text().strip() if self.iid_file else ""

    # ------------------------------------------------------------------
    # Base-image auto-load
    # ------------------------------------------------------------------
    def resolve_base_image(self) -> str:
        """If `manifest.base` looks like a URL to a tarball or a local
        `*.tar` / `*.tgz` / `*.tar.gz` path, download+`docker load` it
        and return the loaded image tag.  Otherwise return the base as-is.

        Matches reg's `downloadBaseImage()` in `buildAppDockerImage.sh`:
        `wget URL && tar --to-stdout -xf FILE | docker load`.  We do the
        equivalent with urllib+tempfile so it works without wget too.

        The resolved tag is what the Dockerfile's `FROM @IMG_BASE@` (or
        `__URL_OF_MIDDLEWARE_BASE_IMAGE__`) placeholder should expand to;
        the caller is expected to substitute BEFORE rendering the
        Dockerfile.  Idempotent: repeated calls return the same tag."""
        if self.resolved_base is not None:
            return self.resolved_base

        base = self.manifest.base
        looks_url  = base.startswith(("http://", "https://", "ftp://"))
        looks_file = (not looks_url) and Path(base).exists() and \
                     base.endswith((".tar", ".tgz", ".tar.gz"))
        if not (looks_url or looks_file):
            self.resolved_base = base
            return base

        # Pull the tarball into a local temp file (or reference the local
        # one directly), then `docker load` it and parse the "Loaded
        # image: <repo:tag>" reply.
        if looks_url:
            tmp = tempfile.NamedTemporaryFile(suffix=".tar", delete=False)
            try:
                with urllib.request.urlopen(base) as resp:
                    shutil.copyfileobj(resp, tmp)
                tmp.close()
                loaded = self._docker_load(Path(tmp.name))
            finally:
                Path(tmp.name).unlink(missing_ok=True)
        else:
            loaded = self._docker_load(Path(base))

        self.resolved_base = loaded
        return loaded

    def _docker_load(self, tar_path: Path) -> str:
        """`docker load -i <tar>` -> parse 'Loaded image: repo:tag'.
        Docker's `load` transparently decompresses gzip/bzip2/xz
        archives, so we don't need to run zcat ourselves.  Returns the
        tag docker reports; raises if none is emitted."""
        proc = subprocess.run(
            [self.docker_bin, "load", "-i", str(tar_path)],
            capture_output=True, text=True,
        )
        if proc.returncode != 0:
            raise RuntimeError(
                f"docker load failed for {tar_path}: {proc.stderr.strip()}")

        # Docker prints one or more `Loaded image: <ref>` lines.  Take
        # the last (typically only) one.
        m = re.findall(r"Loaded image:\s+(\S+)", proc.stdout)
        if not m:
            raise RuntimeError(
                f"docker load did not emit a 'Loaded image:' line for "
                f"{tar_path} -- stdout was: {proc.stdout.strip()!r}")
        return m[-1]
