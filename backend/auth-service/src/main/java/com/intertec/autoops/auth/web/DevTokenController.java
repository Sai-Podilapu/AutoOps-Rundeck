package com.intertec.autoops.auth.web;

import com.intertec.autoops.auth.facade.AuthFacade;
import com.intertec.autoops.auth.security.IpResolver;
import com.intertec.autoops.auth.security.TenantContext;
import com.intertec.autoops.auth.web.dto.OtpGenerateRequest;
import com.intertec.autoops.auth.web.dto.TokenResponse;
import jakarta.servlet.http.HttpServletRequest;
import jakarta.validation.Valid;
import org.springframework.context.annotation.Profile;
import org.springframework.http.HttpHeaders;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;

/**
 * Debug-only token minting for local development — skips OTP delivery.
 * Active ONLY with the dev profile; never deployed to prod.
 */
@RestController
@RequestMapping("/api/auth/dev")
@Profile("dev")
public class DevTokenController {

    private final AuthFacade authFacade;
    private final IpResolver ipResolver;

    public DevTokenController(AuthFacade authFacade, IpResolver ipResolver) {
        this.authFacade = authFacade;
        this.ipResolver = ipResolver;
    }

    @PostMapping("/token")
    public TokenResponse mintToken(@Valid @RequestBody OtpGenerateRequest request,
                                   HttpServletRequest httpRequest) {
        return authFacade.devIssueTokens(request.email(), TenantContext.get(),
                ipResolver.resolve(httpRequest), httpRequest.getHeader(HttpHeaders.USER_AGENT));
    }
}
