#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""elf-rpath.py --buildroot DIR --marker STR [--marker STR ...]

Exes are linked with an RPATH that is relative to the BUILD tree
(target.common.mk), which means nothing inside a package.  For every ELF under
DIR whose RPATH / RUNPATH contains one of the markers, rewrite it in place to
$ORIGIN-relative entries for each directory under DIR that holds shared
objects ($ORIGIN alone if there are none).  The new string is written over the
old one (it must fit; a build-tree path is always longer)."""

from __future__ import annotations

import argparse
import os
import re
import struct
import sys
from pathlib import Path

PT_LOAD, PT_DYNAMIC = 1, 2
DT_NULL, DT_STRTAB, DT_RPATH, DT_RUNPATH = 0, 5, 15, 29


def rpath_slots(data: bytes) -> list[tuple[int, int]]:
    """(file offset, length) of every RPATH / RUNPATH string; [] for anything
    that is not a 64-bit little-endian ELF."""
    if data[:4] != b"\x7fELF" or data[4] != 2 or data[5] != 1:
        return []
    (phoff,) = struct.unpack_from("<Q", data, 0x20)
    phentsize, phnum = struct.unpack_from("<HH", data, 0x36)
    loads: list[tuple[int, int, int]] = []
    dyn: tuple[int, int] | None = None
    for i in range(phnum):
        ptype, _fl, off, vaddr, _pa, filesz, _ms, _al = struct.unpack_from("<IIQQQQQQ", data, phoff + i * phentsize)
        if ptype == PT_LOAD:
            loads.append((vaddr, off, filesz))
        elif ptype == PT_DYNAMIC:
            dyn = (off, filesz)
    if dyn is None:
        return []
    strtab: int | None = None
    names: list[int] = []
    for off in range(dyn[0], dyn[0] + dyn[1], 16):
        tag, val = struct.unpack_from("<qQ", data, off)
        if tag == DT_NULL:
            break
        if tag == DT_STRTAB:
            strtab = val
        elif tag in (DT_RPATH, DT_RUNPATH):
            names.append(val)
    if strtab is None:
        return []
    base = None
    for vaddr, off, filesz in loads:
        if vaddr <= strtab < vaddr + filesz:
            base = strtab - vaddr + off
            break
    if base is None:
        return []
    slots = []
    for name in names:
        start = base + name
        slots.append((start, data.index(b"\0", start) - start))
    return slots


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--buildroot", required=True)
    ap.add_argument("--marker", action="append", default=[], help="substring identifying a build-tree RPATH")
    args = ap.parse_args(argv)
    if not args.marker:
        return 0
    root = Path(args.buildroot)
    elfs = [p for p in sorted(root.rglob("*"))
            if p.is_file() and not p.is_symlink() and p.open("rb").read(4) == b"\x7fELF"]
    libdirs = sorted({str(p.parent.relative_to(root)) for p in elfs if re.search(r"\.so(\.|$)", p.name)})
    for path in elfs:
        data = path.read_bytes()
        exedir = str(path.parent.relative_to(root))
        patches = []
        for start, length in rpath_slots(data):
            old = data[start:start + length].decode(errors="replace")
            if not any(m in old for m in args.marker):
                continue
            rels = (os.path.relpath(d, exedir) for d in libdirs)
            new = ":".join("$ORIGIN" + ("" if r == "." else "/" + r) for r in rels) or "$ORIGIN"
            if len(new) > length:
                print(f"elf-rpath: {path}: new RPATH '{new}' does not fit, left alone", file=sys.stderr)
                continue
            patches.append((start, new.encode() + b"\0"))
        if patches:
            with path.open("r+b") as f:
                for start, blob in patches:
                    f.seek(start)
                    f.write(blob)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
