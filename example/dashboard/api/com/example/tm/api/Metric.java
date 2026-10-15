package com.example.tm.api;

import java.util.Collections;
import java.util.Map;

/** One sample of the exposition: a name, its labels and a value. */
public final class Metric {
    private final String name;
    private final Map<String, String> labels;
    private final double value;

    Metric(String name, Map<String, String> labels, double value) {
        this.name = name;
        this.labels = Collections.unmodifiableMap(labels);
        this.value = value;
    }

    public String name() {
        return name;
    }

    /** The label's value, or "" when the sample has no such label. */
    public String label(String key) {
        String v = labels.get(key);
        return v == null ? "" : v;
    }

    public double value() {
        return value;
    }
}
