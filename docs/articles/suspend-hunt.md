# Article: "It Worked on Mint!" — Hunting the Boot-Time Suspend

*Gleaned from a real debugging session. The machine: a 2015 MacBook, dead battery,
fresh Omarchy install. The mystery: SSH dies ~30s after every reboot, services appear
to "only start after login" — and the same hardware never did this under Linux Mint.*

## The mystery in three observations

1. Every boot, ~30–60s in, the machine suspends itself. No one pressed anything.
2. It looks like "services start only after you log in" — touch the keyboard at the
   greeter and everything comes alive.
3. The user's pointed question: *"It worked with Linux Mint, same dead battery. The
   code is open source — you can fix it!"*

Observation 3 is the clue that cracks it: **same hardware, same battery, different
distro, different behavior.** The difference had to be in the *software* — a config,
a default, a version.

## Step 1: prove it's a suspend, not a login dependency

The "waits for login" theory dies first. A probe script run as root, right after boot,
shows the machine itself is *asleep*:

```
journalctl -b 0 | grep -E 'PM: suspend|requested from'
→ 23:27:24 PM: suspend entry (s2idle)
→ suspend-then-hibernate requested from client PID 1234 ('upowerd')
```

`upowerd` — the power daemon — requested the suspend. Not the login screen, not
`systemd-logind`'s idle logic. The power daemon decided the machine should sleep.

## Step 2: what makes upower suspend a machine?

UPower's policy: when a battery is **discharging** and its level drops below the
critical threshold (default 2%), take the "critical action". On a laptop that's the
right thing. But:

- The battery is **dead**: it reports 0% capacity. It *is* at critical level — forever.
- At boot, before the AC adapter registers, the battery briefly reads "discharging" →
  level drops below 2% → **action fires**.

## Step 3: read the source — why Mint didn't suspend

`CriticalPowerAction` is a config value. The default differs by distro:

| Distro | Shipped default | What the source does with it |
|---|---|---|
| Arch / Omarchy | `Auto` | `up-backend.c`: "if action == Auto → use `Sleep`" → **suspend** |
| Ubuntu / Mint | `HybridSleep` | tries hybrid sleep → needs swap-based hibernation → unavailable on this box → falls through the capability chain to **`Ignore`** |

Same battery. Same hardware. One line of shipped config made the entire difference.
That's why the user's "it worked on Mint!" was the decisive data point — it ruled out
hardware and narrowed the search to a distro default.

## Step 4: fix it for the right reason

The dead battery will always read critical. The correct policy for a dead-battery
AC-only machine is: **never let the battery trigger a suspend.**

```ini
# /etc/UPower/UPower.conf.d/20-dead-battery.conf
[UPower]
CriticalPowerAction=Ignore
AllowRiskyCriticalPowerAction=true
```

The drop-in directory (`UPower.conf.d/`) survives package updates — the main config
file gets clobbered by upgrades, the drop-in wins. `AllowRiskyCriticalPowerAction=true`
is needed because UPower considers ignoring a dying battery "risky" — on this machine
that's precisely the point: the battery is already dead; AC is the power source.

Verified: `busctl ... GetCriticalAction` → `s "Ignore"`. Two clean boots, 8+ hours
uptime, zero suspends.

## The general lesson: "it worked on X" is a debugging superpower

When the same hardware behaves differently across distros/versions, you have a free
experiment. The delta *is* the answer. Here it led straight to:

1. **Read the shipped default** (`/etc/UPower/UPower.conf`) on both systems — they
   looked "nearly identical" until we read the exact `CriticalPowerAction` line.
2. **Read the source** of the program that acts (upower is open source — the mapping
   `Auto → Sleep` is right there in `up-backend.c`).
3. **Fix with a drop-in**, not an edit to a file packages overwrite.

## Related

- [`../02-power-fixes.md`](../02-power-fixes.md) — the full fix set, including the
  boot-blocker issue (why services genuinely *did* wait for login on some boots)
- The "services wait for login" companion article: [boot-blocker-probe.md](boot-blocker-probe.md)
