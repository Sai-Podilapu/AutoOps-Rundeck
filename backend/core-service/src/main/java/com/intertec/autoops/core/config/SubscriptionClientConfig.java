package com.intertec.autoops.core.config;

import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.http.client.SimpleClientHttpRequestFactory;
import org.springframework.web.client.RestClient;

/**
 * RestClients for the services core-service depends on, each with bounded
 * connect/read timeouts — a slow peer must never hang a create call.
 * subscription-service gates every mutation (2s / 3s); workflow-service holds
 * the workflow definitions the run engine, approvals, SCM and compliance
 * read (2s / 10s, since SCM import writes a whole project's worth).
 */
@Configuration
public class SubscriptionClientConfig {

    @Bean("subscriptionRestClient")
    public RestClient subscriptionRestClient(CoreProperties properties) {
        SimpleClientHttpRequestFactory requestFactory = new SimpleClientHttpRequestFactory();
        requestFactory.setConnectTimeout((int) properties.getSubscription().getConnectTimeout().toMillis());
        requestFactory.setReadTimeout((int) properties.getSubscription().getReadTimeout().toMillis());
        return RestClient.builder()
                .baseUrl(properties.getSubscription().getBaseUrl())
                .requestFactory(requestFactory)
                .build();
    }

    @Bean("workflowRestClient")
    public RestClient workflowRestClient(CoreProperties properties) {
        SimpleClientHttpRequestFactory requestFactory = new SimpleClientHttpRequestFactory();
        requestFactory.setConnectTimeout((int) properties.getWorkflow().getConnectTimeout().toMillis());
        requestFactory.setReadTimeout((int) properties.getWorkflow().getReadTimeout().toMillis());
        return RestClient.builder()
                .baseUrl(properties.getWorkflow().getBaseUrl())
                .requestFactory(requestFactory)
                .build();
    }

    /**
     * plugin-service, for outbound notifications. Tightest timeouts here
     * (1s / 2s): this sits on the run engine's hot path and is best-effort,
     * so a sick notification service must be abandoned, not waited on.
     */
    @Bean("pluginRestClient")
    public RestClient pluginRestClient(CoreProperties properties) {
        SimpleClientHttpRequestFactory requestFactory = new SimpleClientHttpRequestFactory();
        requestFactory.setConnectTimeout((int) properties.getPlugin().getConnectTimeout().toMillis());
        requestFactory.setReadTimeout((int) properties.getPlugin().getReadTimeout().toMillis());
        return RestClient.builder()
                .baseUrl(properties.getPlugin().getBaseUrl())
                .requestFactory(requestFactory)
                .build();
    }

    @Bean("agentRestClient")
    public RestClient agentRestClient(CoreProperties properties) {
        SimpleClientHttpRequestFactory requestFactory = new SimpleClientHttpRequestFactory();
        requestFactory.setConnectTimeout((int) properties.getAgent().getConnectTimeout().toMillis());
        requestFactory.setReadTimeout((int) properties.getAgent().getReadTimeout().toMillis());
        return RestClient.builder()
                .baseUrl(properties.getAgent().getBaseUrl())
                .requestFactory(requestFactory)
                .build();
    }
}
