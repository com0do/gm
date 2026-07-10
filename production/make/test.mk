# SPDX-License-Identifier: MIT
#
# test.mk -- top-level test orchestration.  A test-*.mk builds like an exe (see
# target.c.mk's test branch) + -lgtest / vendored gtest headers.
# User-facing knobs: TESTS='<space-separated>', TEST_ARGS='<passthrough>'.
#
# Each test gets a `run/<test>` phony that make -jN can schedule
# independently.  Failures propagate; add -k to keep running after
# the first failure.

ifneq ($(strip $(TESTS)),)
_TESTS_TO_RUN := $(filter $(TESTS),$(TARGET_TEST))
else
_TESTS_TO_RUN := $(TARGET_TEST)
endif

_RUN_TARGETS := $(_TESTS_TO_RUN:%=run/%)

.PHONY: test test-list $(_RUN_TARGETS)


$(_RUN_TARGETS): run/%: %
	@$(ECHO)
	$(V_TEST)
	@"$(GM_EXEC_DIR)/$*" $(TEST_ARGS)


test: $(_RUN_TARGETS)
	@ if [ -z "$(_TESTS_TO_RUN)" ]; then \
	    echo "make test: no test targets $(if $(TESTS),match TESTS='$(TESTS)',discovered)." ; \
	  else \
	    echo "===== Test summary: $(words $(_TESTS_TO_RUN))/$(words $(_TESTS_TO_RUN)) passed =====" ; \
	  fi


test-list:
	@ if [ -n "$(TARGET_TEST)" ]; then \
	    echo "Discovered $(words $(TARGET_TEST)) test target(s):" ; \
	    for t in $(TARGET_TEST) ; do echo "    $$t" ; done ; \
	  else \
	    echo "No test targets found (looking for test-*.mk files)." ; \
	  fi
