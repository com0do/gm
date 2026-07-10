package com.example.j1;

/** A trivial greeter used by j2's App. */
public final class Greeter {
    private final String name;

    public Greeter(String name) {
        this.name = name;
    }

    public String greet() {
        return "Hello, " + name + "!  (from libt " + Utils.moduleTag() + ")";
    }
}
