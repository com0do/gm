# SPDX-License-Identifier: MIT
#
# flags.mk -- compile/link flag accumulators.  Toolchain groups (GCFLAGS, GCCFLAGS,
# GLDFLAGS) + per-mode variants compose into user-visible CFLAGS /
# CCFLAGS / LDFLAGS based on $(BUILD_MODE).  Loaded via env.mk.
# Only internal accumulators are reset here -- child .mk's
# `CFLAGS += ...` (loaded before this file in sub-makes) must survive.

########################################################################
# Compilers (README "Toolchain"): CC / CXX (env or command line, an absolute path or a
# name on PATH), else gcc / g++ on PATH (ccache shim dirs skipped).  C_PATH / CC_PATH /
# LD_PATH are gm-internal: C compiler, C++ compiler, link driver.  CC / CXX are only
# read; gm's own command lines are GM_CC / GM_CXX / GM_LD.  Resolved once, in the top-level
# make: sub-makes get C_PATH / CC_PATH on their command line (_GM_SUBMAKE_VARS), which beats
# the := below -- a CC set in the top-level Makefile reaches every target that way.
########################################################################
_gm_dirs  := $(filter-out %/ccache,$(subst :, ,$(PATH)))
_gm_which  = $(if $(findstring /,$(1)),$(wildcard $(1)),$(firstword $(wildcard $(addsuffix /$(1),$(_gm_dirs)))))
_gm_user   = $(if $(filter default undefined,$(origin $(1))),,$($(1)))
C_PATH    := $(call _gm_which,$(or $(call _gm_user,CC),gcc))
CC_PATH   := $(call _gm_which,$(or $(call _gm_user,CXX),g++))
LD_PATH   := $(CC_PATH)
ifeq ($(and $(C_PATH),$(CC_PATH)),)
$(error gm: C / C++ compiler not found (CC='$(call _gm_user,CC)' CXX='$(call _gm_user,CXX)').  Set CC / CXX or put gcc / g++ on PATH.)
endif

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
                   $(_GM_CCACHE))

ifneq ($(filter $(CCACHE_ENABLE),no 0),)
  CCACHE :=
else ifneq ($(filter $(CCACHE_ENABLE),yes 1),)
  ifeq ($(strip $(CCACHE_PATH)),)
    # Only C sub-makes are handed the ccache probe: warn once, from the top level.
    $(if $(_GM_TOP),$(warning gm: CCACHE_ENABLE=$(CCACHE_ENABLE) but no ccache binary found. \
              Searched $$(ADMIN_DIR)/tools/ccache-*/ccache and $$PATH. \
              Set CCACHE_PATH=/path/to/ccache to override.))
    CCACHE :=
  else
    CCACHE := $(CCACHE_PATH)
  endif
else  # auto
  CCACHE := $(CCACHE_PATH)
endif


$(foreach v,\
    GCFLAGS GCFLAGS_DEB GCFLAGS_REL \
    GCCFLAGS GCCFLAGS_DEB GCCFLAGS_REL \
    C_FLAGS_DEBUG C_FLAGS_RELEASE CC_FLAGS_DEBUG CC_FLAGS_RELEASE \
    GLDFLAGS GLDFLAGS_DEB GLDFLAGS_REL \
    LD_FLAGS_DEBUG LD_FLAGS_RELEASE,\
  $(eval $(v) :=))


# Project-wide flags: set them in your top-level Makefile before it includes env.mk (or on the
# command line).  Every target gets them, after gm's own flags, so they can also relax a
# default.  Flags of one target go in that target's .mk (USER_GUIDE 3.11).
#   PROJECT_CPPFLAGS  C and C++ (defines, -I)      PROJECT_CFLAGS  C only
#   PROJECT_CCFLAGS   C++ only                     PROJECT_LDFLAGS link


# Target machine (gcc -dumpmachine): found once at the top level, handed down on the command line.
ifeq ($(origin GM_MACHINE),undefined)
GM_MACHINE := $(shell $(C_PATH) -dumpmachine 2>/dev/null)
endif
_GM_M64 := $(if $(filter x86_64 ppc64 ppc64le s390x sparc64,$(firstword $(subst -, ,$(GM_MACHINE)))),-m64)

# Reproducible paths: the checkout directory reaches neither __FILE__ nor the debug info, so the
# same sources give the same binaries in any directory (USER_GUIDE 3.15).  PATH_MAP=no turns it
# off; coverage builds keep real paths for gcov.  Needs gcc >= 8 / clang >= 10.
PATH_MAP ?= yes
ifeq ($(filter no 0,$(PATH_MAP))$(_COV),)
_GM_PATH_MAP := -ffile-prefix-map=$(PROJ_TOP)=. -ffile-prefix-map=$(GM_OUT)=./build \
                $(if $(filter $(PROJ_TOP)/%,$(ADMIN_DIR)),,-ffile-prefix-map=$(ADMIN_DIR)=./production)
endif


# HARDEN=no turns hardening off (USER_GUIDE 3.14).
HARDEN ?= yes
_HARDEN := $(if $(filter no 0,$(HARDEN)),,1)

GCFLAGS         += -fPIC $(_GM_M64) $(_GM_PATH_MAP)
GCFLAGS_DEB     += -g -DDEBUG -O0
# -g in every mode: symbols ship in the packages' -debuginfo RPMs (USER_GUIDE 3.13).
GCFLAGS_REL     += -g -O2
ifneq ($(_HARDEN),)
GCFLAGS         += -fstack-protector-strong
GCFLAGS_REL     += -U_FORTIFY_SOURCE -D_FORTIFY_SOURCE=2
endif
C_FLAGS_DEBUG   += $(GCFLAGS_DEB)
C_FLAGS_RELEASE += $(GCFLAGS_REL)


# C++17 default (gcc 7+, Rocky 8 stock gcc 8.5).  A target's .mk can bump it with
# `CXX_STD := c++20` (read when the compiler runs, so it works after this file loaded).  For
# c++20/23 on Rocky 8 use gcc-toolset-13+ (source /opt/rh/gcc-toolset-13/enable, or CC= / CXX=
# pointing at its bin).
CXX_STD  ?= c++17
GCCFLAGS += -fPIC $(_GM_M64) $(_GM_PATH_MAP)
GCCFLAGS_DEB += -g -DDEBUG -O0
GCCFLAGS_REL += -g -O2
ifneq ($(_HARDEN),)
GCCFLAGS       += -fstack-protector-strong
GCCFLAGS_REL   += -U_FORTIFY_SOURCE -D_FORTIFY_SOURCE=2
endif
CC_FLAGS_DEBUG   += $(GCCFLAGS_DEB)
CC_FLAGS_RELEASE += $(GCCFLAGS_REL)


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


# build-id pairs a binary with its -debuginfo RPM.
GLDFLAGS += -Wl,--build-id
ifneq ($(_HARDEN),)
GLDFLAGS += -Wl,-z,relro,-z,now
_GM_PIE  := -pie
endif
GLDFLAGS_DEB   += -g -L$(GM_LIB_DIR)
GLDFLAGS_REL   += -L$(GM_LIB_DIR)
LD_FLAGS_DEBUG   += $(GLDFLAGS) $(GLDFLAGS_DEB) $(_GM_M64)
LD_FLAGS_RELEASE += $(GLDFLAGS) $(GLDFLAGS_REL) $(_GM_M64)


# C / C++ compile and link commands (no trailing comments: make keeps the spaces).
GM_CC  := $(strip $(CCACHE) $(C_PATH))
GM_CXX := $(strip $(CCACHE) $(CC_PATH))
GM_LD  := $(strip $(CCACHE) $(LD_PATH))
CCFLAGS += $(GCCFLAGS) -std=$(CXX_STD)
CFLAGS  += $(GCFLAGS)
ifeq ($(BUILD_MODE), debug)
CFLAGS  += $(C_FLAGS_DEBUG)
CCFLAGS += $(CC_FLAGS_DEBUG)
LDFLAGS += $(LD_FLAGS_DEBUG)
else
CFLAGS  += $(C_FLAGS_RELEASE)
CCFLAGS += $(CC_FLAGS_RELEASE)
LDFLAGS += $(LD_FLAGS_RELEASE)
endif

# Coverage (COVERAGE=1): -O0 keeps line / branch attribution honest;
# -fprofile-abs-path (gcc 8+) embeds absolute source paths in .gcno.
ifneq ($(_COV),)
COV_FLAGS := --coverage -fprofile-arcs -ftest-coverage -fprofile-abs-path -O0 -U_FORTIFY_SOURCE
CFLAGS  += $(COV_FLAGS)
CCFLAGS += $(COV_FLAGS)
LDFLAGS += $(COV_FLAGS) -lgcov
endif

# Sanitizers (SANITIZE, env.mk): compile + link, on top of BUILD_MODE.
ifneq ($(_SAN_LIST),)
SANITIZE_FLAGS ?= -fsanitize=$(subst $(_space),$(_comma),$(_SAN_LIST)) -fno-omit-frame-pointer
CFLAGS  += $(SANITIZE_FLAGS)
CCFLAGS += $(SANITIZE_FLAGS)
LDFLAGS += $(SANITIZE_FLAGS)
# GCC false positives under instrumentation: warn, don't fail (USER_GUIDE 3.12).
CFLAGS  += -Wno-error=maybe-uninitialized
CCFLAGS += -Wno-error=maybe-uninitialized
endif

# Project-wide flags go last (see the top of this file).
CFLAGS  += $(PROJECT_CPPFLAGS) $(PROJECT_CFLAGS)
CCFLAGS += $(PROJECT_CPPFLAGS) $(PROJECT_CCFLAGS)
LDFLAGS += $(PROJECT_LDFLAGS)

# Exported (last, after the `?=` defaults above: exporting an undefined name would define it empty):
# the target sub-makes read the project flags and the knobs from the environment.
export PROJECT_CPPFLAGS PROJECT_CFLAGS PROJECT_CCFLAGS PROJECT_LDFLAGS WARN_LEVEL HARDEN CXX_STD PATH_MAP
