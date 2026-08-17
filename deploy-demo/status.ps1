<#
    Is the demo actually going to work? Run this before you share the link.

        .\deploy-demo\status.ps1

    Exists because the overlay is silently reversible. A bare

        docker compose up -d

    run from the repo root uses ONLY docker-compose.yml, so it recreates
    auth-service, api-gateway, core-service, plugin-service and the frontend
    with their plain localhost settings — dropping the CORS origin, the trusted
    proxy range, the console deep-link base and the nginx config.

    Nothing looks broken when that happens. The tunnel stays up, the page still
    loads, and the only symptom is that login starts returning
    403 "Invalid CORS request" for everyone on the public URL.

    This script catches exactly that, plus the obvious outages, and finishes by
    actually posting a login through the tunnel to prove it end to end.

    Fix for anything it reports: .\deploy-demo\up.ps1
#>

$ErrorActionPreference = "Stop"

$repoRoot = Split-Path -Parent $PSScriptRoot
$envRoot  = Join-Path $repoRoot ".env"

if (-not (Test-Path $envRoot)) {
    Write-Host "  The root .env is missing - run up.ps1 first." -ForegroundColor Red
    exit 1
}

$domain      = $null
$composeFile = $null
foreach ($line in (Get-Content $envRoot)) {
    $t = $line.Trim()
    if ($t -like "NGROK_DOMAIN=*") { $domain      = $t.Substring("NGROK_DOMAIN=".Length).Trim() }
    if ($t -like "COMPOSE_FILE=*") { $composeFile = $t.Substring("COMPOSE_FILE=".Length).Trim() }
}
if (-not $domain) {
    Write-Host "  NGROK_DOMAIN is not set in .env." -ForegroundColor Red
    exit 1
}
$publicUrl = "https://$domain"

$failures = 0
function Report($ok, $label, $detail) {
    if ($ok) {
        Write-Host ("  [ ok ] " + $label) -ForegroundColor Green
    }
    else {
        Write-Host ("  [FAIL] " + $label) -ForegroundColor Red
        if ($detail) { Write-Host ("         " + $detail) -ForegroundColor DarkGray }
        $script:failures++
    }
}

# Reads one variable out of a running container's process environment.
function Get-ContainerEnv($container, $name) {
    try {
        $envLines = & docker exec $container env
        foreach ($l in $envLines) {
            if ($l -like "$name=*") { return $l.Substring($name.Length + 1) }
        }
    } catch { }
    return $null
}

Push-Location $repoRoot
try {
    Write-Host ""
    Write-Host "  Checking the demo at $publicUrl" -ForegroundColor Cyan
    Write-Host ""

    # ---- containers ----
    $expected = @("mysql","redis","auth-service","subscription-service","job-service",
                  "core-service","workflow-service","agent-service","plugin-service",
                  "voice-agent","api-gateway","frontend","ngrok")
    $running = @{}
    foreach ($row in (& docker ps --filter "name=autoops-" --format "{{.Names}}|{{.Status}}")) {
        $parts = $row -split "\|", 2
        $svc = $parts[0] -replace "^autoops-", "" -replace "-1$", ""
        $running[$svc] = $parts[1]
    }
    $missing = @($expected | Where-Object { -not $running.ContainsKey($_) })
    Report ($missing.Count -eq 0) "all 13 containers running" ("missing: " + ($missing -join ", "))

    $unhealthy = @()
    foreach ($k in $running.Keys) { if ($running[$k] -match "unhealthy|health: starting") { $unhealthy += $k } }
    Report ($unhealthy.Count -eq 0) "no container unhealthy or still starting" ("not ready: " + ($unhealthy -join ", "))

    # ---- the guard that stops the overlay being reverted at all ----
    Report ($composeFile -and $composeFile.Contains("docker-compose.demo.yml")) `
        "COMPOSE_FILE in .env pins the overlay" `
        "without this, any plain 'docker compose up -d' reverts everything below"

    # ---- the overlay actually applied ----
    # This is the check that matters. Everything else can look perfect while
    # these are silently missing.
    $authCors = Get-ContainerEnv "autoops-auth-service-1" "AUTOOPS_AUTH_CORS_ALLOWEDORIGINS"
    Report ($authCors -and $authCors.Contains($domain)) `
        "auth-service CORS allows $domain" `
        "OVERLAY LOST - login will 403. auth-service's application-dev.yml hardcodes localhost."

    $gwCors = Get-ContainerEnv "autoops-api-gateway-1" "CORS_ALLOWED_ORIGINS"
    Report ($gwCors -and $gwCors.Contains($domain)) "api-gateway CORS allows $domain" "overlay lost"

    $trusted = Get-ContainerEnv "autoops-auth-service-1" "TRUSTED_PROXIES"
    Report ($trusted -eq "172.16.0.0/12") `
        "auth-service trusts the proxy chain" `
        "overlay lost - every visitor shares ONE rate-limit bucket (10 logins total)"

    foreach ($svc in @("core-service","plugin-service")) {
        $console = Get-ContainerEnv "autoops-$svc-1" "CONSOLE_BASE_URL"
        Report ($console -eq $publicUrl) "$svc deep links point at the tunnel" "overlay lost"
    }

    $mount = (& docker inspect autoops-frontend-1 --format '{{range .Mounts}}{{.Source}}{{end}}')
    Report ($mount -and $mount.EndsWith("nginx.demo.conf")) "frontend serving nginx.demo.conf" "overlay lost"

    # ---- the tunnel ----
    $tunnelUrl = $null
    try {
        $api = Invoke-RestMethod -Uri "http://127.0.0.1:4040/api/tunnels" -TimeoutSec 5
        if ($api.tunnels -and $api.tunnels.Count -gt 0) { $tunnelUrl = $api.tunnels[0].public_url }
    } catch { }
    Report ($tunnelUrl -eq $publicUrl) "ngrok tunnel serving $publicUrl" ("agent reports: " + $tunnelUrl)

    # ---- prove it end to end ----
    # Deliberately bad credentials: 401 means the endpoint is reachable and
    # processing normally. 403 is the CORS rejection this script exists to catch.
    $loginStatus = 0
    try {
        $resp = Invoke-WebRequest -Uri "$publicUrl/api/auth/login" -Method POST -UseBasicParsing `
            -Headers @{ "Origin" = $publicUrl; "ngrok-skip-browser-warning" = "1" } `
            -ContentType "application/json" `
            -Body '{"email":"status-probe@example.com","password":"deliberately-wrong"}' `
            -TimeoutSec 20
        $loginStatus = $resp.StatusCode
    }
    catch {
        if ($_.Exception.Response) { $loginStatus = [int]$_.Exception.Response.StatusCode }
    }
    Report ($loginStatus -eq 401) `
        "live login probe through the tunnel (expect 401)" `
        "got $loginStatus - 403 means CORS is rejecting the public origin"

    # ---- optional extras ----
    Write-Host ""
    $difyKey = Get-ContainerEnv "autoops-core-service-1" "DIFY_API_KEY"
    if ($difyKey) {
        Write-Host "  [ ok ] DIFY_API_KEY is set - the workflow designer should load" -ForegroundColor Green
    }
    else {
        Write-Host "  [note] DIFY_API_KEY is empty - the workflow designer will show" -ForegroundColor Yellow
        Write-Host "         'Dify is not connected'. Not a demo blocker unless you plan"
        Write-Host "         to show workflow authoring. See README.md."
    }

    # ---- verdict ----
    Write-Host ""
    if ($failures -eq 0) {
        Write-Host "  Ready to demo." -ForegroundColor Green
        Write-Host "  Share: $publicUrl"
        Write-Host ""
        exit 0
    }
    Write-Host "  $failures check(s) failed. Fix with:  .\deploy-demo\up.ps1" -ForegroundColor Red
    Write-Host ""
    exit 1
}
finally {
    Pop-Location
}
