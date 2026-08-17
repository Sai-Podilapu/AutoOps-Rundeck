<#
    Takes AutoOps off the public URL.

        .\deploy-demo\down.ps1          # close the tunnel, keep running on localhost
        .\deploy-demo\down.ps1 -All     # stop the whole stack as well

    The default reverts the stack to its plain localhost configuration and drops
    the ngrok container, so http://localhost:5173 keeps working exactly as it did
    before you ever ran up.ps1.

    Neither path passes -v to compose, so the MySQL volume - and the Intertec
    demo data in it - is never touched.
#>

param(
    [switch]$All
)

$ErrorActionPreference = "Stop"

$repoRoot = Split-Path -Parent $PSScriptRoot

Push-Location $repoRoot
try {
    if ($All) {
        Write-Host ""
        Write-Host "  Stopping the whole stack..." -ForegroundColor Cyan
        & docker compose `
            -f docker-compose.yml `
            -f deploy-demo/docker-compose.demo.yml `
            down
        if ($LASTEXITCODE -ne 0) { exit 1 }

        Write-Host ""
        Write-Host "  Stopped. Bring it back with .\deploy-demo\up.ps1 (public)" -ForegroundColor Green
        Write-Host "  or 'docker compose up -d' (localhost only)."
        Write-Host ""
    }
    else {
        # Running the base file alone recreates the services the overlay had
        # rewritten - CORS, CONSOLE_BASE_URL, the nginx mount - back to their
        # localhost defaults. ngrok is not in the base file, so --remove-orphans
        # is what actually closes the tunnel.
        #
        # The explicit -f is load-bearing now: .env sets COMPOSE_FILE to both
        # files, and an explicit -f is what overrides it. This is the ONE place
        # reverting the overlay is the intent rather than an accident.
        Write-Host ""
        Write-Host "  Closing the tunnel and reverting to the localhost stack..." -ForegroundColor Cyan
        & docker compose -f docker-compose.yml up -d --remove-orphans
        if ($LASTEXITCODE -ne 0) { exit 1 }

        Write-Host ""
        Write-Host "  Tunnel closed. AutoOps is running on http://localhost:5173 only." -ForegroundColor Green
        Write-Host ""
    }
}
finally {
    Pop-Location
}
