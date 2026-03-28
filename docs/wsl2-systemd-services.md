# WSL2 systemd User Services

> Services that run in WSL2 under `systemd --user` (NOT root systemd).  
> This is the correct pattern for user-owned long-running processes in WSL2.

---

## Critical Rule

```
✅ ALWAYS:  systemctl --user <command>
❌ NEVER:   sudo systemctl <command>   ← This targets ROOT systemd, not your services
```

Root systemd manages system services (Docker, networking).  
User systemd manages your services (LiteLLM, app servers).  
They are separate namespaces.

---

## Prerequisites

### 1. Enable systemd in WSL2

```bash
sudo tee /etc/wsl.conf << 'EOF'
[boot]
systemd=true
EOF
```

```powershell
# Windows side — restart WSL2
wsl --shutdown
# Wait 8 seconds
wsl -d Ubuntu-24.04
```

```bash
# Verify
systemctl --version
# systemd 255+ → confirmed
```

### 2. Enable user service persistence (lingering)

Without lingering, user services stop when you log out of WSL2:

```bash
# Enable lingering for your user
sudo loginctl enable-linger $USER

# Verify
loginctl show-user $USER | grep Linger
# Linger=yes
```

---

## Service File Location

User service files live at:
```
~/.config/systemd/user/   ← your service .service files
```

System service files (for reference — don't put yours here):
```
/etc/systemd/system/      ← root-owned, requires sudo
```

---

## Installing a Service

Example: LiteLLM proxy service.

```bash
# 1. Place service file
mkdir -p ~/.config/systemd/user
cp litellm-proxy.service ~/.config/systemd/user/

# 2. Reload daemon (required after adding/modifying service files)
systemctl --user daemon-reload

# 3. Enable (start automatically on WSL2 boot)
systemctl --user enable litellm-proxy

# 4. Start now
systemctl --user start litellm-proxy

# 5. Verify
systemctl --user status litellm-proxy
```

---

## Service Lifecycle Commands

```bash
# Status
systemctl --user status litellm-proxy

# Start / Stop / Restart
systemctl --user start   litellm-proxy
systemctl --user stop    litellm-proxy
systemctl --user restart litellm-proxy

# Enable / Disable autostart
systemctl --user enable  litellm-proxy
systemctl --user disable litellm-proxy

# View logs (last 50 lines, follow)
journalctl --user -u litellm-proxy -n 50 -f

# Check all user services at once
for svc in litellm-proxy openclaw-gateway bolt-diy; do
    state=$(systemctl --user is-active $svc 2>/dev/null || echo "not-found")
    printf "%-25s %s\n" "$svc" "$state"
done
```

---

## Service File Template

```ini
[Unit]
Description=My Service Description
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/path/to/binary --flag value

# Use %h for $HOME in service files
# ExecStart=%h/my-env/bin/myapp --config %h/myapp/config.yaml

WorkingDirectory=%h/myapp

Restart=on-failure
RestartSec=10

# Logging
StandardOutput=journal
StandardError=journal
SyslogIdentifier=my-service

[Install]
WantedBy=default.target
```

**Path variables in service files:**

| Variable | Expands to |
|----------|-----------|
| `%h` | User home directory (`$HOME`) |
| `%u` | Username |
| `%H` | Hostname |

---

## Automatic Start on Windows Boot

WSL2 systemd user services start automatically when WSL2 starts — **if lingering is
enabled**. The boot sequence is:

```
Windows boot
    └── Task Scheduler: start-ai-stack.ps1 (PT45S delay)
            └── wsl -d Ubuntu-24.04 (lazy init, triggers WSL2 start)
                    └── systemd boot
                            └── systemd --user (auto for lingering users)
                                    └── litellm-proxy, openclaw-gateway, etc.
```

No explicit WSL2 service start commands are needed in the PowerShell boot script —
WSL2 systemd handles this automatically once WSL2 is running.

---

## Troubleshooting User Services

### Service not found

```bash
# Check the file exists and has correct name
ls ~/.config/systemd/user/*.service

# Check systemd sees it after daemon-reload
systemctl --user list-unit-files | grep my-service
```

### Service fails to start

```bash
# Full status with error detail
systemctl --user status my-service --no-pager

# Full logs since last start attempt
journalctl --user -u my-service --since "10 minutes ago" --no-pager

# Common causes:
# 1. ExecStart path wrong (use absolute paths or %h)
# 2. Working directory doesn't exist
# 3. Port already in use
# 4. Python venv missing or binary not installed
```

### Service starts but immediately exits

```bash
# Check exit code
systemctl --user show my-service | grep ExecMainStatus
# ExecMainStatus=1 → non-zero exit, check logs

# Run ExecStart command manually to see error:
source ~/my-env/bin/activate
my-binary --config ~/myapp/config.yaml
# Error will be visible in terminal
```

### Lingering not working (services stop on WSL2 restart)

```bash
# Re-enable lingering
sudo loginctl enable-linger $USER
loginctl show-user $USER | grep Linger
# Must show: Linger=yes

# Also verify WSL2 systemd is enabled
cat /etc/wsl.conf | grep systemd
# Must show: systemd=true
```
