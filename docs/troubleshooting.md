# Troubleshooting — windows-ai-autostart

---

## Diagnostic Checklist (Start Here)

```powershell
# 1. Is the task registered?
schtasks /query /tn "AIStack-Autostart" /fo LIST /v | Select-String "Status|Logon|Run As"

# 2. What did the last run produce?
Get-Content "C:\AI\logs\stack-startup.log" -Tail 40

# 3. What was the last exit code?
Get-WinEvent -LogName "Microsoft-Windows-TaskScheduler/Operational" -MaxEvents 20 |
    Where-Object { $_.Id -eq 201 -and $_.Message -match "AIStack" } |
    Select-Object -First 1 TimeCreated, Message | Format-List
```

---

## Issue: Log file not created

**Cause A:** Script path in XML doesn't match actual path.

```powershell
# Verify the path Task Scheduler sees
schtasks /query /tn "AIStack-Autostart" /fo LIST /v | Select-String "Task To Run"
# Compare with: Test-Path "C:\AI\scripts\start-ai-stack.ps1"
```

**Cause B:** Script fails before log directory is created.

```powershell
# Run the script directly (bypasses Task Scheduler)
powershell.exe -ExecutionPolicy Bypass -NonInteractive `
    -File "C:\AI\scripts\start-ai-stack.ps1"
# Watch for immediate error output
```

**Cause C:** Log directory doesn't exist and creation fails (permissions).

```powershell
# Manual creation test
New-Item -ItemType Directory -Path "C:\AI\logs" -Force
[System.IO.File]::WriteAllText("C:\AI\logs\test.txt", "write-test")
Test-Path "C:\AI\logs\test.txt"   # Must be True
Remove-Item "C:\AI\logs\test.txt"
```

---

## Issue: Task registered but never runs

**Check 1 — Task status:**
```cmd
schtasks /query /tn "AIStack-Autostart" /fo LIST /v
:: Look for: Status = Ready (not Disabled)
```

**Check 2 — Username match:**
The `<UserId>` in the XML must exactly match your Windows account name.

```powershell
# Get your exact account format
whoami
# Output example: vivo2\istva
# XML must have: <UserId>VIVO2\istva</UserId>
```

**Check 3 — XML encoding:**
The XML must be UTF-16 LE with BOM. Verify:

```powershell
$bytes = [System.IO.File]::ReadAllBytes("C:\AI\scripts\AIStack-Autostart.xml")
"BOM bytes: 0x{0:X2} 0x{1:X2}" -f $bytes[0], $bytes[1]
# Expected: BOM bytes: 0xFF 0xFE
# If different: re-save with correct encoding
```

Re-save with correct encoding:
```powershell
$content = Get-Content "C:\AI\scripts\AIStack-Autostart.xml" -Raw
[System.IO.File]::WriteAllText(
    "C:\AI\scripts\AIStack-Autostart.xml",
    $content,
    [System.Text.Encoding]::Unicode   # Unicode = UTF-16 LE in .NET
)
```

**Check 4 — TaskScheduler Operational log** (disabled by default on Windows Home):

```powershell
# Enable
wevtutil sl "Microsoft-Windows-TaskScheduler/Operational" /e:true

# Relevant Event IDs:
# 100 = Task instance started
# 110 = Task triggered
# 129 = Process created (includes PID)
# 200 = Action started
# 201 = Action completed (includes return code!)
# 102 = Task instance completed

Get-WinEvent -LogName "Microsoft-Windows-TaskScheduler/Operational" -MaxEvents 20 |
    Where-Object { $_.Message -match "AIStack" } |
    Select-Object TimeCreated, Id, Message | Format-List
```

---

## Issue: Task runs, WSL2 part fails

**Symptom in log:**
```
[WARN] Ubuntu-24.04 not running — triggering lazy init...
```
followed by Docker errors.

**Root cause:** WSL2 not started yet at t=45s. Increase delay.

```powershell
# Edit the XML: change PT45S to PT60S or PT90S
notepad "C:\AI\scripts\AIStack-Autostart.xml"
# Find: <Delay>PT45S</Delay>
# Change to: <Delay>PT90S</Delay>

# Reimport
schtasks /create /tn "AIStack-Autostart" /xml "C:\AI\scripts\AIStack-Autostart.xml" /f
```

**Verify WSL2 start time** (measure on your machine):
```powershell
$start = Get-Date
wsl -d Ubuntu-24.04 -- bash -c "echo ready"
$elapsed = (Get-Date) - $start
Write-Host "WSL2 cold start: $($elapsed.TotalSeconds)s"
# Add 10s buffer → this is your minimum delay
```

---

## Issue: Docker containers not starting

**Symptom in log:**
```
[WARN] open-webui not running — starting...
[WARN] docker compose up failed
```

**Check 1 — Docker path:**
```powershell
# Verify the WSL2 path exists
wsl -d Ubuntu-24.04 -- bash -c "ls /mnt/c/AI/docker/openwebui/docker-compose.yml"
# Must output: /mnt/c/AI/docker/openwebui/docker-compose.yml
```

**Check 2 — Docker running in WSL2:**
```powershell
wsl -d Ubuntu-24.04 -- bash -c "docker ps"
# If error: Docker not running
wsl -d Ubuntu-24.04 -u root -- bash -c "service docker start"
Start-Sleep 10
wsl -d Ubuntu-24.04 -- bash -c "docker ps"
```

**Check 3 — Docker group membership:**
```bash
# In WSL2
groups $USER | grep docker
# If docker not listed:
sudo usermod -aG docker $USER
# Log out of WSL2 session and back in
```

---

## Issue: GenieAPIService not starting

**Check 1 — File exists:**
```powershell
Test-Path "C:\AI\GenieAPIService_cpp\GenieAPIService.exe"
Test-Path "C:\AI\GenieAPIService_cpp\QnnHtp.dll"
```

**Check 2 — Manual start:**
```powershell
cd C:\AI\GenieAPIService_cpp
.\GenieAPIService.exe -c models\llama3.1-8b-8380-qnn2.38\config.json -l -d 3 -p 8912
# Watch the console — NPU load errors appear here
```

**Check 3 — Port conflict:**
```powershell
netstat -ano | findstr ":8912"
# If another process is on 8912:
Get-Process -Id <PID-from-netstat> | Stop-Process -Force
```

---

## Issue: Task runs as wrong user / elevation missing

**Symptom:** Firewall rule errors, "Access denied" in log.

**Check:**
```powershell
# Is the configured user an admin?
whoami /groups | Select-String "S-1-5-32-544"
# S-1-5-32-544 = Administrators group
# If not found: user is not an admin → HighestAvailable = NOT elevated
```

**Fix options:**
1. Add user to Administrators group (preferred for homelab)
2. Remove firewall rule creation from script (if elevation not needed)
3. Change `RunLevel` to `LeastPrivilege` if elevation is truly not needed

---

## Useful Commands Reference

```cmd
:: Register task from XML
schtasks /create /tn "AIStack-Autostart" /xml "C:\AI\scripts\AIStack-Autostart.xml" /f

:: Query task details
schtasks /query /tn "AIStack-Autostart" /fo LIST /v

:: Manual trigger (for testing without reboot)
schtasks /run /tn "AIStack-Autostart"

:: Stop a running instance
schtasks /end /tn "AIStack-Autostart"

:: Delete task
schtasks /delete /tn "AIStack-Autostart" /f

:: View last 40 log lines
powershell -c "Get-Content C:\AI\logs\stack-startup.log -Tail 40"

:: Enable TaskScheduler operational log (for Event ID debugging)
wevtutil sl "Microsoft-Windows-TaskScheduler/Operational" /e:true
```
