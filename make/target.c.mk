# target.mk - cyrus make tools
#
# Copyright (c) 2024 cyrus cui <cyrus.cui@nokia-sbell.com>
#
# Permission is hereby granted, free of charge, to any person obtaining
# a copy of this software and associated documentation files (the
# "Software"), to deal in the Software without restriction, including
# without limitation the rights to use, copy, modify, merge, publish,
# distribute, sublicense, and/or sell copies of the Software, and to
# permit persons to whom the Software is furnished to do so, subject to
# the following conditions:
#
# The above copyright notice and this permission notice shall be
# included in all copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
# EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
# MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
# NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE
# LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION
# OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION
# WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
#
########################################################################
#
# brief   : 1. automatic produce target variables/recipe definations;
#           2. provide check target for your debug;
#
########################################################################


CURRENT_FILE:= $(lastword $(abspath $(MAKEFILE_LIST)))
MAKEFILE    := $(lastword $(filter-out $(ADMIN_DIR)/make/% ,$(abspath $(MAKEFILE_LIST))))
TARGET      := $(basename $(notdir $(MAKEFILE)))
MAKEFILE_DIR:= $(abspath $(dir $(MAKEFILE)))
#$(info --> $(ADMIN_DIR) $(TARGET) $(BUILD_DIR))

ifeq ($(DRY_RUN),)

ifeq ($(BUILD_DIR),)
include $(ADMIN_DIR)/make/rules.mk
TMP_DIR   := $(CURDIR)/linux64
BUILD_DIR := $(TMP_DIR)
OUT_DIR   := $(TMP_DIR)
$(info --> Set output location to $(TMP_DIR) which can be replaced with "TMP_DIR=/path")
endif

# variables defined in user's mk file
SPACE         := $(subst ,, )
CCflags_local := $(CCFLAGS) $(CCFLAGS_Linux) $(CCFLAGS_CAF)
Cflags_local  := $(CFLAGS) $(CFLAGS_Linux) $(CFLAGS_CAF)
LDflags_local := $(LDFLAGS)
LDLIBS        += $(LDLIBS_Linux)
LD_PATH       := $(sort $(patsubst -L%,%,$(filter -L%,$(LDflags) $(LDFLAGS))))
CXXSOURCE     := $(sort $(CXXSOURCE))
CPPSOURCE     := $(sort $(CPPSOURCE))
CC_SUFFIX     := $(if $(CXXSOURCE),.cxx,.cpp)
cxx_Srcs      := $(CXXSOURCE) $(CPPSOURCE)
c_Srcs        := $(CSOURCE)


.LIBPATTERNS   = lib%.so lib%.a
GENERATED_DIR  = $(PROJ_TOP)/build/gen/include/home/rhlinux
vpath %$(CC_SUFFIX) $(MAKEFILE_DIR):$(GENERATED_DIR)
vpath %.c   $(MAKEFILE_DIR):$(GENERATED_DIR)
vpath %.d   $(BUILD_DIR)
vpath %.so  $(subst $(SPACE),:,$(LD_PATH))
vpath %.a   $(subst $(SPACE),:,$(LD_PATH))

INC_SOURCE_PATH := -I$(MAKEFILE_DIR) -I$(BUILD_DIR)
Objs            := $(patsubst %$(CC_SUFFIX), $(BUILD_DIR)/%.o, $(cxx_Srcs))
Objs            += $(patsubst %.c, $(BUILD_DIR)/%.o, $(c_Srcs))

ifeq ($($(TARGET)_type),exe)
TARGET          := $(if $(BIN_NAME),$(BIN_NAME),$(TARGET))
TARGET_PATH     := $(OUT_DIR)/$(TARGET)
TARGET_TYPE     := bin
else ifeq ($($(TARGET)_type),lib)
TARGET          := $(if $(LIB_NAME),lib$(LIB_NAME),$(TARGET))
TARGET_PATH     := $(OUT_DIR)/$(TARGET).a \
                   $(OUT_DIR)/$(TARGET).so
TARGET_SUFFIX   := .so
TARGET_TYPE     := lib ar
else ifeq ($($(TARGET)_type),slib)
TARGET          := $(if $(AR_NAME),lib$(AR_NAME),$(TARGET))
TARGET_PATH     := $(OUT_DIR)/$(TARGET).a
TARGET_TYPE     := ar
TARGET_SUFFIX   := .a
else
$(error  target $($(TARGET)_type) not supported yet! )
endif


SHARED_OPT   = -shared -Wl,--soname,$(TARGET).so
BIN_OPT      = -Wl,-rpath=$(OUT_DIR)

LD_CMD = $(LD) -o $(BUILD_DIR)/$(TARGET)$(TARGET_SUFFIX) \
        $(if $(TARGET_SUFFIX),$(SHARED_OPT),$(BIN_OPT)) $(LDflags_local) \
        $(LDflags) $(Objs) $(LDObjects) $(LDLIBS) $(LDflags_options)


$(TARGET) :: $(if $(COMP_HEADER_PATH),$(CompHeader)) $(TARGET_PATH);
ifneq ($(filter %.a,$(TARGET_PATH)),)
$(BUILD_DIR)/%.a : $(Objs) | $(BUILD_DIR)
	@$(ECHO) ...
	@$(ECHO) ... Build the Static Library $(@F)
	@$(ECHO) ...
	$(AR) $(ARflags_local) $(ARflags) $@ $(Objs) $(ObjsCache)
endif

$(if $(filter bin,$(TARGET_TYPE)),$(BUILD_DIR)/$(TARGET),$(BUILD_DIR)/$(TARGET).so) : $(Objs) \
                $(if $(filter bin,$(TARGET_TYPE)),$(LDLIBS)) | $(BUILD_DIR)
	@$(ECHO) ...
	@$(ECHO) ... Build the $(if $(filter bin,$(TARGET_TYPE)),Binary,Shared Library) $(@F)
	@$(ECHO) ...
	@Cmd="$(LD_CMD)";\
	$(ECHO) "$$Cmd"; eval $$Cmd

$(TARGET_PATH) : $(OUT_DIR)/% : $(BUILD_DIR)/% | $(OUT_DIR)
	$(LN) $(BUILD_DIR)/$(@F) $@

$(BUILD_DIR)/%.d: %$(CC_SUFFIX)|$(BUILD_DIR)
	@$(ECHO) ...
	@$(ECHO) ... make depend on $(<F)
	@set -e; $(CC) -MM $(INC_SOURCE_PATH) $(CCflags) $(CCflags_local) $< \
	 | sed 's#\($*\)\.o[ :]*#$(basename $@).o $@ : #g' > $@; [ -s $@ ] || rm -f $@

$(BUILD_DIR)/%.o: %$(CC_SUFFIX) $(MAKEFILE) $(CURRENT_FILE)|$(BUILD_DIR)
	@$(ECHO) ...
	@$(ECHO) ... Build $(@F) "(from" $<")"
	@$(ECHO) ...
	@$(RM) -f $@ $(TARGET_PATH)
	$(CC) -o $@ -c $< $(INC_SOURCE_PATH) $(CCflags_local) $(CCflags) \
		$(CCflags_debug) $(CCflags_release) $(CCflags_local2) $(CCflags_options)

$(BUILD_DIR)/%.d: %.c|$(BUILD_DIR)
	@$(ECHO) ...
	@$(ECHO) ... make depend on $(<F)
	@set -e; $(C) -MM $(INC_SOURCE_PATH) $(Cflags) $(Cflags_local) $< \
	 | sed 's#\($*\)\.o[ :]*#$(basename $@).o $@ : #g' > $@; [ -s $@ ] || rm -f $@

$(BUILD_DIR)/%.o: %.c $(MAKEFILE) $(CURRENT_FILE)|$(BUILD_DIR)
	@$(ECHO) ...
	@$(ECHO) ... Build $(@F) "(from" $<")"
	@$(ECHO) ...
	@$(RM) -f $@ $(TARGET_PATH)
	$(C) -o $@ -c $< $(INC_SOURCE_PATH) $(Cflags_local) $(Cflags) $(Cflags_local2) $(Cflags_options)


.PRECIOUS: %/$(BUILD_MODE)
%/$(BUILD_MODE):
	@$(MKDIR) $@
%/linux64:
	@$(MKDIR) $@

ifneq ($(MAKECMDGOALS), clean)
-include $(patsubst %$(CC_SUFFIX), $(BUILD_DIR)/%.d, $(cxx_Srcs))
ifneq ($(CSOURCE),)
-include $(patsubst %.c, $(BUILD_DIR)/%.d, $(c_Srcs))
endif
endif

clean:
	@$(RM) $(TARGET_PATH) $(BUILD_DIR)/$(TARGET).so
	@$(RM) $(BUILD_DIR)/*.d $(BUILD_DIR)/*.o
	@$(ECHO) ... clean $(BUILD_MODE) $(TARGET) ...

check: clean
	@mk_hash=$$($(MAKE) -f $(MAKEFILE) -B V=1 2>/dev/null | sed "s#$(PROJ_TOP)#\$$(PROJ_TOP)#g") ; \
	$(ECHO) $${mk_hash}|tee $(CURDIR)/mk_hash && sed -i 's/\s/\n/g' $(CURDIR)/mk_hash; \
	mk_hash=($$($(ECHO) $${mk_hash}|md5sum)); \
	$(ECHO) $${mk_hash}; \
	$(ECHO) "add previous compilation commands set, generate output, make comparation manually"



ifneq ($(COMP_HEADER_PATH),)

#  ... Generate component header ...

$(CompHeader):
	@$(ECHO) "\n... Not implement"

clean_comp :
#	$(RM) $(CompHeader)

clean: clean_comp
$(filter-out %.a,$(TARGET_PATH)) : $(CompHeader)
endif

else
#  ... DRY_RUN ...

dep_file := $(ADMIN_DIR)/make/depend.mk
ifneq ($(LDLIBS),)
dep_tgt := $(filter $(patsubst -l%,lib%,$(LDLIBS)),$(TARGET_ALL))
endif
.PHONY:dep
dep: $(MAKEFILE)
	@ $(ECHO) "Dependence deduction for $(TARGET) ..."
	@[ -s $(dep_file) ] || echo >> $(dep_file) ; \
	[ -n "$(dep_tgt)" ] && sed -i "/^$(TARGET):/{h;s/:.*/:$(dep_tgt)/};\$${x;/^$$/{s//$(TARGET):$(dep_tgt)/;H};x}" \
	$(dep_file) || sed -i "/^$(TARGET):/d" $(dep_file)

endif

