
########################################################################
#
#
# author  : Cyrus Cui
# e-mail  : cyrus.cui@nokia-sbell.com
#
#
#
#  usage
# |----------------------------------------|----------------------------------|
# | command                                | meanings                         |
# |----------------------------------------|----------------------------------|
# | make -C production/make dep            | produce target dependence        |
# | make -C production/make                | build all target                 |
# | make -C production/make libxxx         | build target                     |
# | make -C production/make libxxx o=clean | clean target output              |
# | make -C production/make libxxx o=check | check target compilation command |
# |----------------------------------------|----------------------------------|
#
#   restrictions
# |-----|--------------------------------------------------------|
# | No. | content                                                |
# |-----|--------------------------------------------------------|
# | 1   | only one external variable dependence: GMPS_TOP        |
# | 2   | create makefile for your target                        |
# |-----|--------------------------------------------------------|
#
########################################################################




.DEFAULT_GOAL := help

include rules.mk

# config
DEP_DERIVATION_PARALLEL := 0


# target check
ifeq ($(o),clean)
SUB_TARGET := clean
else ifeq ($(o),check)
SUB_TARGET := check
endif

ifneq ($(MAKECMDGOALS),dep)
-include $(TARGET_DEP)
endif

ifneq ($(filter lib%,$(MAKECMDGOALS)),)
ifneq ($(filter pkg%,$(MAKECMDGOALS)),)
$(error ERROR: Do not mix lib and pkg target)
endif
endif


all:  $(TARGET_LIB)
dep:  DRY_RUN := 1
clean:SUB_TARGET := clean
clean:$(TARGET_LIB)
.PRECIOUS: $(TARGET_DEP)
.PHONY: all dep clean

# automatic dependence derivation
ifeq ($(MAKELEVEL), 0)
$(TARGET_DEP): $(MK_ALL)
ifeq ($(DEP_DERIVATION_PARALLEL),1)
	@$(MAKE) $(foreach sub,$?,$(basename $(notdir $(sub)))) DRY_RUN=1
else
	@for sub in $? ;do $(MAKE) $$(basename $$sub .mk) DRY_RUN=1 ;done
endif
	@sort -o $(TARGET_DEP) $(TARGET_DEP)
endif



# general recipe
dep: $(TARGET_LIB)
	@sort -o $(TARGET_DEP) $(TARGET_DEP)

$(TARGET_LIB):
	@[ "$(SOURCE_DIR)" != "not found" ] && $(MAKE) -C $(SOURCE_DIR) -f $@.mk $(SUB_TARGET) \
	|| (echo "Is $(SOURCE_DIR)/$@.mk OK ?";exit 1)




for_udm: libCpuMemWriter libcrypto_wrapper libbracket_read_pure libsignalhandler \
	libUMSsys_mt libinet libicmapi libredisctx libcscfbase libbase libStdEncoDeco \
	libRedisServerHandler libregdbwrapper libUMSctf libUMSctm libUMSmsp libDistribution \
	libSdlEventHandler libEventHandler libsecUtil libencoderDecoder libhttpMsgUtil \
	libcscfbase_mt libUMSsys libUMSsys_caf libAtt_Gsoap libSoapEncodeDecoder \
	libUMSstrcCframe libdnsphapi libKMFSecurity
	@$(ECHO) Fire in the hole ....

help:
	echo "this is a help"
