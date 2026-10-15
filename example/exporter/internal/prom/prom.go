// Package prom writes the Prometheus text exposition format.
package prom

import (
	"fmt"
	"io"
	"sort"
	"strings"
)

// Labels of one sample; written sorted by name.
type Labels map[string]string

// Writer writes metric families: HELP and TYPE once per name, then its samples.
type Writer struct {
	out  io.Writer
	seen map[string]bool
	err  error
}

func NewWriter(out io.Writer) *Writer {
	return &Writer{out: out, seen: map[string]bool{}}
}

// Sample writes one sample of a gauge or counter called name.
func (w *Writer) Sample(name, kind, help string, labels Labels, value float64) {
	if !w.seen[name] {
		w.seen[name] = true
		w.printf("# HELP %s %s\n# TYPE %s %s\n", name, help, name, kind)
	}
	w.printf("%s%s %g\n", name, format(labels), value)
}

// Err is the first write error, if any.
func (w *Writer) Err() error { return w.err }

func (w *Writer) printf(f string, args ...any) {
	if w.err == nil {
		_, w.err = fmt.Fprintf(w.out, f, args...)
	}
}

func format(labels Labels) string {
	if len(labels) == 0 {
		return ""
	}
	names := make([]string, 0, len(labels))
	for n := range labels {
		names = append(names, n)
	}
	sort.Strings(names)
	parts := make([]string, len(names))
	for i, n := range names {
		parts[i] = fmt.Sprintf("%s=%q", n, labels[n])
	}
	return "{" + strings.Join(parts, ",") + "}"
}
