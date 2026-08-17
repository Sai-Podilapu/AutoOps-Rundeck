package com.intertec.autoops.plugin.service;

import com.intertec.autoops.plugin.config.PluginProperties;
import com.intertec.autoops.plugin.exception.PluginException;
import org.junit.jupiter.api.Test;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

class CredentialCryptoTest {

    private static CredentialCrypto crypto(String key) {
        PluginProperties properties = new PluginProperties();
        properties.setCredentialKey(key);
        return new CredentialCrypto(properties);
    }

    @Test
    void roundTripsAConfigBlob() {
        CredentialCrypto crypto = crypto("a-test-key");
        String plaintext = "{\"webhookUrl\":\"https://hooks.slack.com/services/T/B/x\"}";

        assertThat(crypto.decrypt(crypto.encrypt(plaintext))).isEqualTo(plaintext);
    }

    @Test
    void ciphertextDoesNotContainThePlaintext() {
        CredentialCrypto crypto = crypto("a-test-key");

        assertThat(crypto.encrypt("hooks.slack.com/services/T/B/secret"))
                .doesNotContain("hooks.slack.com");
    }

    /** GCM uses a fresh IV per call, so the same input never encrypts alike. */
    @Test
    void encryptingTwiceProducesDifferentCiphertext() {
        CredentialCrypto crypto = crypto("a-test-key");

        assertThat(crypto.encrypt("same")).isNotEqualTo(crypto.encrypt("same"));
    }

    /** A rotated key must fail loudly, not hand back garbage. */
    @Test
    void anotherKeyCannotDecrypt() {
        String ciphertext = crypto("key-one").encrypt("secret");

        assertThatThrownBy(() -> crypto("key-two").decrypt(ciphertext))
                .isInstanceOf(PluginException.class)
                .hasMessageContaining("cannot be decrypted");
    }

    /** GCM authenticates: a flipped byte is detected rather than ignored. */
    @Test
    void tamperedCiphertextIsRejected() {
        CredentialCrypto crypto = crypto("a-test-key");
        String ciphertext = crypto.encrypt("secret");
        char[] chars = ciphertext.toCharArray();
        chars[chars.length - 2] = chars[chars.length - 2] == 'A' ? 'B' : 'A';

        assertThatThrownBy(() -> crypto.decrypt(new String(chars)))
                .isInstanceOf(PluginException.class);
    }
}
