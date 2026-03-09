


|----------------------------------------|----------------------------------|
| command                                | meanings                         |
|----------------------------------------|----------------------------------|
| make -C production/make dep            | produce target dependence        |
| make -C production/make                | build all target                 |
| make -C production/make libxxx         | build target                     |
| make -C production/make libxxx o=clean | clean target output              |
| make -C production/make libxxx o=check | check target compilation command |
|----------------------------------------|----------------------------------|




|-----|--------------------------------------------------------|
| No. | content                                                |
|-----|--------------------------------------------------------|
| 1   | create makefile for your target                        |
| 2   | variables name in you makefile should write in capital |
|-----|--------------------------------------------------------|




# dependence check  --> START
override define DEPEND_CHECK
ifneq ($$(wildcard $$($(1)_srcdir)/$(1).mk),)
ifeq ($(2),lib)
LDLIBS  :=
include $$($(1)_srcdir)/$(1).mk
$(1):$$(filter $$(patsubst -l%,lib%,$$(LDLIBS)),$(TARGET_ALL))
else ifeq ($(2),var)
ASSEMBLE_VAR += $$(shell awk -F"[ +=]" '/^[A-Z]/{print $$$$1}' $$($(1)_srcdir)/$(1).mk)
endif
endif
endef

define BACKUP_VAR
$(1)_B := $$($(1))
endef
define RESTORE_VAR
$(1) := $$($(1)_B)
endef

ifneq ($(filter lib%,$(MAKECMDGOALS)),)
DRY_RUN := Y
ASSEMBLE_VAR :=
$(foreach sub,$(MAKECMDGOALS),$(eval $(call DEPEND_CHECK,$(sub),var)))
$(foreach var,$(sort $(ASSEMBLE_VAR)),$(eval $(call BACKUP_VAR,$(var))))
$(foreach sub,$(MAKECMDGOALS),$(eval $(call DEPEND_CHECK,$(sub),lib)))
$(foreach var,$(sort $(ASSEMBLE_VAR)),$(eval $(call RESTORE_VAR,$(var))))
vpath %.cpp
vpath %.cxx
vpath %.c
vpath %.d
DRY_RUN :=
endif
