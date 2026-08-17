package com.intertec.autoops.core.service;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.intertec.autoops.core.domain.CloudConnection;
import com.intertec.autoops.core.domain.CloudPlatform;
import com.intertec.autoops.core.domain.ConnectionStatus;
import com.intertec.autoops.core.exception.CoreException;
import com.intertec.autoops.core.repo.CloudConnectionRepository;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.util.List;
import java.util.Optional;
import java.util.Set;

/**
 * Tenant-scoped cloud integrations. MAX_CLOUD_INTEGRATIONS gates connecting
 * (counted over CONNECTED rows — disconnecting frees a slot but keeps the
 * record). Credentials are AES-GCM-encrypted at rest and only decrypted to
 * hand to the execution runtime. Reads are never gated.
 *
 * <p>A cloud account belongs to ONE tenant: every path that accepts or proves
 * credentials runs them past {@link CloudAccountRegistry} first, so leaked
 * credentials cannot be replayed into a second tenant. See
 * {@code docs/cloud-account-exclusivity.md}.
 */
@Service
public class CloudConnectionService {

    private static final Logger log = LoggerFactory.getLogger(CloudConnectionService.class);

    private final CloudConnectionRepository connectionRepository;
    private final com.intertec.autoops.core.repo.ProjectRepository projectRepository;
    private final SubscriptionGate gate;
    private final CredentialCrypto crypto;
    private final ObjectMapper objectMapper;
    private final com.intertec.autoops.core.client.VerificationClient verificationClient;
    private final CloudAccountRegistry accountRegistry;

    public CloudConnectionService(CloudConnectionRepository connectionRepository,
                                  com.intertec.autoops.core.repo.ProjectRepository projectRepository,
                                  SubscriptionGate gate,
                                  CredentialCrypto crypto,
                                  ObjectMapper objectMapper,
                                  com.intertec.autoops.core.client.VerificationClient verificationClient,
                                  CloudAccountRegistry accountRegistry) {
        this.connectionRepository = connectionRepository;
        this.projectRepository = projectRepository;
        this.gate = gate;
        this.crypto = crypto;
        this.objectMapper = objectMapper;
        this.verificationClient = verificationClient;
        this.accountRegistry = accountRegistry;
    }

    @Transactional(readOnly = true)
    public List<CloudConnection> list(String tenantId) {
        return connectionRepository.findByTenantIdOrderByCreatedAtDesc(tenantId);
    }

    @Transactional
    public CloudConnection connect(String tenantId, String actor, String accessToken,
                                   String platformCode, String name, String credentialsJson) {
        return connect(tenantId, actor, accessToken, platformCode, name, credentialsJson, null);
    }

    @Transactional
    public CloudConnection connect(String tenantId, String actor, String accessToken,
                                   String platformCode, String name, String credentialsJson,
                                   Long projectId) {
        CloudPlatform platform = CloudPlatform.fromCode(platformCode);
        if (platform == null) {
            throw CoreException.badRequest("unknown_platform",
                    "Unknown cloud platform: " + platformCode);
        }
        // uq_cloud_tenant_name covers (tenant_id, name) whatever the status, so
        // a name a DISCONNECTED integration still holds cannot just be inserted
        // again — that combination used to reach the database and come back as
        // a 500. Reusing the row IS the "reconnect" the disconnected paths tell
        // the user to perform: same id, so audit history, project assignment
        // and any step bound to the name keep pointing at the same integration.
        CloudConnection existing = connectionRepository
                .findFirstByTenantIdAndName(tenantId, name).orElse(null);
        if (existing != null && existing.getStatus() == ConnectionStatus.CONNECTED) {
            throw CoreException.conflict("connection_exists",
                    "A connection with this name already exists");
        }
        if (existing != null && existing.getPlatform() != platform) {
            // Reviving it would silently change what the name means to every
            // step already bound to it — refuse, and say how to get unstuck.
            throw CoreException.conflict("connection_name_taken",
                    "A disconnected " + existing.getPlatform().name() + " integration still holds "
                            + "this name — reconnect it as " + existing.getPlatform().name()
                            + ", or choose a different name");
        }
        JsonNode credentials = parsed(credentialsJson);
        // Before the quota call and before anything is stored: an account that
        // belongs to another tenant never gets this far.
        guarded(tenantId, actor, platform, () ->
                accountRegistry.requireAvailable(tenantId, platform, credentials, null));
        // A reconnect turns a DISCONNECTED row back into a live one, so it
        // consumes a slot exactly like a new integration; the count excludes it
        // either way.
        long connected = connectionRepository.countByTenantIdAndStatus(tenantId,
                ConnectionStatus.CONNECTED);
        gate.requireQuota(accessToken, "MAX_CLOUD_INTEGRATIONS", connected, "cloud integrations");

        CloudConnection connection = existing != null ? existing : new CloudConnection();
        connection.setTenantId(tenantId);
        connection.setPlatform(platform);
        connection.setName(name);
        connection.setProjectId(requireProjectOrNull(tenantId, projectId));
        if (existing == null) {
            connection.setCreatedBy(actor);
        }
        connection.setStatus(ConnectionStatus.CONNECTED);
        connection.setCredentialsEnc(credentials != null ? crypto.encrypt(credentialsJson) : null);
        // These credentials are NEW: no verification badge from the old ones may
        // survive the reconnect, or the UI would vouch for material that is gone.
        connection.setLastVerifiedAt(null);
        connection.setLastVerifiedOk(null);
        connection.setLastVerifiedMessage(null);
        connection.setVerifiedAccountId(null);
        connection.setVerifiedAccountName(null);
        CloudConnection saved = connectionRepository.save(connection);
        guarded(tenantId, actor, platform, () ->
                accountRegistry.claim(tenantId, saved.getId(), platform, credentials, null));
        log.info("Tenant {} {} {} ({}, credentials: {})", tenantId,
                existing != null ? "reconnected" : "connected", platform,
                saved.getId(), saved.getCredentialsEnc() != null);
        return saved;
    }

    /** Set or replace a connection's credentials (gated mutation). */
    @Transactional
    public CloudConnection setCredentials(String tenantId, String actor, String accessToken,
                                          Long id, String credentialsJson) {
        gate.requireActive(accessToken);
        CloudConnection connection = require(tenantId, id);
        if (credentialsJson == null || credentialsJson.isBlank()) {
            throw CoreException.badRequest("missing_credentials", "Credentials are required");
        }
        JsonNode credentials = parsed(credentialsJson);
        // Re-keying is a fresh submission: the new material has to be free too,
        // otherwise this would be the way around the check at connect time.
        guarded(tenantId, actor, connection.getPlatform(), () ->
                accountRegistry.requireAvailable(tenantId, connection.getPlatform(), credentials,
                        connection.getVerifiedAccountId()));
        connection.setCredentialsEnc(crypto.encrypt(credentialsJson));
        CloudConnection saved = connectionRepository.save(connection);
        // Claiming also releases what the replaced credentials used to hold.
        guarded(tenantId, actor, connection.getPlatform(), () ->
                accountRegistry.claim(tenantId, saved.getId(), connection.getPlatform(),
                        credentials, connection.getVerifiedAccountId()));
        log.info("Tenant {} updated credentials for cloud connection {}", tenantId, id);
        return saved;
    }

    /**
     * Runs a claim check, recording the refusal for the security trail before
     * it propagates — the request itself is rolled back, so the audit write
     * inside the registry is the only thing that survives it.
     */
    private void guarded(String tenantId, String actor, CloudPlatform platform, Runnable check) {
        try {
            check.run();
        } catch (CoreException ex) {
            if ("cloud_account_taken".equals(ex.getError())) {
                accountRegistry.recordRejection(tenantId, actor, platform);
            }
            throw ex;
        }
    }

    /**
     * The connection's non-secret identity (account + region) for display.
     * Never throws: an unreadable credential blob degrades to "unknown"
     * rather than breaking the whole Integrations page.
     */
    public CloudAccountDescriptor.AccountInfo describe(CloudConnection connection) {
        JsonNode credentials = null;
        if (connection.getCredentialsEnc() != null) {
            try {
                credentials = objectMapper.readTree(crypto.decrypt(connection.getCredentialsEnc()));
            } catch (Exception ex) {
                log.warn("Cloud connection {} has unreadable credentials: {}",
                        connection.getId(), ex.getMessage());
            }
        }
        return CloudAccountDescriptor.describe(connection.getPlatform(), credentials,
                connection.getVerifiedAccountId(), connection.getVerifiedAccountName(),
                connection.getLastVerifiedMessage());
    }

    /**
     * Assigns the connection to one project (scoping it to that project's
     * pages) or back to global with a null projectId. Gated like the other
     * connection mutations.
     */
    @Transactional
    public CloudConnection assignProject(String tenantId, String accessToken, Long id,
                                         Long projectId) {
        gate.requireActive(accessToken);
        CloudConnection connection = require(tenantId, id);
        connection.setProjectId(requireProjectOrNull(tenantId, projectId));
        CloudConnection saved = connectionRepository.save(connection);
        log.info("Tenant {} assigned cloud connection {} to project {}", tenantId, id,
                projectId == null ? "GLOBAL" : projectId);
        return saved;
    }

    /** A non-null assignment must point at one of the tenant's own projects. */
    private Long requireProjectOrNull(String tenantId, Long projectId) {
        if (projectId == null) {
            return null;
        }
        projectRepository.findByIdAndTenantId(projectId, tenantId)
                .orElseThrow(() -> CoreException.notFound("project_not_found",
                        "No such project"));
        return projectId;
    }

    /**
     * Live verification outcome. checkedAt is null for a preflight check,
     * which is not persisted anywhere.
     */
    public record VerificationOutcome(boolean supported, boolean verified, String message,
                                      String accountId, String accountName,
                                      java.util.Map<String, String> details,
                                      java.time.Instant checkedAt) {
    }

    /**
     * Checks credentials against the provider WITHOUT storing anything —
     * the preflight behind "verify before you add". Nothing is written, so a
     * user who abandons the dialog leaves no trace behind.
     */
    public VerificationOutcome verifyCredentials(String tenantId, String actor,
                                                 String accessToken, String platformCode,
                                                 String credentialsJson) {
        gate.requireActive(accessToken);
        CloudPlatform platform = CloudPlatform.fromCode(platformCode);
        if (platform == null) {
            throw CoreException.badRequest("unknown_platform",
                    "Unknown cloud platform: " + platformCode);
        }
        if (credentialsJson == null || credentialsJson.isBlank()) {
            throw CoreException.badRequest("missing_credentials", "Credentials are required");
        }
        JsonNode data = parsed(credentialsJson);
        // Checked BEFORE the provider call: credentials that are already spoken
        // for are not worth a round-trip, and a stolen key should not be
        // exercised on the victim's account just to tell the thief "taken".
        guarded(tenantId, actor, platform, () ->
                accountRegistry.requireAvailable(tenantId, platform, data, null));
        var result = verificationClient.verify(tenantId, platform.name(), data);
        // Now the provider has named the account — check that too, so the user
        // learns it here rather than after creating a connection.
        guarded(tenantId, actor, platform, () ->
                accountRegistry.requireAvailable(tenantId, platform, data, result.accountId()));
        log.info("Tenant {} preflight-verified {} credentials -> {}", tenantId, platform,
                !result.supported() ? "unsupported" : result.verified() ? "ok" : "failed");
        return new VerificationOutcome(result.supported(), result.verified(), result.message(),
                result.accountId(), result.accountName(), result.details(), null);
    }

    /**
     * Verifies the stored credentials against the REAL provider (via
     * job-service): AWS STS, Microsoft Entra ID, Google OAuth, or the
     * cluster's /version. Read-only on the provider side. The outcome is
     * persisted so the UI shows a durable, honest status. Gated like a
     * mutation — verification exercises tenant secrets.
     */
    @Transactional
    public VerificationOutcome verify(String tenantId, String actor, String accessToken, Long id) {
        gate.requireActive(accessToken);
        CloudConnection connection = require(tenantId, id);
        if (connection.getStatus() != ConnectionStatus.CONNECTED) {
            throw CoreException.badRequest("connection_disconnected",
                    "This integration is disconnected — reconnect it first");
        }
        CredentialBundle bundle = toBundle(connection); // throws missing_credentials when none
        var result = verificationClient.verify(tenantId, bundle.platform().name(),
                bundle.data());
        // The provider has now named the account these credentials reach. If it
        // belongs to someone else, this is no longer a suspicion: destroy the
        // credentials rather than keep a working key to a stranger's account.
        // Nothing has been written yet, so the refusal below rolls back cleanly
        // and only the (REQUIRES_NEW) quarantine survives.
        if (result.accountId() != null) {
            try {
                accountRegistry.requireAvailable(tenantId, connection.getPlatform(),
                        bundle.data(), result.accountId());
            } catch (CoreException ex) {
                if (!"cloud_account_taken".equals(ex.getError())) {
                    throw ex;
                }
                accountRegistry.quarantine(tenantId, id, actor);
                throw ex;
            }
        }
        java.time.Instant checkedAt = java.time.Instant.now();
        connection.setLastVerifiedAt(checkedAt);
        // Unsupported platforms stay "never verified" rather than turning red.
        connection.setLastVerifiedOk(result.supported() ? result.verified() : null);
        connection.setLastVerifiedMessage(truncate(result.message(), 512));
        // Keep the last known identity when a re-check fails — a wrong key
        // today does not unlearn which account this connection points at.
        if (result.accountId() != null) {
            connection.setVerifiedAccountId(truncate(result.accountId(), 128));
        }
        if (result.accountName() != null) {
            connection.setVerifiedAccountName(truncate(result.accountName(), 256));
        }
        connectionRepository.save(connection);
        // The account is only knowable once the provider says so — register it
        // now, so a second tenant arriving later with a different key pair for
        // the same account is turned away.
        guarded(tenantId, actor, connection.getPlatform(), () ->
                accountRegistry.claim(tenantId, id, connection.getPlatform(), bundle.data(),
                        connection.getVerifiedAccountId()));
        log.info("Tenant {} verified cloud connection {} ({}) -> {}", tenantId, id,
                connection.getPlatform(), !result.supported() ? "unsupported"
                        : result.verified() ? "ok" : "failed");
        return new VerificationOutcome(result.supported(), result.verified(), result.message(),
                connection.getVerifiedAccountId(), connection.getVerifiedAccountName(),
                result.details(), checkedAt);
    }

    private static String truncate(String s, int max) {
        return s == null || s.length() <= max ? s : s.substring(0, max);
    }

    /** Disconnecting frees a MAX_CLOUD_INTEGRATIONS slot; the record survives. */
    @Transactional
    public void disconnect(String tenantId, String accessToken, Long id) {
        gate.requireActive(accessToken);
        CloudConnection connection = require(tenantId, id);
        connection.setStatus(ConnectionStatus.DISCONNECTED);
        // A disconnected integration must not keep executable secrets around,
        // nor a stale "verified" badge for credentials that no longer exist.
        connection.setCredentialsEnc(null);
        connection.setLastVerifiedAt(null);
        connection.setLastVerifiedOk(null);
        connection.setLastVerifiedMessage(null);
        connection.setVerifiedAccountId(null);
        connection.setVerifiedAccountName(null);
        connectionRepository.save(connection);
        // Hand the account back: nothing this tenant still holds points at it,
        // so somebody else may now legitimately connect it.
        accountRegistry.releaseOrphans(tenantId);
        log.info("Tenant {} disconnected cloud connection {}", tenantId, id);
    }

    // ------ execution-time resolution (terraform / kubernetes steps) ------

    /** Decrypted credential bundle handed to the execution runtime. */
    public record CredentialBundle(CloudPlatform platform, String name, JsonNode data) {
    }

    /**
     * Resolves the credentials a step should run with: by the step's
     * {@code connection} name when given, otherwise the single CONNECTED
     * connection (with credentials) among the allowed platforms that is
     * VISIBLE TO THIS PROJECT. Ambiguity is an error — never guess between
     * two cloud accounts.
     *
     * <p>Project scoping is enforced here because this is the only path from
     * a run to a decrypted secret: a connection dedicated to project X is
     * unreachable from project Y even if the step names it outright, and a
     * run with no project context (ad-hoc commands) sees global ones only.
     */
    @Transactional(readOnly = true)
    public Optional<CredentialBundle> resolveForStep(String tenantId, Long projectId,
                                                     String connectionName,
                                                     Set<CloudPlatform> allowedPlatforms) {
        if (connectionName != null && !connectionName.isBlank()) {
            CloudConnection connection = connectionRepository
                    .findFirstByTenantIdAndNameAndStatus(tenantId, connectionName.trim(),
                            ConnectionStatus.CONNECTED)
                    .orElseThrow(() -> CoreException.notFound("connection_not_found",
                            "No connected cloud integration named '" + connectionName + "'"));
            if (!visibleTo(connection, projectId)) {
                // Named explicitly but out of reach: say so plainly rather
                // than pretending it does not exist.
                throw CoreException.badRequest("connection_not_in_project",
                        "Cloud integration '" + connection.getName() + "' is dedicated to "
                                + "another project — assign it to this project, or make it "
                                + "global, under Cloud Integrations");
            }
            return Optional.of(toBundle(connection));
        }
        List<CloudConnection> candidates = connectionRepository
                .findByTenantIdAndStatusAndPlatformIn(tenantId, ConnectionStatus.CONNECTED,
                        allowedPlatforms)
                .stream()
                .filter(c -> c.getCredentialsEnc() != null)
                .filter(c -> visibleTo(c, projectId))
                .toList();
        if (candidates.isEmpty()) {
            return Optional.empty();
        }
        if (candidates.size() > 1) {
            throw CoreException.badRequest("ambiguous_connection",
                    "Multiple cloud integrations match — set \"connection\" on the step to "
                            + "one of: " + candidates.stream().map(CloudConnection::getName)
                            .reduce((a, b) -> a + ", " + b).orElse(""));
        }
        return Optional.of(toBundle(candidates.get(0)));
    }

    /** Global connections serve every project; scoped ones serve only theirs. */
    private static boolean visibleTo(CloudConnection connection, Long projectId) {
        return connection.getProjectId() == null
                || connection.getProjectId().equals(projectId);
    }

    private CredentialBundle toBundle(CloudConnection connection) {
        if (connection.getCredentialsEnc() == null) {
            throw CoreException.badRequest("missing_credentials",
                    "Integration '" + connection.getName() + "' has no credentials — "
                            + "configure them in Cloud Integrations");
        }
        try {
            JsonNode data = objectMapper.readTree(crypto.decrypt(connection.getCredentialsEnc()));
            return new CredentialBundle(connection.getPlatform(), connection.getName(), data);
        } catch (CoreException ex) {
            throw ex;
        } catch (Exception ex) {
            throw CoreException.serviceUnavailable("credential_decrypt_failed",
                    "Stored credentials are unreadable — re-enter them");
        }
    }

    private CloudConnection require(String tenantId, Long id) {
        return connectionRepository.findByIdAndTenantId(id, tenantId)
                .orElseThrow(() -> CoreException.notFound("connection_not_found",
                        "No such cloud connection"));
    }

    /**
     * Credentials must be a JSON object (field map). Null for "none given" —
     * a connection may exist as a record without executable secrets.
     */
    private JsonNode parsed(String credentialsJson) {
        if (credentialsJson == null || credentialsJson.isBlank()) {
            return null;
        }
        JsonNode node;
        try {
            node = objectMapper.readTree(credentialsJson);
        } catch (Exception ex) {
            throw CoreException.badRequest("invalid_credentials",
                    "Credentials are not valid JSON");
        }
        if (!node.isObject()) {
            throw CoreException.badRequest("invalid_credentials",
                    "Credentials must be a JSON object");
        }
        return node;
    }
}
