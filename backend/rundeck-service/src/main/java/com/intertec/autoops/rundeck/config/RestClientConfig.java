package com.intertec.autoops.rundeck.config;

import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.http.client.SimpleClientHttpRequestFactory;
import org.springframework.web.client.RestClient;

/**
 * One RestClient per peer, each with BOUNDED connect/read timeouts.
 *
 * <p>The {@code upstreamRestClient} is the one that matters. It talks to a
 * server AutoOps does not run, on a network AutoOps does not control, and it
 * deliberately carries NO base URL — the host comes from the tenant's own
 * connection row, so a single shared client serves every tenant without any of
 * them being able to inherit another's address.
 */
@Configuration
public class RestClientConfig {

    @Bean("subscriptionRestClient")
    public RestClient subscriptionRestClient(RundeckProperties properties) {
        SimpleClientHttpRequestFactory factory = new SimpleClientHttpRequestFactory();
        factory.setConnectTimeout((int) properties.getSubscription().getConnectTimeout().toMillis());
        factory.setReadTimeout((int) properties.getSubscription().getReadTimeout().toMillis());
        return RestClient.builder()
                .baseUrl(properties.getSubscription().getBaseUrl())
                .requestFactory(factory)
                .build();
    }

    @Bean("coreRestClient")
    public RestClient coreRestClient(RundeckProperties properties) {
        RundeckProperties.Peer peer = properties.getCore();
        SimpleClientHttpRequestFactory factory = new SimpleClientHttpRequestFactory();
        factory.setConnectTimeout((int) peer.getConnectTimeout().toMillis());
        factory.setReadTimeout((int) peer.getReadTimeout().toMillis());
        return RestClient.builder()
                .baseUrl(peer.getBaseUrl())
                .requestFactory(factory)
                .build();
    }

    /**
     * Outbound to a customer's Rundeck. No base URL by design — every call
     * passes an absolute URI built from the connection row.
     *
     * <p>The read timeout is the generous one (20s default) because a Rundeck
     * that is mid-dispatch across a large node set genuinely takes seconds to
     * answer. It is still bounded: an upstream that never replies must not pin
     * a request thread here indefinitely.
     */
    @Bean("upstreamRestClient")
    public RestClient upstreamRestClient(RundeckProperties properties) {
        SimpleClientHttpRequestFactory factory = new SimpleClientHttpRequestFactory();
        factory.setConnectTimeout((int) properties.getUpstream().getConnectTimeout().toMillis());
        factory.setReadTimeout((int) properties.getUpstream().getReadTimeout().toMillis());
        return RestClient.builder()
                .requestFactory(factory)
                .build();
    }
}
