package com.intertec.autoops.plugin.service;

import com.fasterxml.jackson.core.type.TypeReference;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.intertec.autoops.plugin.config.PluginProperties;
import com.intertec.autoops.plugin.domain.DeliveryAttempt;
import com.intertec.autoops.plugin.domain.LifecycleEvent;
import com.intertec.autoops.plugin.domain.PluginInstallation;
import com.intertec.autoops.plugin.exception.PluginException;
import com.intertec.autoops.plugin.repo.DeliveryAttemptRepository;
import com.intertec.autoops.plugin.repo.NotificationRuleRepository;
import com.intertec.autoops.plugin.repo.PluginInstallationRepository;
import com.intertec.autoops.plugin.spi.DeliveryResult;
import com.intertec.autoops.plugin.spi.NotificationPlugin;
import com.intertec.autoops.plugin.spi.PluginContext;
import com.intertec.autoops.plugin.spi.PluginDescriptor;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.time.Instant;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

/**
 * Installing, editing, testing and removing a tenant's notification channels.
 *
 * <p>Every method takes {@code tenantId} as its first argument and every load
 * pairs it with the id. That is the whole isolation story in this service —
 * there is no filter to forget to enable, but equally nothing stops a future
 * method from calling {@code findById}, so the repository javadoc says not to.
 */
@Service
public class InstallationService {

    private static final Logger log = LoggerFactory.getLogger(InstallationService.class);

    /** A tenant with hundreds of channels is a runaway script, not a use case. */
    private static final int MAX_INSTALLATIONS_PER_TENANT = 50;

    private final PluginInstallationRepository installations;
    private final NotificationRuleRepository rules;
    private final DeliveryAttemptRepository attempts;
    private final PluginRegistry registry;
    private final CredentialCrypto crypto;
    private final ObjectMapper objectMapper;
    private final PluginProperties properties;

    public InstallationService(PluginInstallationRepository installations,
                               NotificationRuleRepository rules,
                               DeliveryAttemptRepository attempts,
                               PluginRegistry registry,
                               CredentialCrypto crypto,
                               ObjectMapper objectMapper,
                               PluginProperties properties) {
        this.installations = installations;
        this.rules = rules;
        this.attempts = attempts;
        this.registry = registry;
        this.crypto = crypto;
        this.objectMapper = objectMapper;
        this.properties = properties;
    }

    @Transactional(readOnly = true)
    public List<PluginInstallation> list(String tenantId) {
        return installations.findByTenantIdOrderByDisplayNameAsc(tenantId);
    }

    @Transactional(readOnly = true)
    public PluginInstallation get(String tenantId, Long id) {
        return installations.findByIdAndTenantId(id, tenantId)
                .orElseThrow(() -> PluginException.notFound("installation_not_found",
                        "No such integration"));
    }

    @Transactional
    public PluginInstallation install(String tenantId, String createdBy, String pluginKey,
                                      String displayName, Map<String, String> config) {
        PluginDescriptor descriptor = registry.descriptor(pluginKey);
        String name = requireName(displayName);
        if (installations.existsByTenantIdAndDisplayName(tenantId, name)) {
            throw PluginException.conflict("installation_exists",
                    "An integration named \"" + name + "\" already exists");
        }
        if (installations.countByTenantId(tenantId) >= MAX_INSTALLATIONS_PER_TENANT) {
            throw PluginException.badRequest("too_many_installations",
                    "A workspace can have at most " + MAX_INSTALLATIONS_PER_TENANT
                            + " integrations");
        }
        Map<String, String> cleaned = clean(config);
        descriptor.validate(cleaned);

        PluginInstallation installation = new PluginInstallation();
        installation.setTenantId(tenantId);
        installation.setPluginKey(pluginKey);
        installation.setDisplayName(name);
        installation.setConfigEnc(encrypt(cleaned));
        installation.setCreatedBy(createdBy);
        return installations.save(installation);
    }

    /**
     * Updates settings, keeping any secret the caller did not resend.
     *
     * <p>This is required, not a convenience: the API never returns secret
     * values, so an edit form cannot round-trip them. Without the merge, saving
     * a changed display name would wipe the webhook URL.
     */
    @Transactional
    public PluginInstallation update(String tenantId, Long id, String displayName,
                                     Map<String, String> config) {
        PluginInstallation installation = get(tenantId, id);
        PluginDescriptor descriptor = registry.descriptor(installation.getPluginKey());

        if (displayName != null) {
            String name = requireName(displayName);
            if (installations.existsByTenantIdAndDisplayNameAndIdNot(tenantId, name, id)) {
                throw PluginException.conflict("installation_exists",
                        "An integration named \"" + name + "\" already exists");
            }
            installation.setDisplayName(name);
        }

        if (config != null) {
            Map<String, String> merged = new LinkedHashMap<>(clean(config));
            Map<String, String> existing = decrypt(installation);
            for (String secretField : descriptor.secretFieldNames()) {
                if (!merged.containsKey(secretField) && existing.containsKey(secretField)) {
                    merged.put(secretField, existing.get(secretField));
                }
            }
            descriptor.validate(merged);
            installation.setConfigEnc(encrypt(merged));
            // Settings changed, so the previous test result no longer describes
            // this configuration. Saying "last test: OK" about a credential
            // that has since been replaced would be a lie.
            installation.setLastTestOk(null);
            installation.setLastTestAt(null);
            installation.setLastTestDetail(null);
            installation.recordSuccess(); // clears failures and un-parks
        }
        return installations.save(installation);
    }

    @Transactional
    public PluginInstallation setEnabled(String tenantId, Long id, boolean enabled) {
        PluginInstallation installation = get(tenantId, id);
        installation.setEnabled(enabled);
        if (enabled) {
            // Re-enabling is an explicit statement that the tenant believes it
            // works again; leaving it PARKED would make the toggle do nothing.
            installation.recordSuccess();
        }
        return installations.save(installation);
    }

    @Transactional
    public void delete(String tenantId, Long id) {
        PluginInstallation installation = get(tenantId, id);
        // Rules cascade in the schema; deleting them here too keeps the JPA
        // first-level cache honest for anything later in this transaction.
        rules.deleteByTenantIdAndInstallationId(tenantId, id);
        installations.delete(installation);
        log.info("Removed integration {} ({}) for tenant {}",
                installation.getDisplayName(), installation.getPluginKey(), tenantId);
    }

    /**
     * Runs the plugin's real connection test and records the outcome.
     *
     * <p>Every plugin makes an actual call to the third party here. The email
     * plugins authenticate without sending; the chat webhooks genuinely post,
     * because a webhook cannot be probed any other way, and their test message
     * says plainly that no job ran.
     */
    @Transactional
    public DeliveryResult test(String tenantId, Long id) {
        PluginInstallation installation = get(tenantId, id);
        NotificationPlugin plugin = registry.require(installation.getPluginKey());
        DeliveryResult result;
        try {
            result = plugin.verify(context(installation));
        } catch (PluginException ex) {
            result = DeliveryResult.failure(ex.getMessage());
        } catch (Exception ex) {
            // The SPI forbids throwing, but a bug in one plugin must not
            // become a 500 that hides which channel is broken.
            log.warn("Plugin {} threw during verify for tenant {}",
                    installation.getPluginKey(), tenantId, ex);
            result = DeliveryResult.failure(ex.getClass().getSimpleName()
                    + ": " + ex.getMessage());
        }

        installation.setLastTestOk(result.ok());
        installation.setLastTestAt(Instant.now());
        installation.setLastTestDetail(result.detailForStorage());
        if (result.ok()) {
            // A passing test is the one thing that un-parks a channel.
            installation.recordSuccess();
        }
        installations.save(installation);

        DeliveryAttempt attempt = new DeliveryAttempt();
        attempt.setTenantId(tenantId);
        attempt.setInstallationId(installation.getId());
        attempt.setPluginKey(installation.getPluginKey());
        attempt.setEvent(LifecycleEvent.QUEUED); // placeholder; ruleId null marks it a test
        attempt.setOk(result.ok());
        attempt.setStatusCode(result.statusCode());
        attempt.setDetail(result.detailForStorage());
        attempts.save(attempt);
        return result;
    }

    /** Decrypts one installation into the context a plugin receives. */
    public PluginContext context(PluginInstallation installation) {
        return new PluginContext(installation.getTenantId(), installation.getId(),
                installation.getDisplayName(), Map.copyOf(decrypt(installation)));
    }

    /**
     * Which fields are set, WITHOUT their values — so the console can show
     * "Webhook URL: configured" and prefill the non-secret fields on edit.
     */
    public Map<String, String> maskedConfig(PluginInstallation installation) {
        PluginDescriptor descriptor = registry.descriptor(installation.getPluginKey());
        Map<String, String> stored = decrypt(installation);
        Map<String, String> masked = new LinkedHashMap<>();
        for (var field : descriptor.fields()) {
            String value = stored.get(field.name());
            if (value == null || value.isBlank()) {
                continue;
            }
            masked.put(field.name(), field.isSecret() ? "••••••••" : value);
        }
        return masked;
    }

    private Map<String, String> decrypt(PluginInstallation installation) {
        try {
            return objectMapper.readValue(crypto.decrypt(installation.getConfigEnc()),
                    new TypeReference<LinkedHashMap<String, String>>() { });
        } catch (PluginException ex) {
            throw ex;
        } catch (Exception ex) {
            throw PluginException.serviceUnavailable("credential_decrypt_failed",
                    "Stored integration settings cannot be read — re-enter them");
        }
    }

    private String encrypt(Map<String, String> config) {
        try {
            return crypto.encrypt(objectMapper.writeValueAsString(config));
        } catch (Exception ex) {
            throw PluginException.badRequest("invalid_config",
                    "Could not store the integration settings");
        }
    }

    /** Drops blanks so an untouched optional field does not overwrite a value. */
    private Map<String, String> clean(Map<String, String> config) {
        Map<String, String> cleaned = new LinkedHashMap<>();
        if (config == null) {
            return cleaned;
        }
        config.forEach((key, value) -> {
            if (value != null && !value.isBlank()) {
                cleaned.put(key, value.trim());
            }
        });
        return cleaned;
    }

    private String requireName(String displayName) {
        String name = displayName == null ? "" : displayName.trim();
        if (name.isEmpty()) {
            throw PluginException.badRequest("invalid_name", "A name is required");
        }
        if (name.length() > 128) {
            throw PluginException.badRequest("invalid_name",
                    "Name must be 128 characters or fewer");
        }
        return name;
    }
}
