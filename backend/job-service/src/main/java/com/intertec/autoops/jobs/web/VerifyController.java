package com.intertec.autoops.jobs.web;

import com.fasterxml.jackson.databind.JsonNode;
import com.intertec.autoops.jobs.verify.CredentialVerificationService;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RestController;

/**
 * Internal credential-verification API for core-service (guarded by
 * InternalTokenFilter like /internal/execute). Read-only against the cloud
 * provider — a "who am I" call, never a mutation.
 */
@RestController
public class VerifyController {

    private final CredentialVerificationService verificationService;

    public VerifyController(CredentialVerificationService verificationService) {
        this.verificationService = verificationService;
    }

    public record VerifyRequest(String tenantId, String platform, JsonNode data) {
    }

    /**
     * accountId/accountName are the provider's own identity for the account;
     * details is an ordered map of provider-reported facts for display.
     */
    public record VerifyResponse(boolean supported, boolean verified, String message,
                                 String accountId, String accountName,
                                 java.util.Map<String, String> details) {
    }

    @PostMapping("/internal/verify")
    public VerifyResponse verify(@RequestBody VerifyRequest request) {
        CredentialVerificationService.Verification verification =
                verificationService.verify(request.tenantId(), request.platform(),
                        request.data());
        return new VerifyResponse(verification.supported(), verification.verified(),
                verification.message(), verification.accountId(), verification.accountName(),
                verification.details());
    }
}
