package com.intertec.autoops.agent.modelsdk.google;

import com.google.genai.Client;
import com.intertec.autoops.agent.modelsdk.ModelCredentials;

/**
 * Google Gemini, via the Google Gen AI SDK.
 *
 * <p>Google is the vendor that wants its key as a query parameter rather than
 * a header; the SDK handles that placement, which is why the key is handed
 * over rather than assembled into a URL here.
 *
 * <p>The same SDK can also reach Gemini through Vertex AI with GCP
 * credentials. Only the API-key path is built: that is what the console asks a
 * tenant for, and offering a Vertex client nothing supplies credentials for
 * would be a dead branch.
 */
public final class GoogleClientFactory {

    private GoogleClientFactory() {
    }

    public static Client create(ModelCredentials credentials) {
        return Client.builder()
                .apiKey(credentials.require("apiKey"))
                .build();
    }
}
