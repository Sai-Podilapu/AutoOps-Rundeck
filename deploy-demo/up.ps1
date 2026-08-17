<#
    Puts the AutoOps laptop stack on its public ngrok URL.

        .\deploy-demo\up.ps1

    Safe to re-run: it is the same `docker compose up -d` underneath, so it
    doubles as the restart command. Your MySQL volume is never touched, so the
    Intertec demo data and the provider admin account survive every run.

    The script does not print the URL until the stack is actually answering.
    Recreating auth-service and api-gateway reruns the boot-order race that makes
    the gateway 500 for the first minute or two, and handing a client a link that
    is still erroring is the one thing worth avoiding here.
#>

$ErrorActionPreference = "Stop"

$repoRoot = Split-Path -Parent $PSScriptRoot
$envRoot  = Join-Path $repoRoot ".env"

# ---------------------------------------------------------------- preflight --

if (-not (Test-Path $envRoot)) {
    Write-Host ""
    Write-Host "  The root .env is missing - it holds every setting this needs:" -ForegroundColor Red
    Write-Host "  SendGrid, ElevenLabs, Dify, and the two ngrok values."
    Write-Host ""
    Write-Host "  Copy .env.example to .env and fill it in first."
    Write-Host ""
    exit 1
}

# Minimal .env reader: KEY=VALUE, ignoring blanks and comments. Only used to
# check the two values are present and to echo the URL back - Compose does the
# real parsing.
function Read-EnvFile($path) {
    $map = @{}
    foreach ($line in (Get-Content $path)) {
        $trimmed = $line.Trim()
        if ($trimmed -eq "" -or $trimmed.StartsWith("#")) { continue }
        $i = $trimmed.IndexOf("=")
        if ($i -lt 1) { continue }
        $map[$trimmed.Substring(0, $i).Trim()] = $trimmed.Substring($i + 1).Trim()
    }
    return $map
}

$rootVars = Read-EnvFile $envRoot
$missing  = @()
foreach ($key in @("NGROK_AUTHTOKEN", "NGROK_DOMAIN")) {
    if (-not $rootVars.ContainsKey($key) -or $rootVars[$key] -eq "") { $missing += $key }
}
if ($missing.Count -gt 0) {
    Write-Host ""
    Write-Host "  Still blank in .env: $($missing -join ', ')" -ForegroundColor Red
    Write-Host "  Get both from dashboard.ngrok.com (Your Authtoken / Domains)."
    Write-Host ""
    exit 1
}

# COMPOSE_FILE in .env is what stops a bare `docker compose up -d` from
# reverting the overlay. Warn rather than fail: this script passes -f
# explicitly, so it still works without it - but everything else won't.
if (-not $rootVars.ContainsKey("COMPOSE_FILE") -or
    -not $rootVars["COMPOSE_FILE"].Contains("docker-compose.demo.yml")) {
    Write-Host ""
    Write-Host "  Warning: COMPOSE_FILE in .env does not include the demo overlay." -ForegroundColor Yellow
    Write-Host "  Any plain 'docker compose up -d' will silently revert it and login"
    Write-Host "  will start returning 403. See deploy-demo\README.md."
    Write-Host ""
}

$domain = $rootVars["NGROK_DOMAIN"]
if ($domain -match "^https?://") {
    Write-Host ""
    Write-Host "  NGROK_DOMAIN should be a bare hostname, with no https:// prefix." -ForegroundColor Red
    Write-Host "  You have: $domain"
    Write-Host "  Use:      $($domain -replace '^https?://', '' -replace '/$', '')"
    Write-Host ""
    exit 1
}
$publicUrl = "https://$domain"

# ------------------------------------------------------------------- compose --

# Both files named explicitly, so this script works even if COMPOSE_FILE is
# missing from .env. Run from the repo root: with multiple -f files Compose
# resolves all relative paths against the FIRST file's directory.
$composeArgs = @(
    "compose",
    "-f", "docker-compose.yml",
    "-f", "deploy-demo/docker-compose.demo.yml"
)

Push-Location $repoRoot
try {
    Write-Host ""
    Write-Host "  Starting the AutoOps stack on $publicUrl ..." -ForegroundColor Cyan
    Write-Host ""

    function Get-ServiceHealth($service) {
        $id = (& docker @composeArgs ps -q $service | Select-Object -First 1)
        if (-not $id) { return "gone" }
        $state = (& docker inspect --format "{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}" $id)
        if (-not $state) { return "unknown" }
        return $state.Trim()
    }

    # True while any container is still inside its health check's start window.
    function Test-AnyStarting {
        $rows = (& docker ps --filter "name=autoops-" --format "{{.Status}}")
        foreach ($r in $rows) { if ($r -match "health: starting") { return $true } }
        return $false
    }

    & docker @composeArgs up -d
    if ($LASTEXITCODE -ne 0) {
        # Not necessarily a real failure. Every service here has a health check
        # budget of about 150s (interval 10s x 12 retries + a 30s start period),
        # and a cold JVM on a busy laptop can miss it - core-service alone spends
        # ~13s just building its web context. When that happens Compose gives up
        # on the dependency, kills the half-started container (exit 137/143) and
        # leaves the rest in `created`. The stack is fine; it just needed longer.
        #
        # So: let whatever is mid-boot settle, then run up again to start the
        # containers Compose abandoned. Only the health check below decides
        # whether this actually worked.
        Write-Host ""
        Write-Host "  Compose reported a failure. That is usually a health check timing out" -ForegroundColor Yellow
        Write-Host "  while the JVMs boot, not a real error - letting them settle and retrying."
        Write-Host ""

        $settleDeadline = (Get-Date).AddMinutes(4)
        while ((Get-Date) -lt $settleDeadline) {
            if (-not (Test-AnyStarting)) { break }
            Start-Sleep -Seconds 10
        }

        & docker @composeArgs up -d
        if ($LASTEXITCODE -ne 0) {
            Write-Host ""
            Write-Host "  Still failing on the second attempt - the health check below" -ForegroundColor Yellow
            Write-Host "  will say whether anything came up."
            Write-Host ""
        }
    }

    # ------------------------------------------------------------ wait for it --

    # api-gateway depends_on every other service being healthy, so waiting on it
    # transitively waits on the whole backend.
    $deadline = (Get-Date).AddMinutes(5)
    Write-Host "  Waiting for the backend to come up (this takes a minute or two after a recreate)..."
    $gatewayReady = $false
    while ((Get-Date) -lt $deadline) {
        $health = Get-ServiceHealth "api-gateway"
        if ($health -eq "healthy") { $gatewayReady = $true; break }
        if ($health -eq "gone") {
            Write-Host "  api-gateway has no container - check 'docker compose ps'." -ForegroundColor Red
            break
        }
        Start-Sleep -Seconds 5
    }

    if (-not $gatewayReady) {
        Write-Host ""
        Write-Host "  The gateway never reported healthy. Last 40 lines:" -ForegroundColor Yellow
        & docker @composeArgs logs --tail 40 api-gateway
        Write-Host ""
        Write-Host "  The tunnel may still be fine - re-run this script once the stack settles."
        Write-Host ""
        exit 1
    }
    Write-Host "  Backend healthy." -ForegroundColor Green

    # ---------------------------------------------------------- verify ngrok --

    # ngrok validates the traffic policy SERVER-SIDE, on connect. A rejected
    # policy shows up as a crash-looping container, not as a startup error, so
    # this checks the agent actually established a tunnel before declaring
    # victory.
    $tunnelUrl = $null
    $deadline = (Get-Date).AddSeconds(60)
    while ((Get-Date) -lt $deadline) {
        try {
            $api = Invoke-RestMethod -Uri "http://127.0.0.1:4040/api/tunnels" -TimeoutSec 5
            if ($api.tunnels -and $api.tunnels.Count -gt 0) {
                $tunnelUrl = $api.tunnels[0].public_url
                break
            }
        } catch {
            # Agent not listening yet - keep waiting.
        }
        Start-Sleep -Seconds 3
    }

    if (-not $tunnelUrl) {
        Write-Host ""
        Write-Host "  The stack is up, but ngrok did not establish a tunnel." -ForegroundColor Red
        Write-Host ""
        & docker @composeArgs logs --tail 30 ngrok
        Write-Host ""
        Write-Host "  Common causes:" -ForegroundColor Yellow
        Write-Host "    - ERR_NGROK_105/106  bad authtoken in deploy-demo\.env.demo"
        Write-Host "    - domain not found   NGROK_DOMAIN is not a domain you have reserved"
        Write-Host "    - a traffic policy error, which ngrok only reports on connect."
        Write-Host "      Comment the actions out of deploy-demo\traffic-policy.yml,"
        Write-Host "      leaving 'on_http_request: []', and re-run this script."
        Write-Host ""
        exit 1
    }

    # ------------------------------------------------------------------ done --

    Write-Host ""
    Write-Host "  AutoOps is live." -ForegroundColor Green
    Write-Host ""
    Write-Host "    Public (share this)  $tunnelUrl"
    Write-Host "    Still local          http://localhost:5173"
    Write-Host "    Request inspector    http://127.0.0.1:4040"
    Write-Host ""
    if ($tunnelUrl -ne $publicUrl) {
        Write-Host "  Note: ngrok returned $tunnelUrl but the services were configured" -ForegroundColor Yellow
        Write-Host "  for $publicUrl. Make NGROK_DOMAIN match and re-run."
        Write-Host ""
    }
    Write-Host "  First visit from any browser shows ngrok's 'Visit Site' warning page" -ForegroundColor Yellow
    Write-Host "  (free plan - it cannot be turned off). One click and that browser is"
    Write-Host "  fine from then on. Click through it yourself before the call."
    Write-Host ""
    Write-Host "  Stop with:  .\deploy-demo\down.ps1"
    Write-Host ""
}
finally {
    Pop-Location
}
