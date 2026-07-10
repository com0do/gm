
# j2 -- an executable Java target (`java -jar j2.jar`).
#
# Zero-config auto-discovery of JAVASOURCE still works, but we
# declare two knobs:
#
#   JAR_DEPS := j1
#     wires j1's built .jar onto the compile-time classpath AND
#     records it as an edge in depend.mk (`j2: j1`) so a cold clone
#     builds j1 before j2 -- same protocol LDLIBS + libXX uses on the
#     C side.
#
#   JAVA_SRC_ROOTS += $(PROJ_TOP)/example/j1
#     tells depjava.py where to find j1's .java sources when building
#     its class index.  Needed because sub-makes don't have access
#     to project.mk's per-target `_srcdir` map (sub-makes are gm's
#     recipe-time boundary; the map lives at the top level).  Add one
#     line per JAR_DEPS entry.  If we ever export the srcdir map into
#     sub-makes this can be dropped entirely.
#
#   MAIN_CLASS := com.example.j2.App
#     makes the resulting jar executable via `jar cfe` -- i.e.
#     `java -jar $(GM_JAVA_DIR)/j2.jar` runs the app directly.

JAR_DEPS       := j1
JAVA_SRC_ROOTS += $(PROJ_TOP)/example/j1
MAIN_CLASS     := com.example.j2.App
JAVAC_FLAGS    += -Xlint:all
