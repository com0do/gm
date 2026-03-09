



ifeq ($(CONFIG_MODE),GM)
$(info --> MAKE SURE you need work with GM)
define get_target_path
    $(shell perl -e '$$common_path="$(dir $(GMS_TARGET))"; \
        $$GMPS_TOP="$(GMPS_TOP)"; \
        push(@INC,"$(GMS_BIN_DIR)"); \
        require "gmps_lib.pl"; \
        @ret = &get_target_path("$(1)"); \
        if ($$ret[0] ne "not found"){ \
            if ("type" eq "$(2)") {print $$ret[1];} \
            elsif ("src" eq "$(2)") {print $$ret[2];} \
            elsif ("build" eq "$(2)") {print $$ret[3];} \
            elsif ("out" eq "$(2)") {print $$ret[4];} \
            elsif ("all" eq "$(2)") {print "@ret";} \
        } else { \
            print $$ret[0]; \
        } \
        ')
endef
define get_flags_global
    $(shell perl -e '$$config_path="$(dir $(GMS_CONFIG))"; \
        $$GMPS_TOP="$(GMPS_TOP)"; \
        push(@INC,"$(GMS_BIN_DIR)"); \
        require "gmps_lib.pl"; \
        @ret = &get_flags_global("\@$(1)","\@$(2)"); \
        print "@ret"; \
        ')
endef


# get common flags/definations from gms_config
CCACHE     := $(shell $(AWK) -v top="$(GMPS_TOP)" \
              '/CCACHE_PATH[ \t]/{gsub(/GMPS_TOP/, top, $$2); print $$2}' $(GMS_CONFIG))
CCACHE     := $(shell echo $(CCACHE)|cut -b 2-)
CC         := $(shell $(AWK) -v top="$(GMPS_TOP)" \
              '/CC_PATH[ \t]/{gsub(/GMPS_TOP/, top, $$NF); print $$NF}' $(GMS_CONFIG))
CC         := $(CCACHE) $(shell echo $(CC)|cut -b 2-)
LD         := $(shell $(AWK) -v top="$(GMPS_TOP)" \
              '/LD_PATH[ \t]/{gsub(/GMPS_TOP/, top, $$NF); print $$NF}' $(GMS_CONFIG))
LD         := $(CCACHE) $(shell echo $(LD)|cut -b 2-)

ifeq ($(BUILD_MODE), debug)
    GCCFLAGS_MODE = GCCFLAGS_REL64
    GLDFLAGS_MODE = GLDFLAGS_REL
    GLDFLAGS_MODE2 = GLDFLAGS_REL64
else
    GCCFLAGS_MODE = GCCFLAGS_DEB64
    GLDFLAGS_MODE = GLDFLAGS_DEB
    GLDFLAGS_MODE2 = GLDFLAGS_DEB64
endif

CCflags    += $(call get_flags_global,flags_global,GCINCS)
CCflags    += $(call get_flags_global,flags_global,GCCINCS)
CCflags    += $(call get_flags_global,flags_global,GCCFLAGS)
CCflags    += $(call get_flags_global,flags_global,GCCFLAGS64)
CCflags    += $(call get_flags_global,flags_global,$(GCCFLAGS_MODE))

LDflags    += $(call get_flags_global,flags_global,GLDFLAGS64)
LDflags    += $(call get_flags_global,flags_global,$(GLDFLAGS_MODE))
LDflags    += $(call get_flags_global,flags_global,$(GLDFLAGS_MODE2))

lib%: TARGET_CONFIG =$(strip $(call get_target_path,$@,all))
lib%: TYPE =$(word 2,$(TARGET_CONFIG))
lib%: SOURCE_DIR =$(word 3,$(TARGET_CONFIG))
lib%: BUILD_DIR =$(word 4,$(TARGET_CONFIG))/$(GMPS_ARCH)/$(BUILD_MODE)
lib%: OUT_DIR =$(word 5,$(TARGET_CONFIG))/$(GMPS_ARCH)/$(BUILD_MODE)
else
include $(ADMIN_DIR)/production/make/variable.mk
endif


#include $(ADMIN_DIR)/production/make/config.mk

