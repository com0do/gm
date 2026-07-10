# SPDX-License-Identifier: MIT
#
# target.java.mk -- Java sub-target rules; simple javac + jar cf.  Not maven/gradle.
# Knobs (all optional): JAVASOURCE, MAIN_CLASS, JAR_DEPS (in-tree,
# like LDLIBS), CLASSPATH (external), JAVAC_FLAGS, JAR_FLAGS,
# JAVA_SRC_ROOTS (fed to depjava.py's class-index).  DEP_TREE=yes ->
# depjava.py builds {file,deps} by parsing imports (there is no
# `go list -deps` for Java).


CURRENT_FILE := $(lastword $(abspath $(MAKEFILE_LIST)))
MAKEFILE     := $(lastword $(filter-out $(ADMIN_DIR)/make/% ,$(abspath $(MAKEFILE_LIST))))
TARGET       := $(basename $(notdir $(MAKEFILE)))
MAKEFILE_DIR := $(abspath $(dir $(MAKEFILE)))

GM_FRAMEWORK_MK := $(GM_FRAMEWORK_CORE_MK) \
    $(CURRENT_FILE) \
    $(ADMIN_DIR)/make/scripts/depjava.py

include $(ADMIN_DIR)/make/target.common.mk


# DRY_RUN: JAR_DEPS -> depend.mk edges (same protocol as LDLIBS).
ifeq ($(DRY_RUN),1)
DRY_DEPS := $(strip $(filter $(JAR_DEPS),$(TARGET_ALL)))
include $(ADMIN_DIR)/make/target.dry-run.mk
else


JAVAC          ?= $(firstword $(shell command -v javac 2>/dev/null) javac)
JAR            ?= $(firstword $(shell command -v jar    2>/dev/null) jar)

# Auto-discover .java under MAKEFILE_DIR if JAVASOURCE not set.
JAVASOURCE     ?= $(shell find $(MAKEFILE_DIR) -name '*.java' -type f 2>/dev/null)
ifeq ($(strip $(JAVASOURCE)),)
$(error target.java.mk: no .java files found under $(MAKEFILE_DIR).  Set JAVASOURCE in $(MAKEFILE) if the sources live elsewhere.)
endif

JAR_DEPS       ?=
CLASSPATH      ?=
JAVAC_FLAGS    ?=
JAR_FLAGS      ?=
MAIN_CLASS     ?=
JAVA_SRC_ROOTS ?= $(MAKEFILE_DIR)


# javac/jar classpath = external CLASSPATH + in-tree JAR_DEPS resolved
# under $(GM_JAVA_DIR).  SPACE defined locally so this file stands
# alone (target.c.mk sets it but is a sibling, not a prereq).
SPACE             := $(subst ,, )
INTREE_JARS       := $(foreach j,$(JAR_DEPS),$(GM_JAVA_DIR)/$(j).jar)
_CP_ENTRIES       := $(strip $(INTREE_JARS) $(CLASSPATH))
JAVAC_CLASSPATH   := $(if $(_CP_ENTRIES),-classpath $(subst $(SPACE),:,$(_CP_ENTRIES)))


# Jars land DIRECTLY in $(OUT_DIR) (= $(GM_JAVA_DIR)), NOT via a
# BUILD_DIR symlink like C/Go do.  Java's classloader resolves the
# jar's `Class-Path:` relative to the jar's own dir, and it follows
# the symlink first -- staging via `ln -fs` would break sibling-name
# Class-Path resolution.
CLASS_DIR   := $(BUILD_DIR)/classes
JAR_OUT     := $(OUT_DIR)/$(TARGET).jar

ifeq ($(DEP_TREE),yes)
DEP_JSON_LINK := $(OUT_DIR)/$(TARGET).dep.json
DEP_JSON_ALL  := $(DEP_JSON_LINK)
else
DEP_JSON_ALL  :=
endif


# Executable jar wants Class-Path in the manifest -- `java -jar`
# ignores -cp and $CLASSPATH.  Sibling names suffice since every
# in-tree jar lives in $(GM_JAVA_DIR).
GEN_MANIFEST  := $(BUILD_DIR)/MANIFEST.MF
_CP_JAR_NAMES := $(foreach j,$(INTREE_JARS),$(notdir $(j)))


# javac + jar in one shot; no per-.class prereqs (always-run javac is
# fast for gm-scale projects).
$(TARGET) :: $(JAR_OUT) $(DEP_JSON_ALL);

$(GEN_MANIFEST): $(MAKEFILE) $(CURRENT_FILE) | $(BUILD_DIR)
	$(V_GEN)
	$(Q){ echo "Manifest-Version: 1.0" ; \
	   $(if $(strip $(MAIN_CLASS)),echo "Main-Class: $(strip $(MAIN_CLASS))" ;,) \
	   $(if $(strip $(_CP_JAR_NAMES)),echo "Class-Path: $(_CP_JAR_NAMES)" ;,) \
	   echo ; } > $@

$(JAR_OUT): $(JAVASOURCE) $(INTREE_JARS) $(GEN_MANIFEST) $(MAKEFILE) $(GM_FRAMEWORK_MK) | $(BUILD_DIR) $(OUT_DIR)
	$(V_JAVAC)
	$(Q)$(RM) -r $(CLASS_DIR) ; $(MKDIR) $(CLASS_DIR)
	$(Q)$(JAVAC) $(JAVAC_FLAGS) -d $(CLASS_DIR) $(JAVAC_CLASSPATH) $(JAVASOURCE)
	$(V_JAR)
	$(Q)$(JAR) cfm $@ $(GEN_MANIFEST) $(JAR_FLAGS) -C $(CLASS_DIR) .


.PRECIOUS: %/$(BUILD_MODE) $(OUT_DIR)
%/$(BUILD_MODE):
	$(Q)$(MKDIR) $@
$(OUT_DIR):
	$(Q)$(MKDIR) $@


# DEP_TREE=yes: depjava.py builds the class index from JAVA_SRC_ROOTS,
# walks imports, emits {file, deps}.  --intree-jar wires j1.jar -> j2
# edges (mirrors LDLIBS on the C side).
$(DEP_JSON_LINK): $(JAR_OUT) $(GM_FRAMEWORK_MK)
	$(V_JSON)
	$(Q)python3 $(ADMIN_DIR)/make/scripts/depjava.py \
	    --file $(JAR_OUT) \
	    $(foreach r,$(JAVA_SRC_ROOTS),--src-root $(r)) \
	    --target-sources $(JAVASOURCE) \
	    $(foreach j,$(JAR_DEPS),--intree-jar $(j)=$(GM_JAVA_DIR)/$(j).jar) \
	    -o $@.tmp
	@# Fold framework files into deps[] -- parallel to link_dep_json.jq in target.c.mk.
	$(Q)jq --arg FRAMEWORK "$(GM_FRAMEWORK_MK)" \
	    '.deps = ((.deps + ($$FRAMEWORK | split(" ") | map(select(length > 0)))) | unique | sort)' \
	    $@.tmp > $@ && $(RM) $@.tmp


clean:
	$(Q)$(RM) -r $(CLASS_DIR)
	$(Q)$(RM) $(GEN_MANIFEST) $(JAR_OUT) $(DEP_JSON_LINK)
	$(V_CLEAN)


endif # DRY_RUN
