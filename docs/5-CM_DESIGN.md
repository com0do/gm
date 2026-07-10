# Configuration Management (CM), YANG, and gm's boundary

> **Status: architecture reference.**  Where CM lives across the
> product stack, and why gm does nothing about it.

## 1. The product stack

Four independent systems.  gm is #1:

```
┌────────────────────────────────────────────────────────────────────┐
│ Layer 1: gm (this repo)                                            │
│   input   : pkg.yaml + source                                      │
│   output  : *.rpm  +  *.dep.json                                   │
│   scope   : build → rpm.  Nothing else.                            │
└────────────────────────────────────────────────────────────────────┘
                    ▼  (RPMs land in a yum repo)
┌────────────────────────────────────────────────────────────────────┐
│ Layer 2: container/  (separate subsystem, sibling of gm/)          │
│   input   : image.yaml + rpms                                      │
│   output  : container image  +  image.dep.json                     │
│   scope   : compose rpms into images.                              │
└────────────────────────────────────────────────────────────────────┘
                    ▼  (container images pushed to registry)
┌────────────────────────────────────────────────────────────────────┐
│ Layer 3: gm_helm  (separate repo, ref: ~/hss/reg_helm/udm/...)     │
│   input   : pod specs + install/upgrade hooks + product CM         │
│             (yang modules + generic.yaml + cmproxy templates)      │
│   output  : helm chart / product release                           │
│   scope   : pod composition (1 pod = 1+ containers) + product-     │
│             level CM authoring.                                    │
│   this repo's reference:  customization/  (peer of gm/)            │
└────────────────────────────────────────────────────────────────────┘
                    ▼  (helm chart → k8s cluster)
┌────────────────────────────────────────────────────────────────────┐
│ Layer 4: runtime  (in-cluster; not a build artefact)               │
│   * every container carries a `cmproxy` sidecar                    │
│   * cmproxy loads a per-pkg CM template (from customization/)      │
│     and serves that pkg its slice of `generic.yaml`                │
│   * `generic.yaml` is the central authoritative store, pinned at   │
│     product-release time                                           │
│   * pkg processes read config through cmproxy (never directly)     │
└────────────────────────────────────────────────────────────────────┘
```

## 2. gm's boundary is the RPM

gm knows about a pkg only what its `pkg.yaml` says: binaries,
libraries, config files, scripts, `.dep.json`.  gm does **not**:

- ship YANG modules, generic.yaml, or CM templates inside rpms
- validate YANG semantics
- assemble a per-container CM tree
- drive libyang / sysrepo / ConfD / cmproxy
- interpret `image.yaml` or helm charts

Those all live above gm.

## 3. Where YANG + generic.yaml live

**Centralized, at layer 3.**  The `customization/` tree in this
repository (peer of `gm/`, not a subtree of it) is the reference
layout:

```
customization/                    # authored + released at layer 3
├── yang/
│   ├── common/gm-common.yang     # shared groupings + typedefs
│   └── pkg-p2/pkg-p2.yang        # pkg-p2's config schema
├── generic/generic.yaml          # master defaults for the WHOLE product
├── templates/pkg-p2.template.yaml  # cmproxy → generic slice mapping
└── tools/validate.sh             # standalone, pyang-based, no gm
```

Everything under `customization/` is **not built by gm**.  gm's
`EXCLUDE_DIR` skips it during target discovery; `make -j all` doesn't
touch it.  It's shipped alongside the helm chart at product-release
time, and every container's `cmproxy` reaches into the same central
store.

**Why centralized instead of per-rpm?**  Two reasons:

1. **Configuration lives longer than any single rpm.**  The pkg
   binary changes on every code push; its config schema changes
   maybe once a quarter.  Baking YANG into the rpm couples two very
   different release cadences.
2. **One product config, one truth.**  If pkg-p1 and pkg-p2 both
   reference a shared value (say NTP servers), that value has to live
   in one place -- not duplicated across two rpms.  A central
   `generic.yaml` is the natural home.  Per-rpm YANG would force
   either duplication or awkward cross-rpm imports.

The reference HSS system's `ComponentDescription_NetAct.src.xml`
carried CM data inside the pkg because that was the historical
convention; newer 5G-core-family projects moved to a central
`customization/` tree and never looked back.

## 4. pkg.yaml is the single source of truth for pkg-level facts

Whatever gm cares about a pkg -- name, version, files, alarms,
rpm-level `Requires:` -- is authored in `pkg.yaml` and nowhere else.
There is no auto-inference from other trees:

- If pkg-p2 needs pkg-p1 installed to run (e.g. bundles a lib that
  dynamically loads a symbol from pkg-p1), the author declares
  `rpm_deps: [pkg-p1]` in `pkg.yaml`.  That is the truth.  gm
  doesn't second-guess it, and doesn't try to derive it from the
  transitive lib graph.
- If pkg-p2 needs a config knob at runtime, that knob is declared
  in `customization/yang/pkg-p2/pkg-p2.yang` (layer 3), given a
  default in `customization/generic/generic.yaml`, and exposed
  through `customization/templates/pkg-p2.template.yaml`.  None of
  that appears in `pkg.yaml`.  The runtime side (cmproxy) glues them.

`pkg.yaml` describes the **package**.  `customization/` describes
the **product**.  They're independent artefacts with independent
release cadences and independent editors.

## 5. Recommended gm ↔ YANG integration: none

Because YANG lives entirely at layer 3, gm has no interaction with
it at all.  No filegroup convention, no `_pkg_yang.mk` shim, no
`cm:` block in the schema.

The right cross-check for YANG (that every declared leaf has a
default in `generic.yaml`) runs against the customization/ tree
itself -- `customization/tools/validate.sh`.  It uses `pyang` and
plain YAML parsing; it doesn't know gm exists.

## 6. Layered defaults (all at layer 3/4)

The layered-default story that some CM systems have (schema →
per-pkg default → system default → deployment override → runtime
change) all happens INSIDE the customization/ tree + cmproxy runtime,
NOT anywhere gm sees:

- YANG `default "..."` statements
- `generic.yaml` (product-release-pinned defaults)
- Overrides applied per environment when the helm chart is deployed
- (optional) live changes via the cmproxy API

gm doesn't participate at any layer.

## 7. Adding a new pkg's CM

The story from the pkg author's perspective, when a new pkg starts
needing runtime config:

1. In `gm/`: write `pkg.yaml` (unchanged from today).  Do NOT reach
   for a `cm:` block, do NOT put YANG in `files:`.  pkg-build.py
   just packages the binaries.
2. In `customization/yang/<pkg>/`: create the YANG module for this
   pkg's config surface.
3. In `customization/generic/generic.yaml`: add defaults for every
   leaf.
4. In `customization/templates/<pkg>.template.yaml`: add the cmproxy
   mapping.
5. In pkg's code: call `cmproxy_open("<pkg>")` at start; use the
   handle to look up values.
6. Run `customization/tools/validate.sh`.
7. Cut a customization release; ship the helm chart.

Steps 2-6 are all layer 3.  gm only sees step 1.

## 8. References

- Reference `customization/`: `~/hss/5g_core/customization/`.
- YANG: RFC 7950 (v1.1) + RFC 6020 (v1.0).
- pyang (YANG parser + linter): <https://github.com/mbj4668/pyang>.
- sysrepo (open-source YANG datastore, MIT):
  <https://github.com/sysrepo/sysrepo>.
- libyang (parse/validate/manipulate YANG data, BSD):
  <https://github.com/CESNET/libyang>.
