# tmview -- a text dashboard: `tmexport < snapshot | java -jar tmview.jar`.
#
# Shows: an executable jar on an in-tree library jar.
#   JAR_DEPS        tmapi.jar goes on the classpath, and gm records `tmview: tmapi` so tmapi
#                   is built first -- the same as LDLIBS for C
#   JAVA_SRC_ROOTS  where tmapi's sources are, for the file-level graph (DEP_TREE=yes): a change
#                   to them is a change to tmview
#   MAIN_CLASS      makes the jar runnable with `java -jar`

JAVASOURCE     := com/example/tm/view/App.java
JAR_DEPS       := tmapi
JAVA_SRC_ROOTS += $(PROJ_TOP)/example/dashboard/api
MAIN_CLASS     := com.example.tm.view.App
JAVAC_FLAGS    += -Xlint:all
