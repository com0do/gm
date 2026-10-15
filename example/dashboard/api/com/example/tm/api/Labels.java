package com.example.tm.api;

import java.util.LinkedHashMap;
import java.util.Map;

/** Parses `{a="x",b="y"}`.  Package-private: PromReader is the API. */
final class Labels {
    private Labels() {}

    static Map<String, String> parse(String s) {
        Map<String, String> labels = new LinkedHashMap<>();
        int i = 1; // after '{'
        while (i < s.length() && s.charAt(i) != '}') {
            int eq = s.indexOf('=', i);
            String key = s.substring(i, eq).trim();
            StringBuilder value = new StringBuilder();
            int j = eq + 2; // after ="
            for (; s.charAt(j) != '"'; j++) {
                char c = s.charAt(j);
                if (c == '\\') {
                    c = s.charAt(++j);
                    value.append(c == 'n' ? '\n' : c);
                } else {
                    value.append(c);
                }
            }
            labels.put(key, value.toString());
            i = j + 1;
            if (i < s.length() && s.charAt(i) == ',') {
                i++;
            }
        }
        return labels;
    }
}
