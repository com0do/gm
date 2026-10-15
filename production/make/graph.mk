# SPDX-License-Identifier: MIT
#
# graph.mk -- the target graph in the top-level make: three files under GM_OUT that the
# dependency scan writes (DRY_RUN sub-makes, docs/3-DRY_RUN.md), and when they are rebuilt.
#
#   depend.mk     <t>: <deps>                   read here: the build order of the targets
#   pkg_of.mk     PKG_OF_<lib> := <pkg>         read by target sub-makes (env.mk): PKG_HEADERS := yes
#   import_of.mk  IMPORT_OF_<a> := <import-mk>  read by target sub-makes (env.mk): pkg.yaml artefacts
#
# Included once, by the Makefile, after project.mk has found the targets.

TARGET_DEP ?= $(GM_DEP_FILE)

ifneq ($(DRY_RUN),1)
.PRECIOUS: $(TARGET_DEP) $(GM_PKG_OF_FILE) $(GM_IMPORT_OF_FILE)
.PHONY: deps

deps:
	@$(RM) $(TARGET_DEP) $(GM_PKG_OF_FILE) $(GM_IMPORT_OF_FILE)
	@GM_TREE= $(MAKE) $(TARGET_DEP)

# make remakes every makefile it includes before it looks at any goal, so including depend.mk
# scans the tree whenever depend.mk is stale, whatever the goal.  It is included only when a
# goal builds targets in this make: not for gm's goals in _GM_GOALS_ALONE (project.mk), nor for
# the sub-goals in SUB_TARGET_ALONE (env.mk).  Anything else -- a target, run-<t>, show, test,
# all, a project's own goal -- gets the build order.
_GM_GRAPH_GOALS := $(filter-out $(_GM_GOALS_ALONE),$(or $(MAKECMDGOALS),$(.DEFAULT_GOAL)))
ifneq ($(_GM_GRAPH_GOALS),)
ifeq ($(filter $(SUB_TARGET),$(SUB_TARGET_ALONE)),)

include $(TARGET_DEP)
ifeq ($(origin _DEP_DIGEST_NOW),undefined)
_DEP_DIGEST_NOW := $(shell echo $(sort $(TARGET_ALL_MK)) | md5sum | cut -c1-32)
endif
# A target added or removed: every scan result is stale, start over.
ifneq ($(_DEP_DIGEST),$(_DEP_DIGEST_NOW))
$(shell $(RM) $(TARGET_DEP) $(GM_PKG_OF_FILE) $(GM_IMPORT_OF_FILE))
endif

# The scan is serial and strictly ordered:
#   1. imports FIRST -- write IMPORT_OF_<artefact> := <mk> into
#      $(GM_IMPORT_OF_FILE).  Pkgs need this map to resolve
#      multi-artefact vendor products (pkg.yaml referencing e.g.
#      libminijson_file.so where the .mk basename is libminijson).
#   2. pkgs SECOND -- read IMPORT_OF_*, write PKG_OF_<lib> := <pkg>
#      into $(GM_PKG_OF_FILE).
#   3. everything else THIRD -- reads both maps to fill in reverse deps.
#
# Serial (not -j) because every DRY_RUN sub-make does `sed -i` on the
# SHARED depend.mk / pkg_of.mk / import_of.mk files; parallel sed on
# one file races and drops DAG edges.  See docs/4-DEBUGGING.md.
# A failed scan removes depend.mk: half updated, and newer than every .mk, it would look current.
$(TARGET_DEP): _CHANGED = $(foreach mk,$?,$(call _TARGET_NAME_FROM_MK,$(mk)))
$(TARGET_DEP): _IMPORT_ALL = $(TARGET_IMPORT_LIB) $(TARGET_IMPORT_EXE)
$(TARGET_DEP): _ORDERED = \
    $(filter $(_IMPORT_ALL),$(_CHANGED)) \
    $(filter $(TARGET_PKG),$(_CHANGED)) \
    $(filter-out $(_IMPORT_ALL) $(TARGET_PKG),$(_CHANGED))
$(TARGET_DEP): $(TARGET_ALL_MK)
	@mkdir -p $(@D) && touch $(GM_PKG_OF_FILE) $(GM_IMPORT_OF_FILE)
	@$(call V_DEPS,scanning $(words $(_CHANGED)) target(s))
	@for t in $(_ORDERED) ; do \
	    $(ECHO) "  DEPS    $$t" ; \
	    GM_TREE= $(MAKE) -s DRY_RUN=1 $$t || { rc=$$? ; $(RM) $(TARGET_DEP) ; exit $$rc ; } ; \
	 done
	@# Drop target.dry-run.mk's seed blank line, sort + dedupe.
	@sort -u $(GM_PKG_OF_FILE) | grep -v '^[[:space:]]*$$' \
	   > $(GM_PKG_OF_FILE).tmp && mv $(GM_PKG_OF_FILE).tmp $(GM_PKG_OF_FILE) || true
	@sort -u $(GM_IMPORT_OF_FILE) | grep -v '^[[:space:]]*$$' \
	   > $(GM_IMPORT_OF_FILE).tmp && mv $(GM_IMPORT_OF_FILE).tmp $(GM_IMPORT_OF_FILE) || true
	@{ echo '_DEP_DIGEST := $(_DEP_DIGEST_NOW)' ; \
	   grep -Ev '^(_DEP_DIGEST := |[[:space:]]*$$)' $(TARGET_DEP) | sort -u ; } \
	   > $(TARGET_DEP).tmp && mv $(TARGET_DEP).tmp $(TARGET_DEP)
	@$(call V_DEPS,-> $(patsubst $(PROJ_TOP)/%,%,$(TARGET_DEP)) ($$(($$(wc -l < $(TARGET_DEP)) - 1)) edges))
	@$(call V_DEPS,-> $(patsubst $(PROJ_TOP)/%,%,$(GM_PKG_OF_FILE)) ($$(wc -l < $(GM_PKG_OF_FILE)) pkg-of mappings))
	@$(call V_DEPS,-> $(patsubst $(PROJ_TOP)/%,%,$(GM_IMPORT_OF_FILE)) ($$(wc -l < $(GM_IMPORT_OF_FILE)) import-of mappings))

endif
endif
endif # DRY_RUN != 1
