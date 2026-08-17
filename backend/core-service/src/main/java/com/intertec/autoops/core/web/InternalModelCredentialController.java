package com.intertec.autoops.core.web;

import com.intertec.autoops.core.service.ModelProviderService;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;

import java.util.Map;

/**
 * The one place a decrypted model credential leaves this service.
 *
 * <p>It has a file of its own so that it is easy to find and easy to audit.
 * agent-service can talk to eleven vendors and holds no encryption key;
 * core-service holds the key and cannot talk to any of them. That split is
 * the reason this endpoint exists, and keeping it to a single small class
 * keeps the crossing visible.
 *
 * <p>Protections, all of which matter:
 * <ul>
 *   <li>{@code /internal} — behind {@code InternalTokenFilter}, and the
 *       gateway does not route the prefix, so no browser can reach it;</li>
 *   <li>tenant-scoped by an explicit parameter, like every internal read;</li>
 *   <li>resolved per MODEL rather than "give me provider 7's key", so a caller
 *       cannot enumerate a workspace's credentials;</li>
 *   <li>nothing is logged but the vendor and the model — never a value.</li>
 * </ul>
 */
@RestController
public class InternalModelCredentialController {

    private static final Logger log = LoggerFactory.getLogger(InternalModelCredentialController.class);

    private final ModelProviderService modelProviderService;

    public InternalModelCredentialController(ModelProviderService modelProviderService) {
        this.modelProviderService = modelProviderService;
    }

    @GetMapping("/internal/model-credentials")
    public Map<String, Object> credentials(@RequestParam String tenantId,
                                           @RequestParam String model) {
        ModelProviderService.ResolvedCredentials resolved =
                modelProviderService.resolveForModel(tenantId, model);

        log.info("Tenant {} resolved model {} to {} connection #{}", tenantId, model,
                resolved.kind(), resolved.providerId());

        return Map.of(
                "kind", resolved.kind().name(),
                "providerId", resolved.providerId(),
                "providerName", resolved.providerName(),
                "model", resolved.model(),
                "values", resolved.values());
    }
}
