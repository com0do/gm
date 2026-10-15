# tmapi -- reads the Prometheus text tmexport writes (Java library jar).
#
# Shows: a Java target -- the .java.mk suffix makes it one, JAVASOURCE lists its sources
# (relative to this directory).  No MAIN_CLASS: a plain library jar, $(GM_JAVA_DIR)/tmapi.jar.
# Consumers name it in JAR_DEPS (dashboard/view/tmview.java.mk).

JAVASOURCE  := com/example/tm/api/Metric.java \
               com/example/tm/api/PromReader.java \
               com/example/tm/api/Labels.java
JAVAC_FLAGS += -Xlint:all
