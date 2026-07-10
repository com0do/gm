# customization/ — product-level Configuration Management (CM)

> **Not built by gm.**  This tree is a peer of `gm/`, not a subtree of
> it.  gm's `EXCLUDE_DIR` skips this directory during target discovery;
> `make -j all` at the gm root never touches anything here.

## What lives here

Product-level Configuration Management, centralized.  Corresponds to the
`customization/` tree in `~/hss/5g_core/customization`, modernized:

- **YANG modules** are the schema authority.  `yang/common/` holds
  cross-pkg shared groupings/typedefs; `yang/<pkg-name>/` holds the
  schema for each pkg's configuration surface.
- **`generic/generic.yaml`** is the master default config for the
  whole product.  Every leaf of every YANG tree has an initial value
  here.  This is the direct modern equivalent of the reference
  system's `generic.xml` -- one authoritative file at product-release
  time.  YAML because that's what humans edit today.
- **`templates/`** holds the CM templates each container's `cmproxy`
  loads.  A template maps a pkg's config-query (an XPath into its
  yang tree) to the corresponding slice of `generic.yaml`.
- **`tools/validate.sh`** cross-checks every leaf in `generic.yaml`
  against the union of yang modules using
  [`pyang`](https://github.com/mbj4668/pyang).  Runs offline; nothing
  in gm depends on it.

## Where this fits in the stack

```
1. gm         → *.rpm + *.dep.json                       (this repo, layer 1)
2. container/ → container image                          (sibling; layer 2)
3. gm_helm    → helm chart / pod composition             (separate repo; layer 3)
4. runtime    → cmproxy + generic.yaml + YANG schemas    (in-cluster; layer 4)
                                          ▲
                                          │  centralized: this tree
                                          │
                     customization/  (─────┘ authored at layer 3;
                                            shipped alongside helm chart)
```

**gm doesn't package any of this into rpms.**  Runtime CM is
centralized: the generic.yaml + yang modules + templates are shipped
once, at product-release time, into the deployment image.  Every
container's `cmproxy` reaches into the same central store.  Individual
pkg rpms carry *no CM data*; they just call `cmproxy` at runtime.

## Layout

```
customization/
├── README.md
├── yang/
│   ├── common/
│   │   └── gm-common.yang           # shared groupings + typedefs
│   └── pkg-p2/
│       └── pkg-p2.yang              # pkg-p2's config schema
├── generic/
│   └── generic.yaml                 # master defaults for the product
├── templates/
│   └── pkg-p2.template.yaml         # cmproxy → generic.yaml mapping
└── tools/
    └── validate.sh                  # yang + generic self-check
```

## What every pkg does at runtime

```c
// pkg-p2's process, at start:
gm_cmproxy_handle *h = gm_cmproxy_open("pkg-p2");   // reads /etc/cmproxy/pkg-p2.template.yaml
const char *url = gm_cmproxy_get(h, "/pkg-p2:config/backend-url");
uint32_t     ms = gm_cmproxy_get_u32(h, "/pkg-p2:config/timeout-ms");
```

The pkg author doesn't ship yang or defaults inside the rpm.  They
only ship their code that calls `cmproxy`.  The schema + defaults +
templates are all authored here (`customization/`), reviewed
independently, and delivered to production through the helm chart at
release time.

## Modernizations vs. the reference `customization/` tree

| Reference (HSS 5g_core)                               | Here                                       |
|-------------------------------------------------------|--------------------------------------------|
| generic.xml (XML)                                     | **generic.yaml** (YAML)                    |
| Nokia-specific YANG extensions (`nokia:plato`, ...)   | Plain vanilla RFC 7950 YANG                |
| Manifest driven by `manifest.json` + zip bundling     | Plain filesystem layout, no packaging     |
| Multiple product profiles + prefill scripts           | One product, one generic.yaml             |
| Confd Basic (partly-open, partly-proprietary)         | sysrepo + libyang (fully MIT open source)  |
| CI: internal Nokia tooling                            | pyang (open source, `pip install pyang`)   |
| ~40 yang subdirs (one per NF)                         | 1 shared + 1 per pkg                       |

Keep the reference as inspiration; the modern shape here is much
smaller and MIT-only.

## Validating

```bash
cd customization
./tools/validate.sh
# outputs:
#   pyang parse:  yang/common/gm-common.yang ✓
#   pyang parse:  yang/pkg-p2/pkg-p2.yang ✓
#   generic.yaml check: all N leaves resolve against the yang union ✓
```

`validate.sh` is a **standalone script**; it doesn't call gm or share
any code with gm.  Run it in this directory, in CI, before releasing
the product.

## Adding a new pkg's CM

1. `mkdir yang/<pkg>` and drop a YANG module in it.  Import from
   `yang/common/gm-common.yang` if useful.
2. Extend `generic/generic.yaml` with defaults for every leaf you
   declared as `default "..."` (or explicit values where you want
   non-schema defaults).
3. Add a mapping in `templates/<pkg>.template.yaml` so the pkg's
   `cmproxy` client can find its slice.
4. Run `./tools/validate.sh`.

No gm change needed for any of this.
