########################################################################
#
#
# author  : Cyrus Cui
# e-mail  : cyrus.cui@nokia-sbell.com
#
#
#
# brief   : 1. automatic produce target variables/recipe definations;
#           2. provide check target for your debug;
#           3. share output artifact with GM system;
#
########################################################################


ADMIN_DIR   := $(GMPS_TOP)_admin
CURRENT_FILE:= $(lastword $(abspath $(MAKEFILE_LIST)))
MAKEFILE    := $(lastword $(filter-out $(ADMIN_DIR)/production/make/% ,$(abspath $(MAKEFILE_LIST))))
TARGET      := $(basename $(notdir $(MAKEFILE)))
MAKEFILE_DIR:= $(abspath $(dir $(MAKEFILE)))
#$(info --> $(MAKEFILE) $(DRY_RUN))


ifeq ($(DRY_RUN),)

ifdef LIB_NAME
TARGET := lib$(LIB_NAME)
else ifdef AR_NAME
TARGET := lib$(AR_NAME)
else ifdef LIB_AR_NAME
TARGET := lib$(LIB_AR_NAME)
else ifdef BIN_NAME
TARGET := $(BIN_NAME)
endif

ifeq ($(BUILD_DIR),)
include $(ADMIN_DIR)/production/make/rules.mk
TMP_DIR   := $(CURDIR)/linux64
BUILD_DIR := $(TMP_DIR)
OUT_DIR   := $(TMP_DIR)
$(info --> Set output location to $(TMP_DIR) which can be replaced with "TMP_DIR=/path")
endif

SHELL := /bin/bash

SPACE         := $(subst ,, )
CCflags_local := $(CCFLAGS) $(CCFLAGS_Linux) $(CCFLAGS_CAF)
Cflags_local  := $(CFLAGS) $(CFLAGS_Linux) $(CFLAGS_CAF)
LDflags_local := $(LDFLAGS)
LDLIBS        += $(LDLIBS_Linux)
LD_PATH       := $(sort $(patsubst -L%,%,$(filter -L%,$(LDflags) $(LDFLAGS))))
CXXSOURCE     := $(sort $(CXXSOURCE))
CPPSOURCE     := $(sort $(CPPSOURCE))
CC_SRC_SUFFIX := $(if $(CXXSOURCE),.cxx,.cpp)
cxx_Srcs      := $(CXXSOURCE) $(CPPSOURCE)
c_Srcs        := $(CSOURCE)



.LIBPATTERNS   = lib%.so lib%.a
vpath %$(CC_SRC_SUFFIX) $(MAKEFILE_DIR):$(GMPS_TOP)_do/gen/include/home/rhlinux
vpath %.c   $(MAKEFILE_DIR):$(GMPS_TOP)_do/gen/include/home/rhlinux
vpath %.d   $(BUILD_DIR)
vpath %.so  $(subst $(SPACE),:,$(LD_PATH))
vpath %.a   $(subst $(SPACE),:,$(LD_PATH))



INC_SOURCE_PATH := -I$(MAKEFILE_DIR) -I$(BUILD_DIR)
Objs            := $(patsubst %$(CC_SRC_SUFFIX), $(BUILD_DIR)/%.o, $(cxx_Srcs))
Objs            += $(patsubst %.c, $(BUILD_DIR)/%.o, $(c_Srcs))
ifeq ($(patsubst lib%,%,$(TARGET)),$(TARGET))
GMPS_Target     := $(OUT_DIR)/$(TARGET)
TARGET_TYPE     := bin
else ifneq ($(LIB_AR_NAME),)
GMPS_Target     := $(OUT_DIR)/$(TARGET).a \
                   $(OUT_DIR)/$(TARGET).so
TARGET_SUFFIX   := .so
TARGET_TYPE     := lib ar
else ifneq ($(AR_NAME),)
GMPS_Target     := $(OUT_DIR)/$(TARGET).a
TARGET_TYPE     := ar
else
GMPS_Target     := $(OUT_DIR)/$(TARGET).so
TARGET_SUFFIX   := .so
TARGET_TYPE     := lib
endif

#$(info --> $(INC_SOURCE_PATH))

SRC    = $(MAKEFILE_DIR)
GMKFIL = $(MAKEFILE)
GMKOPT = $(SRC)/$(TARGET).options
MKFIL  = $(BUILD_DIR)/$(TARGET).mk
#DEPS   = $(GMKFIL) $(MKFIL)

SHARED_OPT   = -shared -Wl,--soname,$(TARGET).so
LIBS_EXTRA   = -lnsl -lpthread -lresolv -lrt -lm $(if $(filter bin,$(TARGET_TYPE)),-ldl)
LIBS_PATTERN = 'thread|socket|nsl|resolv'

LD_CMD = $(LD) -o $(BUILD_DIR)/$(TARGET)$(TARGET_SUFFIX) \
        $(if $(TARGET_SUFFIX),$(SHARED_OPT)) $(LDflags_local) \
        $(LDflags) $(Objs) $(LDObjects) $(LDLIBS) $(LDflags_options)

PATTERN_STL4 = 'library=stlport4'
USE_STL4     = `$(ECHO) $(LD_CMD)| $(GREP) $(PATTERN_STL4)`



$(TARGET) :: $(if $(COMP_HEADER_PATH),$(CompHeader)) $(GMPS_Target);
ifneq ($(filter %.a,$(GMPS_Target)),)
$(filter %.a,$(GMPS_Target)) : $(LEXYACCTARGET) $(GENTOOLTARGET) $(Objs) | $(OUT_DIR)
	@$(ECHO) ...
	@$(ECHO) ... Build the Static Library $@
	@$(ECHO) ...
	$(AR) $(ARflags_local) $(ARflags) $(BUILD_DIR)/$(@F) $(Objs) $(ObjsCache)
	$(LN) $(BUILD_DIR)/$(@F) $@
endif

$(filter-out %.a,$(GMPS_Target)) : $(LEXYACCTARGET) $(GENTOOLTARGET) $(Objs) $(PreProcList) \
                                   $(if $(filter bin,$(TARGET_TYPE)),$(LDLIBS)) | $(OUT_DIR)
	@$(ECHO) ...
	@$(ECHO) ... Build the Shared Library $@
	@$(ECHO) ...
	@Libs=`$(ECHO) $(LDLIBS) | $(EGREP) $(LIBS_PATTERN)`;\
	if [ "$$Libs" ]; then LibsExtra="$(LIBS_EXTRA)"; fi ;\
	Cmd="$(LD_CMD) $$LibsExtra" ;\
	if [ "$(USE_STL4)" ]; then \
	    Cmd=`$(ECHO) $$Cmd | $(SED) 's/-lCstd//'`;\
	fi;  \
	$(ECHO) "\\t$$Cmd"; eval $$Cmd ;\
	if [ $$? != 0 ]; then $(RM) -f $@; exit 1; fi
	$(LN) $(BUILD_DIR)/$(TARGET)$(TARGET_SUFFIX) $@
	@-if [ -f $(GMKOPT) ]; then $(CAT) $(GMKOPT)>/dev/null; fi
	@if [ "$(Catch_DIR_PATTERN)" ]; then \
	   $(ECHO) ...			 ;\
	   $(ECHO) ... Directory Catcher ;\
	   $(ECHO) ...			 ;\
	  Catch="$(Catch_DIR_PATTERN)"	 ;\
	  for i in $$Catch; do \
	    dir=`$(ECHO) $$i | $(AWK) -F: '{print $$1}'`     ;\
	    pattern=`$(ECHO) $$i | $(AWK) -F: '{print $$2}'` ;\
	    if [ "$$pattern" ]; then \
	       cmd="$(GMPS_HOME)/bin/gms_catcher $$dir '$$pattern'";\
	    else \
	       cmd="$(GMPS_HOME)/bin/gms_catcher $$dir"; fi ;\
	    $(ECHO) $$cmd; eval $$cmd	     ;\
	    if [ $$? != 0 ]; then $(RM) -f $@; exit 1; fi ;\
	  done ;\
	fi
	@if [ "$(Catch_FILE)" ]; then \
	   $(ECHO) ...		    ;\
	   $(ECHO) ... File Catcher ;\
	   $(ECHO) ...		    ;\
	  for i in "$(Catch_FILE)"; do \
	    cmd="$(GMPS_HOME)/bin/gms_file_catcher $$i" ;\
	    $(ECHO) $$cmd; $$cmd	    		  ;\
	    if [ $$? != 0 ]; then $(RM) -f $@; exit 1; fi ;\
	  done ;\
	fi

$(BUILD_DIR)/%.d: %$(CC_SRC_SUFFIX)|$(BUILD_DIR)
	@$(ECHO) ...
	@$(ECHO) ... make depend on $(<F)
	@set -e; $(CC) -MM $(INC_SOURCE_PATH) $(CCflags) $(CCflags_local) $< \
	 | sed 's#\($*\)\.o[ :]*#$(basename $@).o $@ : #g' > $@; [ -s $@ ] || rm -f $@

$(BUILD_DIR)/%.o: %$(CC_SRC_SUFFIX) $(MAKEFILE) $(CURRENT_FILE)|$(BUILD_DIR)
	@$(ECHO) ...
	@$(ECHO) ... Build $(@F) "(from" $<")"
	@$(ECHO) ...
	@$(RM) -f $@ $(GMPS_Target)
	$(CC) -o $@ -c $< $(INC_SOURCE_PATH) $(CCflags_local) $(CCflags) $(CCflags_debug) $(CCflags_release) $(CCflags_local2) $(CCflags_options)

$(BUILD_DIR)/%.d: %.c|$(BUILD_DIR)
	@$(ECHO) ...
	@$(ECHO) ... make depend on $(<F)
	@set -e; $(C) -MM $(INC_SOURCE_PATH) $(Cflags) $(Cflags_local) $< \
	 | sed 's#\($*\)\.o[ :]*#$(basename $@).o $@ : #g' > $@; [ -s $@ ] || rm -f $@

$(BUILD_DIR)/%.o: %.c $(MAKEFILE) $(CURRENT_FILE)|$(BUILD_DIR)
	@$(ECHO) ...
	@$(ECHO) ... Build $(@F) "(from" $<")"
	@$(ECHO) ...
	@$(RM) -f $@ $(GMPS_Target)
	$(C) -o $@ -c $< $(INC_SOURCE_PATH) $(Cflags_local) $(Cflags) $(Cflags_local2) $(Cflags_options)


.PRECIOUS: %/$(BUILD_MODE)
%/$(BUILD_MODE):
	@$(MKDIR) $@
%/linux64:
	@$(MKDIR) $@

ifneq ($(MAKECMDGOALS), clean)
-include $(patsubst %$(CC_SRC_SUFFIX), $(BUILD_DIR)/%.d, $(cxx_Srcs))
ifneq ($(CSOURCE),)
-include $(patsubst %.c, $(BUILD_DIR)/%.d, $(c_Srcs))
endif
endif

clean:
	@$(RM) $(GMPS_Target) $(BUILD_DIR)/$(TARGET).so
	@$(RM) $(BUILD_DIR)/*.d $(BUILD_DIR)/*.o
	@$(ECHO) ... $(TARGET) clean $(BUILD_MODE) ...

check: clean
	@gm $(TARGET) -cld -mk; \
	gm_hash=$$($(MAKE) -C $(BUILD_DIR) -f $(TARGET).mk -B V=1 \
	GCINCS=  GCCINCS=  GLDFLAGS64=  ARFLAGS=   2>/dev/null | \
	sed "s#$(GMPS_TOP)#\$$(GMPS_TOP)#g") ; \
	$(ECHO) $${gm_hash}|tee $(CURDIR)/gm_hash && sed -i 's/\s/\n/g' $(CURDIR)/gm_hash; \
	gm_hash=($$($(ECHO) $${gm_hash}|md5sum)); \
	$(ECHO) $${gm_hash}; \
	mk_hash=$$($(MAKE) -f $(MAKEFILE) -B V=1 2>/dev/null | sed "s#$(GMPS_TOP)#\$$(GMPS_TOP)#g") ; \
	$(ECHO) $${mk_hash}|tee $(CURDIR)/mk_hash && sed -i 's/\s/\n/g' $(CURDIR)/mk_hash; \
	mk_hash=($$($(ECHO) $${mk_hash}|md5sum)); \
	$(ECHO) $${mk_hash};



ifneq ($(COMP_HEADER_PATH),)

#  ... Generate component header ...


export ADVANTAGE_HSS     = $(dir $(COMP_HEADER_PATH))
export ADVANTAGE_TOOLING = $(GMPS_TOP)_tools/advantage/tooling/rhlinux
export TOOLS_ADVANTAGE_ROOT=$(GMPS_TOP)_tools/advantage
export ADVANTAGE_IDIST=$(TOOLS_ADVANTAGE_ROOT)/idist/rhlinux
export ADVANTAGE_INTF_PLATFORM=$(TOOLS_ADVANTAGE_ROOT)/intf/platform
export ADVANTAGE_CFRAME_IF=$(ADVANTAGE_INTF_PLATFORM)/cframe/intf
COMPPATH       = $(COMP_HEADER_PATH)
CHECKPATH      = $(shell echo $(COMPPATH) | $(GREP) '^/' )
COMP           = $(shell basename $(COMPPATH))
PREFIX         = $(shell echo $(COMP) | tr '[:lower:]' '[:upper:]')

DoDirPath      = $(BUILD_DIR)
CompHeader     = $(BUILD_DIR)/$(PREFIX)_Component.h
CompHeaderSAVE = $(CompHeader).SAVE
SrcDeplDIR     = $(COMPPATH)/deployment
SrcDeplDescDIR = $(SrcDeplDIR)/description
DoDeplDIR      = $(DoDirPath)/deployment
DoDeplDescDIR  = $(DoDeplDIR)/description
VPARSER        = $(GMPS_TOP)_admin/production/bin/versionparser
VDEFAULT       = $(GMPS_TOP)_admin/production/bin/versiondefault
GENVERSION     = $(GMPS_TOP)_admin/production/tools/genversion.sh
PkgStrSRC      = $(SrcDeplDescDIR)/PackageStructure.src.xml
PkgStrSrc      = $(DoDeplDescDIR)/PackageStructure.src.xml
CompDescSRC    = $(SrcDeplDescDIR)/ComponentDescription.src.xml
CompDesc       = $(DoDeplDescDIR)/ComponentDescription.xml
DeplDtdSRC     = $(ADVANTAGE_IDIST)/CompDescription.dtd
DeplDtd        = $(DoDeplDescDIR)/CompDescription.dtd
APSName_DEF    = $(shell $(VDEFAULT) | $(CUT) -c1-12)
APSName_SUF    = $(shell $(VDEFAULT) | $(CUT) -c13-16)
APSIMS_DEF     = $(APSName_DEF)$(APSName_SUF)
APS_NAME       = $(APSName_DEF)
APSNAME_IMS    = $(APSIMS_DEF)

#$(info  --> $(PREFIX) $(CompHeader))

CpTarCmd = cd $(SrcDeplDIR)/.. ;\
           Files=`$(FIND) deployment -follow -type f 2>/dev/null |\
           $(FGREP) -v make/genversion.sh| $(FGREP) -v /readme.txt       |\
           $(GREP) -v '/.*Delta.*\.xml'  | $(GREP) -v '/description/.*\.sh'|\
           $(GREP) -v 'hss_.*\.gmk'      | $(FGREP) -v /readme.txt       |\
           $(FGREP) -v /make/dtd2tree ` ;\
           $(TAR) cfh - $$Files | (cd $(DoDirPath); $(TAR) xfo -)

Init :
	@if [ "$(COMPPATH)" -a ! "$(CHECKPATH)" ];then \
	    $(ECHO) ;\
	    $(ECHO) "### ERROR: Wrong Comp.-Path \"$(COMPPATH)\" !!!";\
	    exit 1; fi
	@if [ "$(COMPPATH)" -a ! -d "$(SrcDeplDescDIR)" ];then \
	    $(ECHO) ;\
	    $(ECHO) "### ERROR: $(SrcDeplDescDIR) not found !!!";\
	    exit 1; fi

$(CompDesc) : $(PkgStrSRC) $(CompDescSRC)
	@if [ "`echo $(APSName_DEF) | grep ERROR`" ]; then \
	    $(ECHO) "\n### ERROR from $(VDEFAULT) :"; \
	    $(VDEFAULT); exit 1; fi
	@if [ "$(APS_NAME)" = $(APSName_DEF) ];then \
	    $(ECHO) "\nDEFAULT APS-Name = $(APSName_DEF)$(APSName_SUF)";\
	    $(ECHO) "RESULT from : $(VDEFAULT)"; $(ECHO);\
	 fi
	@$(ECHO) "... Copying files from $(SrcDeplDIR) to $(DoDirPath) ...\n"
	@$(CpTarCmd)
	@-cd $(DoDirPath); $(CHMOD) -R +w *
	@$(SED) 's~Structure=.*deployment/~Structure="$(DoDeplDIR)/~' \
						  $(PkgStrSRC) >$(PkgStrSrc)
	$(VPARSER) -s $(DoDeplDescDIR) -aps $(APSNAME_IMS)

$(CompHeader): $(CompDesc) $(GENVERSION) $(DeplDtdSRC)
	@if [ -s $@ ]; then $(MV) -f $@ $@.SAVE; fi
	$(CP) -f $(DeplDtdSRC) $(DeplDtd)
	@$(ECHO) "\n... Creating $@ (in $(DoDirPath)) \n"
	$(GENVERSION) $(CompDesc) cpp $@ $(PREFIX)
	@if [ -s $@.SAVE -a \
	        "`$(DIFF) $@ $@.SAVE 2>/dev/null`" = "" ]; then \
	    $(ECHO) "\n... $@ didn't change, keeping the old one !";\
	    $(MV) -f $@.SAVE $@      ;\
	 fi

clean_comp :
#	$(RM) $(CompHeader)
#	$(RM) -r $(DoDeplDIR)

clean: clean_comp
$(filter-out %.a,$(GMPS_Target)) : $(CompHeader)
endif

else
#  ... DRY_RUN ...

dep_file := $(ADMIN_DIR)/production/make/depend.mk
ifneq ($(LDLIBS),)
dep_tgt := $(filter $(patsubst -l%,lib%,$(LDLIBS)),$(TARGET_ALL))
endif
.PHONY:dep
dep: $(MAKEFILE)
	@ $(ECHO) "Dependence derivation for $(TARGET) ..."
	@[ -s $(dep_file) ] || echo >> $(dep_file) ; \
	[ -n "$(dep_tgt)" ] && sed -i "/^$(TARGET):/{h;s/:.*/:$(dep_tgt)/};\$${x;/^$$/{s//$(TARGET):$(dep_tgt)/;H};x}" \
	$(dep_file) || sed -i "/^$(TARGET):/d" $(dep_file)

endif

