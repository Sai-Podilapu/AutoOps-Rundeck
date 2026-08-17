# auth-service

AutoOps identity and token authority: passwordless OTP login, Keycloak SSO,
RS256 token issuance with a public JWKS, refresh rotation with reuse
detection, RFC 7662 introspection for the gateway, and entitlement-aware
authorization.

Java 21 - Spring Boot 3.3 - MySQL 8.4 - Redis 7 - port **8081**

## Quick start (dev)

```bash
# 1. Infra: MySQL (3306), Redis (6379), Keycloak (8180)
docker compose up -d

# 2. Run with the dev profile (ephemeral RSA keys, /api/auth/dev/token active)
mvn spring-boot:run -Dspring-boot.run.profiles=dev
```

Swagger UI: `http://localhost:8081/swagger-ui.html`

## HTTP API

| Method | Path | Auth | Purpose |
|---|---|---|---|
| POST | `/api/auth/otp/generate` | public (rate-limited) | Email a one-time code |
| POST | `/api/auth/otp/verify` | public (rate-limited) | Verify OTP, issue access + refresh tokens |
| POST | `/api/auth/refresh` | public | Rotate refresh token, new access token |
| POST | `/api/auth/logout` | public | Revoke one refresh session |
| POST | `/api/auth/logout-all` | bearer | Revoke all sessions + bump token version |
| POST | `/api/auth/authorize` | gateway (HTTP Basic) | Validate token + check feature entitlement |
| GET | `/oauth2/jwks` | public | JWKS public keys for resource services |
| POST | `/oauth2/introspect` | gateway (HTTP Basic) | RFC 7662 token introspection |
| GET | `/api/auth/sso/initiate` | public | 302 redirect to Keycloak login |
| GET | `/api/auth/sso/callback?code=&state=` | public (state-validated) | OIDC code exchange, issue tokens |
| POST | `/api/auth/onboard` | ADMIN | Create user (201) |
| POST | `/api/auth/offboard/{userId}` | ADMIN | Disable user + revoke sessions |
| GET | `/api/auth/me` | bearer | Current user profile |
| POST | `/api/auth/webhooks/sendgrid` | ECDSA signature | OTP delivery status events |
| POST | `/api/auth/dev/token` | dev profile only | Mint tokens without OTP |

## Security design

- **RS256 only.** Tokens are signed with an RSA key pair (PKCS#12 keystore in
  prod, ephemeral in dev) and validated by services via `/oauth2/jwks`.
  There is no shared-secret HS256 anywhere.
- **Access token claims:** `sub` (email), `userId`, `role`, `tenantId`,
  `tokenType=access`, `status`, `ver`, `iss=autoops-auth-service`, 15 min TTL.
- **`ver` claim = users.token_version.** Bumped on logout-all/offboard, so
  outstanding tokens die instantly on the next check.
- **Refresh tokens** are opaque `{sessionId}.{48-byte-secret}`; only the
  SHA-256 hash is stored. Rotation links sessions; replaying a rotated token
  revokes the whole family (reuse detection).
- **OTP:** 6 digits, 5 min TTL, 5 attempts, SHA-256 hashed, constant-time
  compare, lockout + audit. Delivery via SendGrid dynamic template AFTER the
  DB commit, with one retry and fail-closed status tracking.
- **Rate limiting** (Redis fixed window): OTP *generate* fails open (an infra
  outage must not block code delivery), but the *verify* path is keyed
  **per-account** (IP-independent) and **FAILS CLOSED** — a Redis outage or IP
  rotation can never enable brute force of a 6-digit code. Regenerating an OTP
  supersedes the previous entry (one active code per account).
  **Entitlement checks** (subscription-service) FAIL CLOSED unless
  `ENTITLEMENT_FAIL_OPEN=true`.
- **Anti-enumeration:** `/otp/generate` and `/otp/verify` return uniform
  responses whether or not the account exists (`login_failed` / neutral 200);
  the distinction lives only in the audit log.
- **SSO login CSRF/code-injection protection:** `state` is generated
  server-side, stored single-use in Redis (5 min TTL) and verified on the
  callback; the code exchange also uses **PKCE (S256)**.
- **Client IPs:** `X-Forwarded-For` / `X-Real-IP` are honored only when the
  connection comes from a proxy listed in `TRUSTED_PROXIES` (IPs/CIDRs);
  otherwise the socket address is used.
- **`/api/auth/authorize`** requires the gateway's client credentials
  (HTTP Basic) — token validity and claims are never disclosed anonymously.
- **Refresh rotation is race-safe:** the session row is read with
  `SELECT ... FOR UPDATE`, so concurrent replays cannot slip past reuse
  detection.
- **Redis token store is JSON-serialized** (Spring Security's allow-listed
  Jackson modules) — no Java native deserialization anywhere.
- **Prod startup guard** refuses to boot with default gateway/DB secrets, a
  missing JWT keystore, or the `dev` profile active alongside `prod`.
- **Multi-tenancy:** `X-Tenant-ID` header -> `TenantContext` (ThreadLocal,
  cleared in `finally`). The header is client-supplied, so in prod
  `TENANT_REQUIRE_HEADER=true` expects a trusted gateway to set/overwrite it;
  requests without it are rejected instead of falling back to the default
  tenant.

## Configuration (env vars)

| Variable | Default | Notes |
|---|---|---|
| `SERVER_PORT` | `8081` | |
| `DB_HOST` / `DB_PORT` / `DB_NAME` | `localhost` / `3306` / `autoops_auth` | `DB_USER`/`DB_PASSWORD`: `autoops` |
| `REDIS_HOST` / `REDIS_PORT` | `localhost` / `6379` | |
| `JWT_ISSUER` | `autoops-auth-service` | |
| `JWT_KEYSTORE_PATH` / `JWT_KEYSTORE_PASSWORD` / `JWT_KEY_ALIAS` | _(blank)_ | PKCS#12; blank = ephemeral dev keys |
| `ACCESS_TOKEN_TTL` / `REFRESH_TOKEN_TTL` | `15m` / `30d` | |
| `TOKEN_STORE` | `jdbc` | `jdbc` or `redis` |
| `TRUSTED_PROXIES` | _(empty)_ | IPs/CIDRs allowed to set `X-Forwarded-For` / `X-Real-IP` |
| `TENANT_REQUIRE_HEADER` | `false` (dev) / `true` (prod) | reject requests without `X-Tenant-ID` |
| `DEFAULT_TENANT` | `default` | used only when the header isn't required |
| `SUBSCRIPTION_SERVICE_URL` | `http://localhost:8082` | |
| `ENTITLEMENT_FAIL_OPEN` | `false` | |
| `KEYCLOAK_ISSUER_URI` | `http://localhost:8180/realms/autoops` | + `KEYCLOAK_CLIENT_ID/SECRET/REDIRECT_URI` |
| `SENDGRID_API_KEY` / `SENDGRID_OTP_TEMPLATE_ID` | placeholders | |
| `SENDGRID_FROM_EMAIL` | `no-reply@autoops.io` | |
| `SENDGRID_WEBHOOK_PUBLIC_KEY` | _(blank)_ | blank disables the webhook |
| `GATEWAY_CLIENT_ID` / `GATEWAY_CLIENT_SECRET` | `gateway` / `gateway-secret` | introspection client |

## Project layout

```
src/main/java/com/intertec/autoops/auth/
  domain/      JPA entities + enums (strict MySQL ENUM mapping)
  repo/        Spring Data repositories
  service/     OTP, JWT, refresh rotation, users, SendGrid, Keycloak, audit, rate limit
  client/      subscription-service entitlement client
  facade/      AuthFacade use-case orchestration
  web/         controllers + dto/ records
  security/    tenant filter, JWT filter, IP resolver, entry point
  config/      properties, JWK, SAS, token store, security chains, clients
src/main/resources/db/migration/   Flyway V1 (core) + V2 (authorization server)
```

Flyway owns the schema (`ddl-auto: validate`). No Lombok; records for DTOs;
constructor injection everywhere.
