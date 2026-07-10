# alarms_demo -- consumes pkg-p2's auto-generated alarms library
# but isn't ITSELF packaged in pkg-p2 (see pkg-p2.yaml's files[]).
# Use the explicit-list escape hatch to pull the header in anyway.
CXXSOURCE   += main.cxx
LDLIBS      += -lp2alarms
PKG_HEADERS := pkg-p2
