# SPDX-License-Identifier: MIT
#
# flags.mk -- compile/link flag accumulators.  Toolchain groups (GCFLAGS, GCCFLAGS,
# GLDFLAGS) + per-mode variants compose into user-visible CFLAGS /
# CCFLAGS / LDFLAGS based on $(BUILD_MODE).  Loaded via env.mk.
# Only internal accumulators are reset here -- child .mk's
# `CFLAGS += ...` (loaded before this file in sub-makes) must survive.


OS_TYPE := Rocky

# Compiler binaries.  Search: vendored under ADMIN_DIR/tools/, then PATH.
# Override C_PATH/CC_PATH/LD_PATH on the cmdline for custom toolchains.
C_PATH      := $(firstword $(wildcard $(ADMIN_DIR)/tools/rhlinux/gcc/bin/gcc /usr/bin/gcc))
CC_PATH     := $(firstword $(wildcard $(ADMIN_DIR)/tools/rhlinux/gcc/bin/g++ /usr/bin/g++))
LD_PATH     := $(firstword $(wildcard $(ADMIN_DIR)/tools/rhlinux/gcc/bin/g++ /usr/bin/g++))

########################################################################
# Compiler cache (ccache)
#   CCACHE_ENABLE = auto (default)   use ccache if a binary is found,
#                                    silently skip if not
#                 = yes / 1           insist on ccache; warn if missing
#                 = no  / 0           never use ccache
########################################################################

CCACHE_ENABLE ?= auto

CCACHE_PATH ?= $(firstword \
                   $(wildcard $(ADMIN_DIR)/tools/ccache-*/ccache) \
                   $(shell command -v ccache 2>/dev/null))

ifneq ($(filter $(CCACHE_ENABLE),no 0),)
  CCACHE :=
else ifneq ($(filter $(CCACHE_ENABLE),yes 1),)
  ifeq ($(strip $(CCACHE_PATH)),)
    $(warning gm: CCACHE_ENABLE=$(CCACHE_ENABLE) but no ccache binary found. \
              Searched $$(ADMIN_DIR)/tools/ccache-*/ccache and $$PATH. \
              Set CCACHE_PATH=/path/to/ccache to override.)
    CCACHE :=
  else
    CCACHE := $(CCACHE_PATH)
  endif
else  # auto
  CCACHE := $(CCACHE_PATH)
endif


$(foreach v,\
    GCINCS GCINCSUSR GCCINCS CC_INCLUDES C_INCLUDES \
    GCFLAGS GCFLAGS64 GCFLAGS_DEB GCFLAGS_DEB64 GCFLAGS_REL GCFLAGS_REL64 \
    GCCFLAGS GCCFLAGS64 GCCFLAGS_DEB GCCFLAGS_DEB64 GCCFLAGS_REL GCCFLAGS_REL64 \
    C_FLAGS_DEBUG C_FLAGS_RELEASE CC_FLAGS_DEBUG CC_FLAGS_RELEASE \
    GLDFLAGS64 GLDFLAGS_DEB GLDFLAGS_DEB64 GLDFLAGS_REL GLDFLAGS_REL64 \
    LD_FLAGS_DEBUG LD_FLAGS_RELEASE,\
  $(eval $(v) :=))


# User-project shared includes.  Template placeholders -- absent paths
# are harmless, they just don't contribute.
GCINCS +=   -I$(PROJ_TOP)/common/inc \
            -I$(PROJ_TOP)/common/inc_blr

GCINCSUSR +=-I$(ADMIN_DIR)/tools/rhlinux/usr/include
GCCINCS +=  -I$(PROJ_TOP)/common/nem/include \
            -I$(ADMIN_DIR)/tools/rhlinux/usr/include \
            -I$(ADMIN_DIR)/tools/rhlinux/solid

CC_INCLUDES += $(GCINCS) $(GCCINCS)
C_INCLUDES  += $(GCINCS) $(GCINCSUSR)


GCFLAGS         += -fPIC -DLINUX
GCFLAGS64       += -DRTP_64BIT
GCFLAGS_DEB     += -g -DDEBUG
GCFLAGS_DEB64   += -m64
GCFLAGS_REL64   += -m64
GCFLAGS_REL     +=
C_FLAGS_DEBUG   += $(GCFLAGS64) $(GCFLAGS_DEB) $(GCFLAGS_DEB64)
C_FLAGS_RELEASE += $(GCFLAGS64) $(GCFLAGS_REL) $(GCFLAGS_REL64)


# C++17 default (gcc 7+, Rocky 8 stock gcc 8.5).  Child .mk can bump
# via `CXX_STD := c++20` before this file loads.  For c++20/23 on
# Rocky 8 use gcc-toolset-13+ (source /opt/rh/gcc-toolset-13/enable
# or point C_PATH/CC_PATH at its bin).
CXX_STD  ?= c++17
GCCFLAGS += -fPIC -DLINUX -D_REENTRANT -D_POSIX_PTHREAD_SEMANTICS -DNM_NOT_CONFIGURED -std=$(CXX_STD)
GCCFLAGS64 += -DRTP_64BIT -O2
GCCFLAGS_DEB64 += -m64
GCCFLAGS_REL64 += -m64
GCCFLAGS_DEB   += -g -DDEBUG
GCCFLAGS_REL   +=
CC_FLAGS_DEBUG   += $(GCCFLAGS64) $(GCCFLAGS_DEB) $(GCCFLAGS_DEB64)
CC_FLAGS_RELEASE += $(GCCFLAGS64) $(GCCFLAGS_REL) $(GCCFLAGS_REL64)


########################################################################
# Warning bundles.  Modelled after the reference cmake ::warnings
# INTERFACE target (see ~/code/md/example/hello/cmake/CompileOptions.cmake).
#
# WARN_LEVEL knob (default `strict`):
#   strict  --  full warning set + -Werror.  Any warning fails the build.
#               This is the product default -- lifts code quality by
#               forcing every warning to be handled before commit.
#   warn    --  full warning set, warnings visible, no build failure.
#               Use during a big cleanup or when adopting a legacy tree.
#   lax     --  just -Wall.  For third-party sources we can't touch.
#
# target.c.mk drops -Werror + adds -Wno-unused-variable/-Wno-unused-parameter
# for `test-*` targets: gtest fixtures leak these constantly and it isn't
# worth turning down the whole product to make them clean.
########################################################################

WARN_LEVEL ?= strict
ifeq ($(filter $(WARN_LEVEL),strict warn lax),)
$(error WARN_LEVEL='$(WARN_LEVEL)' invalid.  Valid: strict warn lax)
endif

# C warning set (applies to .c compiles).
STRICT_C_WARNINGS := \
    -Wall -Wextra -Wpedantic \
    -Wshadow -Wcast-align \
    -Wformat=2 -Wimplicit-fallthrough \
    -Wnull-dereference

# C++ warning set (strict C set + C++-only lints).
STRICT_CXX_WARNINGS := $(STRICT_C_WARNINGS) \
    -Wnon-virtual-dtor -Woverloaded-virtual

ifeq ($(WARN_LEVEL),strict)
CFLAGS  += $(STRICT_C_WARNINGS)   -Werror
CCFLAGS += $(STRICT_CXX_WARNINGS) -Werror
else ifeq ($(WARN_LEVEL),warn)
CFLAGS  += $(STRICT_C_WARNINGS)
CCFLAGS += $(STRICT_CXX_WARNINGS)
else # lax
CFLAGS  += -Wall
CCFLAGS += -Wall
endif


GLDFLAGS64 += -Wl,-rpath-link,$(ADMIN_DIR)/tools/icm/lib
GLDFLAGS64 += -Wl,-rpath-link,$(PROJ_TOP)/cmrepo/lib
GLDFLAGS64 += -Wl,-rpath-link,$(ADMIN_DIR)/tools/openssl
GLDFLAGS64 += -Wl,-rpath-link,$(PROJ_TOP)/common/tools/boost_1_57_0/lib
GLDFLAGS64 += -L$(ADMIN_DIR)/tools/rhlinux/lib64
GLDFLAGS64 += -L$(ADMIN_DIR)/tools/rhlinux/usr/lib64
GLDFLAGS64 += -Wl,-rpath-link,$(ADMIN_DIR)/tools/icm/lib64
GLDFLAGS64 += -Wl,-rpath-link,$(PROJ_TOP)/cmrepo/lib64
GLDFLAGS64 += -Wl,-rpath-link,$(ADMIN_DIR)/tools/rhlinux/usr/lib64
GLDFLAGS64 += -std=$(CXX_STD)
GLDFLAGS_DEB   += -g -L$(GM_OUT)/lib/$(BUILD_ARCH)/debug
GLDFLAGS_DEB64 += -O2 -m64
GLDFLAGS_REL   += -L$(GM_OUT)/lib/$(BUILD_ARCH)/release
GLDFLAGS_REL64 += -O2 -m64
LD_FLAGS_DEBUG   += $(GLDFLAGS64) $(GLDFLAGS_DEB) $(GLDFLAGS_DEB64)
LD_FLAGS_RELEASE += $(GLDFLAGS64) $(GLDFLAGS_REL) $(GLDFLAGS_REL64)


C      := $(strip $(CCACHE) $(C_PATH))
CC     := $(strip $(CCACHE) $(CC_PATH))
LD     := $(strip $(CCACHE) $(LD_PATH))
CCFLAGS += $(CC_INCLUDES) $(GCCFLAGS)
CFLAGS  += $(C_INCLUDES)  $(GCFLAGS)
ifeq ($(BUILD_MODE), debug)
CFLAGS  += $(C_FLAGS_DEBUG)
CCFLAGS += $(CC_FLAGS_DEBUG)
LDFLAGS += $(LD_FLAGS_DEBUG)
else ifeq ($(BUILD_MODE), coverage)
# `-fprofile-abs-path` (gcc 8+) embeds abs source paths in .gcno.
COV_FLAGS := --coverage -fprofile-arcs -ftest-coverage -fprofile-abs-path
CFLAGS  += $(C_FLAGS_DEBUG)   $(COV_FLAGS)
CCFLAGS += $(CC_FLAGS_DEBUG)  $(COV_FLAGS)
LDFLAGS += $(LD_FLAGS_DEBUG)  $(COV_FLAGS) -lgcov
else
CFLAGS  += $(C_FLAGS_RELEASE)
CCFLAGS += $(CC_FLAGS_RELEASE)
LDFLAGS += $(LD_FLAGS_RELEASE)
endif
