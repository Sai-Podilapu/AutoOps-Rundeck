# AutoOps Subscription Service

Plans, subscriptions, and entitlement/quota decisions (port **8082**). Boot 3.4.2 / Java 21, MySQL (`autoops_subscription`) + Redis. Billing is **stubbed**: subscribing starts a 14-day trial, no charge; time-dependent status transitions (trial expiry, cancel-at-period-end) are computed lazily on read.

## The restriction model

| Kind | Mechanism | Example |
|---|---|---|
| **Feature gate** (binary) | `plan_features` ENUM, checked via `/api/entitlements/check` | SSO, PREMIUM_TEMPLATES, AUDIT_LOG (= full searchable audit, Team+) |
| **Numeric quota** | `plans.max_projects / max_nodes / max_automations` (`NULL` = unlimited) | Starter: 3 projects, 5 workflows |
| **Retention depth** | `plans.history_days` — a read-time bound, NOT a creation gate | Starter sees 30 days of history/audit; Enterprise 2 years |

Tier catalog (Flyway V1..V4, mirrors `frontend-web/src/data/saasData.js`). Since V4
no tier is unlimited — the ladder grows at every step (`NULL` max is still
supported for custom/negotiated plans):

| | Starter $59 | Team $149 | Business $299 | Enterprise $399 |
|---|---|---|---|---|
| Projects | 3 | 10 | 25 | 30 |
| Automation workflows | 5 | 15 | 25 | 30 |
| Jobs | 5 | 10 | 25 | 30 |
| Cloud integrations | 2 | 5 | 5 | 10 |
| Nodes | 10 | 25 | 35 | 50 |
| History/audit depth | 30d | 90d | 180d | 2yr |

## The decision contract (for every consuming service)

`POST /api/entitlements/check` with the **end user's bearer token** — the tenant always comes from the token's `tenantId` claim, never from a header or body.

```jsonc
// Feature gate (auth-service /authorize already uses this):
{ "feature": "AUDIT_LOG" }
→ { "entitled": true, "reason": "ok" }

// Quota gate — the OWNING service counts its own resources and asks BEFORE creating:
{ "quota": { "limit": "MAX_PROJECTS", "current": 3 } }
→ { "entitled": false, "reason": "quota_exceeded", "max": 3, "remaining": 0 }
→ { "entitled": true,  "reason": "ok", "max": 3, "remaining": 1 }   // current=2
→ { "entitled": true,  "reason": "ok" }                             // unlimited plan (no max)

// Both (feature gate evaluated first, denial short-circuits):
{ "feature": "CORE_AUTOMATION", "quota": { "limit": "MAX_AUTOMATIONS", "current": 4 } }
```

Rules for consumers:

- **Count locally, ask centrally.** Usage counts stay in the owning service; only the ceiling and the decision live here. Deny with HTTP 403 `{ "error": "quota_exceeded", ... }` and surface `max` so the UI can render "3 of 3 used — upgrade".
- **Grandfather on downgrade.** A tenant over the new limit keeps existing resources; only NEW creations are blocked. Never delete.
- **Subscription status gates everything first** (`no_subscription`, `trial_expired`, `subscription_canceled`, …), then feature, then quota.
- Feature decisions are Redis-cached 60s (evicted on any subscription change); quota decisions are never cached (they depend on the caller's count).
- Limit names: `MAX_PROJECTS`, `MAX_NODES`, `MAX_AUTOMATIONS`, `MAX_JOBS`, `MAX_CLOUD_INTEGRATIONS`. Retention: read `historyDays` from `GET /api/subscriptions/current` / `GET /api/plans` and bound queries + purges with it.

## Payments (provider-agnostic module)

Charging goes through the `PaymentProvider` seam — `StubPaymentProvider` today
(auto-succeeds), Stripe later as one new bean + `PAYMENT_PROVIDER=stripe`; the
API, records, and lifecycle do not change.

- **When money moves**: trials are free; a charge fires on **reactivation**
  (subscribe after cancel/expiry) and on a **plan change while ACTIVE** (the
  new plan's monthly price, no proration). One immutable `payments` row per
  attempt.
- **Declines**: subscription drops to `PAST_DUE` (entitlements deny with
  `subscription_past_due`); recover via `POST /api/payments/retry` — a new
  charge attempt that lifts the tenant back to ACTIVE on success. Test the
  path locally with `PAYMENT_STUB_FAILS=true`.
- `GET /api/payments` — the tenant's charge history (amounts in cents).
- Audited as `PAYMENT_SUCCEEDED` / `PAYMENT_FAILED` (+ the
  `subscription_events_total` counter).
- Not here yet (arrives with the real provider): checkout/card collection,
  webhooks (3DS/async capture), automatic renewal charging at period end,
  refunds.

## Other endpoints

- `GET /api/plans` — public catalog (pricing page).
- `GET /api/subscriptions/current` — plan + limits + status (`{"status":"NONE"}` when none).
- `POST /api/subscriptions/subscribe {planCode}` / `POST /api/subscriptions/cancel` — ADMIN|PROVIDER only; audited to `subscription_audit_log` + `subscription_events_total`.

## Run

```
mvn spring-boot:run -Dspring-boot.run.profiles=dev   # dev: MySQL on host port 3307
mvn test                                             # hermetic H2 suite
```

With the `prod` profile, `ProdSafetyGuard` refuses startup on dev defaults (DB password, localhost JWKS); Swagger is disabled and TLS to MySQL is required.
