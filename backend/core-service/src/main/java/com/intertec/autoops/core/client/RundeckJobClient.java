package com.intertec.autoops.core.client;

import com.intertec.autoops.core.config.CoreProperties;
import com.intertec.autoops.core.domain.Job;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.http.client.JdkClientHttpRequestFactory;
import org.springframework.stereotype.Component;
import org.springframework.web.client.RestClient;

import java.net.http.HttpClient;
import java.time.Duration;
import java.util.HashMap;
import java.util.Map;

/**
 * Mirrors an AutoOps job onto the execution engine as a real Rundeck job.
 *
 * <p>Before this, a job lived only in {@code autoops_core.jobs}: Rundeck's own
 * JOBS screen was permanently empty, and the engine only ever saw a stream of
 * anonymous ad-hoc scripts at run time. Now creating or editing a job in
 * AutoOps puts a matching job definition on the engine, under the tenant's own
 * project.
 *
 * <p><b>Never throws</b>, same policy as {@link RundeckProjectClient} and for a
 * sharper reason: a job that cannot be imported is usually a job that is not
 * finished. Most of the existing jobs have step labels and no bodies, and the
 * engine rightly refuses those — but refusing to SAVE a half-written job would
 * make the authoring screen unusable. The job is saved either way; the import
 * failure is recorded on the engine-side mapping row.
 *
 * <p>Nor does it retry. This runs on a request thread with a human waiting, and
 * an unhealthy rundeck-service is not fixed by an immediate second attempt.
 */
@Component
public class RundeckJobClient {

    private static final Logger log = LoggerFactory.getLogger(RundeckJobClient.class);

    private final RestClient restClient;
    private final String internalToken;

    public RundeckJobClient(CoreProperties properties) {
        this.internalToken = properties.getExecution().getRundeckServiceToken();
        // Connect timeout belongs on the HttpClient; the JDK-backed factory only
        // exposes a read timeout. Without it an unroutable host hangs a request
        // thread until the read timeout expires.
        HttpClient httpClient = HttpClient.newBuilder()
                .connectTimeout(Duration.ofSeconds(3))
                .build();
        JdkClientHttpRequestFactory requestFactory = new JdkClientHttpRequestFactory(httpClient);
        // Importing a job is a translate plus one API call — it waits on nothing
        // executing, so a long timeout would only mean a longer spinner.
        requestFactory.setReadTimeout(Duration.ofSeconds(20));
        this.restClient = RestClient.builder()
                .baseUrl(properties.getExecution().getRundeckServiceUrl())
                .requestFactory(requestFactory)
                .build();
    }

    /**
     * Create or update this job on the engine.
     *
     * <p>Idempotent: the engine-side UUID is derived from (tenant, job id), so
     * calling this on every save edits one job rather than accumulating a
     * duplicate each time.
     */
    public void sync(Job job) {
        Map<String, Object> body = new HashMap<>();
        body.put("tenantId", job.getTenantId());
        body.put("projectId", job.getProject() == null ? null : job.getProject().getId());
        body.put("jobId", job.getId());
        body.put("name", job.getName());
        body.put("description", job.getDescription());
        body.put("definition", job.getDefinition());
        body.put("schedule", job.getSchedule());
        body.put("scheduleTimezone", job.getScheduleTimezone());
        body.put("enabled", job.isEnabled());
        body.put("requiresApproval", job.isRequiresApproval());
        post("/internal/rundeck/job", body, "sync", job);
    }

    /** The job was deleted in AutoOps — take it off the engine too. */
    public void remove(Job job) {
        Map<String, Object> body = new HashMap<>();
        body.put("tenantId", job.getTenantId());
        body.put("jobId", job.getId());
        post("/internal/rundeck/job/delete", body, "remove", job);
    }

    private void post(String uri, Map<String, Object> body, String action, Job job) {
        try {
            restClient.post()
                    .uri(uri)
                    .header("X-Internal-Token", internalToken)
                    .body(body)
                    .retrieve()
                    .toBodilessEntity();
        } catch (Exception ex) {
            // WARN rather than debug: this leaves AutoOps and the engine
            // disagreeing about what exists, and the drift is invisible until
            // someone opens the engine and counts jobs.
            log.warn("Could not {} job {} (tenant {}) on the execution engine: {}",
                    action, job.getId(), job.getTenantId(), ex.getMessage());
        }
    }
}
