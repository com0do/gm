# SPDX-License-Identifier: MIT
#
# incremental.mk -- file-level incremental phonies -- query + closed-loop refresh over
# the DEP_TREE=yes .dep.json DAG.  User surface: `make changes /
# changes-since / refresh`.

.PHONY: changes changes-since incremental refresh

DEP_QUERY := python3 $(ADMIN_DIR)/make/scripts/dep_query.py \
             --build-dir $(GM_OUT) --proj-top $(PROJ_TOP)

changes:
	@[ -n "$(CHANGES)" ] || (echo 'usage: make changes CHANGES="path1 path2 ..."'; exit 1)
	@$(DEP_QUERY) changes --format json $(CHANGES)

changes-since:
	@[ -n "$(SINCE)" ] || (echo 'usage: make changes-since SINCE=<git-ref>'; exit 1)
	@$(DEP_QUERY) since --format json $(SINCE)

# `make refresh` -- delegates to depUpdate.py: runs `make deps`,
# builds new/missing-dep.json targets, walks the DAG from CHANGES/SINCE
# and rebuilds affected lib/exe/pkg with DEP_TREE=yes, lists container
# images that need `container/imageBuild.py`.
refresh:
	@python3 $(ADMIN_DIR)/tools/depUpdate.py \
	    --build-dir $(GM_OUT) --proj-top $(PROJ_TOP) \
	    $(if $(CHANGES),--changes $(CHANGES)) \
	    $(if $(SINCE),--since $(SINCE)) \
	    $(if $(DRY_RUN),--dry-run) \
	    $(if $(SKIP_DEPS),--skip-deps) \
	    $(if $(JOBS),--jobs $(JOBS))

# Legacy: rebuild affected targets without refreshing the dep graph
# (~2x faster than `refresh` when graph freshness doesn't matter).
incremental:
	@[ -n "$(SINCE)" ] || (echo 'usage: make incremental SINCE=<git-ref>'; exit 1)
	@targets=$$($(DEP_QUERY) since --format targets $(SINCE)) ; \
	if [ -z "$$targets" ]; then \
	    echo "... nothing to rebuild for $(SINCE)..HEAD"; \
	else \
	    echo "... rebuilding: $$targets" ; \
	    GM_TREE= $(MAKE) $$targets ; \
	fi
