// gcgo -- Go binary that links against gm's in-tree libt1 via cgo.
//
// libt1 exports `int t1_c(int)` with `extern "C"` (see
// example/t1/include/t1.hpp).  gm builds libt1.a first (declared as
// `LDLIBS += -lt1` in gcgo.mk) and target.go.mk exports the CGO
// env vars pointing at $(GM_LIB_DIR).  All this .go source needs is
// the include path to libt1's header and the `-lt1` link flag.
package main

// #cgo CFLAGS: -I${SRCDIR}/../t1/include
// #cgo LDFLAGS: -lt1
// #include "t1.hpp"
import "C"

import "fmt"

func main() {
	// Round-trip an int through the C ABI to prove we linked.
	got := int(C.t1_c(C.int(42)))
	fmt.Printf("--> gcgo: libt1's t1_c(42) returned %d\n", got)
}
