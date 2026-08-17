package com.intertec.autoops.core.client;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.beans.factory.annotation.Qualifier;
import org.springframework.core.ParameterizedTypeReference;
import org.springframework.http.HttpHeaders;
import org.springframework.stereotype.Component;
import org.springframework.web.client.RestClient;

import java.time.Duration;
import java.time.Instant;
import java.util.Map;
import java.util.concurrent.ConcurrentHashMap;

/**
 * Read-side companion to {@link EntitlementClient}: fetches the tenant's plan
 * limits (retention depth + capacity ceilings) from GET
 * /api/subscriptions/current. Unlike the gate this NEVER fails closed —
 * reads are never blocked, so an unreachable subscription-service just means
 * unbounded history / unknown quota usage until it recovers. Cached per
 * tenant for 60s.
 */
@Component
public class SubscriptionInfoClient {

    private static final Logger log = LoggerFactory.getLogger(SubscriptionInfoClient.class);

    private static final Duration CACHE_TTL = Duration.ofSeconds(60);

    /** Any field is null when unlimited, no plan, or the service is unreachable. */
    public record PlanLimits(Integer historyDays, Integer maxProjects, Integer maxAutomations,
                             Integer maxJobs, Integer maxCloudIntegrations) {

        static final PlanLimits UNKNOWN = new PlanLimits(null, null, null, null, null);
    }

    private final RestClient subscriptionRestClient;

    private record CacheEntry(PlanLimits limits, Instant fetchedAt) {
    }

    private final ConcurrentHashMap<String, CacheEntry> cache = new ConcurrentHashMap<>();

    public SubscriptionInfoClient(@Qualifier("subscriptionRestClient") RestClient subscriptionRestClient) {
        this.subscriptionRestClient = subscriptionRestClient;
    }

    /** null = no bound (no plan, unlimited retention, or service unreachable). */
    public Integer historyDays(String tenantId, String accessToken) {
        return planLimits(tenantId, accessToken).historyDays();
    }

    public PlanLimits planLimits(String tenantId, String accessToken) {
        CacheEntry cached = cache.get(tenantId);
        if (cached != null && cached.fetchedAt().plus(CACHE_TTL).isAfter(Instant.now())) {
            return cached.limits();
        }
        PlanLimits limits = fetch(accessToken);
        cache.put(tenantId, new CacheEntry(limits, Instant.now()));
        return limits;
    }

    private PlanLimits fetch(String accessToken) {
        try {
            Map<String, Object> response = subscriptionRestClient.get()
                    .uri("/api/subscriptions/current")
                    .header(HttpHeaders.AUTHORIZATION, "Bearer " + accessToken)
                    .retrieve()
                    .body(new ParameterizedTypeReference<Map<String, Object>>() {
                    });
            if (response == null || !(response.get("plan") instanceof Map<?, ?> plan)) {
                return PlanLimits.UNKNOWN;
            }
            return new PlanLimits(intOrNull(plan, "historyDays"), intOrNull(plan, "maxProjects"),
                    intOrNull(plan, "maxAutomations"), intOrNull(plan, "maxJobs"),
                    intOrNull(plan, "maxCloudIntegrations"));
        } catch (Exception ex) {
            log.warn("plan limits lookup failed (history unbounded / usage unknown until it recovers): {}",
                    ex.getMessage());
            return PlanLimits.UNKNOWN;
        }
    }

    private static Integer intOrNull(Map<?, ?> plan, String key) {
        return plan.get(key) instanceof Number n ? n.intValue() : null;
    }
}