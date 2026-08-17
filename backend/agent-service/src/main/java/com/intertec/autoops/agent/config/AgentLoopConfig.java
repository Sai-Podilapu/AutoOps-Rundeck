package com.intertec.autoops.agent.config;

import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.core.task.TaskExecutor;
import org.springframework.scheduling.annotation.EnableScheduling;
import org.springframework.scheduling.concurrent.ThreadPoolTaskExecutor;

import java.util.concurrent.ThreadPoolExecutor;

/**
 * Where an agent run actually executes.
 *
 * <p>One thread per run, and the pool is deliberately small. An agent run is
 * not CPU work — it spends nearly all its time waiting on a model or on a job
 * — but each one holds a thread for minutes, and each one is spending the
 * tenant's money with a vendor. A pool sized for throughput would let a bad
 * afternoon turn into a very large bill and a lot of concurrent changes to
 * production, both without anyone choosing that.
 *
 * <p>The queue is BOUNDED and the rejection policy is
 * {@link ThreadPoolExecutor.CallerRunsPolicy}. Unbounded would swallow runs
 * into memory and lose them all on restart; discarding would leave rows stuck
 * in PENDING forever with nothing to explain it. Caller-runs pushes back on
 * whoever is queueing, which is the honest response to being full.
 */
@Configuration
@EnableScheduling
public class AgentLoopConfig {

    @Bean("agentLoopExecutor")
    public TaskExecutor agentLoopExecutor() {
        ThreadPoolTaskExecutor executor = new ThreadPoolTaskExecutor();
        executor.setCorePoolSize(2);
        executor.setMaxPoolSize(4);
        executor.setQueueCapacity(50);
        executor.setThreadNamePrefix("agent-loop-");
        executor.setRejectedExecutionHandler(new ThreadPoolExecutor.CallerRunsPolicy());
        // Runs are resumable from the transcript, so a shutdown that cuts one
        // off loses at most the step in flight. Waiting for a run that is
        // parked behind a ten-minute job would just delay the shutdown.
        executor.setWaitForTasksToCompleteOnShutdown(false);
        executor.initialize();
        return executor;
    }
}
