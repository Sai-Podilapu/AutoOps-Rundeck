package com.intertec.autoops.jobs.execution;

import java.util.ArrayList;
import java.util.List;

/**
 * Splits a user-typed argument line into argv the way a shell would, so a
 * quoted value survives as ONE argument: {@code get pods -l "app=my app"} is
 * four arguments, not five. Naive whitespace splitting silently mangles every
 * selector, annotation and label with a space in it.
 *
 * <p>Single and double quotes group; a backslash escapes the next character
 * outside single quotes. An unterminated quote is taken literally rather than
 * rejected — the tool being invoked gives a better error than we can.
 */
public final class ArgumentLine {

    private ArgumentLine() {
    }

    public static List<String> tokenize(String line) {
        List<String> tokens = new ArrayList<>();
        if (line == null) {
            return tokens;
        }
        StringBuilder current = new StringBuilder();
        boolean inToken = false;
        char quote = 0;
        for (int i = 0; i < line.length(); i++) {
            char c = line.charAt(i);
            if (quote != 0) {
                if (c == quote) {
                    quote = 0;
                } else if (c == '\\' && quote == '"' && i + 1 < line.length()) {
                    current.append(line.charAt(++i));
                } else {
                    current.append(c);
                }
                continue;
            }
            switch (c) {
                case '\'', '"' -> {
                    quote = c;
                    inToken = true;
                }
                case '\\' -> {
                    if (i + 1 < line.length()) {
                        current.append(line.charAt(++i));
                    }
                    inToken = true;
                }
                case ' ', '\t', '\r', '\n' -> {
                    if (inToken) {
                        tokens.add(current.toString());
                        current.setLength(0);
                        inToken = false;
                    }
                }
                default -> {
                    current.append(c);
                    inToken = true;
                }
            }
        }
        if (inToken) {
            tokens.add(current.toString());
        }
        return tokens;
    }

    /**
     * Whether argv already names a file for the tool to read — {@code -f},
     * {@code --filename}, or either with an inline value. Checked per token:
     * {@code "--force".contains("-f")} is true, which used to make a manifest
     * silently disappear from a {@code delete --force} step.
     */
    public static boolean hasFileArgument(List<String> arguments) {
        for (String argument : arguments) {
            if (argument.equals("-f") || argument.equals("--filename")
                    || argument.startsWith("-f=") || argument.startsWith("--filename=")) {
                return true;
            }
        }
        return false;
    }
}
