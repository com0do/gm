# SPDX-License-Identifier: MIT
#
# coverage.mk -- coverage subsystem.  `make coverage` (gcovr) or `make coverage-lcov`.
# Both rebuild in BUILD_MODE=coverage, run every exe (or COV_EXES),
# aggregate .gcno+.gcda into $(GM_COVERAGE_DIR).

.PHONY: coverage coverage-lcov coverage-diff _coverage-run

COVERAGE_DIR      := $(GM_COVERAGE_DIR)
COVERAGE_HTML     := $(COVERAGE_DIR)/html
COVERAGE_EXEC_DIR := $(GM_OUT)/exec/$(BUILD_ARCH)/coverage
COV_EXES          ?= $(TARGET_EXE)

_coverage-run:
	@$(ECHO) "... rebuild with BUILD_MODE=coverage ..."
	@GM_TREE= $(MAKE) BUILD_MODE=coverage $(if $(COV_EXES),$(COV_EXES),all)
	@$(ECHO) "... run instrumented executables (.gcda counters) ..."
	@$(MKDIR) $(COVERAGE_DIR)
	@find $(GM_OUT) -name '*.gcda' -delete 2>/dev/null || true
	@for exe in $(COV_EXES); do \
	    bin=$(COVERAGE_EXEC_DIR)/$$exe ; \
	    [ -x $$bin ] && { $(ECHO) "    run $$bin" ; $$bin || true ; } || \
	        $(ECHO) "    SKIP $$exe (no exe at $$bin)" ; \
	done

coverage: _coverage-run
	@command -v gcovr >/dev/null 2>&1 || { \
	    echo "gcovr not found; install with: pip install --user gcovr"; \
	    echo "  (or use \`make coverage-lcov\` for the classical lcov flow)"; \
	    exit 1 ; }
	@$(ECHO) "... aggregate via gcovr ..."
	@$(MKDIR) $(COVERAGE_HTML)
	@gcovr --root $(PROJ_TOP) \
	       --exclude '.*/build/.*' \
	       --exclude '/usr/.*' \
	       --gcov-ignore-errors=all \
	       --txt $(COVERAGE_DIR)/summary.txt \
	       --json $(COVERAGE_DIR)/coverage.json \
	       --cobertura $(COVERAGE_DIR)/coverage.xml \
	       --html-details $(COVERAGE_HTML)/index.html \
	       $(GM_OUT)
	@$(ECHO) ""
	@cat $(COVERAGE_DIR)/summary.txt
	@$(ECHO) ""
	@$(ECHO) "... HTML report : $(COVERAGE_HTML)/index.html"
	@$(ECHO) "... JSON report : $(COVERAGE_DIR)/coverage.json"
	@$(ECHO) "... Cobertura   : $(COVERAGE_DIR)/coverage.xml  (feeds \`make coverage-diff\`)"


# Patch-level coverage: how much of the diff between $(SINCE) and
# HEAD is exercised by tests?  Consumes the Cobertura XML that
# `make coverage` already emits, so the sequence is:
#     make coverage
#     make coverage-diff SINCE=main
# Defaults SINCE to origin/main (typical CI baseline); override on
# the cmdline for other bases (HEAD~1 for last-commit-only, etc.).
SINCE ?= origin/main

coverage-diff:
	@[ -f $(COVERAGE_DIR)/coverage.xml ] || { \
	    echo "no $(COVERAGE_DIR)/coverage.xml -- run \`make coverage\` first" ; \
	    exit 1 ; }
	@command -v diff-cover >/dev/null 2>&1 || python3 -m diff_cover --version >/dev/null 2>&1 || { \
	    echo "diff-cover not found; install with: pip install --user diff-cover" ; \
	    exit 1 ; }
	@$(ECHO) "... patch coverage: $(SINCE) -> HEAD ..."
	@cd $(PROJ_TOP) && diff-cover $(COVERAGE_DIR)/coverage.xml \
	    --compare-branch=$(SINCE) \
	    --html-report $(COVERAGE_HTML)/diff.html \
	    --json-report $(COVERAGE_DIR)/diff.json ; \
	rc=$$? ; \
	[ $$rc = 0 ] || [ $$rc = 1 ] || exit $$rc
	@$(ECHO) ""
	@$(ECHO) "... diff HTML  : $(COVERAGE_HTML)/diff.html"
	@$(ECHO) "... diff JSON  : $(COVERAGE_DIR)/diff.json"

# lcov 2.0 exits 25 on a harmless Getopt "Duplicate specification"
# warning -- treat 25 as success.
coverage-lcov: _coverage-run
	@command -v lcov    >/dev/null 2>&1 || { echo "lcov not found (see \`make coverage\` for the gcovr flow)"; exit 1; }
	@command -v genhtml >/dev/null 2>&1 || { echo "genhtml not found"; exit 1; }
	@$(ECHO) "... capture lcov info ..."
	@lcov -d $(GM_OUT) -c -o $(COVERAGE_DIR)/lcov.info \
	      --ignore-errors usage --quiet 2>$(COVERAGE_DIR)/lcov.err ; rc=$$?; \
	    [ $$rc = 0 ] || [ $$rc = 25 ] || { \
	        echo "ERROR: lcov capture failed (exit $$rc) - see $(COVERAGE_DIR)/lcov.err" ; \
	        echo "      hint: \`cpanm DateTime --notest\` (or use \`make coverage\` for gcovr)" ; \
	        exit $$rc ; }
	@lcov -r $(COVERAGE_DIR)/lcov.info '/usr/*' '*/build/*' \
	      -o $(COVERAGE_DIR)/lcov.info --quiet 2>/dev/null ; \
	    rc=$$?; [ $$rc = 0 ] || [ $$rc = 25 ] || exit $$rc
	@genhtml $(COVERAGE_DIR)/lcov.info --output-directory $(COVERAGE_HTML) --quiet 2>/dev/null ; \
	    rc=$$?; [ $$rc = 0 ] || [ $$rc = 25 ] || exit $$rc
	@$(ECHO) ""
	@$(ECHO) "... lcov HTML report : $(COVERAGE_HTML)/index.html"
