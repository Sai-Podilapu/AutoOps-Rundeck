package com.intertec.autoops.auth.web;

import com.intertec.autoops.auth.domain.Tenant;
import com.intertec.autoops.auth.domain.User;
import com.intertec.autoops.auth.domain.UserRole;
import com.intertec.autoops.auth.domain.UserStatus;
import com.intertec.autoops.auth.exception.AuthException;
import com.intertec.autoops.auth.repo.TenantRepository;
import com.intertec.autoops.auth.service.UserService;
import org.springframework.security.core.annotation.AuthenticationPrincipal;
import org.springframework.security.oauth2.jwt.Jwt;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;

import java.time.Instant;
import java.util.ArrayList;
import java.util.List;

/**
 * Platform-operator tenant directory (PROVIDER role): every workspace with
 * its admin contact and member counts. Merged client-side with
 * subscription-service's /api/provider/tenants for the full picture.
 */
@RestController
@RequestMapping("/api/auth/provider")
public class ProviderDirectoryController {

    private final TenantRepository tenantRepository;
    private final UserService userService;

    public ProviderDirectoryController(TenantRepository tenantRepository,
                                       UserService userService) {
        this.tenantRepository = tenantRepository;
        this.userService = userService;
    }

    public record TenantDirectoryEntry(String tenantId, String name, String emailDomain,
                                       String adminEmail, long members, long activeMembers,
                                       Instant createdAt) {
    }

    @GetMapping("/tenants")
    public List<TenantDirectoryEntry> tenants(@AuthenticationPrincipal Jwt jwt) {
        if (!"PROVIDER".equals(jwt.getClaimAsString("role"))) {
            throw AuthException.forbidden("provider_only",
                    "This endpoint is for platform operators");
        }
        List<TenantDirectoryEntry> out = new ArrayList<>();
        for (Tenant tenant : tenantRepository.findAll()) {
            List<User> members = userService.listByTenant(tenant.getTenantId());
            String adminEmail = members.stream()
                    .filter(u -> u.getRole() == UserRole.ADMIN)
                    .map(User::getEmail).findFirst().orElse(null);
            long active = members.stream()
                    .filter(u -> u.getStatus() == UserStatus.ACTIVE).count();
            out.add(new TenantDirectoryEntry(tenant.getTenantId(), tenant.getDisplayName(),
                    tenant.getEmailDomain(), adminEmail, members.size(), active,
                    tenant.getCreatedAt()));
        }
        return out;
    }
}
