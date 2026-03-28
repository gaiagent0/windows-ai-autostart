# Design Decisions — Why Each Choice Was Made

> Engineering rationale for non-obvious decisions in the autostart architecture.

---

## Decision 1 — No SYSTEM Context

**Problem:** Task Scheduler defaults suggest SYSTEM for boot tasks.

**Why SYSTEM fails:**
```
WSL2 launches as a Hyper-V VM tied to the interactive user session.
SYSTEM account has no interactive session token.
WSL2 API call returns: WSL_E_LOCAL_SYSTEM_NOT_SUPPORTED (0x80370101)
```

**Solution:** `LogonType = InteractiveToken` + `ONLOGON` trigger.
This binds the task to the user's logon session, which owns the WSL2 VM.

**Security implication:** The task runs with the user's full permissions.
If the user is an admin, the task gets elevated rights (`HighestAvailable` runlevel).
This is intentional — needed for Windows Firewall rule management.

---

## Decision 2 — XML-Based Delay, Not CLI

**Problem:** `schtasks /create ... /delay 0:00:45` appears to work but is silently ignored
for `ONLOGON` triggers. This is a documented-but-confusing Windows behavior.

**Reproduction:**
```cmd
schtasks /create /tn "Test" /tr "notepad.exe" /sc ONLOGON /delay 0:00:45
schtasks /query /tn "Test" /fo LIST /v
:: Output shows: Delay: disabled   ← delay was ignored
```

**Solution:** Define the task via XML with `<LogonTrigger><Delay>PT45S</Delay>`:
```xml
<LogonTrigger>
  <Delay>PT45S</Delay>   <!-- This works -->
</LogonTrigger>
```

**Verification:**
```cmd
schtasks /query /tn "AIStack-Autostart" /fo LIST /v | findstr "Delay"
:: Should show: Delay: PT45S
```

---

## Decision 3 — 45-Second Delay Calibration

**Boot sequence timing** (cold boot, Snapdragon X Elite X1E78100):

```
t=0s    ONLOGON trigger fires (user desktop appears)
t=10s   Windows shell stabilizes, tray icons load
t=20s   WSL2 Hyper-V VM starts (if not already running)
t=30s   WSL2 kernel + systemd init completes
t=38s   Docker daemon ready (systemd service, after init)
t=45s   Script starts — Docker is available ✅
```

**If delay < 30s:** Script calls `docker ps`, Docker not yet ready → spurious "container
not running" → `docker compose up -d` executes on an already-initializing stack →
duplicate container errors, port conflicts.

**If delay > 60s:** Unnecessary boot latency; no additional benefit.

**ARM64 note:** Snapdragon X Elite boots faster than x86 equivalents due to lower DRAM
latency. On older hardware, increase delay to 60–90s.

---

## Decision 4 — PowerShell 5.1, Not 7.x

**Problem:** Both work, but each has platform risks.

| | PS 5.1 (`powershell.exe`) | PS 7.x (`pwsh.exe`) |
|-|--------------------------|---------------------|
| Availability | Built-in, always present | Requires separate install |
| Path stability | `%SystemRoot%\System32\WindowsPowerShell\v1.0\` | Varies by install method |
| Task Scheduler compat | Native | Works but path must be verified |
| `Invoke-WebRequest` | Needs `-UseBasicParsing` (headless) | No flag needed |
| ARM64 support | ✅ | ✅ |

**Decision:** PS 5.1 for the Task Scheduler action — zero external dependency.
Users who prefer PS 7 can change the Command field in the XML.

**`-UseBasicParsing` requirement:** In headless/non-interactive contexts (Task Scheduler),
the IE engine is not available. Without this flag, `Invoke-WebRequest` throws:
`The response content cannot be parsed because the Internet Explorer engine is not available`.

---

## Decision 5 — Idempotent Container Start Logic

**Pattern used:**
```powershell
$running = docker ps --filter name=^/container-name$ --filter status=running -q
if ([string]::IsNullOrWhiteSpace($running)) {
    docker compose up -d
}
```

**Why `^/` prefix in filter:** Docker container name filter requires exact match with
leading `/`. Without the anchor, `^/open-webui$` → matches only exact name, not
`/other-open-webui-2`.

**Idempotency guarantee:** `docker compose up -d` is itself idempotent — it starts missing
containers and does nothing to running ones. The pre-check just avoids unnecessary Docker
API calls and log noise.

---

## Decision 6 — Log Rotation at 500 Lines

**Why not `Start-Transcript`:** Creates a new file per run — accumulates indefinitely.

**Why not external log management:** Over-engineering for a boot script.

**Implementation:**
```powershell
$lines = Get-Content $LogFile
if ($lines.Count -gt 500) {
    $lines | Select-Object -Last 250 | Set-Content $LogFile
}
```

Keeps the last 250 lines after truncation — preserves recent history across multiple boots
without unbounded growth. With 45-second boot interval and ~30 log lines per run, this
covers ~8 boots worth of history.

**`Add-Content` vs `Set-Content`:** `Add-Content` uses atomic appends (OS-level) — safe
for concurrent access. `Set-Content` in the rotation path is acceptable since rotation
only happens at startup (single-threaded context).

---

## Decision 7 — Non-Blocking Smoke Tests

HTTP smoke tests at the end are **non-blocking** — they warn but don't fail the script:

```powershell
try {
    Invoke-WebRequest -Uri $url -TimeoutSec 3 -UseBasicParsing
    Write-Log "OK"
} catch {
    Write-Log "WARN: not responding"  # does NOT throw
}
```

**Rationale:** A slow-starting service (e.g., Open WebUI JIT compilation on first run)
shouldn't cause the entire startup script to fail. The script's job is to *trigger*
all services, not to *guarantee* they're ready. Readiness is each service's own concern.

Port polling (`Wait-ForPort`) with timeout is used for services we actively start,
where we need to know "did it bind the port?" before proceeding.
