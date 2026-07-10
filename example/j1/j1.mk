
# j1 -- a simple Java library, classified TYPE=java because its dir
# holds *.java files (see production/make/project.mk's _CLASSIFY).
#
# Zero-config path: no JAVASOURCE, no MAIN_CLASS.  target.java.mk
# auto-discovers every .java under this directory (recursively) and
# packages a plain library jar (no Main-Class attribute) into
# $(GM_JAVA_DIR)/j1.jar.
#
# Consumers wire in via `JAR_DEPS := j1` (see example/j2/j2.mk).
JAVAC_FLAGS += -Xlint:all
