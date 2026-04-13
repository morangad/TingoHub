# ─────────────────────────────────────────────────────────────────────────────
# manage.ps1 — Windows equivalent of manage.sh
# Usage: .\manage.ps1 [up|down|reset|logs [service]|status|ip|psql]
# ─────────────────────────────────────────────────────────────────────────────
param(
    [Parameter(Position=0)] [string]$Action  = "up",
    [Parameter(Position=1)] [string]$Service = ""
)

$ErrorActionPreference = "Stop"

# Load .env into the current process
if (Test-Path ".env") {
    Get-Content ".env" | Where-Object { $_ -and $_ -notmatch '^\s*#' } | ForEach-Object {
        $name, $value = $_ -split '=', 2
        if ($name -and $value) {
            Set-Item -Path "Env:$($name.Trim())" -Value $value.Trim()
        }
    }
}

$GrafanaPort = if ($env:GRAFANA_PORT) { $env:GRAFANA_PORT } else { "3000" }
$DbUser      = if ($env:DB_USER)      { $env:DB_USER }      else { "tsdbadmin" }
$DbName      = if ($env:DB_NAME)      { $env:DB_NAME }      else { "metrics" }

function Print-Urls {
    $ip = (Get-NetIPAddress -AddressFamily IPv4 `
              | Where-Object { $_.PrefixOrigin -eq 'Dhcp' -or $_.PrefixOrigin -eq 'Manual' } `
              | Select-Object -First 1).IPAddress
    if (-not $ip) { $ip = "YOUR_LAN_IP" }
    Write-Host ""
    Write-Host "  Grafana:      http://${ip}:${GrafanaPort}"
    Write-Host "  TimescaleDB:  ${ip}:5432  (user: $DbUser, db: $DbName)"
    Write-Host ""
}

switch ($Action) {
    "up" {
        Write-Host "Starting stack..."
        docker compose up -d --build
        Start-Sleep -Seconds 8
        docker compose ps
        Print-Urls
    }
    "down"   { docker compose down }
    "reset"  {
        Write-Host "WARNING: Resetting stack — ALL DATA WILL BE DELETED. Ctrl-C to abort."
        Start-Sleep -Seconds 5
        docker compose down -v --remove-orphans
    }
    "logs"   { docker compose logs -f --tail=100 $Service }
    "status" { docker compose ps; Print-Urls }
    "ip"     { Print-Urls }
    "psql"   { docker compose exec timescaledb psql -U $DbUser -d $DbName }
    default  { Write-Host "Usage: .\manage.ps1 [up|down|reset|logs [service]|status|ip|psql]" }
}
