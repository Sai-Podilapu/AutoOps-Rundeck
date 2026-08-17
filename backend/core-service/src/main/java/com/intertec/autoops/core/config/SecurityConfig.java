package com.intertec.autoops.core.config;

import com.intertec.autoops.core.security.InternalTokenFilter;
import com.intertec.autoops.core.security.RestAuthEntryPoint;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.core.convert.converter.Converter;
import org.springframework.security.authentication.AbstractAuthenticationToken;
import org.springframework.http.HttpMethod;
import org.springframework.security.config.Customizer;
import org.springframework.security.config.annotation.method.configuration.EnableMethodSecurity;
import org.springframework.security.config.annotation.web.builders.HttpSecurity;
import org.springframework.security.config.annotation.web.configuration.EnableWebSecurity;
import org.springframework.security.config.annotation.web.configurers.AbstractHttpConfigurer;
import org.springframework.security.config.http.SessionCreationPolicy;
import org.springframework.security.core.authority.SimpleGrantedAuthority;
import org.springframework.security.oauth2.core.DelegatingOAuth2TokenValidator;
import org.springframework.security.oauth2.core.OAuth2Error;
import org.springframework.security.oauth2.core.OAuth2TokenValidator;
import org.springframework.security.oauth2.core.OAuth2TokenValidatorResult;
import org.springframework.security.oauth2.jwt.Jwt;
import org.springframework.security.oauth2.jwt.JwtDecoder;
import org.springframework.security.oauth2.jwt.JwtValidators;
import org.springframework.security.oauth2.jwt.NimbusJwtDecoder;
import org.springframework.security.oauth2.server.resource.authentication.JwtAuthenticationToken;
import org.springframework.security.web.SecurityFilterChain;
import org.springframework.security.web.authentication.UsernamePasswordAuthenticationFilter;

import java.util.List;

/**
 * Stateless resource server: validates auth-service RS256 access tokens
 * locally via the JWKS endpoint (kid-aware). Checks: signature, exp, iss,
 * and tokenType=access. There are NO public business endpoints — every
 * project/workflow route requires a bearer, and every MUTATION additionally
 * passes the subscription gate (see EntitlementClient).
 */
@Configuration
@EnableWebSecurity
@EnableMethodSecurity
public class SecurityConfig {

    /** Every role except VIEWER may change state. */
    private static final String[] WRITER_ROLES = {"ADMIN", "CLIENT", "PROVIDER"};

    @Bean
    public SecurityFilterChain securityFilterChain(HttpSecurity http, RestAuthEntryPoint entryPoint,
                                                   InternalTokenFilter internalTokenFilter)
            throws Exception {
        http
                .csrf(AbstractHttpConfigurer::disable)
                .cors(Customizer.withDefaults())
                .sessionManagement(s -> s.sessionCreationPolicy(SessionCreationPolicy.STATELESS))
                .addFilterBefore(internalTokenFilter, UsernamePasswordAuthenticationFilter.class)
                .authorizeHttpRequests(auth -> auth
                        .requestMatchers("/actuator/health", "/actuator/info").permitAll()
                        .requestMatchers("/swagger-ui.html", "/swagger-ui/**", "/v3/api-docs/**").permitAll()
                        // Inbound triggers: the unguessable token IS the credential.
                        .requestMatchers("/api/hooks/**").permitAll()
                        // workflow-service / agent-service only; the shared
                        // secret in InternalTokenFilter is the credential.
                        .requestMatchers("/internal/**").permitAll()
                        // VIEWER is read-only. Enforced once here, at the edge,
                        // so no controller has to remember the check: every
                        // state-changing method needs a non-viewer role.
                        .requestMatchers(HttpMethod.POST, "/api/**").hasAnyRole(WRITER_ROLES)
                        .requestMatchers(HttpMethod.PUT, "/api/**").hasAnyRole(WRITER_ROLES)
                        .requestMatchers(HttpMethod.PATCH, "/api/**").hasAnyRole(WRITER_ROLES)
                        .requestMatchers(HttpMethod.DELETE, "/api/**").hasAnyRole(WRITER_ROLES)
                        .anyRequest().authenticated())
                .oauth2ResourceServer(rs -> rs
                        .authenticationEntryPoint(entryPoint)
                        .jwt(jwt -> jwt.jwtAuthenticationConverter(jwtAuthenticationConverter())))
                .exceptionHandling(ex -> ex
                        .authenticationEntryPoint(entryPoint)
                        .accessDeniedHandler(entryPoint));
        return http.build();
    }

    @Bean
    public JwtDecoder jwtDecoder(CoreProperties properties) {
        NimbusJwtDecoder decoder = NimbusJwtDecoder.withJwkSetUri(properties.getJwksUri()).build();
        OAuth2TokenValidator<Jwt> accessTokenOnly = token ->
                "access".equals(token.getClaimAsString("tokenType"))
                        ? OAuth2TokenValidatorResult.success()
                        : OAuth2TokenValidatorResult.failure(new OAuth2Error(
                                "invalid_token", "Not an AutoOps access token", null));
        decoder.setJwtValidator(new DelegatingOAuth2TokenValidator<>(
                JwtValidators.createDefaultWithIssuer(properties.getIssuer()),
                accessTokenOnly));
        return decoder;
    }

    /** Maps the auth-service `role` claim (ADMIN|CLIENT|PROVIDER|VIEWER) to ROLE_*. */
    private Converter<Jwt, AbstractAuthenticationToken> jwtAuthenticationConverter() {
        return jwt -> {
            String role = jwt.getClaimAsString("role");
            return new JwtAuthenticationToken(jwt,
                    role != null ? List.of(new SimpleGrantedAuthority("ROLE_" + role)) : List.of(),
                    jwt.getSubject());
        };
    }
}
