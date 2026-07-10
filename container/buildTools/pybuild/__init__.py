"""container -- container image build subsystem.

Public surface mirrors the build pipeline:

    Manifest -> InstallerDSL -> Repos -> Context -> Dockerfile
                                                 -> Docker -> DepJson

Each module is a thin, testable class.  Orchestrated by `container` CLI.
"""

from .manifest    import Manifest
from .installer   import InstallerDSL
from .repos       import RepoRenderer
from .rpms        import RpmResolver, RpmInfo
from .rpm_query   import (
    RpmRuntimeResolver,
    query_installed_rpms,
    parse_dockerfile_yum,
)
from .overrides   import OverrideTable
from .context     import BuildContext
from .dockerfile  import DockerfileRenderer
from .docker      import DockerBuild
from .dep_json    import DepJson
from .yum_query   import YumQuery
from .lock        import LockGenerator
from .rpm_update  import RpmUpdateChecker, ImageReport, RpmUpdate
from .json_pretty import ShortListJSONEncoder, dumps as pretty_dumps


# Explicit public API.  Declaring `__all__` is what tells linters
# (ruff F401) that these names are intentional re-exports; per-line
# noqa comments only work when the flagged name is on the same
# physical line, which fails for multi-line imports.
__all__ = [
    "Manifest",
    "InstallerDSL",
    "RepoRenderer",
    "RpmResolver", "RpmInfo",
    "RpmRuntimeResolver", "query_installed_rpms", "parse_dockerfile_yum",
    "OverrideTable",
    "BuildContext",
    "DockerfileRenderer",
    "DockerBuild",
    "DepJson",
    "YumQuery",
    "LockGenerator",
    "RpmUpdateChecker", "ImageReport", "RpmUpdate",
    "ShortListJSONEncoder", "pretty_dumps",
]
