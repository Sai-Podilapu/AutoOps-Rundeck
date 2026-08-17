package com.intertec.autoops.core.repo;

import com.intertec.autoops.core.domain.CloudAccountClaim;
import com.intertec.autoops.core.domain.CloudAccountClaimKind;
import com.intertec.autoops.core.domain.CloudPlatform;
import org.springframework.data.jpa.repository.JpaRepository;

import java.util.List;
import java.util.Optional;

public interface CloudAccountClaimRepository extends JpaRepository<CloudAccountClaim, Long> {

    /**
     * The owner of one cloud account. Deliberately NOT tenant-scoped — the
     * whole point is to see a claim held by somebody else.
     */
    Optional<CloudAccountClaim> findByPlatformAndKindAndFingerprint(
            CloudPlatform platform, CloudAccountClaimKind kind, String fingerprint);

    /** Everything one tenant holds — the basis for releasing what it no longer does. */
    List<CloudAccountClaim> findByTenantId(String tenantId);
}