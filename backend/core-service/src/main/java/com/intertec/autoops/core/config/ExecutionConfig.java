package com.intertec.autoops.core.config;

import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.scheduling.annotation.EnableScheduling;
import org.springframework.scheduling.concurrent.ThreadPoolTaskExecutor;

/**
 * Bounded worker pool for run execution (one thread per in-flight run; excess
 * runs wait QUEUED) and the scheduling infrastructure for the cron poller.
 */
@Configuration
@EnableScheduling
public class ExecutionConfig {

    @Bean(name = "executionTaskExecutor")
    public ThreadPoolTaskExecutor executionTaskExecutor(CoreProperties properties) {
        ThreadPoolTaskExecutor executor = new ThreadPoolTaskExecutor();
        executor.setThreadNamePrefix("run-exec-");
        executor.setCorePoolSize(properties.getExecution().getPoolSize());
        executor.setMaxPoolSize(properties.getExecution().getPoolSize());
        executor.setQueueCapacity(500);
        executor.setWaitForTasksToCompleteOnShutdown(false);
        return executor;
    }
}