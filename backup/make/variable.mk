

#ifeq ($(MAKELEVEL), 0)
ifeq ($(VARIABLE_MK_INCLUDED),)
VARIABLE_MK_INCLUDED := Y

C_PATH  := $(GMPS_TOP)_tools/rhlinux/gcc/bin/gcc
CC_PATH := $(GMPS_TOP)_tools/rhlinux/gcc/bin/g++
LD_PATH := $(GMPS_TOP)_tools/rhlinux/gcc/bin/g++
CCACHE_PATH := $(GMPS_TOP)_tools/ccache-4.8-linux-x86_64/ccache

GCINCS +=   -I$(GMPS_TOP)_cmrepo/include \
            -I$(GMPS_TOP)_common/inc_muc -I$(GMPS_TOP)_common/inc_brq \
            -I$(GMPS_TOP)_common/inc_vie -I$(GMPS_TOP)_common/inc_blr \
            -I$(GMPS_TOP)_cxif/inc_blr \
            -I$(GMPS_TOP)_hss1/inc_vie  -I$(GMPS_TOP)_hss1/inc_blr  -I$(GMPS_TOP)_hss2/inc_blr \
            -I$(GMPS_TOP)_cscf1/inc_muc -I$(GMPS_TOP)_cscf1/inc_vie \
            -I$(GMPS_TOP)_cscf1/inc_brq -I$(GMPS_TOP)_cscf1/inc_blr \
            -I$(GMPS_TOP)_cscf2/inc_brq -I$(GMPS_TOP)_cscf2/inc_muc -I$(GMPS_TOP)_cscf2/inc_vie \
            -I$(GMPS_TOP)_tools/advantage/intf/tsp7f/include/linux \
            -I$(GMPS_TOP)_common/inc_pltf_os \
            -I$(GMPS_TOP)_diameter/inc_blr \
            -I$(GMPS_TOP)_diameter/msp/inc_blr/bmp \
            -I$(GMPS_TOP)_diameter/msp/inc_blr/cxp \
            -I$(GMPS_TOP)_diameter/msp/inc_blr/e2p \
            -I$(GMPS_TOP)_diameter/msp/inc_blr/rop \
            -I$(GMPS_TOP)_diameter/msp/inc_blr/s6p \
            -I$(GMPS_TOP)_diameter/msp/inc_blr/shp \
            -I$(GMPS_TOP)_diameter/msp/inc_blr/swx \
            -I$(GMPS_TOP)_diameter/msp/inc_blr/wxp \
            -I$(GMPS_TOP)_diameter/msp/inc_blr/zhp \
            -I$(GMPS_TOP)_diameter/msp/inc_blr     \
            -I$(GMPS_TOP)_diameter/msp/inc_blr/gqp

GCCINCS +=  -I$(GMPS_TOP)_common/nem/include \
            -I$(GMPS_TOP)_tools/rhlinux/usr/include \
            -I$(GMPS_TOP)_tools/rhlinux/solid
GCINCSUSR +=-I$(GMPS_TOP)_tools/rhlinux/usr/include

CC_INCLUDES += $(GCINCS) $(GCCINCS)
C_INCLUDES  += $(GCINCS) $(GCINCSUSR)


GCFLAGS         += -fPIC -DLINUX -DHSS_NODE
GCFLAGS64       += -DRTP_64BIT
GCFLAGS_DEB     += -g -DDEBUG
GCFLAGS_DEB64   += -m64
GCFLAGS_REL64   += -m64
GCFLAGS_REL     +=
C_FLAGS_Debug += $(GCFLAGS64) $(GCFLAGS_DEB) $(GCFLAGS_DEB64)
C_FLAGS_Release += $(GCFLAGS64) $(GCFLAGS_REL) $(GCFLAGS_REL64)


GCCFLAGS += -fPIC -DLINUX -D_REENTRANT -D_POSIX_PTHREAD_SEMANTICS -DNM_NOT_CONFIGURED  -std=c++11
GCCFLAGS64 += -DRTP_64BIT -Wall -Wno-conversion -Wno-sign-conversion -Wno-reorder -DHSS_NODE -O2
GCCFLAGS_DEB64 += -m64
GCCFLAGS_REL64 += -m64
GCCFLAGS_DEB += -g -DDEBUG
GCCFLAGS_REL +=
CC_FLAGS_Debug += $(GCCFLAGS64) $(GCCFLAGS_DEB) $(GCCFLAGS_DEB64)
CC_FLAGS_Release += $(GCCFLAGS64) $(GCCFLAGS_REL) $(GCCFLAGS_REL64)



GLDFLAGS64 += -L$(GMPS_TOP)_cmrepo/lib
GLDFLAGS64 += -L$(GMPS_TOP)_tools/icm/lib
GLDFLAGS64 += -Wl,-rpath-link,$(GMPS_TOP)_tools/icm/lib
GLDFLAGS64 += -Wl,-rpath-link,$(GMPS_TOP)_cmrepo/lib
GLDFLAGS64 += -Wl,-rpath-link,$(GMPS_TOP)_tools/openssl
GLDFLAGS64 += -Wl,-rpath-link,$(GMPS_TOP)_common/tools/boost_1_57_0/lib
GLDFLAGS64 += -L$(GMPS_TOP)_tools/rhlinux/lib64
GLDFLAGS64 += -L$(GMPS_TOP)_tools/rhlinux/usr/lib64
GLDFLAGS64 += -L$(GMPS_TOP)_tools/advantage/intf/tsp7f/lib64/linux
GLDFLAGS64 += -L$(GMPS_TOP)_tools/advantage/idist/rhlinux/lib64
GLDFLAGS64 += -L$(GMPS_TOP)_tools/rhlinux/solid/lib64
GLDFLAGS64 += -L$(GMPS_TOP)_cmrepo/lib64
GLDFLAGS64 += -L$(GMPS_TOP)_tools/icm/lib64
GLDFLAGS64 += -Wl,-rpath-link,$(GMPS_TOP)_tools/icm/lib64
GLDFLAGS64 += -Wl,-rpath-link,$(GMPS_TOP)_cmrepo/lib64
GLDFLAGS64 += -Wl,-rpath-link,$(GMPS_TOP)_tools/rhlinux/usr/lib64
GLDFLAGS64 += -std=c++11 
GLDFLAGS_DEB   += -g -L$(GMPS_TOP)_do/lib/rhlinux/debug
GLDFLAGS_DEB64 += -O2 -m64
GLDFLAGS_REL   += -L$(GMPS_TOP)_do/lib/rhlinux/release
GLDFLAGS_REL64 += -O2 -m64
LD_FLAGS_Debug += $(GLDFLAGS64) $(GLDFLAGS_DEB) $(GLDFLAGS_DEB64)
LD_FLAGS_Release += $(GLDFLAGS64) $(GLDFLAGS_REL) $(GLDFLAGS_REL64)


# output settings
CCACHE := $(CCACHE_PATH)
C      := $(CCACHE) $(C_PATH)
CC     := $(CCACHE) $(CC_PATH)
LD     := $(CCACHE) $(LD_PATH)
CCflags += $(CC_INCLUDES) $(GCCFLAGS)
Cflags += $(C_INCLUDES) $(GCFLAGS)
ifeq ($(BUILD_MODE), debug)
Cflags += $(C_FLAGS_Debug)
CCflags += $(CC_FLAGS_Debug)
LDflags += $(LD_FLAGS_Debug)
else
Cflags += $(C_FLAGS_Release)
CCflags += $(CC_FLAGS_Release)
LDflags += $(LD_FLAGS_Release)
endif

endif
