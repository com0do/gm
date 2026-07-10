#  Per-target link-dep JSON aggregator.
#
#  Inputs (via --arg from target.c.mk):
#     FILE        absolute path of the primary artifact this dep.json describes
#                 (exe for binaries, .so for shared libs, .a for static-only)
#     LIB_DEPS    space-separated absolute paths of linked .so files
#                 (resolved from -lXXX by depcxx.sh)
#     HEADER_INS  space-separated .h.in template paths
#     MK_FILE     the child .mk file
#     FRAMEWORK   space-separated absolute paths of build-system files
#                 whose change should force this target to rebuild
#                 (env.mk / flags.mk / project.mk / check.mk /
#                 target.common.mk / target.c.mk / helper scripts).
#                 Populated from target.c.mk's $(GM_FRAMEWORK_MK),
#                 which is $(GM_FRAMEWORK_CORE_MK) + type-specific
#                 files.  See env.mk's GM_FRAMEWORK_CORE_MK block for
#                 the rationale ("if the build system changes, every
#                 build product may change").
#
#  Stdin (via jq -s) = the array of all per-obj .dep.json blobs
#  ({file:".../foo.o", deps:[<sources, headers>]} each).
#
#  Output: a single {file:<artifact>, deps:[<union, uniqued, sorted>]} object.

{
  file: $FILE,
  deps: ( map(select(.file | endswith(".o")) | .deps[])
        + ($LIB_DEPS   | split(" ") | map(select(length > 0)))
        + ($HEADER_INS | split(" ") | map(select(length > 0)))
        + ($FRAMEWORK  | split(" ") | map(select(length > 0)))
        + [$MK_FILE]
        | unique
        | sort )
}
