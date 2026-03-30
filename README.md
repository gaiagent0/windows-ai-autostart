# windows-ai-autostart

> **Reliable AI stack autostart for Windows 11 ARM64 + WSL2**  
> Task Scheduler · PowerShell 5.1 · systemd --user · Boot automation

[![Platform](https://img.shields.io/badge/platform-Windows%2011%20ARM64-blue)](https://docs.microsoft.com/en-us/windows/wsl/)
[![WSL2](https://img.shields.io/badge/WSL2-Ubuntu%2024.04-orange)](https://ubuntu.com/wsl)
[![License](https://img.shields.io/badge/license-MIT-green)](LICENSE)

---

## What This Is

Production-tested automation for starting a complete local AI stack on Windows 11 login.
Handles the non-obvious pitfalls of Task Scheduler + WSL2 interaction:

- **WSL2 ≠ SYSTEM account** — `WSL_E_LOCAL_SYSTEM_NOT_SUPPORTED` solved by design
- **`/delay` silently ignored** with ONLOGON trigger via CLI — solved with XML definition
- **Docker cold-start timing** — 45-second delay calibrated to Snapdragon X Elite boot sequence
- **Container health checks** — idempotent, safe to re-run on already-running stack
- **Log rotation** — auto-truncates at 500 lines, no unbounded growth

---

## Architecture

```
Windows Boot
    │
    ├── Task Scheduler: AIStack-Autostart
    │   Trigger:  ONLOGON, PT45S delay
    │   Principal: VIVO2\gaiagent0, InteractiveToken, HighestAvailable
    │   Action:  powershell.exe -File start-ai-stack.ps1
    │       │
    │       ├── 1. WSL2 ready check (lazy init if needed)
    │       ├── 2. Docker service health + auto-start
    │       ├── 3. Container health ×4 (docker compose up -d if down)
    │       ├── 4. GenieAPIService NPU (port 8912, 90s polling)
    │       ├── 5. Open WebUI (port 8080, 150s polling)
    │       └── 6. HTTP smoke tests (non-blocking)
    │
    └── WSL2 systemd --user (automatic, parallel)
        ├── litellm-proxy.service  :4000
        ├── openclaw-gateway.service :18789
        └── bolt-diy.service :5173
```

**Critical design decisions explained in [docs/design-decisions.md](docs/design-decisions.md).**

---

## Quick Start

### 1. Prepare directories

```powershell
New-Item -ItemType Directory -Path "C:\AI\scripts" -Force
New-Item -ItemType Directory -Path "C:\AI\logs"    -Force
```

### 2. Copy scripts

```powershell
Copy-Item scripts\start-ai-stack.ps1 C:\AI\scripts\
Copy-Item task-scheduler\AIStack-Autostart.xml C:\AI\scripts\
```

### 3. Edit script — set your paths

```powershell
notepad C:\AI\scripts\start-ai-stack.ps1
# Edit the $Config section at the top of the file
```

### 4. Register Task Scheduler task

```cmd
:: Run as Administrator
schtasks /create /tn "AIStack-Autostart" /xml "C:\AI\scripts\AIStack-Autostart.xml" /f

:: Verify
schtasks /query /tn "AIStack-Autostart" /fo LIST /v
```

Expected output:
```
Status:          Ready
Logon Mode:      Interactive only
Run As User:     gaiagent0
Schedule Type:   At logon time
```

### 5. Test without rebooting

```cmd
schtasks /run /tn "AIStack-Autostart"
```

```powershell
Start-Sleep 20
Get-Content "C:\AI\logs\stack-startup.log" -Tail 30
```

---

## Files

```
windows-ai-autostart/
├── README.md
├── scripts/
│   └── start-ai-stack.ps1              ← Main boot script (PS 5.1)
├── task-scheduler/
│   └── AIStack-Autostart.xml           ← Task definition (UTF-16 LE BOM required)
└── docs/
    ├── design-decisions.md             ← Why each decision was made
    ├── troubleshooting.md              ← Diagnostic runbook
    └── wsl2-systemd-services.md        ← WSL2 user service setup
```

---

## Compatibility

| Component | Requirement | Notes |
|-----------|------------|-------|
| Windows | 11 24H2 ARM64 | Also works on x64 with path edits |
| PowerShell | 5.1 (`powershell.exe`) | Not `pwsh.exe` — Task Scheduler compatibility |
| WSL2 | Ubuntu 22.04 / 24.04 | systemd must be enabled |
| Docker | Engine (not Desktop) | Via WSL2 systemd |

---

## Related Repositories

| Repo | Description |
|------|-------------|
| [snapdragon-ai-stack](https://github.com/gaiagent0/snapdragon-ai-stack) | Full stack setup guide |
| [litellm-local-config](https://github.com/gaiagent0/litellm-local-config) | LiteLLM proxy config |
