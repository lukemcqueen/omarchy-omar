# 01 — Installing Omarchy on an Old Mac (and the post-install baseline)

This is the starting point: Omarchy on a 2015-era Intel MacBook with a dead battery.
If you have a working battery, skip the power stuff in §3 — but read §4 (boot blockers)
anyway; it bites regardless.

## What we're building

| Goal | Outcome |
|---|---|
| OS | Omarchy (Arch, Hyprland, Wayland) on the internal SSD |
| Power | Never suspends at boot, never hibernates (dead battery), stays on 24/7 |
| Reachability | SSH up in ~2s after boot, no login required |
| Agent | Hermes gateway as a system service, answering on Telegram |
| Remote | Tailscale + VNC/SSH from anywhere |
| Security | Firewall, fail2ban, key-only SSH |

## 1. Install Omarchy

Follow the [official Omarchy install](https://omarchy.org) for the MacBook's architecture.
Notes specific to old Macs:

- **Back up everything first.** If the old disk is dying (SMART errors, repeated
  `WRITE DMA EXT` failures in the journal), the new install may be your last boot of the
  old data.
- Choose **LUKS + btrfs** on the internal SSD. Encryption costs nothing on modern
  hardware and makes a stolen laptop a non-event.
- The installer will handle WiFi (if used) — but for a server, prefer Ethernet or a
  USB dongle; WiFi radios in 2015 MacBooks are fine but not great for 24/7 service.

## 2. Post-install baseline

```bash
# Update everything
sudo pacman -Syu

# Base tooling for what follows
sudo pacman -S --needed git openssh tailscale fail2ban nftables ufw wayvnc

# Enable SSH at boot
sudo systemctl enable --now sshd

# Generate an SSH key if you don't have one (on the CLIENT machine):
#   ssh-keygen -t ed25519
#   ssh-copy-id user@mac
```

Set a real hostname (not the Apple default), then **reboot once** and confirm:
`journalctl -b 0 | grep 'PM: suspend entry'` returns nothing.

## 3. Power fixes (dead-battery edition)

On a 2015 MacBook the battery is often at 0% design capacity. The machine is AC-only,
but UPower doesn't know that — it reads "0% discharging" at boot and suspends the box
~30s in. **Do this before anything else, or every reboot will kill your SSH session:**

```bash
sudo bash scripts/fix-power.sh
```

What it does, in one line each: UPower `CriticalPowerAction=Ignore` drop-in (kills the
boot-time suspend), mask `hibernate.target`/`hybrid-sleep.target`/`suspend-then-hibernate.target`
(kills dead-battery hibernation), `AllowSuspendThenHibernate=no` (kills the hibernate
fallback in logind's sleep chain). Full explanation with the source-level root cause:
[`02-power-fixes.md`](02-power-fixes.md).

## 4. Boot blockers (services wait for login)

Even with the suspend fixed, you may find SSH/the agent only start minutes after boot —
because distro oneshot services hold the boot chain. Fix:

```bash
sudo bash scripts/fix-boot-blockers.sh
```

Verify: reboot, then `systemctl show -p ActiveEnterTimestamp sshd` → seconds after boot,
not minutes.

## 5. Hermes as a first-class citizen

```bash
# install Hermes per its docs, then:
bash scripts/install-hermes-first-class.sh   # creates system-scope units
```

Now the gateway, dashboard, bus, and health endpoint start with the machine and survive
reboot with zero login. Full walkthrough: [`03-hermes-first-class.md`](03-hermes-first-class.md).

## 6. Remote access + hardening

```bash
sudo tailscale up                       # join your tailnet
# ...follow docs/04-secure-remote.md for wayvnc config...
sudo bash scripts/setup-fail2ban.sh     # sshd + nginx jails, nftables backend
```

## The 30-minute checklist

After all of the above, from a fresh reboot **with no one at the machine**:

```bash
ssh user@mac 'echo up'                          # works, <10s after boot
ssh user@mac 'systemctl is-active hermes-gateway'   # active
ssh user@mac 'journalctl -b 0 | grep -c "PM: suspend entry"'  # 0
```

If all three pass, the machine is a server now. Plug it in, put it on a shelf, forget it.
