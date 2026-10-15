// tmcrc prints the CRC-32 of each file (or of standard input) twice: computed by libtmcore,
// called through cgo, and by Go's hash/crc32.  It exits 1 if they ever disagree.
//
//	tmcrc FILE...
package main

// #cgo CFLAGS: -I${SRCDIR}/../core/include
// #cgo LDFLAGS: -ltmcore
// #include <tm/core.h>
import "C"

import (
	"fmt"
	"hash/crc32"
	"io"
	"os"
	"unsafe"
)

func checksums(r io.Reader) (c uint32, g uint32, err error) {
	buf := make([]byte, 64*1024)
	var cc C.uint32_t
	for {
		n, rerr := r.Read(buf)
		if n > 0 {
			cc = C.tm_crc32_update(cc, unsafe.Pointer(&buf[0]), C.size_t(n))
			g = crc32.Update(g, crc32.IEEETable, buf[:n])
		}
		if rerr == io.EOF {
			return uint32(cc), g, nil
		}
		if rerr != nil {
			return 0, 0, rerr
		}
	}
}

// check prints one line for name ("-": standard input); false on an error or a mismatch.
func check(name string) bool {
	in := io.Reader(os.Stdin)
	if name != "-" {
		f, err := os.Open(name)
		if err != nil {
			fmt.Fprintln(os.Stderr, "tmcrc:", err)
			return false
		}
		defer f.Close()
		in = f
	}
	c, g, err := checksums(in)
	if err != nil {
		fmt.Fprintln(os.Stderr, "tmcrc:", name+":", err)
		return false
	}
	verdict := "ok"
	if c != g {
		verdict = "MISMATCH"
	}
	fmt.Printf("%08x %08x %-8s %s\n", c, g, verdict, name)
	return c == g
}

func main() {
	files := os.Args[1:]
	if len(files) == 0 {
		files = []string{"-"}
	}
	status := 0
	for _, name := range files {
		if !check(name) {
			status = 1
		}
	}
	os.Exit(status)
}
