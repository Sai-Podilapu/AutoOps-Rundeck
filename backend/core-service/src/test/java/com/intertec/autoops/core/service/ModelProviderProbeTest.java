package com.intertec.autoops.core.service;

import com.fasterxml.jackson.databind.ObjectMapper;
import org.junit.jupiter.api.Test;

import static org.assertj.core.api.Assertions.assertThat;

/**
 * The probe's network calls are the vendors' business; what is ours is the
 * sentence we put on the row afterwards. Two things matter about it: an
 * operator can act on it, and no part of a credential is in it.
 *
 * <p>Deliberately Spring-free and offline — these exercise the parsing, not
 * the HTTP.
 */
class ModelProviderProbeTest {

    private final ModelProviderProbe probe = new ModelProviderProbe(new ObjectMapper());

    @Test
    void quotesTheVendorsOwnExplanation() {
        // The distinction that used to be lost: a wrong key and a key without
        // the models scope are both HTTP 401, and have different fixes.
        assertThat(probe.vendorMessage("""
                {"error":{"message":"You have insufficient permissions for this operation. \
                Missing scopes: api.model.read","type":"invalid_request_error"}}"""))
                .contains("Missing scopes: api.model.read");

        assertThat(probe.vendorMessage(
                "{\"error\":{\"message\":\"Invalid bearer token\",\"type\":\"authentication_error\"}}"))
                .isEqualTo("Invalid bearer token");
    }

    @Test
    void readsTheShapesTheCloudVendorsUseInstead() {
        // AWS and Huawei do not nest their message under "error".
        assertThat(probe.vendorMessage("{\"message\":\"The security token included in the "
                + "request is invalid.\"}"))
                .isEqualTo("The security token included in the request is invalid.");
        assertThat(probe.vendorMessage("{\"error_msg\":\"Incorrect IAM authentication information\"}"))
                .isEqualTo("Incorrect IAM authentication information");
    }

    @Test
    void neverQuotesAnythingKeyShaped() {
        // OpenAI echoes a partially masked key back in its own error text, and
        // this message is about to be stored and rendered in a browser.
        String message = probe.vendorMessage(
                "{\"error\":{\"message\":\"Incorrect API key provided: sk-proj-AbCdEf123456. "
                        + "You can find your API key at https://platform.openai.com.\"}}");
        assertThat(message).doesNotContain("sk-proj-AbCdEf123456").contains("***");

        assertThat(ModelProviderProbe.scrub("bad key AKIAIOSFODNN7EXAMPLE for this account"))
                .doesNotContain("AKIAIOSFODNN7EXAMPLE");
        assertThat(ModelProviderProbe.scrub("token AIzaSyD-abcdefgh12345 rejected"))
                .doesNotContain("AIzaSyD-abcdefgh12345");
    }

    @Test
    void saysNothingRatherThanSomethingUseless() {
        // A proxy's HTML error page or an empty body has nothing worth
        // quoting; the caller falls back to its own wording.
        assertThat(probe.vendorMessage("<html><body>502 Bad Gateway</body></html>")).isNull();
        assertThat(probe.vendorMessage("{\"error\":{\"type\":\"server_error\"}}")).isNull();
        assertThat(probe.vendorMessage("")).isNull();
        assertThat(probe.vendorMessage(null)).isNull();
    }

    @Test
    void keepsTheMessageShortEnoughToStore() {
        // last_test_note is a bounded column, and a vendor stack trace would
        // push the useful first sentence out of view.
        String message = ModelProviderProbe.scrub("x".repeat(500));
        assertThat(message).hasSizeLessThanOrEqualTo(200).endsWith("...");
    }
}
