"""gm dep-analysis library.

Class-per-file split of the dependency-analysis toolbox.  Lives at
`production/tools/pydep/` (moved out of `production/make/scripts/lib/`
so container/ can import from the same source of truth via a sys.path
shim -- see container/imageBuild.py).  Public entries mirror what the
CLI (`dep_query.py`) consumes:

    from pydep.artifact      import Kind, classify, target_name
    from pydep.paths         import normalize, rel
    from pydep.pretty        import ShortListJSONEncoder, dumps
    from pydep.gitignore     import GitignoreFilter
    from pydep.change_source import ChangeSource
    from pydep.dag           import DepGraph
    from pydep.cache         import DepCache
    from pydep.image_walk    import ImageWalker, AffectedReport
    from pydep.snapshot      import snapshot as dep_snapshot
"""

from .artifact      import Kind, classify, target_name             # noqa: F401
from .paths         import normalize, rel                          # noqa: F401
from .pretty        import ShortListJSONEncoder, dumps             # noqa: F401
from .gitignore     import GitignoreFilter                         # noqa: F401
from .change_source import ChangeSource                            # noqa: F401
from .dag           import DepGraph                                # noqa: F401
from .cache         import DepCache                                # noqa: F401
from .image_walk    import ImageWalker, AffectedReport             # noqa: F401
from .snapshot      import snapshot                                # noqa: F401
