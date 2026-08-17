package com.intertec.autoops.core.web;

import com.intertec.autoops.core.client.DifyClient;
import com.intertec.autoops.core.exception.CoreException;
import com.intertec.autoops.core.service.DifyWorkflowService;
import org.springframework.core.io.InputStreamResource;
import org.springframework.http.MediaType;
import org.springframework.http.ResponseEntity;
import org.springframework.security.core.annotation.AuthenticationPrincipal;
import org.springframework.security.oauth2.jwt.Jwt;
import org.springframework.web.bind.annotation.DeleteMapping;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.PutMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;

import java.util.List;
import java.util.Map;

/**
 * The AutoOps face of Dify. The console calls here; this service calls Dify
 * with a workspace token the browser never sees.
 *
 * <p><b>Authoring is PROVIDER-only</b>, consistent with the rest of the
 * platform: workflows are designed by the provider and rolled out to
 * customers, so creating, editing, publishing and deleting Dify apps — and
 * touching model-provider credentials — all require the PROVIDER role. A
 * tenant reaching these gets 403, the same answer workflow-service gives.
 *
 * <p>Paths are mapped EXPLICITLY onto Dify's console API rather than proxied
 * blind. A pass-through proxy would let any authenticated caller reach every
 * console endpoint the workspace token can reach — including workspace member
 * management and other apps' credentials. Only the operations the designer
 * actually needs are exposed.
 */
@RestController
@RequestMapping("/api/dify")
public class DifyController {

    private final DifyClient dify;
    private final DifyWorkflowService difyWorkflows;

    public DifyController(DifyClient dify, DifyWorkflowService difyWorkflows) {
        this.dify = dify;
        this.difyWorkflows = difyWorkflows;
    }

    // ---- apps ----------------------------------------------------------

    @GetMapping("/apps")
    public Object listApps() {
        return dify.get("/apps?page=1&limit=100");
    }

    @GetMapping("/apps/{appId}")
    public Object getApp(@PathVariable String appId) {
        return dify.get("/apps/" + appId);
    }

    @PostMapping("/apps")
    public Object createApp(@RequestBody Map<String, Object> body,
                            @AuthenticationPrincipal Jwt jwt) {
        requireProvider(jwt);
        // Dify needs a mode; the designer only builds workflow-mode apps.
        return dify.post("/apps", Map.of(
                "name", body.getOrDefault("name", "Untitled workflow"),
                "mode", body.getOrDefault("mode", "workflow"),
                "description", body.getOrDefault("description", ""),
                "icon_type", "emoji", "icon", "🤖", "icon_background", "#EFF1F5"));
    }

    @DeleteMapping("/apps/{appId}")
    public Map<String, String> deleteApp(@PathVariable String appId,
                                         @AuthenticationPrincipal Jwt jwt) {
        requireProvider(jwt);
        dify.delete("/apps/" + appId);
        return Map.of("result", "success");
    }

    // ---- the draft graph the designer edits -----------------------------

    @GetMapping("/apps/{appId}/draft")
    public Object getDraft(@PathVariable String appId) {
        return dify.get("/apps/" + appId + "/workflows/draft");
    }

    @PutMapping("/apps/{appId}/draft")
    public Object saveDraft(@PathVariable String appId,
                            @RequestBody Map<String, Object> draft,
                            @AuthenticationPrincipal Jwt jwt) {
        requireProvider(jwt);
        return dify.post("/apps/" + appId + "/workflows/draft", draft);
    }

    @PostMapping("/apps/{appId}/publish")
    public Object publish(@PathVariable String appId, @AuthenticationPrincipal Jwt jwt) {
        requireProvider(jwt);
        return dify.post("/apps/" + appId + "/workflows/publish", null);
    }

    @GetMapping("/apps/{appId}/dsl")
    public Object exportDsl(@PathVariable String appId) {
        return dify.get("/apps/" + appId + "/export");
    }

    // ---- model providers -------------------------------------------------

    @GetMapping("/model-providers")
    public Object listProviders() {
        return dify.get("/workspaces/current/model-providers");
    }

    @GetMapping("/models")
    public Object listAvailableModels(@RequestParam(defaultValue = "llm") String type) {
        return dify.get("/workspaces/current/models/model-types/" + type);
    }

    @GetMapping("/model-providers/{provider}/models")
    public Object listProviderModels(@PathVariable String provider) {
        return dify.get("/workspaces/current/model-providers/" + provider + "/models");
    }

    /**
     * Credentials go INTO Dify and are never read back out — Dify itself only
     * ever returns them obfuscated, and this endpoint deliberately has no GET
     * counterpart.
     */
    @PostMapping("/model-providers/{provider}/credentials")
    public Object saveCredentials(@PathVariable String provider,
                                  @RequestBody Map<String, Object> body,
                                  @AuthenticationPrincipal Jwt jwt) {
        requireProvider(jwt);
        return dify.post("/workspaces/current/model-providers/" + provider,
                Map.of("credentials", body.getOrDefault("credentials", Map.of())));
    }

    @DeleteMapping("/model-providers/{provider}/credentials")
    public Map<String, String> removeCredentials(@PathVariable String provider,
                                                 @AuthenticationPrincipal Jwt jwt) {
        requireProvider(jwt);
        dify.delete("/workspaces/current/model-providers/" + provider);
        return Map.of("result", "success");
    }

    @GetMapping("/workspace/default-models")
    public Object defaultModels() {
        return dify.get("/workspaces/current/default-model?model_type=llm");
    }

    @PostMapping("/workspace/default-models")
    public Object setDefaultModel(@RequestBody Map<String, Object> body,
                                  @AuthenticationPrincipal Jwt jwt) {
        requireProvider(jwt);
        return dify.post("/workspaces/current/default-model", body);
    }

    // ---- plugins / tools / knowledge -------------------------------------

    @GetMapping("/plugins/marketplace")
    public Object marketplace(@RequestParam(required = false, defaultValue = "") String q) {
        return dify.get("/workspaces/current/plugin/list?page=1&page_size=100"
                + (q.isBlank() ? "" : "&keyword=" + q));
    }

    @PostMapping("/plugins/install")
    public Object installPlugin(@RequestBody Map<String, Object> body,
                                @AuthenticationPrincipal Jwt jwt) {
        requireProvider(jwt);
        return dify.post("/workspaces/current/plugin/install/marketplace", body);
    }

    @PostMapping("/plugins/uninstall")
    public Object uninstallPlugin(@RequestBody Map<String, Object> body,
                                  @AuthenticationPrincipal Jwt jwt) {
        requireProvider(jwt);
        return dify.post("/workspaces/current/plugin/uninstall", body);
    }

    @GetMapping("/tool-providers")
    public Object toolProviders() {
        return dify.get("/workspaces/current/tool-providers");
    }

    @GetMapping("/datasets")
    public Object datasets() {
        return dify.get("/datasets?page=1&limit=100");
    }

    // ---- runs -------------------------------------------------------------

    @GetMapping("/apps/{appId}/logs")
    public Object runLogs(@PathVariable String appId) {
        return dify.get("/apps/" + appId + "/workflow-runs?page=1&limit=50");
    }

    @GetMapping("/runs/{runId}")
    public Object getRun(@PathVariable String runId) {
        return dify.get("/workflow-runs/" + runId);
    }

    @PostMapping("/runs/{taskId}/stop")
    public Object stopRun(@PathVariable String taskId) {
        return dify.post("/workflow-tasks/" + taskId + "/stop", null);
    }

    /**
     * Relays Dify's SSE run stream straight through.
     *
     * <p>{@code InputStreamResource} rather than a buffered body on purpose: a
     * run emits tokens progressively and the designer's console is useless if
     * the whole run is buffered and delivered at the end.
     */
    @PostMapping(value = "/apps/{appId}/draft-run",
            produces = MediaType.TEXT_EVENT_STREAM_VALUE)
    public ResponseEntity<InputStreamResource> draftRun(@PathVariable String appId,
                                                        @RequestBody Map<String, Object> body,
                                                        @AuthenticationPrincipal Jwt jwt) {
        requireProvider(jwt);
        return stream("/apps/" + appId + "/workflows/draft/run", body);
    }

    /**
     * PROVIDER-only like everything else here, and that is a fix rather than a
     * convention: without the check, any authenticated user who knew an app id
     * could run any app in the shared workspace, because the call is made with
     * the workspace token and carries no tenant scope of its own. Customers run
     * a workflow that was rolled out to them, through
     * {@code POST /api/workflows/{id}/run}, which is tenant-scoped.
     */
    @PostMapping(value = "/apps/{appId}/run",
            produces = MediaType.TEXT_EVENT_STREAM_VALUE)
    public ResponseEntity<InputStreamResource> run(@PathVariable String appId,
                                                   @RequestBody Map<String, Object> body,
                                                   @AuthenticationPrincipal Jwt jwt) {
        requireProvider(jwt);
        return stream("/apps/" + appId + "/workflows/run", body);
    }

    // ---- runnable catalog (Service API) ---------------------------------

    /**
     * The workflows this platform holds a Service API key for — what the
     * provider can actually publish and roll out.
     *
     * <p>Separate from {@code GET /apps}, which lists everything in the Dify
     * workspace including half-built drafts. A workflow is only runnable once
     * it is published AND its {@code app-…} key has been configured here, so
     * this is the list that reflects reality.
     */
    @GetMapping("/catalog")
    public List<DifyWorkflowService.CatalogEntry> catalog(@AuthenticationPrincipal Jwt jwt) {
        requireProvider(jwt);
        return difyWorkflows.catalog();
    }

    private ResponseEntity<InputStreamResource> stream(String path, Map<String, Object> body) {
        Map<String, Object> payload = Map.of(
                "inputs", body.getOrDefault("inputs", Map.of()),
                "response_mode", "streaming");
        return ResponseEntity.ok()
                .contentType(MediaType.TEXT_EVENT_STREAM)
                .body(new InputStreamResource(dify.stream(path, payload)));
    }

    private static void requireProvider(Jwt jwt) {
        if (!"PROVIDER".equals(jwt.getClaimAsString("role"))) {
            throw CoreException.forbidden("provider_authored_only",
                    "Workflows are designed by your provider and rolled out to your workspace.");
        }
    }
}
