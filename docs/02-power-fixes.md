# 02 — Power Fixes: making an old Mac stay on

The #1 reason old Macs die as servers is **power management**. This doc covers the four
fixes that matter, in the order they bit us — each with the *root cause* (read from
source) and the *fix* (tested).

---

## 1. The boot-time suspend (kills SSH + agents until login)

**Symptom:** ~30–60s after every boot the machine suspends itself. SSH dies, the agent
gateway dies, everything is unreachable. Touching the keyboard at the login screen wakes
it, so it *looks* like "services only start after login" — they don't; the box was asleep.

**Root cause — read from UPower source (`up-daemon.c`, `up-backend.c`):**

1. UPower only takes critical-battery action when a battery reports
   `state == UP_DEVICE_STATE_DISCHARGING` and percentage ≤ `PercentageAction` (default 2.0).
2. On a MacBook with a **dead battery**, the battery reads **0%**. At boot, before the AC
   adapter (ADP1) registers as online, the battery briefly looks "discharging at 0%" →
   `UP_DEVICE_LEVEL_ACTION` fires → `up_backend_take_action()`.
3. What it does depends on the shipped default:
   - **Arch / Omarchy default:** `CriticalPowerAction=Auto` → the source maps `Auto` to
     `"Sleep"` → logind `Sleep()` → **suspend**. This is the bug.
   - **Ubuntu / Mint default:** `CriticalPowerAction=HybridSleep` → falls through the
     `CanHybridSleep → CanHibernate → CanPowerOff → CanSleep` chain → lands on `Ignore`
     on hardware without swap-based hibernation. **Same battery, no suspend.** That's why
     the identical Mac never slept under Mint.

**Fix** — make UPower never act on the (dead) battery, via a drop-in that survives
package updates:

```bash
sudo mkdir -p /etc/UPower/UPower.conf.d
sudo tee /etc/UPower/UPower.conf.d/20-dead-battery.conf >/dev/null <<'EOF'
[UPower]
CriticalPowerAction=Ignore
AllowRiskyCriticalPowerAction=true
EOF
sudo systemctl restart upower
```

Why `AllowRiskyCriticalPowerAction=true`: UPower refuses plain `Ignore` without it
(treats ignoring a dying battery as "risky"). That's correct for this machine — the
battery is *already* dead; the box runs on AC; an abrupt power cut is the status quo.

**Verify:**
```bash
busctl call org.freedesktop.UPower /org/freedesktop/UPower \
  org.freedesktop.UPower GetCriticalAction   # → s "Ignore"
journalctl -b 0 | grep -c 'PM: suspend entry'   # → 0
```

---

## 2. Hibernate on a dead battery = bricked boot

**Symptom:** machine hibernates (or suspend-then-hibernates), and with a battery that
can't hold charge, resume is unreliable — sometimes a hard crash, sometimes a black
screen needing a forced reboot.

**Fix** — mask the targets and refuse at the config layer (belt and braces, so an update
unmasking the target still can't re-enable it):

```bash
sudo systemctl mask hibernate.target hybrid-sleep.target suspend-then-hibernate.target

sudo tee /etc/systemd/sleep.conf.d/20-no-hibernate.conf >/dev/null <<'EOF'
[Sleep]
AllowHibernation=no
AllowHybridSleep=no
AllowSuspendThenHibernate=no
EOF

sudo systemctl daemon-reload
```

Suspend stays *allowed* — manual sleep / the sleep menu still works; we only kill the
hibernate family. (On this hardware s2idle is the only reliable suspend anyway:
`MemorySleepMode=s2idle SuspendState=freeze` per the MacBook recipe, see
[`configs/systemd/10-mac-sleep.conf`](../configs/systemd/10-mac-sleep.conf).)

**Verify:** `systemctl is-enabled hibernate.target` → `masked`; `systemctl hibernate`
→ "Unit hibernate.target is masked, refusing operation."

---

## 3. "Services only come up after login" — boot-blocking oneshots

**Symptom:** SSH + agent services appear to start only after you log in at the greeter.
We proved this one with a probe script on the machine's own clock:

```
up=148s sshd=LISTENING gateway=active telegram=no dns=FAIL session=none   ← before login
up=158s sshd=LISTENING gateway=active telegram=no dns=ok    session=desktop
up=179s sshd=LISTENING gateway=active telegram=connected   session=desktop
```

**Root cause:** `systemctl list-jobs` showed `multi-user.target` still `waiting` because
**`Type=oneshot` services in the boot chain were taking 3–5 minutes to *complete*** —
systemd considers a target reached only after its oneshots finish. Two culprits shipped
by the distro:

- a boot-reachability probe that polled for up to 5 minutes
- an SDDM greeter-blank service that slept 60s+ up to 120s probing socket paths

sshd didn't even start until uptime 147s (normally 3–7s). Login "fixed" it only because
by the time you typed a password, the chain had finally completed.

**Fix** — run the real work in a *detached* transient unit so the boot-chain job finishes
instantly:

```ini
# /etc/systemd/system/greeter-blank.service (example)
[Service]
Type=oneshot
ExecStart=/usr/bin/systemd-run --no-block --unit=greeter-blank-detached --collect \
  /usr/local/sbin/greeter-blank.sh
```

The probe: check `$XDG_RUNTIME_DIR/hypr` **before** the legacy `/tmp/hypr` path (the
old order wasted the whole budget on a path that moved), with a short 10s budget.
Full working units + script: [`scripts/fix-boot-blockers.sh`](../scripts/fix-boot-blockers.sh).

---

## 4. Screensaver too aggressive (ttfx at 120fps)

**Symptom:** after idle, a fullscreen terminal launches the Omarchy branding screensaver
using `ttfx` with `--random-effect` at **120 fps** — matrix rain, fireworks, black holes.
It's distracting and (on a server) pointless.

**Root cause:** `/usr/bin/omarchy-screensaver` invokes
`ttfx ... --random-effect --frame-rate 120`.

**Fix (no root, survives updates):** shadow the system script with a user-level copy
earlier in `PATH` (`~/.local/bin` beats `/usr/bin`), restricted to calm effects at 30fps:

```bash
mkdir -p ~/.local/bin
# copy /usr/bin/omarchy-screensaver, then change the ttfx line to:
#   --frame-rate 30 --random-effect --include-effects \
#     print wipe sweep highlight colorshift pour slide slice expand scattered middleout
```

Full script: [`scripts/calm-screensaver.sh`](../scripts/calm-screensaver.sh).
Also set the idle timeout: `~/.config/omarchy/shell.json` → `"idle": {"screensaver": 30, "lock": 300}`
(the shell hot-reloads the file, no restart needed).

---

## Order of operations

1. Fix the suspend (drop-in) — otherwise every reboot dies before you can test anything.
2. Mask hibernate — dead-battery safety.
3. Fix boot blockers — so SSH is up in seconds, not minutes.
4. Calm the screensaver — quality of life.

All four are idempotent and safe to re-run.
