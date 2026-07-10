package com.example.j1;

/** Same-package helper -- exercised by Greeter without an import. */
final class Utils {
    private Utils() {}

    static String moduleTag() {
        return "j1@1.0.0";
    }
}
