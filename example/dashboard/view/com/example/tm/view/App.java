package com.example.tm.view;

import com.example.tm.api.Metric;
import com.example.tm.api.PromReader;

import java.io.BufferedReader;
import java.io.IOException;
import java.io.InputStreamReader;
import java.nio.charset.StandardCharsets;
import java.util.List;
import java.util.Map;
import java.util.TreeMap;

/** Reads tmexport's output on standard input and draws the mean and p95 of every metric. */
public final class App {
    private static final int WIDTH = 40;

    private App() {}

    public static void main(String[] args) throws IOException {
        BufferedReader in = new BufferedReader(new InputStreamReader(System.in, StandardCharsets.UTF_8));
        List<Metric> metrics = PromReader.read(in);

        Map<String, double[]> stats = new TreeMap<>(); // metric -> {mean, p95, max}
        for (Metric m : metrics) {
            if (!m.name().equals("tm_metric")) {
                continue;
            }
            double[] s = stats.computeIfAbsent(m.label("metric"), k -> new double[3]);
            switch (m.label("stat")) {
                case "mean": s[0] = m.value(); break;
                case "p95":  s[1] = m.value(); break;
                case "max":  s[2] = m.value(); break;
                default: break;
            }
        }

        System.out.println("metric               mean      p95       0 .. max");
        for (Map.Entry<String, double[]> e : stats.entrySet()) {
            double[] s = e.getValue();
            System.out.printf("%-20s %-9.4g %-9.4g %s%n", e.getKey(), s[0], s[1], bar(s[0], s[1], s[2]));
        }
        for (Metric m : metrics) {
            if (m.name().equals("tm_alarm_active")) {
                System.out.printf("ALARM %-8s %s on %s%n", m.label("severity"), m.label("alarm"), m.label("metric"));
            }
        }
    }

    /** `=` up to the mean, `+` up to p95, scaled to max. */
    private static String bar(double mean, double p95, double max) {
        if (max <= 0) {
            return "";
        }
        int m = (int) Math.round(WIDTH * mean / max);
        int p = (int) Math.round(WIDTH * p95 / max);
        StringBuilder b = new StringBuilder("|");
        for (int i = 0; i < WIDTH; i++) {
            b.append(i < m ? '=' : i < p ? '+' : ' ');
        }
        return b.append('|').toString();
    }
}
