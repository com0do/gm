#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""jar-normalize.py JAR EPOCH -- rewrite JAR in place with fixed entry mtimes
(UTC, from EPOCH) and a stable entry order, so the same classes always give
the same jar (reproducible builds; `jar` stamps META-INF with the clock)."""

from __future__ import annotations

import os
import sys
import time
import zipfile


def normalize(path: str, epoch: int) -> None:
    stamp = time.gmtime(max(epoch, 315532800))[:6]  # zip dates start at 1980
    tmp = path + ".tmp"
    with zipfile.ZipFile(path) as src, zipfile.ZipFile(tmp, "w", zipfile.ZIP_DEFLATED) as dst:
        names = sorted(src.namelist(), key=lambda n: (n != "META-INF/", n != "META-INF/MANIFEST.MF", n))
        for name in names:
            info = zipfile.ZipInfo(name, stamp)
            info.create_system = 3
            info.compress_type = zipfile.ZIP_DEFLATED
            info.external_attr = (0o40755 << 16) | 0x10 if name.endswith("/") else 0o100644 << 16
            dst.writestr(info, src.read(name))
    os.replace(tmp, path)


def main(argv: list[str]) -> int:
    if len(argv) != 3 or not argv[2].isdigit():
        print(__doc__, file=sys.stderr)
        return 2
    normalize(argv[1], int(argv[2]))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
