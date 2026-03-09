########################################################################
#
#
# author  : Cyrus Cui
# e-mail  : cyrus.cui@nokia-sbell.com
#
#
#
# brief   : get common variables definations from gms_config;
#           get target source location form gms_targets;
#           export environment for all sub makefile;
#
#
#
#
#
########################################################################

ADMIN_DIR    := $(GMPS_TOP)_admin
MAKEFILE     := $(lastword $(filter-out $(ADMIN_DIR)/production/tools/% ,$(abspath $(MAKEFILE_LIST))))
TARGET       ?= $(basename $(notdir $(MAKEFILE)))
MAKEFILE_DIR := $(abspath $(dir $(MAKEFILE)))
ROOT_DIR     := $(realpath $(MAKEFILE_DIR)/../../../)
GMPS_TOP     := $(ROOT_DIR)/ims
ADMIN_DIR    := $(ROOT_DIR)/ims_admin
CONFIG_MODE  := MK


.EXPORT_ALL_VARIABLES:
MAKEFLAGS += --no-print-directory

ifeq ($(RULES_MK_INCLUDED),)
RULES_MK_INCLUDED := Y

MKDIR    = /usr/bin/mkdir -p
RM       = /usr/bin/rm -f
MKDEP    = /usr/openwin/bin/makedepend -f -
TOUCH    = /usr/bin/touch
FIND     = /usr/bin/find
XARGS    = /usr/bin/xargs
AWK      = /bin/awk
BASENAME = /bin/basename

CAT      = /bin/cat
CHMOD    = /bin/chmod
CLT      = /usr/atria/bin/cleartool
CMP      = /bin/cmp
CP       = /bin/cp
CUT      = /bin/cut
DIFF     = /bin/diff
ECHO     = /bin/echo
EGREP    = /bin/egrep
FGREP    = /bin/fgrep
FLEX     = $(GMPS_TOP)_tools/rhlinux/flex/bin/flex
FLEX++   = $(GMPS_TOP)_tools/rhlinux/flex/bin/flex++
BISON    = $(GMPS_TOP)_tools/rhlinux/bison/bin/bison
YACC     = $(GMPS_TOP)_tools/rhlinux/bison/bin/yacc

AR       = /usr/bin/ar
ARflags  = -r
GREP     = /bin/grep
GZIP     = /bin/gzip
HOSTNAME = /bin/hostname
LN       = /bin/ln -f
MV       = /bin/mv
NAWK     = /bin/nawk
PRINTF   = /bin/printf
PKGMK    = /usr/bin/pkgmk
PKGTRANS = /usr/bin/pkgtrans
RANLIB   = /usr/ccs/bin/ranlib
RMDIR    = /bin/rmdir
RSH      = /bin/rsh
SED      = /bin/sed
SHELL    = /bin/sh
SLEEP    = /bin/sleep
SORT     = /bin/sort
TAR      = /bin/tar
UNAME    = /bin/uname

LEX      = /bin/lex
RPM      = /usr/bin/rpmbuild
CLT      = /atria/bin/cleartool


BUILD_MODE     ?= debug
GMPS_ARCH      := rhlinux
GMPS_BUILD_MODE?= debug
TSUFF          = .so
SUBSYS         = home
GMPS_PROJECT   = ims
GMPS_DO        = $(GMPS_TOP)_do
GMPS_HOME      = $(ADMIN_DIR)/gmps
GMS_TARGET     = $(GMPS_HOME)/etc/$(GMPS_PROJECT)/common/gms_targets
GMS_CONFIG     = $(GMPS_HOME)/etc/$(GMPS_PROJECT)/$(GMPS_ARCH)/gms_config
GMS_BIN_DIR    = $(GMPS_HOME)/bin
GENPATH        = $(GMPS_TOP)_do/gen/include
GENINC         = -I$(GENPATH)

macro_build:GCOV = /view/admin/vobs/ims_tools/rhlinux/gcc/bin/gcov


define uniq =
	$(eval seen :=)
	$(foreach _,$1,$(if $(filter $_,$(seen)),,$(eval seen += $_)))
	$(seen)
endef

ifeq ($(CONFIG_MODE),GM)
    $(info --> DEPRECATED: MAKE SURE you need work with GM)
else
    include $(ADMIN_DIR)/production/make/variable.mk
endif

endif

#include $(ADMIN_DIR)/production/make/config.mk

EXCLUDE_DIR      ?= github.com lean_disp
INCLUDE_REPO     ?= hss1 hss2 mt
INCLUDE_EXPLICIT ?= httpcs common
NAME_EXPLICIT    := make/project.txt
#rwildcard=$(foreach d,$(wildcard $(1:=/*)),$(if $(findstring /github.com/,$d),,$(call rwildcard,$d,$2) $(filter $(subst *,%,$2),$d)))
rwildcard=$(shell find $(1) $(foreach d,$(EXCLUDE_DIR), ! -path "*/$(d)/*") \
            -type f $(foreach ext,$(2),-name "$(ext)"))

MK_ALL := $(foreach d, $(INCLUDE_REPO), $(call rwildcard,$(ROOT_DIR)/ims_$(d),*.mk))
MK_ALL += $(foreach d, $(INCLUDE_EXPLICIT), $(if $(wildcard $(ROOT_DIR)/ims_$d/$(NAME_EXPLICIT)),\
            $(foreach p,$(shell cat $(ROOT_DIR)/ims_$d/$(NAME_EXPLICIT)),$(ROOT_DIR)/ims_$d/$p),\
            $(error can not found $(ROOT_DIR)/ims_$d/$(NAME_EXPLICIT))))
MK_ALL := $(strip $(sort $(MK_ALL)))
TARGET_ALL := $(foreach t,$(MK_ALL),$(subst .mk,,$(notdir $t)))
INFO_ALL := $(shell echo $(MK_ALL) | tr ' ' '\n'| awk -F'[/.]' '{for(i=1;i<=NF;i++) if($$i ~ /^ims_/){print $$i "/" $$(i+1) "/" $$(NF-1)}}')

#$(info $(MK_ALL))
#$(info $(TARGET_ALL))
#$(info $(INFO_ALL))

define FIND_TYPE
    $(if $(strip $(1)),
        ifeq ($(findstring lib,$(1)),lib)
            TARGET_TYPE := slib
        else ifneq ($(shell grep "go build" $(2)),)
            TARGET_TYPE := ngg
        else
            TARGET_TYPE := exe
        endif
    ,)
endef

define SET_TARGET
    $(if $(strip $(1)),
        $(eval $(call FIND_TYPE,$(1),$(2)))
        $(1)_type := $(TARGET_TYPE)
        $(1)_srcdir     := $(realpath $(dir $(2)))
        $(1): TYPE      := $(TARGET_TYPE)
        $(1): SOURCE_DIR:= $$($(1)_srcdir)
        $(1): BUILD_DIR := $(ROOT_DIR)/ims_do/$(3)/$(GMPS_ARCH)/$(BUILD_MODE)
        $(1): OUT_DIR   := $(ROOT_DIR)/ims_do/lib/$(GMPS_ARCH)/$(BUILD_MODE)
        $(1): REL_DIR   := $(4)
    ,)
endef

$(foreach t,$(TARGET_ALL),$(eval $(call SET_TARGET,$t,$(filter %/$t.mk,$(MK_ALL)),$(filter %/$t,$(INFO_ALL)))))
TARGET_GO     := $(sort $(foreach sub,$(TARGET_ALL),$(if $(filter ngg,$($(sub)_type)), $(sub))))
TARGET_LIB    := $(filter-out $(TARGET_GO),$(TARGET_ALL))
TARGET_DEP    := $(CURDIR)/depend.mk
#$(info $(TARGET_GO))
#$(info $(TARGET_LIB))

# old style
#TARGET_ALL_MK := $(sort $(foreach sub,$(TARGET_ALL),$(wildcard $($(sub)_srcdir)/$(sub).mk)))
#TARGET_ALL    := $(foreach sub,$(TARGET_ALL_MK),$(basename $(notdir $(sub))))
#TARGET_GO     := $(sort $(foreach sub,$(TARGET_ALL),$(if $(filter ngg,$($(sub)_type)), $(sub))))
#TARGET_LIB    := $(filter-out $(TARGET_GO),$(TARGET_ALL))
#TARGET_DEP    := $(CURDIR)/depend.mk

