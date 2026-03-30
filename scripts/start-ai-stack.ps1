#Requires -Version 5.1
<#
.SYNOPSIS
    AI Stack autostart script for Windows 11 ARM64 + WSL2.

.DESCRIPTION
    Starts and health-checks the full local AI stack on Windows login.
    Designed for Task Scheduler: ONLOGON trigger, 45s delay, HighestAvailable.

    Components managed:
      - WSL2 Ubuntu readiness
      - Docker Engine in WSL2
      - Docker containers (open-webui, searxng, chromadb, n8n)
      - GenieAPIService (NPU inference, optional)
      - Open WebUI (Windows-native, uvx)

.NOTES
    PowerShell: 5.1 only (powershell.exe, NOT pwsh.exe)
    Reason:     Task Scheduler compatibility on all Windows 11 editions

    IMPORTANT: Run as the user who owns the WSL2 session.
               SYSTEM account is NOT compatible with WSL2.

    Autostart via Task Scheduler XML:
      schtasks /create /tn "AIStack-Autostart" /xml AIStack-Autostart.xml /f

.LINK
    https://github.com/gaiagent0/windows-ai-autostart
#>

# ─────────────────────────────────────────────────────────────────────────────
# CONFIGURATION — Edit this section for your environment
# ─────────────────────────────────────────────────────────────────────────────
$Config = @{
    # Log file path — auto-rotates at LogMaxLines
    LogFile     = "C:\AI\logs\stack-startup.log"
    LogMaxLines = 500

    # WSL2 distribution name
    WslDistro   = "Ubuntu-24.04"

    # Docker compose directories (WSL2 paths, using /mnt/c/ mount)
    # Translate: C:\AI\docker\ → /mnt/c/AI/docker/
    DockerComposeDir = "/mnt/c/AI/docker"

    # Containers to health-check and start if down
    # Format: @{ Name = "container-name"; ComposeDir = "/wsl2/path/to/compose" }
    Containers  = @(
        @{ Name = "open-webui"; ComposeDir = "/mnt/c/AI/docker/openwebui" }
        @{ Name = "searxng";    ComposeDir = "/mnt/c/AI/docker/searxng" }
        @{ Name = "chromadb";   ComposeDir = "/mnt/c/AI/docker/chromadb" }
        @{ Name = "n8n";        ComposeDir = "/mnt/c/AI/docker/n8n"; EnvFile = ".env" }
    )

    # GenieAPIService (NPU) — set $null to skip
    GenieService = @{
        Enabled    = $true
        Exe        = "C:\AI\GenieAPIService_cpp\GenieAPIService.exe"
        WorkingDir = "C:\AI\GenieAPIService_cpp"
        Args       = "-c models\llama3.1-8b-8380-qnn2.38\config.json -l -d 3 -p 8912"
        Port       = 8912
        MaxWaitSec = 90
    }

    # Open WebUI (Windows-native, uvx)
    OpenWebUI = @{
        Enabled    = $true
        # Path to uvx.exe — adjust to your Python install location
        UvxPath    = "$env:USERPROFILE\.local\bin\uvx.exe"
        DataDir    = "C:\AI\openwebui"
        Port       = 8080
        MaxWaitSec = 150
    }

    # HTTP smoke tests (non-blocking — failure only warns, doesn't abort)
    SmokeTests  = @(
        @{ Name = "Ollama";       URL = "http://127.0.0.1:11434/" }
        @{ Name = "Open WebUI";   URL = "http://127.0.0.1:8080/" }
        @{ Name = "GenieAPIService"; URL = "http://127.0.0.1:8912/v1/models" }
    )
}

# ─────────────────────────────────────────────────────────────────────────────
# LOGGING
# ─────────────────────────────────────────────────────────────────────────────
function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $ts   = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $line = "[$ts] [$Level] $Message"
    Add-Content -Path $Config.LogFile -Value $line -Encoding UTF8
    Write-Host $line
}

function Rotate-Log {
    if (Test-Path $Config.LogFile) {
        $lines = Get-Content $Config.LogFile
        if ($lines.Count -gt $Config.LogMaxLines) {
            $lines | Select-Object -Last ($Config.LogMaxLines / 2) |
                Set-Content $Config.LogFile -Encoding UTF8
            Write-Log "Log rotated (was $($lines.Count) lines)" "INFO"
        }
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# UTILITIES
# ─────────────────────────────────────────────────────────────────────────────
function Wait-ForPort {
    param([int]$Port, [int]$MaxWaitSec = 60, [string]$ServiceName = "Service")
    $deadline = (Get-Date).AddSeconds($MaxWaitSec)
    Write-Log "Waiting for $ServiceName on port $Port (max ${MaxWaitSec}s)..."
    while ((Get-Date) -lt $deadline) {
        try {
            $tcp = New-Object System.Net.Sockets.TcpClient
            $tcp.Connect("127.0.0.1", $Port)
            $tcp.Close()
            Write-Log "$ServiceName is UP on port $Port"
            return $true
        } catch {
            Start-Sleep -Seconds 3
        }
    }
    Write-Log "$ServiceName did NOT respond on port $Port after ${MaxWaitSec}s" "WARN"
    return $false
}

function Invoke-Wsl {
    param([string]$Command, [string]$User = "")
    $userArg = if ($User) { "-u $User" } else { "" }
    $result  = wsl -d $Config.WslDistro $userArg -- bash -c $Command 2>$null
    return $result
}

# ─────────────────────────────────────────────────────────────────────────────
# STEP 1 — Initialize
# ─────────────────────────────────────────────────────────────────────────────
$null = New-Item -ItemType Directory -Path (Split-Path $Config.LogFile) -Force
Rotate-Log
Write-Log "=== AI Stack Startup ==="
Write-Log "User: $env:USERNAME | PID: $PID | Host: $env:COMPUTERNAME"

# ─────────────────────────────────────────────────────────────────────────────
# STEP 2 — WSL2 Ready Check
# ─────────────────────────────────────────────────────────────────────────────
Write-Log "--- WSL2 Ready Check ---"
$running = wsl --list --running 2>$null
if ($running -notmatch $Config.WslDistro) {
    Write-Log "$($Config.WslDistro) not running — triggering lazy init..."
    # Lazy init: run a no-op to start WSL2
    wsl -d $Config.WslDistro -- bash -c "echo WSL2-ready" 2>$null | Out-Null
    Start-Sleep -Seconds 8
    Write-Log "WSL2 init triggered"
} else {
    Write-Log "WSL2 already running"
}

# ─────────────────────────────────────────────────────────────────────────────
# STEP 3 — Docker Service
# ─────────────────────────────────────────────────────────────────────────────
Write-Log "--- Docker Service Check ---"
$dockerActive = Invoke-Wsl "systemctl is-active docker 2>/dev/null || service docker status 2>/dev/null | grep -c 'is running'"

if ($dockerActive -notmatch "active|1") {
    Write-Log "Docker not running — starting..." "WARN"
    Invoke-Wsl "sudo service docker start" -User "root"
    Start-Sleep -Seconds 10
    Write-Log "Docker start attempted"
} else {
    Write-Log "Docker is running"
}

# ─────────────────────────────────────────────────────────────────────────────
# STEP 4 — Container Health (idempotent)
# ─────────────────────────────────────────────────────────────────────────────
Write-Log "--- Container Health Check ---"
foreach ($container in $Config.Containers) {
    $name   = $container.Name
    $cdir   = $container.ComposeDir
    $envArg = if ($container.EnvFile) { "--env-file $($container.EnvFile)" } else { "" }

    $running = Invoke-Wsl "docker ps --filter name=^/${name}$ --filter status=running -q 2>/dev/null"

    if ([string]::IsNullOrWhiteSpace($running)) {
        Write-Log "$name not running — starting..." "WARN"
        Invoke-Wsl "cd $cdir && docker compose $envArg up -d 2>&1"
        Write-Log "$name started"
    } else {
        Write-Log "$name is running (ID: $($running.Trim()))"
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# STEP 5 — GenieAPIService (NPU)
# ─────────────────────────────────────────────────────────────────────────────
if ($Config.GenieService.Enabled) {
    Write-Log "--- GenieAPIService (NPU) ---"
    $genie = $Config.GenieService

    # Check if already running
    $proc = Get-Process -Name "GenieAPIService" -ErrorAction SilentlyContinue
    if ($proc) {
        Write-Log "GenieAPIService already running (PID: $($proc.Id))"
    } elseif (Test-Path $genie.Exe) {
        Write-Log "Starting GenieAPIService..."
        Start-Process `
            -FilePath      $genie.Exe `
            -ArgumentList  $genie.Args `
            -WorkingDirectory $genie.WorkingDir `
            -WindowStyle   Hidden `
            -NoNewWindow

        $up = Wait-ForPort -Port $genie.Port -MaxWaitSec $genie.MaxWaitSec -ServiceName "GenieAPIService"
        if (-not $up) {
            Write-Log "GenieAPIService failed to start within $($genie.MaxWaitSec)s" "WARN"
        }
    } else {
        Write-Log "GenieAPIService.exe not found at $($genie.Exe) — skipping" "WARN"
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# STEP 6 — Open WebUI (Windows-native, uvx)
# ─────────────────────────────────────────────────────────────────────────────
if ($Config.OpenWebUI.Enabled) {
    Write-Log "--- Open WebUI ---"
    $webui = $Config.OpenWebUI

    # Check if port is already listening
    try {
        $tcp = New-Object System.Net.Sockets.TcpClient
        $tcp.Connect("127.0.0.1", $webui.Port)
        $tcp.Close()
        Write-Log "Open WebUI already running on port $($webui.Port)"
    } catch {
        if (Test-Path $webui.UvxPath) {
            Write-Log "Starting Open WebUI..."
            $env:DATA_DIR = $webui.DataDir
            Start-Process `
                -FilePath     $webui.UvxPath `
                -ArgumentList "--python 3.11 open-webui serve" `
                -WindowStyle  Hidden `
                -NoNewWindow

            $up = Wait-ForPort -Port $webui.Port -MaxWaitSec $webui.MaxWaitSec -ServiceName "Open WebUI"
            if (-not $up) {
                Write-Log "Open WebUI failed to start within $($webui.MaxWaitSec)s" "WARN"
            }
        } else {
            Write-Log "uvx.exe not found at $($webui.UvxPath) — skipping" "WARN"
        }
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# STEP 7 — HTTP Smoke Tests (non-blocking)
# ─────────────────────────────────────────────────────────────────────────────
Write-Log "--- HTTP Smoke Tests ---"
foreach ($test in $Config.SmokeTests) {
    try {
        $r = Invoke-WebRequest -Uri $test.URL -TimeoutSec 3 -UseBasicParsing -EA Stop
        Write-Log "$($test.Name): HTTP $($r.StatusCode) OK"
    } catch {
        Write-Log "$($test.Name): not responding at $($test.URL)" "WARN"
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# DONE
# ─────────────────────────────────────────────────────────────────────────────
Write-Log "=== Startup complete ==="
