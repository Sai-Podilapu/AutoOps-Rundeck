package com.intertec.autoops.auth.config;

import com.intertec.autoops.auth.security.RestAuthEntryPoint;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.core.annotation.Order;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.security.config.Customizer;
import org.springframework.security.config.annotation.web.builders.HttpSecurity;
import org.springframework.security.crypto.bcrypt.BCryptPasswordEncoder;
import org.springframework.security.crypto.password.PasswordEncoder;
import org.springframework.security.oauth2.core.AuthorizationGrantType;
import org.springframework.security.oauth2.core.ClientAuthenticationMethod;
import org.springframework.security.oauth2.server.authorization.client.JdbcRegisteredClientRepository;
import org.springframework.security.oauth2.server.authorization.client.RegisteredClient;
import org.springframework.security.oauth2.server.authorization.client.RegisteredClientRepository;
import org.springframework.security.oauth2.server.authorization.config.annotation.web.configurers.OAuth2AuthorizationServerConfigurer;
import org.springframework.security.oauth2.server.authorization.settings.AuthorizationServerSettings;
import org.springframework.security.oauth2.server.authorization.settings.ClientSettings;
import org.springframework.security.oauth2.server.authorization.settings.TokenSettings;
import org.springframework.security.web.SecurityFilterChain;

import java.util.UUID;

/**
 * Spring Authorization Server wiring:
 * <ul>
 *   <li>the registered {@code gateway} client (client_credentials, basic auth)</li>
 *   <li>RFC 7662 token introspection at {@code /oauth2/introspect}</li>
 *   <li>the public JWKS endpoint at {@code /oauth2/jwks}</li>
 * </ul>
 *
 * <p>NOTE: user access tokens are minted directly by {@code JwtService}
 * (not through SAS), so they are NOT persisted as {@code OAuth2Authorization}
 * records — {@code /oauth2/introspect} only knows tokens SAS itself issued
 * (the gateway's client_credentials tokens). For revocation-aware validation
 * of user tokens, callers must use {@code POST /api/auth/authorize}, which
 * checks the live user status and {@code ver} (token_version) in the DB.
 * The OAuth2AuthorizationService in TokenStoreConfig backs SAS's own state.
 */
@Configuration
public class AuthorizationServerConfig {

    @Bean
    @Order(1)
    public SecurityFilterChain authorizationServerSecurityFilterChain(HttpSecurity http,
                                                                      RestAuthEntryPoint entryPoint)
            throws Exception {
        OAuth2AuthorizationServerConfigurer authorizationServerConfigurer =
                OAuth2AuthorizationServerConfigurer.authorizationServer();
        http
                .securityMatcher(authorizationServerConfigurer.getEndpointsMatcher())
                .with(authorizationServerConfigurer, Customizer.withDefaults())
                .csrf(csrf -> csrf.ignoringRequestMatchers(authorizationServerConfigurer.getEndpointsMatcher()))
                .exceptionHandling(ex -> ex.authenticationEntryPoint(entryPoint));
        return http.build();
    }

    @Bean
    public AuthorizationServerSettings authorizationServerSettings() {
        return AuthorizationServerSettings.builder().build();
    }

    @Bean
    public PasswordEncoder passwordEncoder() {
        return new BCryptPasswordEncoder();
    }

    /**
     * JDBC-backed registered clients. Seeds the {@code gateway} introspection
     * client on first boot if it is missing (secret bcrypt-encoded).
     */
    @Bean
    public RegisteredClientRepository registeredClientRepository(JdbcTemplate jdbcTemplate,
                                                                 AuthProperties properties,
                                                                 PasswordEncoder passwordEncoder) {
        JdbcRegisteredClientRepository repository = new JdbcRegisteredClientRepository(jdbcTemplate);
        String gatewayClientId = properties.getGatewayClient().getClientId();
        if (repository.findByClientId(gatewayClientId) == null) {
            RegisteredClient gateway = RegisteredClient.withId(UUID.randomUUID().toString())
                    .clientId(gatewayClientId)
                    .clientSecret(passwordEncoder.encode(properties.getGatewayClient().getClientSecret()))
                    .clientName("AutoOps API Gateway")
                    .clientAuthenticationMethod(ClientAuthenticationMethod.CLIENT_SECRET_BASIC)
                    .authorizationGrantType(AuthorizationGrantType.CLIENT_CREDENTIALS)
                    .scope("introspect")
                    .clientSettings(ClientSettings.builder()
                            .requireProofKey(false)
                            .requireAuthorizationConsent(false)
                            .build())
                    .tokenSettings(TokenSettings.builder()
                            .accessTokenTimeToLive(properties.getAccessTokenTtl())
                            .build())
                    .build();
            repository.save(gateway);
        }
        return repository;
    }
}
