package com.intertec.autoops.plugin.web;

import com.intertec.autoops.plugin.domain.PluginInstallation;
import com.intertec.autoops.plugin.exception.PluginException;
import com.intertec.autoops.plugin.repo.DeliveryAttemptRepository;
import com.intertec.autoops.plugin.repo.NotificationRuleRepository;
import com.intertec.autoops.plugin.service.InstallationService;
import com.intertec.autoops.plugin.service.PluginRegistry;
import com.intertec.autoops.plugin.spi.DeliveryResult;
import com.intertec.autoops.plugin.web.dto.DeliveryAttemptResponse;
import com.intertec.autoops.plugin.web.dto.InstallationRequest;
import com.intertec.autoops.plugin.web.dto.InstallationResponse;
import com.intertec.autoops.plugin.web.dto.TestResponse;
import jakarta.validation.Valid;
import org.springframework.data.domain.PageRequest;
import org.springframework.http.HttpStatus;
import org.springframework.security.core.annotation.AuthenticationPrincipal;
import org.springframework.security.oauth2.jwt.Jwt;
import org.springframework.web.bind.annotation.DeleteMapping;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.PutMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.ResponseStatus;
import org.springframework.web.bind.annotation.RestController;

import java.util.List;
import java.util.Map;

/**
 * A tenant's installed notification channels.
 *
 * <p>Every handler derives the tenant from the token's {@code tenantId} claim
 * and passes it into the service, which pairs it with the row id on load. No
 * path or body value ever selects a tenant.
 */
@RestController
public class InstallationController {

    /** Enough delivery history to diagnose a channel without paging the UI. */
    private static final int DELIVERY_PAGE_SIZE = 100;

    private final InstallationService installationService;
    private final PluginRegistry registry;
    private final NotificationRuleRepository rules;
    private final DeliveryAttemptRepository attempts;

    public InstallationController(InstallationService installationService,
                                  PluginRegistry registry,
                                  NotificationRuleRepository rules,
                                  DeliveryAttemptRepository attempts) {
        this.installationService = installationService;
        this.registry = registry;
        this.rules = rules;
        this.attempts = attempts;
    }

    @GetMapping("/api/plugins/installations")
    public List<InstallationResponse> list(@AuthenticationPrincipal Jwt jwt) {
        String tenantId = tenant(jwt);
        return installationService.list(tenantId).stream().map(this::toResponse).toList();
    }

    @GetMapping("/api/plugins/installations/{id}")
    public InstallationResponse get(@PathVariable Long id, @AuthenticationPrincipal Jwt jwt) {
        return toResponse(installationService.get(tenant(jwt), id));
    }

    @PostMapping("/api/plugins/installations")
    @ResponseStatus(HttpStatus.CREATED)
    public InstallationResponse install(@Valid @RequestBody InstallationRequest request,
                                        @AuthenticationPrincipal Jwt jwt) {
        PluginInstallation installation = installationService.install(
                tenant(jwt), jwt.getSubject(), request.pluginKey(),
                request.displayName(), request.config());
        return toResponse(installation);
    }

    /**
     * Secrets the caller omits keep their stored values — the API never returns
     * them, so an edit form has nothing to resubmit.
     */
    @PutMapping("/api/plugins/installations/{id}")
    public InstallationResponse update(@PathVariable Long id,
                                       @RequestBody InstallationRequest request,
                                       @AuthenticationPrincipal Jwt jwt) {
        return toResponse(installationService.update(tenant(jwt), id,
                request.displayName(), request.config()));
    }

    @PostMapping("/api/plugins/installations/{id}/enable")
    public InstallationResponse enable(@PathVariable Long id, @AuthenticationPrincipal Jwt jwt) {
        return toResponse(installationService.setEnabled(tenant(jwt), id, true));
    }

    @PostMapping("/api/plugins/installations/{id}/disable")
    public InstallationResponse disable(@PathVariable Long id, @AuthenticationPrincipal Jwt jwt) {
        return toResponse(installationService.setEnabled(tenant(jwt), id, false));
    }

    /**
     * Real connection test against the third party.
     *
     * <p>Answers 200 whether or not it worked: "it failed, and here is why" is
     * a successful answer to the question asked. A 4xx would make the console
     * render it as a broken request instead of a diagnosis.
     */
    @PostMapping("/api/plugins/installations/{id}/test")
    public TestResponse test(@PathVariable Long id, @AuthenticationPrincipal Jwt jwt) {
        DeliveryResult result = installationService.test(tenant(jwt), id);
        return TestResponse.from(result);
    }

    /** Delivery history for one channel — what was sent, and what came back. */
    @GetMapping("/api/plugins/installations/{id}/deliveries")
    public List<DeliveryAttemptResponse> deliveries(@PathVariable Long id,
                                                    @AuthenticationPrincipal Jwt jwt) {
        String tenantId = tenant(jwt);
        installationService.get(tenantId, id); // 404s before any log is read
        return attempts.findByTenantIdAndInstallationIdOrderByAttemptedAtDesc(
                        tenantId, id, PageRequest.of(0, DELIVERY_PAGE_SIZE))
                .stream().map(DeliveryAttemptResponse::from).toList();
    }

    /** Delivery history across every channel in the workspace. */
    @GetMapping("/api/plugins/deliveries")
    public List<DeliveryAttemptResponse> allDeliveries(
            @RequestParam(defaultValue = "100") int limit,
            @AuthenticationPrincipal Jwt jwt) {
        int capped = Math.max(1, Math.min(limit, DELIVERY_PAGE_SIZE * 5));
        return attempts.findByTenantIdOrderByAttemptedAtDesc(tenant(jwt),
                        PageRequest.of(0, capped))
                .stream().map(DeliveryAttemptResponse::from).toList();
    }

    @DeleteMapping("/api/plugins/installations/{id}")
    @ResponseStatus(HttpStatus.NO_CONTENT)
    public void delete(@PathVariable Long id, @AuthenticationPrincipal Jwt jwt) {
        installationService.delete(tenant(jwt), id);
    }

    private InstallationResponse toResponse(PluginInstallation installation) {
        // A row whose plugin was dropped from the build must still be listable,
        // so the tenant can see it and delete it. Both the display name and the
        // masked config need that fallback — maskedConfig reads the descriptor.
        boolean known = registry.exists(installation.getPluginKey());
        String pluginName = known
                ? registry.descriptor(installation.getPluginKey()).displayName()
                : installation.getPluginKey();
        long ruleCount = rules.findByTenantIdAndInstallationId(
                installation.getTenantId(), installation.getId()).size();
        return InstallationResponse.from(installation, pluginName,
                known ? installationService.maskedConfig(installation) : Map.of(), ruleCount);
    }

    private String tenant(Jwt jwt) {
        String tenantId = jwt.getClaimAsString("tenantId");
        if (tenantId == null || tenantId.isBlank()) {
            throw PluginException.badRequest("missing_tenant", "Token has no tenantId claim");
        }
        return tenantId;
    }
}
