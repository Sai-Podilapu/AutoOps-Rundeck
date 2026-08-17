package com.intertec.autoops.plugin.config;

import com.intertec.autoops.plugin.provider.support.OutboundHttp;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.scheduling.concurrent.ThreadPoolTaskExecutor;

import java.util.concurrent.ThreadPoolExecutor;

/** Wiring for the outbound side: the shared HTTP client and the send pool. */
@Configuration
public class DeliveryConfig {

    @Bean
    public OutboundHttp outboundHttp(PluginProperties properties) {
        return new OutboundHttp(properties.getDelivery().getConnectTimeout(),
                properties.getDelivery().getReadTimeout());
    }

    /**
     * Bounded pool for outbound sends. A lifecycle event must never wait on a
     * third party, so core-service's POST returns as soon as the fan-out is
     * queued.
     *
     * <p>CallerRunsPolicy on saturation is deliberate: the alternative is
     * discarding a FAILED alert, and back-pressuring the caller for a moment
     * is far better than a run failing silently. The queue is capped so a dead
     * Slack endpoint cannot grow it without limit.
     */
    @Bean(name = "deliveryTaskExecutor", destroyMethod = "shutdown")
    public ThreadPoolTaskExecutor deliveryTaskExecutor(PluginProperties properties) {
        ThreadPoolTaskExecutor executor = new ThreadPoolTaskExecutor();
        executor.setCorePoolSize(properties.getDelivery().getWorkers());
        executor.setMaxPoolSize(properties.getDelivery().getWorkers());
        executor.setQueueCapacity(properties.getDelivery().getQueueCapacity());
        executor.setThreadNamePrefix("plugin-delivery-");
        executor.setRejectedExecutionHandler(new ThreadPoolExecutor.CallerRunsPolicy());
        // Let in-flight notifications finish on shutdown rather than vanishing.
        executor.setWaitForTasksToCompleteOnShutdown(true);
        executor.setAwaitTerminationSeconds(20);
        executor.initialize();
        return executor;
    }
}
