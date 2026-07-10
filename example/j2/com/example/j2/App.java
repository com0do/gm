package com.example.j2;

import com.example.j1.Greeter;

/** Entry point.  Uses j1's Greeter via a classpath dep. */
public final class App {
    public static void main(String[] args) {
        String who = (args.length > 0) ? args[0] : "gm";
        Greeter g = new Greeter(who);
        System.out.println(g.greet());
    }
}
