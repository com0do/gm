# tmcrc -- CRC-32 of files computed twice, by libtmcore through cgo and by Go's hash/crc32.
#
# Shows: cgo calling an in-tree C library.  LDLIBS declares it as a C target would, so gm
# builds libtmcore first; the `#cgo` lines in main.go find its header and library (gm points
# cgo's linker at $(GM_LIB_DIR)).

LDLIBS += -ltmcore
