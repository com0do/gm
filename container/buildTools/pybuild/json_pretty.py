"""ShortListJSONEncoder shim -- delegates to the shared library.

Container's dep.json wants the exact same "compact-primitive-list,
indented-dict" shape gm's dep_query.py uses.  Rather than keep two
drift-prone copies, we import from the single source of truth at
`production/tools/pydep/pretty.py`.

The sys.path setup that makes `pydep` importable is done exactly
once at the top of `container/imageBuild.py` -- container's own
modules (this one, dep_json, rpm_update, etc.) never see gm's
directory layout beyond that one bootstrap.

Spinout playbook (when container/ moves to its own repo):
    1. `cp production/tools/pydep/pretty.py container/buildTools/pybuild/json_pretty.py`
       -- replacing this shim with the full implementation.
    2. Remove the `production/tools` line from imageBuild.py's
       sys.path setup.
    3. Done -- no downstream changes needed; every consumer already
       imports `from .json_pretty import ...`.
"""
from pydep.pretty import ShortListJSONEncoder, dumps   # noqa: F401
