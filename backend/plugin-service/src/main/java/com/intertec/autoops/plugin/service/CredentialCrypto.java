package com.intertec.autoops.plugin.service;

import com.intertec.autoops.plugin.config.PluginProperties;
import com.intertec.autoops.plugin.exception.PluginException;
import org.springframework.stereotype.Component;

import javax.crypto.Cipher;
import javax.crypto.spec.GCMParameterSpec;
import javax.crypto.spec.SecretKeySpec;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.security.SecureRandom;
import java.util.Base64;

/**
 * AES-256-GCM for plugin credentials at rest — webhook URLs, API tokens and
 * SMTP passwords. Same construction as core-service's {@code CredentialCrypto}
 * (key = SHA-256 of the secret, layout {@code base64(iv[12] || ct+tag)}) but
 * keyed from PLUGIN_CRED_KEY, so compromising one service's key does not open
 * the other's vault.
 *
 * <p>Known limitation, inherited from the core-service original: there is no
 * key id stored beside the ciphertext, so rotating the key makes existing rows
 * undecryptable and the tenant has to re-enter the credential. Adding a
 * version prefix here would need a matching migration and re-encrypt pass.
 */
@Component
public class CredentialCrypto {

    private static final int IV_BYTES = 12;
    private static final int TAG_BITS = 128;

    private final SecretKeySpec key;
    private final SecureRandom random = new SecureRandom();

    public CredentialCrypto(PluginProperties properties) {
        try {
            this.key = new SecretKeySpec(sha256(properties.getCredentialKey()), "AES");
        } catch (Exception ex) {
            throw new IllegalStateException("Cannot initialize plugin credential crypto", ex);
        }
    }

    private static byte[] sha256(String value) throws Exception {
        return MessageDigest.getInstance("SHA-256").digest(value.getBytes(StandardCharsets.UTF_8));
    }

    public String encrypt(String plaintext) {
        try {
            byte[] iv = new byte[IV_BYTES];
            random.nextBytes(iv);
            Cipher cipher = Cipher.getInstance("AES/GCM/NoPadding");
            cipher.init(Cipher.ENCRYPT_MODE, key, new GCMParameterSpec(TAG_BITS, iv));
            byte[] ciphertext = cipher.doFinal(plaintext.getBytes(StandardCharsets.UTF_8));
            byte[] combined = new byte[iv.length + ciphertext.length];
            System.arraycopy(iv, 0, combined, 0, iv.length);
            System.arraycopy(ciphertext, 0, combined, iv.length, ciphertext.length);
            return Base64.getEncoder().encodeToString(combined);
        } catch (Exception ex) {
            throw PluginException.badRequest("credential_encrypt_failed",
                    "Could not protect the integration settings");
        }
    }

    public String decrypt(String encoded) {
        try {
            byte[] combined = Base64.getDecoder().decode(encoded);
            Cipher cipher = Cipher.getInstance("AES/GCM/NoPadding");
            cipher.init(Cipher.DECRYPT_MODE, key,
                    new GCMParameterSpec(TAG_BITS, combined, 0, IV_BYTES));
            byte[] plaintext = cipher.doFinal(combined, IV_BYTES, combined.length - IV_BYTES);
            return new String(plaintext, StandardCharsets.UTF_8);
        } catch (Exception ex) {
            // Wrong key (rotated without re-encrypting) or a corrupt row.
            throw PluginException.serviceUnavailable("credential_decrypt_failed",
                    "Stored integration settings cannot be decrypted — re-enter them");
        }
    }
}
