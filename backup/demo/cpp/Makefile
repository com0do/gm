
#.SILENT:
.DELETE_ON_ERROR:
.EXPORT_ALL_VARIABLES:
MAKEFLAGS += --no-print-directory


AUTHOR  ?= CYRUS
MKDIR   := mkdir -p
OBJDIR  := $(CURDIR)/build
BINDIR  := $(OBJDIR)/bin
DIR     := $(OBJDIR) $(BINDIR)
SOURCE  := $(wildcard $(CURDIR)/*.cc)
OFILES  := $(patsubst %.cc,$(OBJDIR)/%.o,$(notdir $(wildcard *.cc */*.cc)))
TARGET  := $(BINDIR)/first
TEST    := $(BINDIR)/first_ut
Q       := $(if $(filter 1,$(V)),,@)

LDLIBS  = -lstdc++

DEP_TREE ?= no
# dependencies parser choice: raw=(eval+sed+jq), py=python, cpp=c++
DEP_PARSER ?= raw


# test start
LDLIBS += -lubox
LDFLAGS += -L$(CURDIR)/lib
# Library dependency filter paths (colon-separated)
# Only libraries in these paths will be tracked as dependencies
LIB_FILTER_PATHS ?= $(HOME)/third-party/lib:$(HOME)/work/md/demo/cpp/lib
# test end



all:$(TARGET)
#--------------------------------->
CMAKE_PROJECT := $(abspath $(CURDIR)/../hello)
CMAKE_TARGET  := $(CMAKE_PROJECT)/build/hello
$(CMAKE_PROJECT)/build/Makefile: $(CMAKE_PROJECT)/CMakeLists.txt
	@cmake -S $(<D) -B $(@D)
$(CMAKE_TARGET):$(CMAKE_PROJECT)/build/Makefile
	#@$(MAKE) -C $(@D) $(@F)
.PHONY: $(CMAKE_TARGET)

# LINK.o = $(CC) $(LDFLAGS) $(TARGET_ARCH)
$(TARGET): $(OFILES) # | $(CMAKE_TARGET)
	$(Q)$(CXX) $(LDFLAGS) $(TARGET_ARCH) $(filter %.o, $^) $(LOADLIBES) $(LDLIBS) -o $@
ifeq ($(DEP_TREE), yes)
	$(Q)LIB_DEPS="$$($(CURDIR)/getdeps.sh --filter '$(LIB_FILTER_PATHS)' $(LDFLAGS) $(LOADLIBES) $(LDLIBS) | tr '\n' ' ')"; \
	OBJ_DEPS="$(filter %.o,$^)"; \
	jq -n \
		--arg file '$@' \
		--arg obj_deps "$$OBJ_DEPS" \
		--arg lib_deps "$$LIB_DEPS" \
		'{ file: $$file, deps: ($$obj_deps + " " + $$lib_deps) | split(" ") | map(select(length > 0)) } | [.]' \
		> '$@.link.dep.json'
	$(Q)echo "Generated $@.link.dep.json"
endif
$(OFILES): $(abspath $(lastword $(filter-out %.d, $(MAKEFILE_LIST))))

ifneq ($(MAKECMDGOALS),clean)
include $(OFILES:.o=.d)
endif

$(DIR):
	$(Q)$(MKDIR) $@


$(OBJDIR)/%.d: %.cc | $(DIR)
	$(Q)$(CXX) -MM $(CPPFLAGS) $(CURDIR)/$< > $@.tmp; \
	sed -i 's,\($(notdir $*)\)\.o[ :]*,$(basename $@).o $@ :,g' $@.tmp; \
	mv $@.tmp $@

$(OBJDIR)/%.d: %.cpp | $(DIR)
	$(Q)$(CXX) -MM $(CPPFLAGS) $(CURDIR)/$< > $@.tmp; \
	sed -i 's,\($(notdir $*)\)\.o[ :]*,$(basename $@).o $@ :,g' $@.tmp; \
	mv $@.tmp $@

$(OBJDIR)/%.d: %.cxx | $(DIR)
	$(Q)$(CXX) -MM $(CPPFLAGS) $(CURDIR)/$< > $@.tmp; \
	sed -i 's,\($(notdir $*)\)\.o[ :]*,$(basename $@).o $@ :,g' $@.tmp; \
	mv $@.tmp $@

$(OBJDIR)/%.d: %.c | $(DIR)
	$(Q)$(CC) -MM $(CPPFLAGS) $(CURDIR)/$< > $@.tmp; \
	sed -i 's,\($(notdir $*)\)\.o[ :]*,$(basename $@).o $@ :,g' $@.tmp; \
	mv $@.tmp $@

dep_parser_cpp: dep_parser.cpp
	$(Q)$(CXX) -o $@ $< -std=c++11 -O2
	$(Q)echo "Compiled C++ dependency parser"

.PRECIOUS: $(OBJDIR)/%.dep.json
$(OBJDIR)/%.dep.json: $(OBJDIR)/%.d $(if $(filter cpp,$(DEP_PARSER)),dep_parser_cpp)
ifeq ($(DEP_PARSER), py)
	$(Q)$(CURDIR)/dep_parser.py $< $@
else ifeq ($(DEP_PARSER), cpp)
	$(Q)$(CURDIR)/dep_parser_cpp $< $@
else
	$(Q)$(eval DEPS := $(shell sed -e ':a' -e '/\\$$/N' -e 's/\\\n/ /g' -e 'ta' -e 's/.*: *//' '$<'))
	$(Q)jq -n \
	  --arg file '$(@:.dep.json=.o)' \
	  --arg deps '$(DEPS)' \
	  '[{file: $$file, deps: [$$deps | split(" ") | .[] | select(length > 0)]}]' \
	  > '$@'
	$(Q)echo "Generated $@"
endif

# COMPILE.cc = $(CXX) $(CXXFLAGS) $(CPPFLAGS) $(TARGET_ARCH) -c
$(OBJDIR)/%.o: %.cc $(if $(filter yes,$(DEP_TREE)),$(OBJDIR)/%.dep.json) | $(DIR)
	$(Q)$(COMPILE.cc) $(OUTPUT_OPTION) $<

$(OBJDIR)/%.o: %.cpp $(if $(filter yes,$(DEP_TREE)),$(OBJDIR)/%.dep.json) | $(DIR)
	$(Q)$(COMPILE.cc) $(OUTPUT_OPTION) $<

$(OBJDIR)/%.o: %.cxx $(if $(filter yes,$(DEP_TREE)),$(OBJDIR)/%.dep.json) | $(DIR)
	$(Q)$(COMPILE.cc) $(OUTPUT_OPTION) $<

$(OBJDIR)/%.o: %.c $(if $(filter yes,$(DEP_TREE)),$(OBJDIR)/%.dep.json) | $(DIR)
	$(Q)$(COMPILE.c) $(OUTPUT_OPTION) $<

all:$(TARGET)
	$(Q)echo "[ $(AUTHOR) ]: all work done"; $(TARGET)



.PHONY: clean all
clean_cmake:
	$(Q)cmake --build $(CMAKE_PROJECT)/build --target clean

clean: # clean_cmake
	$(Q)d=$$(date +%s); \
	$(RM) $(OFILES) $(OFILES:.o=.d) $(OFILES:.o=.dep.json) $(TARGET) $(TARGET).link.dep.json dep.json ; \
	echo "Elapse $$(($$(date +%s)-d)) seconds"

dep.json: $(if $(filter yes,$(DEP_TREE)),$(OFILES:.o=.dep.json) $(TARGET))
ifeq ($(DEP_TREE), yes)
	$(Q)jq -s 'flatten' $(OFILES:.o=.dep.json) $(TARGET).link.dep.json > $@
	$(Q)echo "Generated $@"
else
	$(Q)echo "dep.json target requires DEP_TREE=yes"
	$(Q)false
endif

check: dep.json
	$(Q)find . -name "dep.json" -exec sh -c "echo {};cat {}" \;

benchmark: clean
	@echo "=== dependencies parser benchmark test ==="
	@echo "raw (eval+sed+jq)..."
	@time make DEP_TREE=yes DEP_PARSER=raw all > /dev/null
	@make clean > /dev/null
	@echo "Python parser..."
	@time make DEP_TREE=yes DEP_PARSER=py all > /dev/null
	@make clean > /dev/null
	@echo "C++ parser..."
	@time make DEP_TREE=yes DEP_PARSER=cpp all > /dev/null
	@echo "=== test completed ==="

