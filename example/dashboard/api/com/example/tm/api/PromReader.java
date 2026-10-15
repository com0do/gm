package com.example.tm.api;

import java.io.BufferedReader;
import java.io.IOException;
import java.util.ArrayList;
import java.util.Collections;
import java.util.List;
import java.util.Map;

/** Reads the Prometheus text exposition format, as tmexport writes it. */
public final class PromReader {
    private PromReader() {}

    /** Every sample in the input; comment lines (# HELP, # TYPE) are skipped. */
    public static List<Metric> read(BufferedReader in) throws IOException {
        List<Metric> metrics = new ArrayList<>();
        String line;
        while ((line = in.readLine()) != null) {
            line = line.trim();
            if (line.isEmpty() || line.startsWith("#")) {
                continue;
            }
            int brace = line.indexOf('{');
            int space = line.lastIndexOf(' ');
            String name;
            Map<String, String> labels;
            if (brace >= 0 && brace < space) {
                name = line.substring(0, brace);
                labels = Labels.parse(line.substring(brace, line.lastIndexOf('}') + 1));
            } else {
                name = line.substring(0, space);
                labels = Collections.emptyMap();
            }
            metrics.add(new Metric(name, labels, Double.parseDouble(line.substring(space + 1))));
        }
        return metrics;
    }
}
