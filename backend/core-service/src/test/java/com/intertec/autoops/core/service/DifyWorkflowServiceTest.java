package com.intertec.autoops.core.service;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.intertec.autoops.core.client.DifyAppClient;
import com.intertec.autoops.core.config.DifyAppRegistry;
import com.intertec.autoops.core.exception.CoreException;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;

import java.util.List;
import java.util.Map;
import java.util.Optional;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

/**
 * The seam between a catalog item and Dify: which workflow a definition names,
 * what form that workflow asks for, and whether a set of answers is complete.
 *
 * <p>No Spring context and no Dify — the client is mocked, because what is
 * being pinned here is the translation, not the transport.
 */
class DifyWorkflowServiceTest {

    private static final ObjectMapper MAPPER = new ObjectMapper();

    /** A realistic /v1/parameters body: a list of single-key control objects. */
    private static final String PARAMETERS = """
            {"user_input_form":[
              {"text-input":{"label":"Hostname","variable":"host","required":true,"max_length":48}},
              {"select":{"label":"Environment","variable":"env","required":true,
                         "default":"prod","options":["dev","prod"]}},
              {"paragraph":{"label":"Reason","variable":"reason","required":false}},
              {"number":{"label":"Retries","variable":"retries","required":false}}
            ]}
            """;

    private DifyAppRegistry registry;
    private DifyAppClient client;
    private DifyWorkflowService service;

    @BeforeEach
    void setUp() throws Exception {
        registry = mock(DifyAppRegistry.class);
        client = mock(DifyAppClient.class);
        service = new DifyWorkflowService(registry, client, MAPPER);
        when(registry.keyFor("patch-tuesday")).thenReturn(Optional.of("app-secret"));
        when(registry.keyFor("unknown")).thenReturn(Optional.empty());
        when(client.parameters(anyString())).thenReturn(MAPPER.readTree(PARAMETERS));
    }

    // ---- which workflow a definition names ------------------------------

    @Test
    void definitionNamingASlugIsRecognised() {
        assertThat(service.slugIn("{\"difyWorkflow\":\"patch-tuesday\"}"))
                .isEqualTo("patch-tuesday");
    }

    @Test
    void aPlainNodeCanvasNamesNoSlug() {
        // This is the branch that keeps every pre-existing workflow running
        // through job-service untouched. A false positive here would silently
        // stop them all executing.
        assertThat(service.slugIn("{\"nodes\":[{\"type\":\"script\"}]}")).isNull();
        assertThat(service.slugIn("not json at all")).isNull();
        assertThat(service.slugIn("")).isNull();
        assertThat(service.slugIn(null)).isNull();
    }

    @Test
    void aBlankSlugIsNotASlug() {
        assertThat(service.slugIn("{\"difyWorkflow\":\"  \"}")).isNull();
    }

    // ---- the input form -------------------------------------------------

    @Test
    void difysControlShapeIsFlattenedIntoFields() {
        List<DifyWorkflowService.InputField> fields = service.inputsFor("patch-tuesday");

        assertThat(fields).extracting(DifyWorkflowService.InputField::variable)
                .containsExactly("host", "env", "reason", "retries");
        // The control name IS the type in Dify's shape — losing it would render
        // a 4-line paragraph box as a one-line text input.
        assertThat(fields).extracting(DifyWorkflowService.InputField::type)
                .containsExactly("text", "select", "paragraph", "number");
        assertThat(fields.get(0).required()).isTrue();
        assertThat(fields.get(0).maxLength()).isEqualTo(48);
        assertThat(fields.get(1).options()).containsExactly("dev", "prod");
        assertThat(fields.get(2).required()).isFalse();
    }

    @Test
    void aFieldWithNoVariableIsDropped() throws Exception {
        when(client.parameters(anyString())).thenReturn(MAPPER.readTree(
                "{\"user_input_form\":[{\"text-input\":{\"label\":\"Nameless\"}}]}"));
        // There is nothing to send it back under, so offering it would produce
        // a field whose value is silently discarded.
        assertThat(service.inputsFor("patch-tuesday")).isEmpty();
    }

    @Test
    void anUnconfiguredSlugSaysWhichVariableToSet() {
        assertThatThrownBy(() -> service.inputsFor("unknown"))
                .isInstanceOf(CoreException.class)
                .hasMessageContaining("DIFY_WF_UNKNOWN");
    }

    // ---- validation -----------------------------------------------------

    @Test
    void missingRequiredValuesAreNamedNotSilentlyDropped() {
        // Dify runs a workflow with an unset variable quite happily and
        // produces nonsense, so this has to fail before the call is made.
        assertThatThrownBy(() -> service.validate("patch-tuesday", Map.of("reason", "audit")))
                .isInstanceOf(CoreException.class)
                .hasMessageContaining("Hostname");
    }

    @Test
    void aDeclaredDefaultSatisfiesARequiredField() {
        Map<String, Object> clean = service.validate("patch-tuesday", Map.of("host", "db01"));
        assertThat(clean).containsEntry("host", "db01").containsEntry("env", "prod");
    }

    @Test
    void blankOptionalsAreDroppedRatherThanSentAsEmpty() {
        Map<String, Object> clean = service.validate("patch-tuesday",
                Map.of("host", "db01", "reason", "   "));
        // An absent key lets the workflow's own default apply; "" overrides it.
        assertThat(clean).doesNotContainKey("reason");
    }

    @Test
    void unknownKeysAreNotForwarded() {
        Map<String, Object> clean = service.validate("patch-tuesday",
                Map.of("host", "db01", "sneaky", "value"));
        assertThat(clean).doesNotContainKey("sneaky");
    }

    @Test
    void runPassesTheResolvedKeyAndNeverTheSlug() {
        service.run("patch-tuesday", Map.of("host", "db01"), "acme-corp");
        // The key is the thing that must not be reconstructible from anything
        // stored in a library item.
        verify(client).run(eq("app-secret"), any(), eq("acme-corp"));
    }
}
