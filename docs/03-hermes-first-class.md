# 03 — Hermes as a First-Class Citizen

[Hermes](https://hermes-agent.nousresearch.com) is a personal AI agent: it answers on
Telegram, runs cron jobs, delegates to subagents, keeps memory and skills, and can drive
the whole box. On an old Mac you want it to behave like a **server service** — up at
boot, reachable headless, surviving reboots without a login. This doc is the
first-class-citizen recipe.

## The trap: user-scope services that wait for login

Hermes' gateway is normally installed as a **user-scope** systemd service
(`~/.config/systemd/user/hermes-gateway.service`). User services only run while the
user manager is alive — and on a headless box the user manager (`user@1000.service`)
may not start until someone logs in at the greeter, *even with lingering enabled*.
Net effect: no login → no agent. (Compounded by the boot-blocker bug in
[`02-power-fixes.md`](02-power-fixes.md) — the box was also asleep.)

On this hardware, `loginctl enable-linger` + a user-boot oneshot + a runtime-dir
pre-provisioning dance still failed three separate greeter tests. The reliable fix:
**run the stack at system scope**.

## The fix: system-scope units

Create system services that run as the user but start with `multi-user.target`:

```ini
# /etc/systemd/system/hermes-gateway.service
[Unit]
Description=Hermes Agent Gateway - Messaging Platform Integration
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=YOURUSER
ExecStart=/home/YOURUSER/.hermes/hermes-agent/venv/bin/python -m hermes_cli.main gateway run
WorkingDirectory=/home/YOURUSER/.hermes
Environment="PATH=/home/YOURUSER/.hermes/hermes-agent/venv/bin:/usr/local/bin:/usr/bin:/bin"
Environment="HERMES_HOME=/home/YOURUSER/.hermes"
Environment="HERMES_CRON_TIMEOUT=600"
Environment="HERMES_TIMEZONE=Asia/Seoul"
Restart=always
RestartSec=5
KillMode=mixed
KillSignal=SIGTERM
```

Do the same for the siblings (dashboard, bus, health endpoint), then:

```bash
sudo systemctl enable --now hermes-gateway.service cortex-bus.service \
  hermes-cortex-dashboard.service health-vector.service
```

## The double-start trap

After migrating to system scope, **disable the old user-scope copies** and any
user-boot shim — otherwise *both* scopes start the same service at boot, they fight
over ports, and the boot-time one dies:

```bash
# kill the user-scope bootstrap (if present)
sudo systemctl mask hermes-user-boot.service
systemctl --user disable hermes-gateway.service cortex-bus.service \
  hermes-cortex-dashboard.service health-vector.service   # if they exist
```

## Verify (after a real reboot)

```bash
systemctl is-active hermes-gateway cortex-bus hermes-cortex-dashboard health-vector
#   → all "active"

pgrep -af 'gateway run'        # exactly ONE process

# boot log must show systemd[1] starting them, no user-manager double-start:
journalctl -b 0 | grep -E 'Started Hermes'
```

## Headless facts we confirmed

- SSH is up **before** login (2s after boot with the boot-blocker fix).
- Telegram connectivity may take ~30s more (DNS + network settle); that's normal.
- The "login screen that never goes away" on this setup was the **idle lock**, not the
  login — disable the idle lock / screensaver for a headless box
  (`omarchy toggle idle stay-awake`, or set `idle.screensaver`/`idle.lock` high in
  `~/.config/omarchy/shell.json`).

## State.db note

Hermes stores sessions in `~/.hermes/state.db` (SQLite + FTS). If you ever see
`session storage could not be written` or a lost reply after a disk hiccup, the
canonical recovery is:

```bash
hermes sessions recover --source ~/.hermes/state.db \
  --output ~/.hermes/state.db.recovered --allow-partial
```

It salvages around damaged rows and never installs over the live DB. Full story:
[`docs/articles/state-db-recovery.md`](articles/state-db-recovery.md).
