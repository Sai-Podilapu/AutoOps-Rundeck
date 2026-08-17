# deploy-demo — the localhost stack, on a public URL

For showing AutoOps to a client from this laptop. Same images, same `dev`
profiles, same database, same demo data — just reachable over the internet on a
stable `https://` link.

This is an **overlay** on the root `docker-compose.yml`, not a replacement.

> Not to be confused with `deploy/aws-ec2/`. That one runs prebuilt ECR images
> against RDS with `SPRING_PROFILES_ACTIVE=prod`, where every service's
> `ProdSafetyGuard` refuses to boot on a dev default. Different deployment,
> different behaviour. This folder deliberately changes nothing about how the
> app runs.

---

## One-time setup

1. **Claim your free static domain.** [dashboard.ngrok.com](https://dashboard.ngrok.com)
   → **Domains** → **New Domain**. Free accounts include exactly one. Name it
   something you're happy for a client to see, e.g. `autoops-demo`.

   This is worth doing rather than taking a random URL: the hostname gets baked
   into the containers at startup (CORS origins, notification deep links), so a
   reserved domain means you configure it once and every restart hands out the
   same link.

2. **Copy your authtoken.** Same dashboard → **Your Authtoken**.

3. **Add four lines to the root `.env`** (not a separate file — one source of
   truth, see `.env.example`):

   ```
   COMPOSE_FILE=docker-compose.yml;deploy-demo/docker-compose.demo.yml
   COMPOSE_PATH_SEPARATOR=;
   NGROK_AUTHTOKEN=2abc...
   NGROK_DOMAIN=autoops-demo.ngrok-free.app
   ```

   `NGROK_DOMAIN` is the **bare hostname** — no `https://`, no trailing slash.
   `.env` is gitignored; the authtoken is a credential.

   **`COMPOSE_FILE` is the load-bearing line** — see the warning below. Without
   it the demo works, but any stray Compose command silently breaks login.

The same `.env` supplies everything else (SendGrid, ElevenLabs, Dify), so there
is one file to edit and one command to restart.

---

## Running it

```powershell
.\deploy-demo\up.ps1        # go live  (also the restart command — safe to re-run)
.\deploy-demo\status.ps1    # is it actually going to work? run before sharing the link
.\deploy-demo\down.ps1      # close the tunnel, stay running on localhost
.\deploy-demo\down.ps1 -All # stop everything
```

> ### Why `COMPOSE_FILE` is in `.env`
>
> Without it, **any** Compose command that omitted `-f deploy-demo/docker-compose.demo.yml`
> used only the root file — recreating auth-service, api-gateway, core-service,
> plugin-service and the frontend with their **plain localhost settings**, and
> silently dropping the CORS origin, the trusted-proxy range, the console
> deep-link base and the nginx config.
>
> Nothing looked broken. The tunnel stayed up, the page still loaded, and the
> only symptom was **login returning `403 Invalid CORS request`** for everyone on
> the public link. That happened three times — twice from a bare
> `docker compose up -d`, and it is also what IntelliJ's and Docker Desktop's
> Compose integrations do, with no command typed at all.
>
> `COMPOSE_FILE` fixes it at the root: Compose reads it from `.env` before
> anything else, so every command run from the repo root loads both files
> automatically. A bare `docker compose up -d` is now a no-op that recreates
> nothing — verified.
>
> To go localhost-only **on purpose**, pass `-f` explicitly (an explicit `-f`
> beats `COMPOSE_FILE`) — which is exactly what `down.ps1` does.
>
> `status.ps1` checks this line first, and finishes by posting a real login
> through the tunnel: 401 means healthy, 403 means something reverted it.

> **If PowerShell refuses to run the script** ("running scripts is disabled on
> this system"), your execution policy is the default `Restricted`. Either:
> ```powershell
> powershell -ExecutionPolicy Bypass -File .\deploy-demo\up.ps1   # one-off
> Set-ExecutionPolicy -Scope CurrentUser RemoteSigned             # permanent
> ```

`up.ps1` waits for the backend to actually report healthy before printing the
URL. Recreating `auth-service` and `api-gateway` reruns the boot-order race that
makes the gateway 500 for the first minute or two, and a link that's still
erroring is the last thing you want to paste into a call.

It also survives a slow start. Each service's health check allows about 150s
(`interval: 10s` × 12 retries + a 30s start period), and a cold JVM on a busy
laptop can miss that — core-service alone spends ~13s just building its web
context. When it does, Compose gives up on the dependency, kills the half-booted
container (exit 137/143) and leaves the rest in `created`. That looks alarming
and isn't: `up.ps1` waits for the in-flight containers to settle, runs `up` again
to start the ones Compose abandoned, and only then decides whether it worked.

> One thing to avoid doing by hand: `docker compose up -d --force-recreate ngrok`
> **without `--no-deps`**. ngrok depends on the frontend, which depends on the
> gateway, which depends on everything — so it quietly recreates the entire
> stack. Use `up -d --no-deps ngrok` to restart just the tunnel.

Three URLs when it's done:

| | |
|---|---|
| `https://<your-domain>` | share this |
| `http://localhost:5173` | still works, unchanged |
| `http://127.0.0.1:4040` | ngrok's request inspector — every request, header and response that crossed the tunnel |

---

## Why one tunnel covers the whole platform

`frontend/nginx.conf` already proxies `/api/` and `/oauth2/` to `api-gateway:8080`,
so the browser only ever talks to one origin. Tunnelling `frontend:80` carries
the entire app. No service other than the frontend is reachable from outside, and
ngrok runs as a container on the compose network — nothing to install on Windows.

Three things that would normally bite on a tunnel, and don't here:

- **Tokens** live in `localStorage` (`frontend/src/lib/api.js`), not cookies, so
  there's no `SameSite`/`Secure` breakage.
- **The bundle** calls a relative `/api` with no hardcoded hostname, so the same
  frontend image works on any domain. No rebuild.
- **Dify** is called server-side by core-service via `/api/dify/**`
  (`frontend/src/lib/dify/difyApi.js`), so serving over HTTPS causes no
  mixed-content block against the plain-HTTP Dify host.

The voice agent actually works *better*: `getUserMedia` needs a secure context,
which `https://` provides and a plain-HTTP LAN IP would not.

---

## What the overlay changes

Only environment variables, plus one bind-mounted nginx config. No image is
rebuilt and the `mysql-data` volume is never touched — the Intertec demo data and
the provider admin account survive every run.

| Service | Change | Why |
|---|---|---|
| `ngrok` | new container | tunnels `frontend:80` to your reserved domain |
| `frontend` | mounts `nginx.demo.conf` | preserves the edge's `X-Forwarded-Proto`; the stock config overwrites ngrok's `https` with `http` |
| `auth-service` | `TRUSTED_PROXIES=172.16.0.0/12` | **the important one** — see below |
| `auth-service`, `api-gateway` | `CORS_ALLOWED_ORIGINS` | the SPA is same-origin so CORS never fires for it; this covers direct calls |
| `core-service`, `plugin-service` | `CONSOLE_BASE_URL` | otherwise "Open in AutoOps" links in notifications point at `localhost:5173`, which resolves to the *recipient's* machine |

**On the auth-service CORS override — this one causes a 403 on login if you miss
it.** auth-service is the only service running `SPRING_PROFILES_ACTIVE=dev`, and
its `application-dev.yml:19-22` hardcodes the origins as a literal list:

```yaml
cors:
  allowed-origins:
    - http://localhost:5173
    - http://localhost:3000
```

A profile YAML outranks the `${CORS_ALLOWED_ORIGINS}` placeholder in
`application.yml`, so setting that env var has **no effect here**. Only an
environment variable outranks a profile YAML, which is why the overlay sets
`AUTOOPS_AUTH_CORS_ALLOWEDORIGINS` (the relaxed-binding name for
`autoops.auth.cors.allowed-origins`). The api-gateway runs no profile, which is
why it honours plain `CORS_ALLOWED_ORIGINS` and auth-service does not.

It matters even though the SPA is same-origin: **browsers attach an `Origin`
header to every non-GET request, including same-origin ones**, so Spring's CORS
filter still evaluates it. A rejected origin comes back as `403 Invalid CORS
request` — login fails while everything else on the page looks fine.

Worth fixing at the source eventually: `application-dev.yml` should use the
`${CORS_ALLOWED_ORIGINS:...}` placeholder like `application.yml` does, so the
documented env var behaves as documented. That needs an auth-service rebuild, so
the overlay works around it instead.

**On `TRUSTED_PROXIES`:** `trusted-proxies` defaults to empty
(`auth-service/src/main/resources/application.yml:38`), which means
`X-Forwarded-For` is never trusted and every visitor shares **one** rate-limit
bucket keyed by the gateway's container IP. With `login-attempts: 10` and
`otp-requests: 5`, two clients fumbling a password would lock out the room
mid-demo. Trusting the Docker private range gives each visitor their own bucket.
The trade-off is that anything on that bridge network could spoof the header —
fine on a laptop where every container is ours.

---

## The ngrok warning page

Free ngrok endpoints show browsers a "You are about to visit…" interstitial with
a **Visit Site** button. **On a free plan this cannot be turned off**, and that
was tested against this endpoint rather than assumed:

| Request | Result |
|---|---|
| Chrome User-Agent | 2824 bytes — the warning page |
| Non-browser User-Agent | 1192 bytes — the real SPA |
| `ngrok-skip-browser-warning` header | bypasses it, but a browser can't set a header on a top-level navigation |
| `add-headers` traffic-policy action injecting that header | **does not work** — ngrok's abuse check runs ahead of the policy |

That last row is why `traffic-policy.yml` no longer tries: it was measured, not
guessed. So the honest position is one click. The visitor clicks **Visit Site**
once and that browser is fine from then on; `/api` calls were never affected
(they're not HTML navigations), so nothing inside the app is touched.

**Click through it yourself before the call** so you know what the client sees.

If you later want it gone entirely, two things work: the ngrok Hobbyist plan
(~$10/mo, removes it by default and keeps this exact setup unchanged), or
Cloudflare Tunnel, which has no interstitial at all.

If ngrok ever rejects the traffic policy, `up.ps1` catches it, prints the agent's
log, and points you at `traffic-policy.yml`. The tunnel works fine without it.

---

## The link is open

No password, so a client can just click it. Worth knowing what that means:
`job-service` executes shell, python, terraform and kubectl steps, so anyone with
the URL has a real path into this laptop. That's a reasonable trade for a link
you hand out on a call and close afterwards — run `down.ps1` when you're done.

If you ever want a gate, `traffic-policy.yml` has commented-out `basic-auth` and
`restrict-ips` blocks. Uncomment either and re-run `up.ps1`.

---

## Files

| | |
|---|---|
| `docker-compose.demo.yml` | the overlay — ngrok + the env deltas |
| `traffic-policy.yml` | ngrok auth / IP rules / header injection (v3 moved these out of CLI flags) |
| `nginx.demo.conf` | near-copy of `frontend/nginx.conf`, one header changed. Keep in step if that file changes |
| `up.ps1` / `down.ps1` | start and stop |
| `status.ps1` | pre-flight check — verifies the overlay is actually applied and posts a live login through the tunnel |

Everything runs from the repo root: with multiple `-f` files, Compose resolves
all relative paths against the **first** file's directory, which is why the
volume paths in the overlay read `./deploy-demo/...`.
