# i1 -- legacy demo (Dockerfile.tmpl + entrypoint.sh)

Preserved from `example/i1/` before gm dropped its container-image
integration (`production/make/target.img.mk` was removed and the
opinion pivoted to "yum repo is the natural boundary between RPM
build and container image build" -- see the discussion in the git
history around that removal).

The files here are the raw docker inputs the old target.img.mk
consumed:

- `Dockerfile.tmpl`  -- `@VAR@`-style placeholder template
- `entrypoint.sh`    -- launched by the Dockerfile's `ENTRYPOINT`

They're kept as a reference for anyone porting the old gm-integrated
image workflow to container's `image.yaml` manifest format.  Contrast
with `../hello/` which is the native container demo (uses `image.yaml`
+ `installGuide.in` + container's own Dockerfile template).

## Porting to container

Roughly:

1. Write an `image.yaml` naming the image, base, docker context, and
   any `installGuide.in` entries.
2. Convert the `@VAR@` placeholders in `Dockerfile.tmpl` to
   container's `__VAR__` convention (or use container's standard
   template + `installGuide.in` and skip a custom Dockerfile).
3. Drop the `IMG_PKGS` list from `img-i1.mk` -- container lets you
   declare pkgs to `yum install` in `installGuide.in`'s
   `[RPMINSTALL]` section, consumed from a yum repo (not staged
   from a local build tree).
4. Run `container build image.yaml`.

See `container/README.md` at the repo root for the full container
workflow and the `hello` sibling for a live example.
