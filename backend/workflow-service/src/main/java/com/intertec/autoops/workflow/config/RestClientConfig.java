package com.intertec.autoops.workflow.config;

import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.http.client.SimpleClientHttpRequestFactory;
import org.springframework.web.client.RestClient;

/**
 * One RestClient per peer service, each with BOUNDED connect/read timeouts —
 * a slow peer must never hang a workflow call. Splitting workflows out of
 * core-service means three of these calls now sit on the request path, so the
 * budgets matter more than they did in the monolith.
 */
@Configuration
public class RestClientConfig {

    @Bean("subscriptionRestClient")
    public RestClient subscriptionRestClient(WorkflowProperties properties) {
        SimpleClientHttpRequestFactory factory = new SimpleClientHttpRequestFactory();
        factory.setConnectTimeout((int) properties.getSubscription().getConnectTimeout().toMillis());
        factory.setReadTimeout((int) properties.getSubscription().getReadTimeout().toMillis());
        return RestClient.builder()
                .baseUrl(properties.getSubscription().getBaseUrl())
                .requestFactory(factory)
                .build();
    }

    @Bean("coreRestClient")
    public RestClient coreRestClient(WorkflowProperties properties) {
        return peerClient(properties.getCore());
    }

    @Bean("agentRestClient")
    public RestClient agentRestClient(WorkflowProperties properties) {
        return peerClient(properties.getAgent());
    }

    private static RestClient peerClient(WorkflowProperties.Peer peer) {
        SimpleClientHttpRequestFactory factory = new SimpleClientHttpRequestFactory();
        factory.setConnectTimeout((int) peer.getConnectTimeout().toMillis());
        factory.setReadTimeout((int) peer.getReadTimeout().toMillis());
        return RestClient.builder()
                .baseUrl(peer.getBaseUrl())
                .requestFactory(factory)
                .build();
    }
}
