// tmexport reads a tmd snapshot (a file, or standard input) and prints it in the Prometheus
// text exposition format: tm_metric{metric=...,stat=...} per statistic, tm_alarm_active per
// raised alarm.
//
//	tmd < samples | tmexport
package main

import (
	"encoding/json"
	"fmt"
	"io"
	"os"
	"sort"

	"example.com/tm/exporter/internal/prom"
)

type snapshot struct {
	Tmd       string                        `json:"tmd"`
	Samples   uint64                        `json:"samples"`
	Malformed uint64                        `json:"malformed"`
	Metrics   map[string]map[string]float64 `json:"metrics"`
	Alarms    []struct {
		Number   int     `json:"number"`
		Name     string  `json:"name"`
		Severity string  `json:"severity"`
		Metric   string  `json:"metric"`
		Value    float64 `json:"value"`
	} `json:"alarms"`
}

var stats = []string{"count", "mean", "stddev", "min", "max", "p50", "p95"}

func main() {
	in := io.Reader(os.Stdin)
	if len(os.Args) == 2 {
		f, err := os.Open(os.Args[1])
		if err != nil {
			fail(err)
		}
		defer f.Close()
		in = f
	} else if len(os.Args) > 2 {
		fmt.Fprintln(os.Stderr, "usage: tmexport [SNAPSHOT.json]")
		os.Exit(2)
	}

	var s snapshot
	if err := json.NewDecoder(in).Decode(&s); err != nil {
		fail(fmt.Errorf("not a tmd snapshot: %w", err))
	}

	w := prom.NewWriter(os.Stdout)
	w.Sample("tm_build_info", "gauge", "The tmd that wrote the snapshot.", prom.Labels{"version": s.Tmd}, 1)
	w.Sample("tm_samples_total", "counter", "Samples tmd has read.", nil, float64(s.Samples))
	w.Sample("tm_malformed_total", "counter", "Input lines tmd skipped.", nil, float64(s.Malformed))

	names := make([]string, 0, len(s.Metrics))
	for n := range s.Metrics {
		names = append(names, n)
	}
	sort.Strings(names)
	for _, n := range names {
		for _, st := range stats {
			w.Sample("tm_metric", "gauge", "Statistics over each metric's window.",
				prom.Labels{"metric": n, "stat": st}, s.Metrics[n][st])
		}
	}
	for _, a := range s.Alarms {
		w.Sample("tm_alarm_active", "gauge", "Alarms raised and not cleared.",
			prom.Labels{"alarm": a.Name, "severity": a.Severity, "metric": a.Metric}, 1)
	}
	if err := w.Err(); err != nil {
		fail(err)
	}
}

func fail(err error) {
	fmt.Fprintln(os.Stderr, "tmexport:", err)
	os.Exit(1)
}
