# SPDX-License-Identifier: MIT
#
# target.c.mk -- C/C++ sub-target rules.  Artifact basename = .mk basename;
# no rename knob (gm keys the dispatcher, depend.mk edges, LDLIBS refs
# and artefact paths on that one name).  Output by $(TYPE):
#   exe/test:  <name>
#   lib:       <name>.so (default) | <name>.a (LIB_KIND := static)


CURRENT_FILE := $(lastword $(abspath $(MAKEFILE_LIST)))
MAKEFILE     := $(lastword $(filter-out $(ADMIN_DIR)/make/% ,$(abspath $(MAKEFILE_LIST))))
TARGET       := $(basename $(notdir $(MAKEFILE)))
MAKEFILE_DIR := $(abspath $(dir $(MAKEFILE)))

GM_FRAMEWORK_MK := $(GM_FRAMEWORK_CORE_MK) \
    $(CURRENT_FILE) \
    $(ADMIN_DIR)/make/scripts/depcxx.sh \
    $(ADMIN_DIR)/make/scripts/link_dep_json.jq \
    $(ADMIN_DIR)/make/scripts/make-versionstamp.sh

ifeq ($(TYPE),test)
LDLIBS  += -lgtest $(if $(filter 1,$(TEST_HAS_MAIN)),,-lgtest_main) -lpthread
endif

include $(ADMIN_DIR)/make/target.common.mk

# unset / empty         -> no coupling (default)
# PKG_HEADERS := yes    -> auto-derive from pkg_of.mk (PKG_OF_$(TARGET))
# Escape hatch for rare "not bundled but still needs the header"
# cases (e.g. tests asserting on pkg identity without being
# packaged): set an explicit list, `PKG_HEADERS := pkg-p2 pkg-p3`.
# Any value other than `yes` is taken as a list verbatim.
ifeq ($(PKG_HEADERS),yes)
PKG_HEADERS := $(PKG_OF_$(TARGET))
endif


ifeq ($(DRY_RUN),1)
DRY_DEPS := $(strip \
    $(filter $(patsubst -l%,lib%,$(LDLIBS)),$(TARGET_ALL)) \
    $(patsubst %,%-header,$(filter $(PKG_HEADERS),$(TARGET_ALL))))

ifeq ($(LDLIB_CHECK),1)
_DRY_LINK_DIRS    := $(sort $(patsubst -L%,%,$(filter -L%,$(LDFLAGS))))
_USER_LIB_STEMS   := $(call _SCAN_LIB_DIRS,$(_DRY_LINK_DIRS))
_LDLIB_UNRESOLVED := $(filter-out \
    $(patsubst lib%,%,$(filter lib%,$(TARGET_ALL))) $(GM_SYS_LIBS) $(_USER_LIB_STEMS), \
    $(patsubst -l%,%,$(filter -l%,$(LDLIBS))))
ifneq ($(_LDLIB_UNRESOLVED),)
$(warning $(MAKEFILE): LDLIBS entries $(_LDLIB_UNRESOLVED)) resolve to nothing.)
endif
endif

include $(ADMIN_DIR)/make/target.dry-run.mk
else


# Auto-wired dirs: <srcdir>/src on vpath, <srcdir>/include on -I.
CONV_SRC_DIR := $(wildcard $(MAKEFILE_DIR)/src)
CONV_INC_DIR := $(wildcard $(MAKEFILE_DIR)/include)
ifeq ($(TYPE),test)
CONV_INC_DIR += $(wildcard $(MAKEFILE_DIR)/../include)
endif


# Generated headers: <srcdir>/**/*.h.in -> $(BUILD_DIR)/**/*.h with
# @VAR@ substitution.
HEADER_INS    := $(shell find $(MAKEFILE_DIR) -name '*.h.in' 2>/dev/null)
GEN_HEADERS   := $(patsubst $(MAKEFILE_DIR)/%.h.in, $(BUILD_DIR)/%.h, $(HEADER_INS))
GEN_INC_DIRS  := $(sort $(dir $(GEN_HEADERS)))

# PKG_HEADERS wiring: each pkg's component.h lives at $(GM_GEN_DIR)/<pkg>.
# `strings <artefact> | grep GM_VERSIONSTAMP:` recovers pkg identity.
_PKG_HEADER_FILES := $(foreach p,$(PKG_HEADERS),$(GM_GEN_DIR)/$(p)/component.h)
ifneq ($(PKG_HEADERS),)
CCFLAGS += -I$(GM_GEN_DIR)
_VS_CPP := $(GM_GEN_DIR)/$(TARGET)_versionstamp.cpp
endif

BUILD_DATE    ?= $(shell date -u +%Y-%m-%dT%H:%M:%SZ)
BUILD_HOST    ?= $(shell hostname 2>/dev/null || echo unknown)
HEADER_GEN_VARS ?=
HEADER_GEN_VARS += TARGET BUILD_MODE BUILD_ARCH BUILD_DATE BUILD_HOST


SPACE         := $(subst ,, )
comma         := ,
CC_SUFFIX     := $(if $(CXXSOURCE),.cxx,.cpp)
CXXSOURCE     := $(sort $(CXXSOURCE))
CPPSOURCE     := $(sort $(CPPSOURCE))
CXX_SRCS      := $(CXXSOURCE) $(CPPSOURCE)
C_SRCS        := $(CSOURCE)

# -L dirs mined from LDFLAGS for .LIBPATTERNS vpath resolution.
# Name kept distinct from flags.mk's LD_PATH (linker binary).
LINK_DIRS     := $(sort $(patsubst -L%,%,$(filter -L%,$(LDFLAGS))))


.LIBPATTERNS   = lib%.so lib%.a
GENERATED_DIR  = $(GM_GEN_DIR)
vpath %$(CC_SUFFIX) $(MAKEFILE_DIR)$(if $(CONV_SRC_DIR),:$(CONV_SRC_DIR)):$(GENERATED_DIR)
vpath %.c   $(MAKEFILE_DIR)$(if $(CONV_SRC_DIR),:$(CONV_SRC_DIR)):$(GENERATED_DIR)
vpath %.d   $(BUILD_DIR)
vpath %.so  $(subst $(SPACE),:,$(LINK_DIRS))
vpath %.a   $(subst $(SPACE),:,$(LINK_DIRS))

INC_SOURCE_PATH := -I$(MAKEFILE_DIR) -I$(BUILD_DIR) $(addprefix -I,$(CONV_INC_DIR)) $(addprefix -I,$(GEN_INC_DIRS))
OBJS            := $(patsubst %$(CC_SUFFIX), $(BUILD_DIR)/%.o, $(CXX_SRCS))
OBJS            += $(patsubst %.c, $(BUILD_DIR)/%.o, $(C_SRCS))
ifneq ($(_VS_CPP),)
_VS_OBJ         := $(BUILD_DIR)/$(TARGET)_versionstamp.o
_VS_DEPJSON     := $(BUILD_DIR)/$(TARGET)_versionstamp.dep.json
OBJS            += $(_VS_OBJ)
endif

LIB_KIND       ?= shared
LIB_KIND_VALID := shared static
ifeq ($(filter $(LIB_KIND),$(LIB_KIND_VALID)),)
$(error $(MAKEFILE): LIB_KIND='$(LIB_KIND)' is invalid.  Valid: $(LIB_KIND_VALID))
endif

ifeq ($(TYPE),exe)
TARGET_PATH   := $(OUT_DIR)/$(TARGET)
TARGET_KIND   := bin
LINK_OUT      := $(BUILD_DIR)/$(TARGET)
# rpath points at GM_LIB_DIR (where .so's live), not OUT_DIR.
LINK_OPT      := -Wl,-rpath=$(GM_LIB_DIR)
LINK_LIBS     := $(LDLIBS)
else ifeq ($(TYPE),lib)
ifeq ($(LIB_KIND),static)
TARGET_PATH   := $(OUT_DIR)/$(TARGET).a
TARGET_KIND   := ar
LINK_OUT      :=
LINK_OPT      :=
else
TARGET_PATH   := $(OUT_DIR)/$(TARGET).so
TARGET_KIND   := lib
LINK_OUT      := $(BUILD_DIR)/$(TARGET).so
LINK_OPT      := -shared -Wl,--soname,$(TARGET).so
endif
LINK_LIBS     :=
else ifeq ($(TYPE),test)
# test-* is a gtest-linked exe.  -lgtest / -lgtest_main / CXX_STD are
# wired at the top of this file so DRY_RUN sees them too.
TARGET_PATH   := $(OUT_DIR)/$(TARGET)
TARGET_KIND   := bin
LINK_OUT      := $(BUILD_DIR)/$(TARGET)
LINK_OPT      := -Wl,-rpath=$(GM_LIB_DIR) -pthread
LINK_LIBS     := $(LDLIBS)

GTEST_ROOT   ?= $(ADMIN_DIR)/tools/gtest-1.14.0
CCFLAGS      += -I$(GTEST_ROOT)/include -pthread

# Tests get relaxed compile options
# Product code keeps strict + -Werror (see flags.mk).
CFLAGS  := $(filter-out -Werror,$(CFLAGS))
CCFLAGS := $(filter-out -Werror,$(CCFLAGS))
CFLAGS  += -Wno-unused-variable -Wno-unused-parameter
CCFLAGS += -Wno-unused-variable -Wno-unused-parameter
else
$(error target.c.mk: target type "$(TYPE)" not handled here. )
endif


LD_CMD = $(LD) -o $(LINK_OUT) $(LINK_OPT) $(LDFLAGS) $(OBJS) $(LDLIBS)


# flag-change detection
_CFLAGS_STAMP  := $(BUILD_DIR)/.$(TARGET).cflags.stamp
_LDFLAGS_STAMP := $(BUILD_DIR)/.$(TARGET).ldflags.stamp
_CFLAGS_SIG    := $(CC)|$(C)|$(CFLAGS)|$(CCFLAGS)|$(INC_SOURCE_PATH)
_LDFLAGS_SIG   := $(LD)|$(LDFLAGS)|$(LDLIBS)|$(LINK_OPT)|$(AR)|$(ARFLAGS)
.PHONY: _c_flags_force
_c_flags_force: ;
$(_CFLAGS_STAMP): _c_flags_force | $(BUILD_DIR)
	@sig='$(_CFLAGS_SIG)' ; \
	 [ "$$sig" = "$$(cat $@ 2>/dev/null || true)" ] && exit 0 ; \
	 had=$$( [ -f $@ ] && echo 1 ) ; \
	 printf '%s' "$$sig" > $@ ; \
	 [ -n "$$had" ] && $(ECHO) "  FLAGS   $(TARGET): compile flags changed" ; \
	 exit 0
$(_LDFLAGS_STAMP): _c_flags_force | $(BUILD_DIR)
	@sig='$(_LDFLAGS_SIG)' ; \
	 [ "$$sig" = "$$(cat $@ 2>/dev/null || true)" ] && exit 0 ; \
	 had=$$( [ -f $@ ] && echo 1 ) ; \
	 printf '%s' "$$sig" > $@ ; \
	 [ -n "$$had" ] && $(ECHO) "  FLAGS   $(TARGET): link flags changed" ; \
	 exit 0

$(OBJS): $(_CFLAGS_STAMP)
ifneq ($(LINK_OUT),)
$(LINK_OUT): $(_LDFLAGS_STAMP)
endif
ifneq ($(filter %.a,$(TARGET_PATH)),)
$(BUILD_DIR)/$(TARGET).a: $(_LDFLAGS_STAMP)
endif


ifeq ($(DEP_TREE),yes)
DEP_JSON_OBJS  := $(patsubst %.o,%.dep.json,$(OBJS))
_DEP_JSON_TAG  := $(if $(strip $(filter $(TARGET).o,$(notdir $(OBJS)))),$(TYPE).,)
DEP_JSON_LINK  := $(OUT_DIR)/$(TARGET).$(_DEP_JSON_TAG)dep.json
DEP_JSON_ALL   := $(DEP_JSON_OBJS) $(DEP_JSON_LINK)
else
DEP_JSON_ALL   :=
endif


ifneq ($(_PKG_HEADER_FILES),)
$(OBJS): $(_PKG_HEADER_FILES)

# Two-step versionstamp: gen .cpp, then compile to .o like any object.
$(_VS_CPP): $(_PKG_HEADER_FILES) $(MAKEFILE) $(ADMIN_DIR)/make/scripts/make-versionstamp.sh | $(GM_GEN_DIR)
	$(V_VER)
	$(Q)$(ADMIN_DIR)/make/scripts/make-versionstamp.sh $@ $(TARGET) $(_PKG_HEADER_FILES)

$(_VS_OBJ): $(_VS_CPP) $(_PKG_HEADER_FILES) | $(BUILD_DIR)
	$(V_CXX)
	$(Q)$(CC) -c -o $@ $< -I$(GM_GEN_DIR) $(CCFLAGS)
	$(Q)jq -cn --arg f '$(abspath $<)' \
	          --arg d '$(MAKEFILE_DIR)' \
	          --arg c '$(CC) -c $(abspath $<) -o $@ -I$(GM_GEN_DIR) $(CCFLAGS)' \
	          --arg o '$@' \
	          '{file:$$f, directory:$$d, command:$$c, output:$$o}' > $(@:.o=.cc.json)

# Explicit .dep.json for the versionstamp .o -- the standard
# `%.dep.json: %.d` pattern rule doesn't fire (no .d for a synthesised
# .cpp).  Deps are exact: pkg headers + generator script + owning .mk.
$(_VS_DEPJSON): $(_VS_OBJ) $(ADMIN_DIR)/make/scripts/make-versionstamp.sh | $(BUILD_DIR)
	$(V_JSON)
	$(Q)jq -n \
	    --arg file    '$(_VS_OBJ)'                                   \
	    --arg gen     '$(ADMIN_DIR)/make/scripts/make-versionstamp.sh' \
	    --arg mk      '$(MAKEFILE)'                                  \
	    --arg headers '$(_PKG_HEADER_FILES)'                         \
	    '{file: $$file, deps: (($$headers | split(" ")) + [$$gen, $$mk] | map(select(length > 0)) | unique | sort)}' > $@
endif

ifneq ($(GEN_HEADERS),)
$(OBJS): $(GEN_HEADERS)
$(BUILD_DIR)/%.h: $(MAKEFILE_DIR)/%.h.in | $(BUILD_DIR)
	$(V_GEN)
	$(Q)mkdir -p $(@D)
	$(Q)sed $(foreach v,$(HEADER_GEN_VARS),-e 's|@$(v)@|$(subst |,\|,$($(v)))|g') $< > $@.tmp && mv $@.tmp $@
endif


# $(TARGET) :: artifact + (DEP_TREE=yes only) dep.json sidecars.
$(TARGET) :: $(TARGET_PATH) $(DEP_JSON_ALL);

ifneq ($(filter %.a,$(TARGET_PATH)),)
$(BUILD_DIR)/%.a : $(OBJS) | $(BUILD_DIR)
	$(V_AR)
	$(Q)$(AR) $(ARFLAGS) $@ $(OBJS)
endif

# Link (exe or .so).  LINK_OUT is empty for static-only libs -> skip.
ifneq ($(LINK_OUT),)
$(LINK_OUT) : $(OBJS) $(LINK_LIBS) | $(BUILD_DIR)
	$(if $(filter bin,$(TARGET_KIND)),$(V_LD_EXE),$(V_LD_SO))
	$(Q)$(LD_CMD)
endif

# Stage BUILD_DIR artefact into OUT_DIR (symlink for exe/.so/.a).
$(TARGET_PATH) : $(OUT_DIR)/% : $(BUILD_DIR)/% | $(OUT_DIR)
	$(V_LN)
	$(Q)$(LN) $(BUILD_DIR)/$(@F) $@

$(BUILD_DIR)/%.d: %$(CC_SUFFIX)|$(BUILD_DIR)
	$(V_DEP)
	$(Q)set -e; $(CC) -MM $(INC_SOURCE_PATH) $(CCFLAGS) $< \
	 | sed 's#\($*\)\.o[ :]*#$(basename $@).o $@ : #g' > $@; [ -s $@ ] || rm -f $@

$(BUILD_DIR)/%.o: %$(CC_SUFFIX) $(MAKEFILE) $(GM_FRAMEWORK_MK)|$(BUILD_DIR)
	$(V_CXX)
	$(Q)$(RM) -f $@ $(TARGET_PATH)
	$(Q)$(CC) -o $@ -c $< $(INC_SOURCE_PATH) $(CCFLAGS)
	$(Q)jq -cn --arg f '$(abspath $<)' \
	          --arg d '$(MAKEFILE_DIR)' \
	          --arg c '$(CC) -c $(abspath $<) -o $@ $(INC_SOURCE_PATH) $(CCFLAGS)' \
	          --arg o '$@' \
	          '{file:$$f, directory:$$d, command:$$c, output:$$o}' > $(@:.o=.cc.json)

$(BUILD_DIR)/%.d: %.c|$(BUILD_DIR)
	$(V_DEP)
	$(Q)set -e; $(C) -MM $(INC_SOURCE_PATH) $(CFLAGS) $< \
	 | sed 's#\($*\)\.o[ :]*#$(basename $@).o $@ : #g' > $@; [ -s $@ ] || rm -f $@

$(BUILD_DIR)/%.o: %.c $(MAKEFILE) $(GM_FRAMEWORK_MK)|$(BUILD_DIR)
	$(V_CC)
	$(Q)$(RM) -f $@ $(TARGET_PATH)
	$(Q)$(C) -o $@ -c $< $(INC_SOURCE_PATH) $(CFLAGS)
	$(Q)jq -cn --arg f '$(abspath $<)' \
	          --arg d '$(MAKEFILE_DIR)' \
	          --arg c '$(C) -c $(abspath $<) -o $@ $(INC_SOURCE_PATH) $(CFLAGS)' \
	          --arg o '$@' \
	          '{file:$$f, directory:$$d, command:$$c, output:$$o}' > $(@:.o=.cc.json)

$(BUILD_DIR)/%.dep.json: $(BUILD_DIR)/%.d
	$(V_JSON)
	$(Q)sed -e ':a' -e '/\\$$/N' -e 's/\\\n/ /g' -e 'ta' -e 's/.*: *//' '$<' | tr '\n' ' ' | \
	 jq -R -s --arg file '$(@:.dep.json=.o)' \
		'{file: $$file, deps: [. | split(" ") | .[] | select(length > 0)]}' > '$@'

$(DEP_JSON_LINK): $(TARGET_PATH) $(DEP_JSON_OBJS) | $(OUT_DIR)
	$(V_JSON)
	$(Q)LIB_DEPS=$$($(ADMIN_DIR)/make/scripts/depcxx.sh -L$(OUT_DIR) \
	            $(filter -L%,$(LDFLAGS)) $(filter -l%,$(LDLIBS)) | tr '\n' ' ') ; \
	jq -s -f $(ADMIN_DIR)/make/scripts/link_dep_json.jq          \
	    --arg LIB_DEPS   "$$LIB_DEPS"                            \
	    --arg HEADER_INS "$(HEADER_INS)"                         \
	    --arg MK_FILE    "$(MAKEFILE)"                           \
	    --arg FRAMEWORK  "$(GM_FRAMEWORK_MK)"                    \
	    --arg FILE       "$(lastword $(TARGET_PATH))"            \
	    $(DEP_JSON_OBJS) > $@


.PRECIOUS: %/$(BUILD_MODE)
%/$(BUILD_MODE):
	@$(MKDIR) $@
%/linux64:
	@$(MKDIR) $@

ifneq ($(MAKECMDGOALS), clean)
-include $(patsubst %$(CC_SUFFIX), $(BUILD_DIR)/%.d, $(CXX_SRCS))
ifneq ($(CSOURCE),)
-include $(patsubst %.c, $(BUILD_DIR)/%.d, $(C_SRCS))
endif
endif

clean:
	@$(RM) $(TARGET_PATH) $(DEP_JSON_LINK) $(BUILD_DIR)/$(TARGET).so
	@$(RM) $(BUILD_DIR)/*.d $(BUILD_DIR)/*.o $(BUILD_DIR)/*.dep.json $(BUILD_DIR)/*.cc.json
	@$(RM) $(_CFLAGS_STAMP) $(_LDFLAGS_STAMP)
	@$(RM) $(BUILD_DIR)/*.gcda $(BUILD_DIR)/*.gcno
	@$(RM) $(GEN_HEADERS)
	$(V_CLEAN)


endif # DRY_RUN
