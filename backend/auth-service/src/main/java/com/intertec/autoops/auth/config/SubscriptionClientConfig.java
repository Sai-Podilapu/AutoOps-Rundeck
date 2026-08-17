package com.intertec.autoops.auth.config;

import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.http.client.SimpleClientHttpRequestFactory;
import org.springframework.web.client.RestClient;

/**
 * RestClient for subscription-service with bounded connect/read timeouts
 * (2s / 3s) — a slow subscription-service must never hang an authorize call.
 */
@Configuration
public class SubscriptionClientConfig {

    @Bean("subscriptionRestClient")
    public RestClient subscriptionRestClient(AuthProperties properties) {
        SimpleClientHttpRequestFactory requestFactory = new SimpleClientHttpRequestFactory();
        requestFactory.setConnectTimeout((int) properties.getSubscription().getConnectTimeout().toMillis());
        requestFactory.setReadTimeout((int) properties.getSubscription().getReadTimeout().toMillis());
        return RestClient.builder()
                .baseUrl(properties.getSubscription().getBaseUrl())
                .requestFactory(requestFactory)
                .build();
    }
}
