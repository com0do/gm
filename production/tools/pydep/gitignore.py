"""Filter paths against `.gitignore` rules.

Ported from `production/py/change2target.py::DependencyDAG._check_ignore_batch`
with a smaller class-based API.  Delegates to `git check-ignore` so
the semantics match git itself -- no re-implementation of the ignore
rule engine.
"""

from __future__ import annotations
import subprocess
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable, List


@dataclass
class GitignoreFilter:
    """Drop paths that git considers ignored.

    Fail-open: when the repo isn't a git checkout, `filter()` returns
    its input unchanged.  Batch mode uses a single
    `git check-ignore --stdin` call so it scales.
    """
    repo_dir: Path

    def is_ignored(self, path: str) -> bool:
        try:
            r = subprocess.run(
                ["git", "-C", str(self.repo_dir), "check-ignore", "-q", path],
                capture_output=True, timeout=5,
            )
            return r.returncode == 0
        except (FileNotFoundError, subprocess.SubprocessError):
            return False

    def filter(self, paths: Iterable[str]) -> List[str]:
        paths_list = [p for p in paths if p]
        if not paths_list:
            return []
        try:
            r = subprocess.run(
                ["git", "-C", str(self.repo_dir), "check-ignore", "--stdin"],
                input   = "\n".join(paths_list),
                capture_output = True,
                text    = True,
                timeout = 30,
            )
        except (FileNotFoundError, subprocess.SubprocessError):
            return paths_list
        # `check-ignore` exits 0 when it matched, 1 when nothing matched.
        if r.returncode not in (0, 1):
            return paths_list
        ignored = {line.strip() for line in r.stdout.splitlines() if line.strip()}
        return [p for p in paths_list if p not in ignored]
