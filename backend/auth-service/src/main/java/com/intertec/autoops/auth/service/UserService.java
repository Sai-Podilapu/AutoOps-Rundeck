package com.intertec.autoops.auth.service;

import com.intertec.autoops.auth.domain.User;
import com.intertec.autoops.auth.domain.UserRole;
import com.intertec.autoops.auth.domain.UserStatus;
import com.intertec.autoops.auth.exception.AuthException;
import com.intertec.autoops.auth.repo.UserRepository;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.util.List;
import java.util.Locale;

/** User lifecycle: lookups, onboarding/offboarding, token-version bumps, SSO linking. */
@Service
public class UserService {

    private final UserRepository userRepository;

    public UserService(UserRepository userRepository) {
        this.userRepository = userRepository;
    }

    /**
     * Resolves the ACTIVE account for a login email. Self-registration creates
     * one tenant per sign-up, so the browser cannot know its tenant up front:
     * a single account with this email wins outright; with several (possible
     * via admin onboarding), {@code tenantHint} (X-Tenant-ID) disambiguates.
     */
    @Transactional(readOnly = true)
    public User requireActiveByEmail(String email, String tenantHint) {
        User user = requireByEmail(email, tenantHint);
        if (user.getStatus() != UserStatus.ACTIVE) {
            throw AuthException.forbidden("user_not_active", "Account is not active");
        }
        return user;
    }

    /** Like {@link #requireActiveByEmail} but status-agnostic (verification flows). */
    @Transactional(readOnly = true)
    public User requireByEmail(String email, String tenantHint) {
        List<User> candidates = userRepository.findByEmailOrderByIdAsc(normalize(email));
        if (candidates.isEmpty()) {
            throw AuthException.notFound("user_not_found", "No account found for this email");
        }
        if (candidates.size() == 1) {
            return candidates.get(0);
        }
        return candidates.stream()
                .filter(c -> c.getTenantId().equals(tenantHint))
                .findFirst()
                .orElseThrow(() -> AuthException.badRequest("tenant_ambiguous",
                        "This email exists in multiple workspaces; X-Tenant-ID is required"));
    }

    @Transactional(readOnly = true)
    public boolean emailExists(String email) {
        return userRepository.existsByEmail(normalize(email));
    }

    @Transactional(readOnly = true)
    public User requireById(Long userId) {
        return userRepository.findById(userId)
                .orElseThrow(() -> AuthException.notFound("user_not_found", "User does not exist"));
    }

    /** Self-service profile edit: display name only (email is identity). */
    @Transactional
    public User updateFullName(Long userId, String fullName) {
        if (fullName == null || fullName.isBlank() || fullName.length() > 255) {
            throw AuthException.badRequest("invalid_name", "Enter a display name");
        }
        User user = requireById(userId);
        user.setFullName(fullName.trim());
        return userRepository.save(user);
    }

    /** Invalidates every outstanding access token (`ver` claim check). */
    @Transactional
    public User bumpTokenVersion(Long userId) {
        User user = requireById(userId);
        user.setTokenVersion(user.getTokenVersion() + 1);
        return userRepository.save(user);
    }

    @Transactional(readOnly = true)
    public java.util.List<User> listByTenant(String tenantId) {
        return userRepository.findByTenantIdOrderByIdAsc(tenantId);
    }

    /** Admins who can still sign in — the last-admin guard counts these. */
    @Transactional(readOnly = true)
    public long countActiveAdmins(String tenantId) {
        return userRepository.countByTenantIdAndRoleAndStatusNot(tenantId, UserRole.ADMIN,
                UserStatus.DISABLED);
    }

    /** Social login resolves by email across tenants (like password login). */
    @Transactional(readOnly = true)
    public java.util.Optional<User> findFirstActiveByEmail(String email) {
        return userRepository.findByEmailOrderByIdAsc(normalize(email)).stream()
                .filter(user -> user.getStatus() == UserStatus.ACTIVE)
                .findFirst();
    }

    /**
     * Changes the member's role and bumps token_version — outstanding access
     * tokens carry the OLD role claim and must die immediately.
     */
    @Transactional
    public User changeRole(Long userId, UserRole role) {
        User user = requireById(userId);
        user.setRole(role);
        user.setTokenVersion(user.getTokenVersion() + 1);
        return userRepository.save(user);
    }

    @Transactional
    public User onboard(String email, String fullName, UserRole role, String tenantId) {
        String normalizedEmail = normalize(email);
        userRepository.findByEmailAndTenantId(normalizedEmail, tenantId).ifPresent(existing -> {
            throw AuthException.conflict("user_exists",
                    "A user with this email already exists in this tenant");
        });
        User user = new User();
        user.setEmail(normalizedEmail);
        user.setFullName(fullName);
        user.setRole(role);
        user.setStatus(UserStatus.ACTIVE);
        user.setTenantId(tenantId);
        user.setTokenVersion(0);
        return userRepository.save(user);
    }

    /**
     * Creates a PENDING account with a (pre-hashed) password. Used by
     * self-service registration; the account is activated (ACTIVE) only after
     * the emailed verification code is confirmed.
     */
    @Transactional
    public User createWithPassword(String email, String fullName, String passwordHash,
                                   UserRole role, String tenantId) {
        String normalizedEmail = normalize(email);
        userRepository.findByEmailAndTenantId(normalizedEmail, tenantId).ifPresent(existing -> {
            throw AuthException.conflict("user_exists",
                    "An account with this email already exists");
        });
        User user = new User();
        user.setEmail(normalizedEmail);
        user.setFullName(fullName);
        user.setRole(role);
        user.setStatus(UserStatus.PENDING);
        user.setTenantId(tenantId);
        user.setTokenVersion(0);
        user.setPasswordHash(passwordHash);
        return userRepository.save(user);
    }

    /** PENDING -> ACTIVE after email-ownership proof (registration verify). */
    @Transactional
    public User activate(Long userId) {
        User user = requireById(userId);
        user.setStatus(UserStatus.ACTIVE);
        return userRepository.save(user);
    }

    /**
     * Sets a new password hash and bumps token_version — every outstanding
     * access token dies immediately (reset/change must evict a hijacker).
     */
    @Transactional
    public User replacePassword(Long userId, String passwordHash) {
        User user = requireById(userId);
        user.setPasswordHash(passwordHash);
        user.setTokenVersion(user.getTokenVersion() + 1);
        return userRepository.save(user);
    }

    /** Disables the account and bumps the token version (kills live tokens). */
    @Transactional
    public User offboard(Long userId) {
        User user = requireById(userId);
        user.setStatus(UserStatus.DISABLED);
        user.setTokenVersion(user.getTokenVersion() + 1);
        return userRepository.save(user);
    }

    /**
     * Resolves the local account for a Keycloak identity: by keycloak_subject
     * first, else by email (linking the subject on first SSO login). SSO does
     * NOT auto-provision — users must be onboarded by an admin first.
     */
    @Transactional
    public User resolveSsoUser(String subject, String email, String fullName, String tenantId) {
        User bySubject = userRepository.findByKeycloakSubject(subject).orElse(null);
        if (bySubject != null) {
            return bySubject;
        }
        User byEmail = userRepository.findByEmailAndTenantId(normalize(email), tenantId)
                .orElseThrow(() -> AuthException.forbidden("user_not_provisioned",
                        "No AutoOps account is linked to this SSO identity"));
        byEmail.setKeycloakSubject(subject);
        if (byEmail.getFullName() == null && fullName != null) {
            byEmail.setFullName(fullName);
        }
        return userRepository.save(byEmail);
    }

    private String normalize(String email) {
        return email == null ? "" : email.trim().toLowerCase(Locale.ROOT);
    }
}
