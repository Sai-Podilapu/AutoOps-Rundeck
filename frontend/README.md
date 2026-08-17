# AutoOps — Website

Professional marketing website for **AutoOps**, the self-hosted automation &
orchestration platform. Built with React 18 + Vite + Tailwind + React Router.

## Run locally

```bash
npm install
npm run dev
```

Then open http://localhost:5173

## Routes

| Path | Page |
| --- | --- |
| `/` | Landing (hero, orchestrate marquee, features, designer, observability, capabilities, enterprise, CTA) |
| `/pricing` | 4-tier pricing (Starter / Team / Business / Enterprise) |
| `/login` | Sign in (Keycloak SSO + email) |
| `/features/:slug` | 10 capability detail pages (data-driven) |

Feature slugs: real-time-ingestion, sandbox-isolation, secure-apis, zero-latency,
intelligent-audit, composable-workflows, automated-runbooks, access-control,
execution-audit-trails, environment-discovery.

## Polish & interactions

- **Scroll reveal** — `components/Reveal.jsx` fades sections up on scroll (IntersectionObserver).
- **Horizontal marquee** — the “Orchestrate across every target” strip auto-scrolls with provider icons + names and pauses on hover.
- **Hover effects** — lift, glow, gradient washes and icon scaling on every card.
- **9 capability cards** — each links to its full feature page.
- **Reduced-motion** respected via `prefers-reduced-motion`.

## Brand

- Gradient: cyan `#22d3ee` → teal `#2dd4bf` → emerald `#34d399`
- Surface: charcoal `#04060d`
- Fonts: Inter + JetBrains Mono
- Logo: woven-R mark (`components/ui.jsx` + `public/favicon.svg`)

## Structure

```
src/
  components/   ui, Navbar, Footer, Icon, Reveal
  sections/     Hero, OrchestrateMarquee, Features, WorkflowDesigner,
                Observability, Capabilities, Enterprise, FinalCTA
  pages/        Home, Pricing, Login, FeaturePage
  data/         features.js (drives all 10 feature pages)
```

## Testing

```bash
npm test              # 127 tests
npm run test:coverage # + a coverage summary for lib/ and store/
```

Vitest + React Testing Library on jsdom. The suite is **hermetic**, the same
way the Java suites are: no backend, no network, no fixtures downloaded.
`src/test/setup.js` replaces `global.fetch` with a stub that throws — a test
that forgets to stub its own responses fails loudly instead of quietly reaching
for localhost:8080.

| Suite | Tests | What it holds down |
| --- | --- | --- |
| `lib/api.transport` | 23 | Bearer-token attachment, JSON bodies, error mapping, the subscription-gate event, and the transparent 401 refresh — including that two concurrent 401s share **one** refresh call. Refresh tokens rotate and auth-service revokes the whole session family on replay, so a second parallel refresh signs the user out everywhere |
| `lib/api.mapping` | 16 | Every backend payload reshaped for the UI: profile, session establishment, subscription (active / unlimited / none), projects, runs. Pins the field names the services actually return |
| `lib/helpers` | 31 | Duration and date formatting, CSV escaping (RFC 4180 quoting), plan entitlement ranking, project route base |
| `lib/useCollection` | 7 | The hook behind every project-scoped list page: loading, error, non-array payloads, optimistic create/remove, reload on project change |
| `store/store` | 18 | The client-side RBAC matrix (operator runs but never approves; billing/members/keys/governance stay admin-only), sign-in for client and provider contexts, sign-out clearing every trace, and account-scoped localStorage not leaking between users on a shared machine |
| `App.guards` | 11 | Route guards: unauthenticated bounces, no login flash while the session restores, provider console closed to clients, capability redirects |
| `pages/Login` | 12 | All four sign-in outcomes plus the server-driven detours — unverified email, enforced SSO, provider console — and double-submit protection |
| `pages/Signup` | 9 | Two-step registration: client-side password rule, code verification, and completing sign-up even when the plan-trial call fails (the workspace already exists by then) |

Coverage across `lib/` and `store/` is **56% of statements, 82% of branches**.
The branch figure is the meaningful one: the logic that decides *what happens*
is covered; the uncovered statements are mostly the ~100 thin `api.*` wrappers
that only build a URL.

**Not covered yet:** the 45+ app and provider pages beyond Login and Signup.
Those need either per-page tests or a Playwright pass against the compose
stack — the latter is probably better value per hour.
