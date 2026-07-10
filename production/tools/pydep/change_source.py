"""Resolve the set of changed files for one dep-query invocation.

Two sources:
  - `from_paths(paths)`    -- explicit list, typically CLI --changes
  - `from_git(repo, ref)`  -- `git diff <ref>..HEAD --name-only`

`drop_ignored(repo_dir)` runs the collected paths through
`GitignoreFilter` so temporary / build / IDE files don't pollute
the query.
"""

from __future__ import annotations
import subprocess
import sys
from dataclasses import dataclass, field
from pathlib import Path
from typing import Iterable, List

from .gitignore import GitignoreFilter


@dataclass
class ChangeSource:
    paths: List[str] = field(default_factory=list)

    @classmethod
    def from_paths(cls, paths: Iterable[str]) -> "ChangeSource":
        return cls([p for p in paths if p])

    @classmethod
    def from_git(cls, repo_dir: Path, ref: str) -> "ChangeSource":
        try:
            out = subprocess.check_output(
                ["git", "-C", str(repo_dir), "diff", "--name-only", f"{ref}..HEAD"],
                text=True, stderr=subprocess.PIPE,
            )
        except FileNotFoundError:
            print("error: `git` not on PATH", file=sys.stderr)
            sys.exit(2)
        except subprocess.CalledProcessError as e:
            print(f"error: git diff failed: {e.stderr.strip()}", file=sys.stderr)
            sys.exit(2)
        return cls([line.strip() for line in out.splitlines() if line.strip()])

    def drop_ignored(self, repo_dir: Path) -> "ChangeSource":
        self.paths = GitignoreFilter(repo_dir).filter(self.paths)
        return self

    def __bool__(self) -> bool:
        return bool(self.paths)

    def __iter__(self):
        return iter(self.paths)
