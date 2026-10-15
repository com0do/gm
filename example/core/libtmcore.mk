# libtmcore -- the C core everything else builds on: a sample ring and CRC-32 (tm/core.h).
#
# Shows: a static library (LIB_KIND), C sources under src/ (found without being listed with a
# path), the public headers under include/ (on the include path of this target and its tests),
# and a header generated from a template.

LIB_KIND := static
CSOURCE  += ring.c crc32.c version.c

# include/tm_build.h.in -> $(BUILD_DIR)/include/tm_build.h, every @VAR@ substituted.  Only the
# templates listed here are generated.  BUILD_DATE follows SOURCE_DATE_EPOCH (the last commit),
# so a rebuild gives the same library byte for byte.
HEADER_GEN      += include/tm_build.h.in
HEADER_GEN_VARS += PROJECT_VERSION
PROJECT_VERSION := 1.4.0
