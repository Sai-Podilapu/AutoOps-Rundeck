package com.intertec.autoops.auth.repo;

import com.intertec.autoops.auth.domain.User;
import com.intertec.autoops.auth.domain.UserRole;
import com.intertec.autoops.auth.domain.UserStatus;
import org.springframework.data.jpa.repository.JpaRepository;

import java.util.List;
import java.util.Optional;

public interface UserRepository extends JpaRepository<User, Long> {

    Optional<User> findByEmailAndTenantId(String email, String tenantId);

    /** Same email may exist in several tenants (admin-onboarded); ordered for determinism. */
    List<User> findByEmailOrderByIdAsc(String email);

    boolean existsByEmail(String email);

    Optional<User> findByKeycloakSubject(String keycloakSubject);

    /** Team roster for the members page (all statuses; the UI labels them). */
    List<User> findByTenantIdOrderByIdAsc(String tenantId);

    /**
     * Admin headcount used by the last-admin guard. DISABLED accounts are
     * excluded — an offboarded admin cannot sign in to undo anything.
     */
    long countByTenantIdAndRoleAndStatusNot(String tenantId, UserRole role, UserStatus status);
}
