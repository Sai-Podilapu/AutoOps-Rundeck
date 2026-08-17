package com.intertec.autoops.jobs.execution;

import org.junit.jupiter.api.Test;

import java.util.List;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertTrue;

/** Shell-style argument splitting for kubectl steps. */
class ArgumentLineTest {

    @Test
    void splitsOnWhitespace() {
        assertEquals(List.of("get", "pods", "-A"), ArgumentLine.tokenize("get  pods\t-A"));
    }

    @Test
    void keepsADoubleQuotedValueTogether() {
        assertEquals(List.of("get", "pods", "-l", "app=my app"),
                ArgumentLine.tokenize("get pods -l \"app=my app\""));
    }

    @Test
    void keepsASingleQuotedValueTogether() {
        assertEquals(List.of("annotate", "pod", "x", "note=hello world"),
                ArgumentLine.tokenize("annotate pod x 'note=hello world'"));
    }

    @Test
    void joinsQuotedAndUnquotedHalvesOfOneArgument() {
        assertEquals(List.of("-l", "app=my app"), ArgumentLine.tokenize("-l app=\"my app\""));
    }

    @Test
    void honoursEscapes() {
        assertEquals(List.of("get", "pod", "my pod"), ArgumentLine.tokenize("get pod my\\ pod"));
    }

    @Test
    void treatsAnUnterminatedQuoteLiterally() {
        assertEquals(List.of("get", "pods", "-l app="), ArgumentLine.tokenize("get pods \"-l app="));
    }

    @Test
    void isEmptyForBlankInput() {
        assertTrue(ArgumentLine.tokenize("   ").isEmpty());
        assertTrue(ArgumentLine.tokenize(null).isEmpty());
    }

    // ---- the -f detection that decides whether a manifest is written ----

    @Test
    void detectsRealFileArguments() {
        assertTrue(ArgumentLine.hasFileArgument(List.of("apply", "-f", "x.yaml")));
        assertTrue(ArgumentLine.hasFileArgument(List.of("apply", "--filename", "x.yaml")));
        assertTrue(ArgumentLine.hasFileArgument(List.of("apply", "-f=x.yaml")));
        assertTrue(ArgumentLine.hasFileArgument(List.of("apply", "--filename=x.yaml")));
    }

    /** "--force".contains("-f") was true — and silently dropped the manifest. */
    @Test
    void doesNotMistakeOtherFlagsForAFileArgument() {
        assertFalse(ArgumentLine.hasFileArgument(List.of("delete", "pod", "x", "--force")));
        assertFalse(ArgumentLine.hasFileArgument(List.of("get", "pods", "--field-selector=x")));
        assertFalse(ArgumentLine.hasFileArgument(List.of("logs", "pod", "--follow")));
        assertFalse(ArgumentLine.hasFileArgument(List.of("get", "pods", "-o", "wide")));
    }
}
