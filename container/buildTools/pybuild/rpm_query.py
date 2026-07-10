"""Query the RPMs actually installed inside a built image.

Two strategies (both explored by reg_container_tooling's design doc
section 1.3.1):

  (A) `docker run --rm --entrypoint /bin/rpm <img> -qa --qf ...`
      Runs `rpm -qa` inside the container.  Works with Docker + Podman.
      Slow if the image is large (multi-GB pull/start).  We use this
      one -- it's the reg framework's fallback and the most portable
      of the options that were tried.

  (B) Add `RUN rpm -qa` to the Dockerfile with `==== RPM_LIST_START ====`
      markers, then grep the build log.  Slightly faster (no separate
      `docker run`) but only works if we control the Dockerfile
      template AND capture the build log.  Not implemented here yet.

The list of "declared" RPM names (from installGuide.in + Dockerfile
`yum install`) is used as a *filter* -- we return only the RPMs the
manifest actually asked for, not the entire base-image contents.
"""

from __future__ import annotations
import re
import subprocess
from dataclasses import dataclass

from .rpms import RpmInfo


_DOCKERFILE_YUM_RE = re.compile(r"yum\s+install\s+(.+?)(?:&&|$)", re.IGNORECASE)


def parse_dockerfile_yum(dockerfile_text: str) -> list[str]:
    """Extract package names from `RUN yum install <pkg1> <pkg2>` lines.

    Escaped newlines (`\\<newline>`) are joined first so multi-line
    `RUN yum install a \\\n b \\\n c` still collapses to one string.
    """
    text = dockerfile_text.replace("\\\n", " ")
    out: list[str] = []
    for line in text.split("\n"):
        m = _DOCKERFILE_YUM_RE.search(line)
        if m:
            for tok in m.group(1).split():
                if tok and not tok.startswith("-"):
                    out.append(tok)
    return out


def query_installed_rpms(image_ref: str, docker_bin: str = "docker") -> list[RpmInfo]:
    """Return every RPM installed in the image (unfiltered)."""
    cmd = [
        docker_bin, "run", "--rm", "--entrypoint", "/bin/rpm",
        image_ref, "-qa", "--qf",
        "%{NAME} %{VERSION} %{RELEASE} %{ARCH}\n",
    ]
    try:
        p = subprocess.run(cmd, capture_output=True, text=True, timeout=120)
    except subprocess.TimeoutExpired:
        return []
    if p.returncode != 0:
        return []
    out: list[RpmInfo] = []
    for line in p.stdout.splitlines():
        parts = line.split()
        if len(parts) == 4:
            out.append(RpmInfo(name=parts[0], version=parts[1],
                               release=parts[2], arch=parts[3]))
    return out


def filter_declared(installed: list[RpmInfo], declared: set[str]) -> list[RpmInfo]:
    """Keep only the RpmInfo entries whose name is in `declared`."""
    return [r for r in installed if r.name in declared]


@dataclass
class RpmRuntimeResolver:
    """End-to-end RPM resolution for a built image.

    Pipeline:
      1. `declared` = union(installGuide's [RPMINSTALL], Dockerfile yum install)
      2. `installed` = every RPM currently in the built image (rpm -qa)
      3. Return installed ∩ declared
      4. Apply manifest overrides (they win over the observed versions)
    """
    image_ref:    str
    declared:     set[str]
    docker_bin:   str = "docker"

    def resolve(self) -> list[RpmInfo]:
        installed = query_installed_rpms(self.image_ref, self.docker_bin)
        return filter_declared(installed, self.declared)
