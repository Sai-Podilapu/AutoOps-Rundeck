package com.intertec.autoops.core.service;

import com.intertec.autoops.core.domain.Secret;
import com.intertec.autoops.core.exception.CoreException;
import com.intertec.autoops.core.repo.SecretRepository;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.util.List;
import java.util.Locale;
import java.util.regex.Pattern;

/**
 * Tenant secret vault. Values are AES-GCM encrypted with the platform
 * credential key and are WRITE-ONLY — no read path exists, by design.
 * Mutations pass the subscription gate; listing metadata never does.
 */
@Service
public class SecretService {

    private static final Logger log = LoggerFactory.getLogger(SecretService.class);
    private static final Pattern PATH = Pattern.compile("^[a-zA-Z0-9._/-]{1,255}$");

    private final SecretRepository secretRepository;
    private final SubscriptionGate gate;
    private final CredentialCrypto crypto;

    public SecretService(SecretRepository secretRepository, SubscriptionGate gate,
                         CredentialCrypto crypto) {
        this.secretRepository = secretRepository;
        this.gate = gate;
        this.crypto = crypto;
    }

    @Transactional(readOnly = true)
    public List<Secret> list(String tenantId) {
        return secretRepository.findByTenantIdOrderByPathAsc(tenantId);
    }

    @Transactional
    public Secret create(String tenantId, String actor, String accessToken,
                         String path, String type, String value) {
        gate.requireActive(accessToken);
        validatePath(path);
        if (value == null || value.isBlank()) {
            throw CoreException.badRequest("missing_value", "A secret needs a value");
        }
        if (secretRepository.existsByTenantIdAndPath(tenantId, path)) {
            throw CoreException.conflict("secret_exists",
                    "A secret already exists at this path");
        }
        Secret secret = new Secret();
        secret.setTenantId(tenantId);
        secret.setPath(path);
        secret.setType(parseType(type));
        secret.setValueEnc(crypto.encrypt(value));
        secret.setCreatedBy(actor);
        Secret saved = secretRepository.save(secret);
        log.info("Tenant {} created secret {} ({})", tenantId, saved.getId(), path);
        return saved;
    }

    /** Path/type edits and value rotation; null value = keep the stored one. */
    @Transactional
    public Secret update(String tenantId, String accessToken, Long id,
                         String path, String type, String value) {
        gate.requireActive(accessToken);
        Secret secret = require(tenantId, id);
        if (path != null && !path.isBlank() && !path.equals(secret.getPath())) {
            validatePath(path);
            if (secretRepository.existsByTenantIdAndPath(tenantId, path)) {
                throw CoreException.conflict("secret_exists",
                        "A secret already exists at this path");
            }
            secret.setPath(path);
        }
        if (type != null && !type.isBlank()) {
            secret.setType(parseType(type));
        }
        if (value != null && !value.isBlank()) {
            secret.setValueEnc(crypto.encrypt(value));
        }
        return secretRepository.save(secret);
    }

    @Transactional
    public void delete(String tenantId, String accessToken, Long id) {
        gate.requireActive(accessToken);
        secretRepository.delete(require(tenantId, id));
    }

    private Secret require(String tenantId, Long id) {
        return secretRepository.findByIdAndTenantId(id, tenantId)
                .orElseThrow(() -> CoreException.notFound("secret_not_found", "No such secret"));
    }

    private static void validatePath(String path) {
        if (path == null || !PATH.matcher(path).matches()) {
            throw CoreException.badRequest("invalid_path",
                    "Secret paths use letters, digits, dots, dashes and slashes "
                            + "— e.g. apps/production/api-key");
        }
    }

    private static Secret.Type parseType(String type) {
        try {
            return Secret.Type.valueOf(type.trim().toUpperCase(Locale.ROOT));
        } catch (Exception ex) {
            throw CoreException.badRequest("unknown_secret_type",
                    "Unknown secret type: " + type + " — use opaque, tls, or ssh");
        }
    }
}
