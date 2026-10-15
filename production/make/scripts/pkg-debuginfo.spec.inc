# gm: split symbols into <name>-debuginfo, keyed by build-id (USER_GUIDE 3.13).
# No debugsource / gdb index; a missing build-id only warns.
# Needs elfutils' eu-strip (always there on RHEL family); hosts without it, e.g. Ubuntu
# CI runners, build the plain package instead of failing in find-debuginfo.
# (Percent-brace macros must not appear in spec comments: rpm expands them.)
%undefine _debugsource_packages
%undefine _include_gdb_index
%global _missing_build_ids_terminate_build 0
%global _empty_manifest_terminate_build 0
%if %(command -v eu-strip >/dev/null 2>&1 && echo 1 || echo 0)
%debug_package
%endif
