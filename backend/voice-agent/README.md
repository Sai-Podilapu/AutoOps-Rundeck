# voice-agent

Aegis-01 — the live voice agent on the AutoOps landing page.

The browser talks to ElevenLabs directly over a WebSocket, because that is the
only way to get real-time duplex audio. This service exists so it can do that
**without ever holding the ElevenLabs API key**: it exchanges the key for a
signed URL that is scoped to one conversation and expires in 15 minutes, and
hands the browser that instead.

```
browser ──POST /api/voice/session──▶ gateway ──▶ voice-agent ──xi-api-key──▶ ElevenLabs
   ▲                                                                             │
   └──────────────── signed wss:// URL (15 min, one conversation) ◀───────────────┘
   │
   └── opens the audio WebSocket straight to ElevenLabs
```

## Endpoints

Both are **anonymous** — a landing-page visitor has no account yet. The
api-gateway permits exactly these two paths and nothing else under
`/api/voice/`.

| Method | Path                 | Returns                                        |
| ------ | -------------------- | ---------------------------------------------- |
| `GET`  | `/api/voice/config`  | `{ "enabled": true, "agentName": "Aegis-01" }`  |
| `POST` | `/api/voice/session` | `{ "signedUrl": "wss://…", "expiresInSeconds": 900 }` |

`config` carries no secret — not even the agent id — so the agent can stay
private to signed URLs. The landing page calls it on mount and renders no talk
button at all when `enabled` is false, which is what an un-keyed deployment
degrades to.

`session` is a POST because it spends an ElevenLabs quota slot; it is not a
safe, cacheable read.

## Protecting the credits

`/api/voice/session` is unauthenticated and every call costs real money, so the
rate limiter — not authentication — is what stands between a scripted client
and the billing account:

- **per-IP** (`VOICE_RATE_LIMIT_PER_IP`, default 5 per 10 minutes) — generous
  for a human, tight for a loop. The client address comes from
  `X-Forwarded-For`, which is forgeable, so treat this as the courtesy limit.
- **global** (`VOICE_RATE_LIMIT_GLOBAL`, default 120 per 10 minutes) — the cap
  that actually bounds the bill, since it holds no matter how many source
  addresses an attacker rotates through.

Both are in-memory and therefore per-replica: a deliberate trade so the landing
page's talk button never depends on Redis being up. Rejected attempts are not
counted against the caller, so a client that keeps retrying still recovers
exactly one window after its last *allowed* call. The prod profile refuses to
start with the limiter disabled.

## Configuration

| Variable | Default | Notes |
| --- | --- | --- |
| `ELEVENLABS_API_KEY` | `REPLACE_ME` | Server-side only. Never routed to a browser. |
| `ELEVENLABS_AGENT_ID` | `REPLACE_ME` | The `agent_…` id from the dashboard. |
| `VOICE_AGENT_NAME` | `Aegis-01` | Shown on the landing-page button. |
| `VOICE_API_BASE_URL` | `https://api.elevenlabs.io` | Override for a regional endpoint. |
| `VOICE_REQUEST_TIMEOUT` | `10s` | Connect + read timeout on the one outbound call. |
| `VOICE_RATE_LIMIT` | `true` | Prod refuses to start when false. |
| `VOICE_RATE_LIMIT_PER_IP` | `5` | Per window. |
| `VOICE_RATE_LIMIT_GLOBAL` | `120` | Per window, all IPs. |
| `VOICE_RATE_LIMIT_WINDOW` | `10m` | Sliding window. |
| `SERVER_PORT` | `8085` | |

Missing credentials are a warning, not a startup failure — an un-keyed deploy
should lose the button, not the platform.

## Creating the agent in ElevenLabs

1. **Agents → New agent.** Name it `Aegis-01`.
2. Paste the system prompt, first message and dashboard settings from
   **[`agent-prompt.md`](agent-prompt.md)** — the version-controlled copy of
   what the live agent says, including the English/Telugu language rules and
   the scope guardrail that keeps it on AutoOps.
3. Pick a voice trained on the languages you enabled.
4. **Security → Enable authentication.** This makes the agent reachable only
   through signed URLs, which is the whole point of this service. Leave the
   allowlist empty or add your production hostname(s) — matching is exact per
   hostname, so `example.com` and `www.example.com` are two entries.
5. Copy the `agent_…` id into `ELEVENLABS_AGENT_ID`, and an API key with
   Agents access into `ELEVENLABS_API_KEY`.

When the product's capabilities or prices change, update `agent-prompt.md` and
re-paste it. An agent quoting last quarter's pricing on a sales call is worse
than one that says "let me connect you with the team".

## Running

```bash
# whole platform
docker compose up -d --build

# just this service
cd voice-agent && ELEVENLABS_API_KEY=sk_… ELEVENLABS_AGENT_ID=agent_… mvn spring-boot:run

# smoke test
curl localhost:8085/api/voice/config
curl -X POST localhost:8085/api/voice/session
```

## Tests

`mvn test` — 36 tests, no network. `ElevenLabsClientTest` drives the upstream
call through `MockRestServiceServer`, `SessionRateLimiterTest` moves a fake
clock instead of sleeping.
