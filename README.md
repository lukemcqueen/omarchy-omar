# omarchy-omar

**Old Mac, Agentically Renewed** — turn a dusty old MacBook into a headless agent server that runs 24/7.

A field-tested companion to [Omarchy](https://omarchy.org) (Arch + Hyprland, by DHH) for the specific job of rescuing aging Apple laptops: fix the firmware-era power bugs, keep the machine awake and reachable, install an AI agent (Hermes) as a first-class citizen, and harden it so it survives on a hostile network.

> Everything here was learned the hard way on a real 2015 MacBook Pro with a dead battery, running Omarchy. Configs and scripts are generic — substitute your own hostname, IPs, and domain names.

## Why old Macs

- Cheap/free hardware with great build quality, still fine for server work
- Omarchy runs beautifully on them (Hyprland on 2015-era Intel GPUs is buttery)
- The catch: **power management is a minefield** — phantom lid suspends, dead batteries, `suspend-then-hibernate` loops, boot-time suspends that kill SSH before you can log in

This repo is the collection of fixes that make an old Mac *stay on, stay reachable, stay useful* — instead of dying in a drawer.

## Contents

| Path | What |
|---|---|
| [`docs/01-install.md`](docs/01-install.md) | Omarchy install on old Mac + post-install baseline |
| [`docs/02-power-fixes.md`](docs/02-power-fixes.md) | **The big one** — suspend/hibernate/boot-blocker fixes |
| [`docs/03-hermes-first-class.md`](docs/03-hermes-first-class.md) | Install Hermes as a system-scope first-class citizen |
| [`docs/04-secure-remote.md`](docs/04-secure-remote.md) | VNC + SSH + Tailscale remote access |
| [`docs/05-hardening.md`](docs/05-hardening.md) | Firewall, nginx, fail2ban, SSH hardening |
| [`docs/articles/`](docs/articles/) | Stories and lessons from the trenches |
| [`scripts/`](scripts/) | Copy-paste fix scripts (idempotent) |
| [`configs/`](configs/) | Drop-in configs (UPower, systemd, fail2ban, wayvnc) |

## Quick start

```bash
# 1. The power fixes (dead battery / phantom suspend / boot blockers)
sudo bash scripts/fix-power.sh            # see docs/02-power-fixes.md

# 2. Hermes as a system service
bash scripts/install-hermes-first-class.sh  # see docs/03-hermes-first-class.md

# 3. Secure remote access
#    Tailscale + wayvnc — see docs/04-secure-remote.md

# 4. Harden
sudo bash scripts/setup-fail2ban.sh       # see docs/05-hardening.md
```

## The TL;DR of the power fixes

| Symptom | Root cause | Fix |
|---|---|---|
| Machine suspends ~30s after every boot; SSH dies until login | UPower `CriticalPowerAction=Auto` + dead battery at 0% reads as "discharging ≤2%" before AC is noticed | `CriticalPowerAction=Ignore` drop-in ([configs/UPower](configs/UPower/20-dead-battery.conf)) |
| Hibernate on a dead battery = bricked boot | systemd hibernate targets unmasked, `suspend-then-hibernate` armed | Mask targets + `AllowSuspendThenHibernate=no` |
| SSH/hermes come up only *after* login | Boot-blocking oneshots in the systemd target chain (3-5 min greeter-blank / probe) | Detach with `systemd-run --no-block` |
| Crazy fullscreen screensaver | Omarchy `ttfx --random-effect --frame-rate 120` | User shadow: calm effects, 30fps ([scripts/calm-screensaver.sh](scripts/calm-screensaver.sh)) |
| State.db corruption / lost replies | Disk I/O errors → torn SQLite pages in `messages` | `hermes sessions recover --allow-partial` (see [docs/articles/state-db-recovery.md](docs/articles/state-db-recovery.md)) |

## Why Hermes here?

[Hermes](https://hermes-agent.nousresearch.com) is the agent that runs this box: it answers on Telegram, runs cron jobs, maintains the knowledge base, and drives the fleet. Docs/03 covers making it survive reboot, run headless, and start with the machine — not with your login.

## License

MIT — do whatever helps. If it fixes an old Mac, that's the point.
