# AutoOps API Gateway

Single entry point for the AutoOps platform (port **8080**). Spring Cloud Gateway MVC on Boot 3.4.2 / Java 21.

## What it does

- **Routing** — `/api/auth/**`, `/oauth2/**` → auth-service (8081); `/api/plans/**`, `/api/subscriptions/**`, `/api/entitlements/**` → subscription-service (8082). Pure YAML config, no code.
- **Edge authentication** — every non-public route requires an AutoOps RS256 **access** token, validated locally against auth-service's JWKS (issuer + `tokenType=access` claim). Refresh tokens are rejected. Fine-grained authorization stays downstream; the gateway never makes business decisions.
- **Trusted tenant injection** — `TenantHeaderFilter` OVERWRITES `X-Tenant-ID` with the token's own `tenantId` claim before proxying, so a client can never smuggle another workspace's tenant header past the edge. Anonymous requests (login/register) pass their header through untouched.
- **CORS** for the frontend dev origins (5173/3000 by default).

## Configuration

All settings are env-overridable (`${VAR:default}`); custom keys live under `autoops.gateway.*` and bind to `GatewayProperties`:

| Env var | Default | Meaning |
|---|---|---|
| `SERVER_PORT` | `8080` | Listen port |
| `AUTH_SERVICE_URL` | `http://localhost:8081` | Route target |
| `SUBSCRIPTION_SERVICE_URL` | `http://localhost:8082` | Route target |
| `AUTH_JWKS_URI` | `http://localhost:8081/oauth2/jwks` | JWKS for local token validation |
| `JWT_ISSUER` | `autoops-auth-service` | Expected `iss` claim |
| `CORS_ALLOWED_ORIGINS` | `http://localhost:5173,http://localhost:3000` | Browser origins |

With the `prod` profile active, `ProdSafetyGuard` refuses startup while any localhost default (JWKS, routes, CORS) survives.

## Run

```
mvn spring-boot:run        # local (auth-service + subscription-service must be up)
mvn test                   # security + tenant-filter tests, no downstream needed
```
