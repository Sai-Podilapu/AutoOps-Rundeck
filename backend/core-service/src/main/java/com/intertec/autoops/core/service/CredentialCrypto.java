package com.intertec.autoops.core.service;

import com.intertec.autoops.core.config.CoreProperties;
import com.intertec.autoops.core.exception.CoreException;
import org.springframework.stereotype.Component;

import javax.crypto.Cipher;
import javax.crypto.Mac;
import javax.crypto.spec.GCMParameterSpec;
import javax.crypto.spec.SecretKeySpec;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.security.SecureRandom;
import java.util.Base64;

/**
 * AES-256-GCM for cloud credentials at rest. The key is derived (SHA-256)
 * from CLOUD_CRED_KEY; ProdSafetyGuard refuses prod with the dev default.
 * Ciphertext layout: base64(iv[12] || ct+tag).
 *
 * <p>Also mints the keyed fingerprints that back cloud-account exclusivity —
 * see {@link #fingerprint}.
 */
@Component
public class CredentialCrypto {

    private static final int IV_BYTES = 12;
    private static final int TAG_BITS = 128;
    private static final String HMAC = "HmacSHA256";

    private final SecretKeySpec key;
    /** Separate derivation: one secret, but never the same key for two algorithms. */
    private final SecretKeySpec fingerprintKey;
    private final SecureRandom random = new SecureRandom();

    public CredentialCrypto(CoreProperties properties) {
        try {
            String secret = properties.getCloud().getCredentialKey();
            this.key = new SecretKeySpec(sha256(secret), "AES");
            this.fingerprintKey = new SecretKeySpec(sha256("fingerprint:" + secret), HMAC);
        } catch (Exception ex) {
            throw new IllegalStateException("Cannot initialize credential crypto", ex);
        }
    }

    private static byte[] sha256(String value) throws Exception {
        return MessageDigest.getInstance("SHA-256").digest(value.getBytes(StandardCharsets.UTF_8));
    }

    /**
     * A stable, non-reversible handle for an identifying value — the same
     * input always yields the same 64-char hex digest, and the digest reveals
     * nothing without CLOUD_CRED_KEY.
     *
     * <p>KEYED on purpose: cloud identifiers have tiny search spaces (a
     * 12-digit AWS account number is 10^12 guesses, minutes of GPU time), so a
     * plain hash of one is effectively the account number itself. HMAC makes
     * the claims table useless to anyone who only has the database.
     */
    public String fingerprint(String... parts) {
        try {
            Mac mac = Mac.getInstance(HMAC);
            mac.init(fingerprintKey);
            byte[] digest = mac.doFinal(String.join("|", parts)
                    .getBytes(StandardCharsets.UTF_8));
            StringBuilder hex = new StringBuilder(digest.length * 2);
            for (byte b : digest) {
                hex.append(Character.forDigit((b >> 4) & 0xf, 16))
                        .append(Character.forDigit(b & 0xf, 16));
            }
            return hex.toString();
        } catch (Exception ex) {
            throw new IllegalStateException("Cannot fingerprint credential identity", ex);
        }
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
            throw CoreException.badRequest("credential_encrypt_failed",
                    "Could not protect the credentials");
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
            // Wrong key (rotated without re-encrypting) or corrupt row.
            throw CoreException.serviceUnavailable("credential_decrypt_failed",
                    "Stored credentials cannot be decrypted — re-enter them");
        }
    }
}
