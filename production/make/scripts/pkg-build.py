#!/usr/bin/env python3
"""
pkg-build.py -- compile a pkg spec (YAML) into rpmbuild inputs.

Requires Python 3.12+.  Hard deps: PyYAML, jsonschema.  There is no
XML backend and no lxml dependency; the schema at
`production/make/schemas/pkg.schema.yaml` is the canonical data model
for a gm package.

Input:  --pkg <path-to-pkg.yaml>
Outputs (any combination):
    --manifest-out PATH       manifest.json for downstream tools
    --spec-out     PATH       auto-generated rpmbuild .spec (no %build)
    --header-out   PATH       component.h with pkg-identity #defines
    --alarms-out   DIR        alarms.h + alarms.cxx from <alarms>
    --print-intree-targets X  short-circuit for target.pkg.mk DRY_RUN

The schema owns the vocabulary: pkg_type enum, filegroup_map defaults,
install_root default, severity enum, etc.  Editing conventions is a
schema edit, not a code edit.
"""

import argparse
import copy
import json
import os
import re
import sys
from dataclasses import dataclass, field
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

def _dep_or_die(mod_name: str, pip_name: str | None = None) -> Any:
    """Import a hard dep; if missing, print an install hint tailored to
    the interpreter's context (venv vs. system).  Any tool that shells
    out to pkg-build.py -- rpmbuild recipe, alarm shim -- shows a
    single-line, actionable error instead of a bare traceback."""
    try:
        return __import__(mod_name)
    except ImportError:
        pass
    pip_name = pip_name or mod_name
    in_venv  = sys.prefix != sys.base_prefix
    py       = sys.executable
    hint     = f"{py} -m pip install {pip_name}"
    tail = (" (inside your active venv; do NOT use --user)" if in_venv
            else " --user  (or without --user for system-wide)")
    print(
        f"pkg-build: missing Python dep '{mod_name}'.\n"
        f"    fix:  {hint}{tail}\n"
        f"    python: {py}  ({'venv' if in_venv else 'system'})",
        file=sys.stderr,
    )
    sys.exit(2)


yaml = _dep_or_die("yaml", "PyYAML")

# jsonschema is heavy (~1.4s cold on Python 3.12: it pulls
# `rfc3987_syntax` for URI-format validation).  We import it LAZILY so
# the DRY_RUN fast path (`--print-intree-targets`, which just needs
# yaml.safe_load) doesn't pay for it: three YAML-mode pkg targets in
# a fresh depend.mk scan used to eat ~5s here, now they eat ~0.3s.
# The full spec/manifest/header path still validates as before.


########################################################################
# Type aliases (PEP 695) + schema loading
########################################################################

type VarMap = dict[str, str]
type FilegroupEntry = dict[str, str]
type FilegroupMap = dict[str, FilegroupEntry]

SCHEMA_PATH = Path(__file__).resolve().parent.parent / "schemas" / "pkg.schema.yaml"

_VALIDATOR: Any = None  # populated on first _validate_config() call


def _ensure_validator() -> Any:
    """Import jsonschema + build the defaults-filling validator on
    first use.  Idempotent; subsequent calls are ~0 overhead."""
    global _VALIDATOR
    if _VALIDATOR is not None:
        return _VALIDATOR

    _dep_or_die("jsonschema")
    from jsonschema import Draft202012Validator, validators

    def _fill_defaults(validator_class: Any) -> Any:
        """Extend a jsonschema validator so `default:` keywords are
        materialised into the instance during validation.  Per the
        JSON Schema spec `default` is annotative, not normative; this
        is the well-known extension pattern from jsonschema's docs."""
        validate_properties = validator_class.VALIDATORS["properties"]

        def set_defaults(validator, properties, instance, schema):
            if isinstance(instance, dict):
                for prop, subschema in properties.items():
                    if "default" in subschema and prop not in instance:
                        instance[prop] = copy.deepcopy(subschema["default"])
            yield from validate_properties(validator, properties, instance, schema)

        return validators.extend(validator_class, {"properties": set_defaults})

    with SCHEMA_PATH.open() as _schema_fp:
        schema: dict[str, Any] = yaml.safe_load(_schema_fp)
    Draft202012Validator.check_schema(schema)
    _VALIDATOR = _fill_defaults(Draft202012Validator)(schema)
    return _VALIDATOR


def _validate_config(cfg: dict[str, Any]) -> dict[str, Any]:
    """Mutating validate: fill schema defaults, then error on any
    remaining schema violation.  Returns the same dict for chaining."""
    validator = _ensure_validator()
    errors = sorted(validator.iter_errors(cfg), key=lambda e: list(e.absolute_path))
    if errors:
        lines = [f"pkg-build: config invalid per {SCHEMA_PATH.name}:"]
        for e in errors:
            path = "/".join(str(p) for p in e.absolute_path) or "(root)"
            lines.append(f"  {path}: {e.message}")
        raise SystemExit("\n".join(lines))
    return cfg


########################################################################
# Data model -- fed by the validated YAML into the renderers below
########################################################################

@dataclass
class PkgFile:
    src: str             # absolute source path (after $VAR substitution)
    dest: str            # absolute install path under buildroot
    mode: str            # octal string, e.g. "0555"
    owner: str
    group: str
    filegroup: str       # original filegroup name (for diagnostics)


@dataclass
class Component:
    name:          str = ""
    major_version: str = "1"
    minor_version: str = "0"
    id:            str = ""
    comp_type:     str = ""


@dataclass
class Alarm:
    """One entry from a pkg's `alarms:` list."""
    name:                str = ""
    number:              str = "0"
    alarm_type:          str = ""
    severity:            str = ""
    suppression_time:    str = ""
    corr_specifier:      str = ""
    short_text:          str = ""
    long_text:           str = ""
    repair_text:         str = ""


@dataclass
class Manifest:
    pkg: str
    version: str
    release: str
    description: str
    pkg_type: str
    components: list[str]
    rpm_deps: list[str]
    files: list[PkgFile]
    install_root: str
    component: Component = field(default_factory=Component)
    unresolved_vars: list[str] = field(default_factory=list)


########################################################################
# $VAR / ${VAR} substitution
########################################################################

_VAR_RE = re.compile(r"\$\{([A-Za-z_][A-Za-z0-9_]*)\}|\$([A-Za-z_][A-Za-z0-9_]*)")

# Names that always pass through unresolved without a warning.  `schema`
# is the yaml-language-server LSP directive marker
# (`# yaml-language-server: $schema=path.yaml`); we want that line to
# survive intact and NOT show up as a phantom unresolved-var complaint.
_SUBST_PASSTHROUGH: frozenset[str] = frozenset({"schema"})


def _substitute(text: str, mapping: VarMap, unresolved: list[str]) -> str:
    """Expand $NAME and ${NAME} in `text`.  Unknown names are
    recorded in `unresolved` (deduped by the caller) and left in
    place -- caller decides whether that's fatal."""
    if not text:
        return text

    def _sub(match: re.Match) -> str:
        name = match.group(1) or match.group(2)
        if name in mapping:
            return mapping[name]
        if name not in _SUBST_PASSTHROUGH:
            unresolved.append(name)
        return match.group(0)

    return _VAR_RE.sub(_sub, text)


def _parse_vars(pairs: list[str]) -> VarMap:
    """Turn --vars KEY=VALUE strings into a dict.  Repeatable; later wins."""
    out: VarMap = {}
    for pair in pairs:
        if "=" not in pair:
            raise SystemExit(f"pkg-build: --vars entry {pair!r} missing '='")
        k, v = pair.split("=", 1)
        out[k.strip()] = v
    return out


########################################################################
# YAML loader
########################################################################

def _load_pkg_yaml(path: Path, mapping: VarMap, unresolved: list[str]) -> dict[str, Any]:
    """Read pkg.yaml, substitute $VARs in the raw text, parse.
    Substituting on raw text is deliberate: some fields (e.g.
    `src: $GM_LIB_DIR/libt2.so`) reference the same placeholders used
    across the tree; single-pass substitution keeps the semantics
    uniform whether the value shows up as a string, a key, or inside
    a long-form multiline scalar."""
    try:
        raw = path.read_text(encoding="utf-8")
    except OSError as exc:
        raise SystemExit(f"pkg-build: cannot read {path}: {exc}")
    substituted = _substitute(raw, mapping, unresolved)
    try:
        data = yaml.safe_load(substituted)
    except yaml.YAMLError as exc:
        raise SystemExit(f"pkg-build: YAML parse error in {path}: {exc}")
    if not isinstance(data, dict):
        raise SystemExit(f"pkg-build: {path} must be a YAML mapping at top level, got {type(data).__name__}")
    return data


########################################################################
# Config -> Manifest
########################################################################

def _resolve_pkg_file(
    entry: str | dict[str, Any],
    filegroup_name: str,
    filegroup_map: FilegroupMap,
    filegroup_fallback: FilegroupEntry,
    install_root: str,
) -> PkgFile:
    """Turn one entry under ``files.<filegroup_name>[]`` into a PkgFile.

    `entry` is either a plain src string (short form: filegroup defaults
    apply for mode/owner/group) or an object ``{src, mode?, owner?,
    group?}`` (long form: any declared field overrides the filegroup
    default for this one file).  `filegroup_name` comes from the parent
    key -- it is NEVER repeated inside the object form."""
    if isinstance(entry, str):
        src: str = entry
        overrides: dict[str, Any] = {}
    else:
        src = entry["src"]
        overrides = entry

    fg = filegroup_map.get(filegroup_name, filegroup_fallback)
    name = os.path.basename(src.rstrip("/"))
    dest_subdir = fg["dir"].strip("/")
    dest_dir = f"{install_root.rstrip('/')}/{dest_subdir}" if dest_subdir else install_root.rstrip("/")
    dest = f"{dest_dir}/{name}"

    return PkgFile(
        src=src,
        dest=dest,
        mode=overrides.get("mode")  or fg["mode"],
        owner=overrides.get("owner") or fg["owner"],
        group=overrides.get("group") or fg["group"],
        filegroup=filegroup_name,
    )


def _build_manifest(cfg: dict[str, Any], args: argparse.Namespace,
                    unresolved: list[str]) -> Manifest:
    """Assemble a Manifest from the validated pkg config + CLI overrides.
    All defaults have already been filled by _validate_config, so this
    function reads without any `or "..."` fallbacks."""
    fg_map: FilegroupMap = cfg["filegroup_map"]
    fg_fallback: FilegroupEntry = cfg["filegroup_fallback"]
    install_root: str = cfg["install_root"]

    files: list[PkgFile] = []
    for filegroup_name, entries in cfg["files"].items():
        for entry in entries:
            files.append(_resolve_pkg_file(entry, filegroup_name,
                                           fg_map, fg_fallback, install_root))

    comp_dict = cfg["component"]
    component = Component(
        name=comp_dict["name"],
        id=comp_dict["id"],
        major_version=comp_dict["major_version"],
        minor_version=comp_dict["minor_version"],
        comp_type=comp_dict["comp_type"],
    )

    version = args.version or f"{cfg['major']}.{cfg['minor']}"
    return Manifest(
        pkg=cfg["pkg"],
        version=version,
        release=args.release,
        description=cfg["description"],
        pkg_type=cfg["pkg_type"],
        components=[component.name] if component.name else [],
        rpm_deps=sorted(set(cfg["rpm_deps"])),
        files=files,
        install_root=install_root,
        component=component,
        unresolved_vars=sorted(set(unresolved)),
    )


def _build_alarms(cfg: dict[str, Any]) -> list[Alarm]:
    """`alarms:` list -> Alarm dataclasses.  Schema has already filled
    every optional field, so this is a straight dict-to-dataclass copy."""
    return [Alarm(**a) for a in cfg["alarms"]]


########################################################################
# .spec generation
########################################################################

# Spec template.  Deliberately has NO %build section: make owns the
# build phase (that's how we retain full dep-tracking authority).  A
# %build here would run inside rpmbuild's private shell and escape our
# instrumentation entirely.  Only %install (staging into buildroot) and
# %files (payload manifest) are emitted.
SPEC_TEMPLATE = """\
Summary:        {summary}
Name:           {name}
Version:        {version}
Release:        {release}%{{?dist}}
License:        Proprietary
Group:          Networking
BuildArch:      {arch}
AutoReqProv:    no
Prefix:         {install_root}
{requires_lines}\

%description
{description_body}

%global __strip /bin/true

# Auto-generated -- do NOT hand-edit.  make owns build; this spec only
# stages already-built artefacts into the buildroot and lists them.

%install
{install_body}

%files
%defattr(-,bin,bin)
{files_body}

%pre

%post

%preun

%postun

%changelog
* {changelog_date} pkg-build auto-generated - {version}-{release}
- Generated from pkg.yaml
"""


def _render_spec(m: Manifest, arch: str) -> str:
    """Emit an rpmbuild-consumable .spec that stages already-built
    artefacts into %{buildroot} straight from their absolute source
    paths.  Absolute paths matter: pkgdeps.py reads the rpmbuild log's
    `+ install /abs/src /buildroot/dst` lines to recover deps, so
    hiding sources behind %{_sourcedir}/<basename> would break the
    log-based capture."""
    requires_lines = "".join(f"Requires:       {d}\n" for d in m.rpm_deps)

    # Legacy '!!!' prefix that some upstream .spec templates carried; strip.
    body = m.description or f"RPM package {m.pkg}"
    body_lines = [ln.lstrip("!") for ln in body.splitlines()] or [body]

    dest_dirs = sorted({os.path.dirname(f.dest) for f in m.files})
    install_lines: list[str] = ["set -x"]
    for d in dest_dirs:
        install_lines.append(f"mkdir -p %{{buildroot}}{d}")
    for f in m.files:
        install_lines.append(
            f"install -m {f.mode} {f.src} %{{buildroot}}{f.dest}"
        )

    files_lines = [
        f"%attr({f.mode},{f.owner},{f.group}) {f.dest}"
        for f in m.files
    ]

    return SPEC_TEMPLATE.format(
        summary=m.description or f"RPM package {m.pkg}",
        name=m.pkg,
        version=m.version,
        release=m.release,
        arch=arch,
        install_root=m.install_root,
        requires_lines=requires_lines,
        description_body="\n".join(body_lines),
        install_body="\n".join(install_lines),
        files_body="\n".join(files_lines),
        changelog_date=datetime.now(timezone.utc).strftime("%a %b %d %Y"),
    )


########################################################################
# Alarm .h + .cxx rendering (mirrors reference-project's alarm framework)
########################################################################

def _c_ident(name: str) -> str:
    """Turn any string into a valid C identifier (upper-case).
    `pkg-p2` -> `PKG_P2`."""
    return re.sub(r"[^A-Za-z0-9_]", "_", name).upper()


def _alarm_ns(pkg: str) -> str:
    """C++ namespace for a pkg's alarms.  `pkg-p2` -> `gm_alarms_pkg_p2`."""
    return f"gm_alarms_{_c_ident(pkg).lower()}"


def _alarm_enumerator(name: str) -> str | None:
    """Turn an alarm's Name into a C++ enumerator.  `P2ConfigMissing`
    -> `kP2ConfigMissing`; non-identifier chars collapse to underscore;
    returns None to skip when the name is empty / leads with a digit."""
    stripped = re.sub(r"[^A-Za-z0-9_]", "_", name)
    if not stripped or stripped[0].isdigit():
        return None
    return f"k{stripped}"


def _render_alarms_header(alarms: list[Alarm], pkg: str, component: Component) -> str:
    """Header describing the `alarms[]` table + a `kName = number`
    enum.  Consumers `#include` this and either walk the table or
    reference kFooAlarm by name."""
    ns = _alarm_ns(pkg)
    lines: list[str] = []
    lines.append("/*")
    lines.append(" * Auto-generated by pkg-build.py --alarms-out -- DO NOT EDIT.")
    lines.append(f" * Source: alarms[] of {component.name or pkg}'s pkg.yaml.")
    lines.append(f" * Emitted: {datetime.now(timezone.utc).isoformat(timespec='seconds')}")
    lines.append(" */")
    lines.append("#pragma once")
    lines.append("")
    lines.append("#include <cstddef>  /* size_t */")
    lines.append("")
    lines.append(f"namespace {ns} {{")
    lines.append("")
    lines.append("struct AlarmDef {")
    lines.append("    const char* name;")
    lines.append("    unsigned    number;")
    lines.append('    const char* type;         /* e.g. "PROCESSING", "EQUIPMENT" */')
    lines.append('    const char* severity;     /* e.g. "WARNING", "MAJOR" */')
    lines.append("    const char* short_text;")
    lines.append("    const char* long_text;")
    lines.append("    const char* repair_text;")
    lines.append("    unsigned    suppression_time;")
    lines.append("    unsigned    corr_specifier;")
    lines.append("};")
    lines.append("")
    lines.append("extern const AlarmDef alarms[];")
    lines.append("extern const size_t    alarms_count;")
    lines.append("")
    lines.append("/* Numeric IDs -- match the AlarmNumber attribute in the CD XML. */")
    lines.append("enum : unsigned {")
    for a in alarms:
        ident = _alarm_enumerator(a.name)
        if ident:
            lines.append(f"    {ident:<32} = {a.number},")
    lines.append("};")
    lines.append("")
    lines.append(f"}}  /* namespace {ns} */")
    lines.append("")
    return "\n".join(lines)


def _render_alarms_cxx(alarms: list[Alarm], pkg: str, component: Component,
                       header_include: str) -> str:
    """Compilation unit with the `alarms[]` definitions.  Includes the
    matching alarms.h so type declarations stay in one place.  The
    `extern const AlarmDef alarms[]` definition explicitly opts into
    external linkage -- namespace-scope `const` has internal linkage
    in C++ and would be DCE'd at -O2 when nothing in the same TU
    references it (killing the .so's payload)."""
    ns = _alarm_ns(pkg)
    lines: list[str] = []
    lines.append("/*")
    lines.append(" * Auto-generated by pkg-build.py --alarms-out -- DO NOT EDIT.")
    lines.append(f" * Source: alarms[] of {component.name or pkg}'s pkg.yaml.")
    lines.append(f" * Emitted: {datetime.now(timezone.utc).isoformat(timespec='seconds')}")
    lines.append(" */")
    lines.append("")
    lines.append(f'#include "{header_include}"')
    lines.append("")
    lines.append(f"namespace {ns} {{")
    lines.append("")
    lines.append("// Field order matches struct AlarmDef in alarms.h:")
    lines.append("//   name, number, type, severity, short_text, long_text,")
    lines.append("//   repair_text, suppression_time, corr_specifier")
    lines.append("extern const AlarmDef alarms[] = {")

    def _escape(s: str) -> str:
        """C-string escaping; also collapses runs of whitespace so a
        YAML block scalar (`long_text: |\n  ...`) stays readable."""
        s = re.sub(r"\s+", " ", s.strip())
        return s.replace("\\", "\\\\").replace('"', '\\"')

    for a in alarms:
        # Positional (not designated) init -- designated init in aggregate
        # requires C++20 (via P0329), but pkg-build.py's output has to
        # compile under gm's C++17 default.  Order matches struct.
        lines.append("    {")
        lines.append(f'        "{a.name}",')
        lines.append(f'        {a.number},')
        lines.append(f'        "{_escape(a.alarm_type)}",')
        lines.append(f'        "{_escape(a.severity)}",')
        lines.append(f'        "{_escape(a.short_text)}",')
        lines.append(f'        "{_escape(a.long_text)}",')
        lines.append(f'        "{_escape(a.repair_text)}",')
        lines.append(f'        {a.suppression_time or 0},')
        lines.append(f'        {a.corr_specifier or 0},')
        lines.append("    },")
    lines.append("};")
    lines.append("")
    lines.append("extern const size_t alarms_count = sizeof(alarms) / sizeof(alarms[0]);")
    lines.append("")
    lines.append(f"}}  /* namespace {ns} */")
    lines.append("")
    return "\n".join(lines)


ALARMS_HEADER_NAME = "alarms.h"
ALARMS_CXX_NAME    = "alarms.cxx"


def _emit_alarms(alarms: list[Alarm], manifest: Manifest, out_dir: Path) -> None:
    """Write `alarms.h` + `alarms.cxx` into `out_dir`; both files ship
    as a pair by construction (the .cxx `#include`s the .h)."""
    out_dir.mkdir(parents=True, exist_ok=True)
    header_out = out_dir / ALARMS_HEADER_NAME
    cxx_out    = out_dir / ALARMS_CXX_NAME
    header_out.write_text(
        _render_alarms_header(alarms, manifest.pkg, manifest.component),
        encoding="utf-8",
    )
    cxx_out.write_text(
        _render_alarms_cxx(alarms, manifest.pkg, manifest.component, ALARMS_HEADER_NAME),
        encoding="utf-8",
    )
    print(f"pkg-build: wrote {len(alarms)} alarm(s) for {manifest.pkg} "
          f"-> {cxx_out} + {header_out}")


########################################################################
# component.h -- pkg identity #defines compiled into consumer libs
########################################################################

def _pkg_prefix(pkg_name: str) -> str:
    """Derive the macro prefix used for this pkg's component.h.

    Convention: last dot-or-hyphen segment of the pkg name, uppercased.
      pkg-p2                       -> P2
      pkg-alpha                    -> ALPHA
      group-name                   -> NAME
      Component.HssServer.pcgw     -> PCGW"""
    tail = re.split(r"[-.]", pkg_name)[-1] or pkg_name
    return re.sub(r"[^A-Za-z0-9_]", "_", tail).upper()


def _render_component_header(m: Manifest) -> str:
    """component.h: compile-time metadata (name, id, version) as
    prefixed #defines.  Consumers `#include <pkg-p2/component.h>` +
    reference P2_PKG_VERSION / P2_NAME / etc.

    No unprefixed aliases -- would silently collide when a second pkg
    starts sharing the same lib.  Multi-pkg consumers reference
    `P1_NAME` alongside `P2_NAME` without any ambiguity.

    The `pkg-xml prefix: <PREFIX>` marker line is load-bearing:
    make-versionstamp.sh grep's it out to discover the prefix without
    re-parsing the yaml.  Do NOT rename it without updating that script."""
    prefix = _pkg_prefix(m.pkg)

    # UNIQUE_COMPONENT_ID: strip non-digits, then leading zeros so C
    # doesn't parse the literal as octal.
    id_digits = re.sub(r"\D", "", m.component.id).lstrip("0") or "0"

    lines: list[str] = []
    lines.append("/*")
    lines.append(" * Auto-generated by pkg-build.py -- do NOT hand-edit.")
    lines.append(f" * pkg-build source: {m.pkg}")
    lines.append(f" * Emitted: {datetime.now(timezone.utc).isoformat(timespec='seconds')}")
    lines.append(" */")
    lines.append("")
    lines.append(f"#ifndef COMPONENT_H_{prefix}_INCLUDED")
    lines.append(f"#define COMPONENT_H_{prefix}_INCLUDED")
    lines.append("")
    lines.append(f"/* pkg-xml prefix: {prefix}   -- ")
    lines.append(" * DO NOT reformat this marker; make-versionstamp.sh")
    lines.append(" * grep's the prefix out of it. */")
    lines.append("")

    if m.component.name:
        lines.append("/* Component identity (from pkg.yaml's `component:` block) */")
        lines.append(f'#define {prefix}_NAME                "{m.component.name}"')
        lines.append(f'#define {prefix}_ID                  "{m.component.id}"')
        lines.append(f'#define {prefix}_COMP_TYPE           "{m.component.comp_type}"')
        lines.append("")
        lines.append("/* Component version */")
        lines.append(f"#define {prefix}_MAJOR_VERSION       {m.component.major_version}")
        lines.append(f"#define {prefix}_MINOR_VERSION       {m.component.minor_version}")
        lines.append(f"#define {prefix}_UNIQUE_COMPONENT_ID {id_digits}LL")
        lines.append("")
    lines.append("/* RPM-level identity */")
    lines.append(f'#define {prefix}_PKG_NAME            "{m.pkg}"')
    lines.append(f'#define {prefix}_PKG_VERSION         "{m.version}"')
    lines.append(f'#define {prefix}_PKG_RELEASE         "{m.release}"')
    lines.append(f'#define {prefix}_PKG_TYPE            "{m.pkg_type}"')
    lines.append(f'#define {prefix}_PKG_DESCRIPTION     "{m.description}"')
    lines.append("")
    lines.append(f"#endif  /* COMPONENT_H_{prefix}_INCLUDED */")
    lines.append("")
    return "\n".join(lines)


########################################################################
# In-tree target discovery for target.pkg.mk's DRY_RUN
########################################################################

def _derive_intree_target_name(src: str, intree_dirs: list[str]) -> str | None:
    """If `src` lives directly under any of `intree_dirs`, return the
    corresponding make target name (basename minus `.so` / `.a`).

      exe   -> `<dir>/foo`     -> target `foo`
      shlib -> `<dir>/libt.so` -> target `libt`
      arlib -> `<dir>/libt.a`  -> target `libt`
    Non-`.so`/`.a` extensions pass through (a config file next to a
    lib is a target unto itself if it's named like one)."""
    for intree_dir in intree_dirs:
        intree = intree_dir.rstrip("/")
        if not intree or not src.startswith(intree + "/"):
            continue
        name = os.path.basename(src)
        for suffix in (".so", ".a"):
            if name.endswith(suffix):
                return name[: -len(suffix)]
        return name
    return None


########################################################################
# CLI
########################################################################

def _parse_args(argv: list[str]) -> argparse.Namespace:
    p = argparse.ArgumentParser(
        description="Compile a YAML pkg spec into rpmbuild inputs "
                    "(manifest.json + auto-generated .spec), plus optional "
                    "component.h and alarm .h/.cxx code-gen.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    p.add_argument("--pkg", required=True, metavar="PATH",
                   help="pkg.yaml path (conforms to production/make/schemas/pkg.schema.yaml).")
    p.add_argument("--vars", action="append", default=[],
                   help="KEY=VALUE substitution for $KEY / ${KEY} inside pkg.yaml. Repeatable.")
    p.add_argument("--install-root", default=None,
                   help=f"install prefix (default: from {SCHEMA_PATH.name})")
    p.add_argument("--filegroup-map", default=None,
                   help=f"JSON file merged on top of {SCHEMA_PATH.name}'s default "
                        "filegroup->{dir,mode,owner,group} map (shallow, per-key).")
    p.add_argument("--version", default=None,
                   help="override package version (default: `major`.`minor` from pkg.yaml)")
    p.add_argument("--release", default="1",
                   help="package release (default: 1)")
    p.add_argument("--arch", default=None,
                   help="target arch for the spec's BuildArch: (default: `uname -m`)")
    p.add_argument("--manifest-out", help="manifest.json output path")
    p.add_argument("--spec-out",     help="generated .spec output path")
    p.add_argument("--fail-on-unresolved", action="store_true",
                   help="exit non-zero if any $VAR could not be substituted")
    p.add_argument("--print-intree-targets", metavar="DIRS", default=None,
                   help="dry-run short-circuit for target.pkg.mk: for every "
                        "file entry whose resolved src lives directly under one "
                        "of DIRS (comma-separated: typically $(GM_LIB_DIR),"
                        "$(GM_EXEC_DIR)), print the derived make target name; "
                        "also print every rpm_deps entry so pkg-to-pkg chains "
                        "flow through.  Skips manifest/spec/header emission.")
    p.add_argument("--header-out", metavar="PATH", default=None,
                   help="emit component.h with pkg-identity #defines.  "
                        "Consumer libs `#include <pkg-<name>/component.h>` to "
                        "bake compile-time metadata into their artefacts.")
    p.add_argument("--alarms-out", metavar="DIR", default=None,
                   help="emit alarms.h + alarms.cxx into DIR.  Header declares "
                        "the `AlarmDef` struct, externs `alarms[]` + "
                        "`alarms_count`, and an `enum : unsigned` mapping each "
                        "alarm's name to its number (`kFooAlarm = 4901`); .cxx "
                        "defines the table.  Empty alarms: -> empty-table stub, "
                        "still safe to link.")
    return p.parse_args(argv)


########################################################################
# main
########################################################################

def main(argv: list[str] | None = None) -> int:
    args = _parse_args(argv or sys.argv[1:])

    if not (args.print_intree_targets or args.header_out or args.alarms_out):
        missing = [flag for flag, val in (("--manifest-out", args.manifest_out),
                                          ("--spec-out",     args.spec_out))
                   if not val]
        if missing:
            raise SystemExit("pkg-build: missing required flag(s): " + ", ".join(missing))

    mapping = _parse_vars(args.vars)
    unresolved: list[str] = []

    # Load + schema-validate the pkg.yaml.  Schema defaults fill in
    # install_root, filegroup_map, filegroup_fallback, pkg_type,
    # component's major/minor/id/comp_type, alarm severity/type/etc.
    pkg_yaml_path = Path(args.pkg).resolve()
    cfg = _load_pkg_yaml(pkg_yaml_path, mapping, unresolved)

    # DRY_RUN short-circuit (target.pkg.mk `_YAML_INTREE` scan).  This
    # only needs `files[*].src` and `rpm_deps[]` -- both already
    # $VAR-substituted by _load_pkg_yaml.  Skipping _validate_config
    # keeps `import jsonschema` (~1.4s cold) out of the process, so a
    # DRY_RUN call is ~150ms instead of ~1.6s.  Semantic errors will
    # still be caught in the real spec/rpm build path.
    if args.print_intree_targets:
        intree_dirs = [d for d in args.print_intree_targets.split(",") if d]
        for _fg, entries in (cfg.get("files") or {}).items():
            for entry in entries:
                src = entry if isinstance(entry, str) else entry.get("src", "")
                if src:
                    name = _derive_intree_target_name(src, intree_dirs)
                    if name:
                        print(name)
        for r in cfg.get("rpm_deps", []) or []:
            print(r)
        return 0

    # CLI overrides live in the cfg dict so schema validation sees them.
    if args.install_root is not None:
        cfg["install_root"] = args.install_root
    _validate_config(cfg)

    # --filegroup-map JSON is a shallow, per-key merge on top of the
    # schema-filled default map.  Re-validate to catch bad overrides.
    if args.filegroup_map:
        try:
            overrides = json.loads(Path(args.filegroup_map).read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError) as exc:
            raise SystemExit(f"pkg-build: cannot read --filegroup-map {args.filegroup_map}: {exc}")
        for k, v in overrides.items():
            merged = dict(cfg["filegroup_map"].get(k, cfg["filegroup_fallback"]))
            merged.update(v)
            cfg["filegroup_map"][k] = merged
        _validate_config(cfg)

    manifest = _build_manifest(cfg, args, unresolved)

    if args.fail_on_unresolved and manifest.unresolved_vars:
        raise SystemExit(
            "pkg-build: unresolved variables in pkg.yaml: "
            + ", ".join(manifest.unresolved_vars)
        )

    if args.header_out or args.alarms_out:
        if args.header_out:
            header_out = Path(args.header_out)
            header_out.parent.mkdir(parents=True, exist_ok=True)
            header_out.write_text(_render_component_header(manifest), encoding="utf-8")
            print(f"pkg-build: wrote component header for {manifest.pkg} -> {header_out}")
        if args.alarms_out:
            _emit_alarms(_build_alarms(cfg), manifest, Path(args.alarms_out))
        return 0

    # Full mode: manifest.json + .spec.
    manifest_out = Path(args.manifest_out)
    manifest_out.parent.mkdir(parents=True, exist_ok=True)
    manifest_out.write_text(json.dumps(_manifest_to_dict(manifest), indent=2), encoding="utf-8")

    arch = args.arch or os.uname().machine
    spec_out = Path(args.spec_out)
    spec_out.parent.mkdir(parents=True, exist_ok=True)
    spec_out.write_text(_render_spec(manifest, arch), encoding="utf-8")

    print(f"pkg-build: {manifest.pkg} v{manifest.version}-{manifest.release} "
          f"({len(manifest.files)} files, {len(manifest.rpm_deps)} rpm deps) -> {spec_out}")
    if manifest.unresolved_vars:
        print("pkg-build: warning -- unresolved vars: "
              + ", ".join(manifest.unresolved_vars), file=sys.stderr)
    return 0


def _manifest_to_dict(m: Manifest) -> dict[str, Any]:
    """Serialise Manifest to the JSON shape downstream consumers expect."""
    return {
        "pkg":            m.pkg,
        "version":        m.version,
        "release":        m.release,
        "description":    m.description,
        "pkg_type":       m.pkg_type,
        "components":     m.components,
        "rpm_deps":       m.rpm_deps,
        "install_root":   m.install_root,
        "files":          [{"src": f.src, "dest": f.dest, "mode": f.mode,
                            "owner": f.owner, "group": f.group,
                            "filegroup": f.filegroup} for f in m.files],
        "component": {
            "name":          m.component.name,
            "major_version": m.component.major_version,
            "minor_version": m.component.minor_version,
            "id":            m.component.id,
            "comp_type":     m.component.comp_type,
        },
        "unresolved_vars": m.unresolved_vars,
    }


if __name__ == "__main__":
    sys.exit(main())
