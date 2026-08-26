package com.intertec.autoops.core.client;

import com.intertec.autoops.core.config.CoreProperties;
import com.intertec.autoops.core.domain.Project;
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
 * Keeps the execution engine's project list in step with the tenant's.
 *
 * <p>Without this, the two drift in four ways, all of which a tenant can see:
 * a Rundeck project appears only once something has RUN in it, a rename in
 * AutoOps never reaches it, an archived project stays live on the engine, and
 * the engine shows the derived identifier rather than the name the customer
 * chose.
 *
 * <p><b>This class never throws</b>, and the policy is copied from
 * {@link PluginClient} for the same reason: project bookkeeping on the engine
 * must not be able to fail a tenant's project creation. If rundeck-service is
 * down, the AutoOps project is still created, renamed or archived, and the
 * engine catches up the next time the project is touched — or, for creation,
 * on the first step that runs in it, since provision-on-first-use is still
 * there underneath.
 *
 * <p>Nor does it retry. This sits on a request thread that a human is waiting
 * on, and rundeck-service being unhealthy is not something a second immediate
 * attempt fixes.
 *
 * <p>Deliberately NOT conditional on {@code execution.mode=rundeck}. A
 * deployment rolled back to job-service still wants the engine's project list
 * accurate for when it rolls forward again, and the calls are harmless when
 * rundeck-service is simply unreachable.
 */
@Component
public class RundeckProjectClient {

    private static final Logger log = LoggerFactory.getLogger(RundeckProjectClient.class);

    private final RestClient restClient;
    private final String internalToken;

    public RundeckProjectClient(CoreProperties properties) {
        this.internalToken = properties.getExecution().getRundeckServiceToken();
        // The connect timeout belongs on the HttpClient, not the factory — the
        // JDK-backed factory exposes only a read timeout, so setting connect
        // here is the difference between failing fast and hanging a request
        // thread on an unroutable host until the read timeout expires.
        HttpClient httpClient = HttpClient.newBuilder()
                .connectTimeout(Duration.ofSeconds(3))
                .build();
        JdkClientHttpRequestFactory requestFactory = new JdkClientHttpRequestFactory(httpClient);
        // Short and fixed. Unlike a step, none of these calls wait on anything
        // executing — provisioning a project is a handful of API calls — so a
        // long timeout here would only ever mean a tenant staring at a spinner
        // while an unhealthy service takes its time saying no.
        requestFactory.setReadTimeout(Duration.ofSeconds(15));
        this.restClient = RestClient.builder()
                .baseUrl(properties.getExecution().getRundeckServiceUrl())
                .requestFactory(requestFactory)
                .build();
    }

    /**
     * The project exists in AutoOps and is ACTIVE — make sure the engine has it,
     * carrying the display name across.
     *
     * <p>Used for create, rename and restore alike: all three reduce to the
     * same desired end state, and the endpoint is idempotent, so there is no
     * reason for three code paths.
     */
    public void sync(Project project) {
        Map<String, Object> body = new HashMap<>();
        body.put("tenantId", project.getTenantId());
        body.put("projectId", project.getId());
        body.put("label", project.getName());
        body.put("description", project.getDescription());
        post("/internal/rundeck/project", body, "sync", project);
    }

    /**
     * The project was archived — have the engine drop it.
     *
     * <p>This DELETES the Rundeck project and its execution history. That is
     * the configured behaviour, chosen so the engine's list mirrors active
     * projects exactly; a restore re-provisions an empty one.
     */
    public void archive(Project project) {
        Map<String, Object> body = new HashMap<>();
        body.put("tenantId", project.getTenantId());
        body.put("projectId", project.getId());
        post("/internal/rundeck/project/archive", body, "archive", project);
    }

    private void post(String uri, Map<String, Object> body, String action, Project project) {
        try {
            restClient.post()
                    .uri(uri)
                    .header("X-Internal-Token", internalToken)
                    .body(body)
                    .retrieve()
                    .toBodilessEntity();
        } catch (Exception ex) {
            // WARN, not debug: unlike a missed notification this leaves two
            // systems disagreeing about what exists, and the drift is silent
            // until someone opens the engine and counts projects.
            log.warn("Could not {} project {} (tenant {}) on the execution engine: {}",
                    action, project.getId(), project.getTenantId(), ex.getMessage());
        }
    }
}
