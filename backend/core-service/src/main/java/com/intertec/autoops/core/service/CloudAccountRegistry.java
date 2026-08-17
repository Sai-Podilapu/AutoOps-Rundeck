package com.intertec.autoops.core.service;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.intertec.autoops.core.domain.CloudAccountClaim;
import com.intertec.autoops.core.domain.CloudConnection;
import com.intertec.autoops.core.domain.CloudPlatform;
import com.intertec.autoops.core.domain.ConnectionStatus;
import com.intertec.autoops.core.domain.CoreAuditEventType;
import com.intertec.autoops.core.exception.CoreException;
import com.intertec.autoops.core.repo.CloudAccountClaimRepository;
import com.intertec.autoops.core.repo.CloudConnectionRepository;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.beans.factory.ObjectProvider;
import org.springframework.boot.context.event.ApplicationReadyEvent;
import org.springframework.context.event.EventListener;
import org.springframework.dao.DataIntegrityViolationException;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Propagation;
import org.springframework.transaction.annotation.Transactional;

import java.time.Instant;
import java.util.Comparator;
import java.util.HashSet;
import java.util.List;
import java.util.Optional;
import java.util.Set;

/**
 * Holds every cloud account to exactly ONE tenant.
 *
 * <p>The threat this closes: cloud credentials leak — pasted into a ticket,
 * committed to a repo, lifted from a laptop — and the finder signs up for
 * AutoOps, connects them, and now has a scheduler, a shell-command runtime and
 * a terraform executor aimed at somebody else's infrastructure, wearing their
 * own tenant's clothes. Registering the account to its first tenant means the
 * second one is turned away at the door, and — once a provider check proves it
 * — the credentials it typed are destroyed rather than kept.
 *
 * <p>Two rules, checked together (see {@link CloudAccountIdentity}):
 * <ul>
 *   <li>the CREDENTIAL itself may only exist under one tenant — caught at the
 *       moment it is submitted, with no provider round-trip;</li>
 *   <li>the ACCOUNT it points at may only be claimed by one tenant — caught
 *       when the provider confirms the identity, so a fresh key pair for an
 *       already-claimed account does not get through.</li>
 * </ul>
 *
 * <p>Ownership is per tenant, not per connection: one tenant may hold the same
 * account across several connections (one AWS account, one connection per
 * project, different IAM users). Claims are released as soon as the tenant's
 * last connection holding them goes away, so an account can be legitimately
 * handed over.
 */
@Service
public class CloudAccountRegistry {

    private static final Logger log = LoggerFactory.getLogger(CloudAccountRegistry.class);

    /**
     * Deliberately says nothing about WHO holds the account. Confirming "your
     * competitor uses this AWS account" to anyone holding a stolen key would be
     * its own disclosure.
     */
    private static final String TAKEN_MESSAGE =
            "This cloud account is already linked to another AutoOps tenant. A cloud "
                    + "account can only be connected to one tenant — if it should belong "
                    + "here, disconnect it from the other tenant first or contact support.";

    private static final String QUARANTINE_MESSAGE =
            "The provider confirmed these credentials belong to a cloud account that is "
                    + "already linked to another AutoOps tenant. They have been removed "
                    + "from this integration.";

    private final CloudAccountClaimRepository claimRepository;
    private final CloudConnectionRepository connectionRepository;
    private final CredentialCrypto crypto;
    private final ObjectMapper objectMapper;
    /** Nullable: slice tests have no AuditService, same pattern as MeterRegistry. */
    private final AuditService auditService;

    public CloudAccountRegistry(CloudAccountClaimRepository claimRepository,
                                CloudConnectionRepository connectionRepository,
                                CredentialCrypto crypto,
                                ObjectMapper objectMapper,
                                ObjectProvider<AuditService> auditService) {
        this.claimRepository = claimRepository;
        this.connectionRepository = connectionRepository;
        this.crypto = crypto;
        this.objectMapper = objectMapper;
        this.auditService = auditService.getIfAvailable();
    }

    // ------ enforcement ------

    /**
     * Refuses if anything these credentials identify is held by another
     * tenant. Read-only, so it can guard a request BEFORE any state — or any
     * provider round-trip with a possibly-stolen secret — happens.
     */
    @Transactional(readOnly = true)
    public void requireAvailable(String tenantId, CloudPlatform platform, JsonNode credentials,
                                 String verifiedAccountId) {
        for (CloudAccountIdentity.Claim claim :
                CloudAccountIdentity.of(platform, credentials, verifiedAccountId)) {
            owner(platform, claim).ifPresent(existing -> {
                if (!existing.getTenantId().equals(tenantId)) {
                    log.warn("Tenant {} was refused {} {} — already claimed by another tenant",
                            tenantId, platform, claim.kind());
                    throw taken();
                }
            });
        }
    }

    /**
     * Registers every identity these credentials expose to this tenant, then
     * drops whatever the tenant no longer holds (a re-keyed connection releases
     * the old credential's claim). Idempotent.
     */
    @Transactional
    public void claim(String tenantId, Long connectionId, CloudPlatform platform,
                      JsonNode credentials, String verifiedAccountId) {
        for (CloudAccountIdentity.Claim claim :
                CloudAccountIdentity.of(platform, credentials, verifiedAccountId)) {
            Optional<CloudAccountClaim> existing = owner(platform, claim);
            if (existing.isPresent()) {
                if (!existing.get().getTenantId().equals(tenantId)) {
                    log.warn("Tenant {} was refused {} {} on connection {} — already claimed",
                            tenantId, platform, claim.kind(), connectionId);
                    throw taken();
                }
                continue;
            }
            try {
                claimRepository.saveAndFlush(new CloudAccountClaim(platform, claim.kind(),
                        fingerprint(platform, claim), tenantId, connectionId));
            } catch (DataIntegrityViolationException ex) {
                // Two tenants raced for the same account; the unique index
                // decided it, and this one lost.
                log.warn("Tenant {} lost the race for {} {} on connection {}",
                        tenantId, platform, claim.kind(), connectionId);
                throw taken();
            }
        }
        releaseOrphansIn(tenantId);
    }

    /** Drops the claims this tenant no longer holds through any live connection. */
    @Transactional
    public void releaseOrphans(String tenantId) {
        releaseOrphansIn(tenantId);
    }

    /**
     * Strips a connection whose credentials turned out to point at somebody
     * else's account: the secret is deleted and the integration is left
     * disconnected, saying why.
     *
     * <p>REQUIRES_NEW because the caller aborts the request right afterwards —
     * the refusal must not roll back the containment it triggered.
     */
    @Transactional(propagation = Propagation.REQUIRES_NEW)
    public void quarantine(String tenantId, Long connectionId, String actor) {
        connectionRepository.findByIdAndTenantId(connectionId, tenantId).ifPresent(connection -> {
            connection.setStatus(ConnectionStatus.DISCONNECTED);
            connection.setCredentialsEnc(null);
            connection.setLastVerifiedAt(Instant.now());
            connection.setLastVerifiedOk(false);
            connection.setLastVerifiedMessage(QUARANTINE_MESSAGE);
            connection.setVerifiedAccountId(null);
            connection.setVerifiedAccountName(null);
            connectionRepository.save(connection);
            log.warn("Quarantined connection {} for tenant {}: credentials belong to an "
                    + "account claimed by another tenant", connectionId, tenantId);
        });
        releaseOrphansIn(tenantId);
        if (auditService != null) {
            auditService.record(CoreAuditEventType.CONNECTION_QUARANTINED, tenantId, actor,
                    null, "CONNECTION", connectionId, null, QUARANTINE_MESSAGE);
        }
    }

    /**
     * Records a refused claim for the security trail. REQUIRES_NEW for the same
     * reason as {@link #quarantine} — the refusal rolls the request back.
     */
    @Transactional(propagation = Propagation.REQUIRES_NEW)
    public void recordRejection(String tenantId, String actor, CloudPlatform platform) {
        if (auditService != null) {
            auditService.record(CoreAuditEventType.CONNECTION_CLAIM_REJECTED, tenantId, actor,
                    null, "CONNECTION", null, platform == null ? null : platform.name(),
                    "Refused: the cloud account is already claimed by another tenant");
        }
    }

    /** 409, with a message that names no other tenant. */
    public static CoreException taken() {
        return CoreException.conflict("cloud_account_taken", TAKEN_MESSAGE);
    }

    // ------ reconciliation ------

    /**
     * Claims what already exists. Connections created before this rule shipped
     * hold nothing, and an unclaimed account is an account a second tenant can
     * still take — which would invert the protection, locking the rightful
     * owner out on their next verification. Oldest connection wins a contested
     * account; a contest is logged, never resolved silently by disconnecting
     * somebody.
     */
    @EventListener(ApplicationReadyEvent.class)
    public void reconcileAll() {
        List<CloudConnection> connections;
        try {
            connections = connectionRepository.findByStatus(ConnectionStatus.CONNECTED).stream()
                    .sorted(Comparator.comparing(CloudConnection::getCreatedAt,
                            Comparator.nullsLast(Comparator.naturalOrder())))
                    .toList();
        } catch (Exception ex) {
            log.error("Cloud account reconciliation could not read connections: {}",
                    ex.getMessage());
            return;
        }
        int claimed = 0;
        int contested = 0;
        for (CloudConnection connection : connections) {
            try {
                claimed += reconcile(connection);
            } catch (CoreException ex) {
                contested++;
                log.error("Cloud account contested: connection {} (tenant {}, {}) points at an "
                                + "account already claimed by an older connection from another "
                                + "tenant — review manually ({})",
                        connection.getId(), connection.getTenantId(), connection.getPlatform(),
                        ex.getError());
            } catch (Exception ex) {
                log.warn("Could not reconcile cloud connection {}: {}", connection.getId(),
                        ex.getMessage());
            }
        }
        if (claimed > 0 || contested > 0) {
            log.info("Cloud account reconciliation: {} claim(s) registered, {} contested",
                    claimed, contested);
        }
    }

    /**
     * Claim-by-claim, each write its own transaction: reconciliation is
     * idempotent, so partial progress is progress, and one unreadable row
     * cannot roll back everything before it.
     */
    private int reconcile(CloudConnection connection) {
        int added = 0;
        for (CloudAccountIdentity.Claim claim : identitiesOf(connection)) {
            Optional<CloudAccountClaim> existing = owner(connection.getPlatform(), claim);
            if (existing.isPresent()) {
                if (!existing.get().getTenantId().equals(connection.getTenantId())) {
                    throw taken();
                }
                continue;
            }
            claimRepository.save(new CloudAccountClaim(connection.getPlatform(),
                    claim.kind(), fingerprint(connection.getPlatform(), claim),
                    connection.getTenantId(), connection.getId()));
            added++;
        }
        return added;
    }

    // ------ internals ------

    private Optional<CloudAccountClaim> owner(CloudPlatform platform,
                                              CloudAccountIdentity.Claim claim) {
        return claimRepository.findByPlatformAndKindAndFingerprint(platform, claim.kind(),
                fingerprint(platform, claim));
    }

    private String fingerprint(CloudPlatform platform, CloudAccountIdentity.Claim claim) {
        return crypto.fingerprint(platform.name(), claim.kind().name(), claim.value());
    }

    /**
     * Recomputes what the tenant genuinely holds right now and deletes the
     * rest. Recomputing beats a reference count: it cannot drift, and it
     * self-heals whatever an interrupted request left behind.
     */
    private void releaseOrphansIn(String tenantId) {
        List<CloudAccountClaim> owned = claimRepository.findByTenantId(tenantId);
        if (owned.isEmpty()) {
            return;
        }
        Set<String> held = new HashSet<>();
        for (CloudConnection connection : connectionRepository
                .findByTenantIdAndStatus(tenantId, ConnectionStatus.CONNECTED)) {
            Set<CloudAccountIdentity.Claim> claims;
            try {
                claims = identitiesOf(connection);
            } catch (Exception ex) {
                // Unreadable credentials must not silently release the account
                // they belong to — keep whatever this connection registered.
                log.warn("Cloud connection {} is unreadable; keeping its existing claims",
                        connection.getId());
                owned.stream()
                        .filter(claim -> connection.getId().equals(claim.getConnectionId()))
                        .forEach(claim -> held.add(key(claim)));
                continue;
            }
            for (CloudAccountIdentity.Claim claim : claims) {
                held.add(connection.getPlatform() + "|" + claim.kind() + "|"
                        + fingerprint(connection.getPlatform(), claim));
            }
        }
        List<CloudAccountClaim> stale = owned.stream()
                .filter(claim -> !held.contains(key(claim)))
                .toList();
        if (!stale.isEmpty()) {
            claimRepository.deleteAll(stale);
            log.info("Released {} cloud account claim(s) no longer held by tenant {}",
                    stale.size(), tenantId);
        }
    }

    private static String key(CloudAccountClaim claim) {
        return claim.getPlatform() + "|" + claim.getKind() + "|" + claim.getFingerprint();
    }

    /** Everything one stored connection identifies, credentials included. */
    private Set<CloudAccountIdentity.Claim> identitiesOf(CloudConnection connection) {
        JsonNode credentials = null;
        if (connection.getCredentialsEnc() != null) {
            try {
                credentials = objectMapper.readTree(
                        crypto.decrypt(connection.getCredentialsEnc()));
            } catch (Exception ex) {
                throw new IllegalStateException("unreadable credentials", ex);
            }
        }
        return CloudAccountIdentity.of(connection.getPlatform(), credentials,
                connection.getVerifiedAccountId());
    }
}