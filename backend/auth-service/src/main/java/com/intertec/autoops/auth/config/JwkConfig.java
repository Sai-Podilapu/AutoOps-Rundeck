package com.intertec.autoops.auth.config;

import com.nimbusds.jose.jwk.JWKSet;
import com.nimbusds.jose.jwk.RSAKey;
import com.nimbusds.jose.jwk.source.ImmutableJWKSet;
import com.nimbusds.jose.jwk.source.JWKSource;
import com.nimbusds.jose.proc.SecurityContext;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.context.annotation.Primary;
import org.springframework.security.oauth2.jwt.JwtDecoder;
import org.springframework.security.oauth2.jwt.JwtEncoder;
import org.springframework.security.oauth2.jwt.NimbusJwtEncoder;
import org.springframework.security.oauth2.server.authorization.config.annotation.web.configuration.OAuth2AuthorizationServerConfiguration;

import java.io.InputStream;
import java.nio.file.Files;
import java.nio.file.Path;
import java.security.KeyPair;
import java.security.KeyPairGenerator;
import java.security.KeyStore;
import java.security.cert.Certificate;
import java.security.interfaces.RSAPrivateKey;
import java.security.interfaces.RSAPublicKey;
import java.util.ArrayList;
import java.util.Enumeration;
import java.util.List;
import java.util.UUID;

/**
 * RSA signing keys for RS256 tokens.
 *
 * <p>The private key is held ONLY by auth-service. Downstream services
 * (gateway, subscription-service) validate tokens locally using the public
 * JWKS endpoint {@code /oauth2/jwks} (kid-aware, cacheable).
 *
 * <p><strong>Key rotation:</strong> EVERY certificate alias in the keystore is
 * published in the JWKS (public halves), but only {@code keystore-alias} signs.
 * To rotate: add the new key pair to the keystore under a new alias, point
 * {@code JWT_KEYSTORE_ALIAS} at it, and keep the old alias in the keystore
 * until the last token it signed has expired (access TTL, 15 min) — then
 * remove it. No downstream coordination needed: consumers pick keys by kid.
 *
 * <p>Prod loads a PKCS#12 keystore from {@code JWT_KEYSTORE_PATH}; dev
 * auto-generates an ephemeral RSA-2048 pair.
 */
@Configuration
public class JwkConfig {

    private static final Logger log = LoggerFactory.getLogger(JwkConfig.class);

    private final AuthProperties properties;

    public JwkConfig(AuthProperties properties) {
        this.properties = properties;
    }

    /** The kid JwtService must put in the JWS header (JWKS may hold several keys). */
    public record SigningKey(String kid) {
    }

    @Bean
    public SigningKey signingKey(JWKSource<SecurityContext> jwkSource) {
        // The signing key is the one whose private half is present.
        try {
            JWKSet set = ((ImmutableJWKSet<SecurityContext>) jwkSource).getJWKSet();
            return set.getKeys().stream()
                    .filter(k -> k instanceof RSAKey rsa && rsa.isPrivate())
                    .findFirst()
                    .map(k -> new SigningKey(k.getKeyID()))
                    .orElseThrow(() -> new IllegalStateException("No private signing key in JWKS"));
        } catch (ClassCastException ex) {
            throw new IllegalStateException("Unexpected JWKSource implementation", ex);
        }
    }

    @Bean
    public JWKSource<SecurityContext> jwkSource() {
        List<RSAKey> keys = properties.getKeystorePath() == null || properties.getKeystorePath().isBlank()
                ? List.of(generateEphemeralKey())
                : loadAllFromKeystore();
        return new ImmutableJWKSet<>(new JWKSet(List.copyOf(keys)));
    }

    private RSAKey generateEphemeralKey() {
        try {
            KeyPairGenerator generator = KeyPairGenerator.getInstance("RSA");
            generator.initialize(2048);
            KeyPair pair = generator.generateKeyPair();
            String kid = UUID.randomUUID().toString();
            log.warn("No JWT keystore configured — generated an EPHEMERAL RSA-2048 key pair (kid={}). "
                    + "All tokens are invalidated on restart. Never use this in prod.", kid);
            return new RSAKey.Builder((RSAPublicKey) pair.getPublic())
                    .privateKey((RSAPrivateKey) pair.getPrivate())
                    .keyID(kid)
                    .build();
        } catch (Exception ex) {
            throw new IllegalStateException("Unable to generate RSA key pair", ex);
        }
    }

    /**
     * Loads EVERY RSA certificate alias: the configured signing alias keeps its
     * private key; all others are published public-only (rotation overlap).
     */
    private List<RSAKey> loadAllFromKeystore() {
        try (InputStream in = Files.newInputStream(Path.of(properties.getKeystorePath()))) {
            KeyStore keyStore = KeyStore.getInstance("PKCS12");
            char[] password = properties.getKeystorePassword().toCharArray();
            keyStore.load(in, password);
            String signingAlias = properties.getKeystoreAlias();
            if (keyStore.getCertificate(signingAlias) == null) {
                throw new IllegalStateException("Keystore has no alias '" + signingAlias + "'");
            }

            List<RSAKey> keys = new ArrayList<>();
            Enumeration<String> aliases = keyStore.aliases();
            while (aliases.hasMoreElements()) {
                String alias = aliases.nextElement();
                Certificate certificate = keyStore.getCertificate(alias);
                if (certificate == null
                        || !(certificate.getPublicKey() instanceof RSAPublicKey publicKey)) {
                    continue;
                }
                // kid derived from the certificate so it is stable across restarts.
                String kid = UUID.nameUUIDFromBytes(certificate.getEncoded()).toString();
                RSAKey.Builder builder = new RSAKey.Builder(publicKey).keyID(kid);
                if (alias.equals(signingAlias)) {
                    builder.privateKey((RSAPrivateKey) keyStore.getKey(alias, password));
                    // Signing key first: deterministic pick in signingKey().
                    keys.add(0, builder.build());
                    log.info("Loaded SIGNING key '{}' from keystore (kid={})", alias, kid);
                } else {
                    keys.add(builder.build());
                    log.info("Published retired/rotation key '{}' in JWKS (kid={})", alias, kid);
                }
            }
            return keys;
        } catch (IllegalStateException ex) {
            throw ex;
        } catch (Exception ex) {
            throw new IllegalStateException("Unable to load RSA signing keys from keystore "
                    + properties.getKeystorePath(), ex);
        }
    }

    @Bean
    public JwtEncoder jwtEncoder(JWKSource<SecurityContext> jwkSource) {
        return new NimbusJwtEncoder(jwkSource);
    }

    /** Decoder for OUR tokens (local JWKS). Marked primary; the Keycloak decoder is a separate qualified bean. */
    @Bean
    @Primary
    public JwtDecoder jwtDecoder(JWKSource<SecurityContext> jwkSource) {
        return OAuth2AuthorizationServerConfiguration.jwtDecoder(jwkSource);
    }
}
