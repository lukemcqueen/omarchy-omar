# Article: Proving "Services Wait for Login" Is a Boot Blocker

*Gleaned from a real debugging session: SSH and the agent gateway seemed to come up
only after logging in at the greeter. It wasn't a login dependency — it was
boot-blocking oneshot services holding the whole boot chain.*

## The observation

On a headless server (old MacBook running Omarchy), after a reboot:

- SSH was unreachable for the first ~2.5 minutes
- The Hermes agent gateway answered only after someone logged in at the greeter
- Touch the keyboard → everything appears within seconds

It *looks* like "services need login". The fix that worked everywhere else
(`loginctl enable-linger`, user-scope services) failed repeatedly.

## The probe that settled it

Instead of theorizing, run a root probe script right after boot that snapshots the
state every few seconds — a timestamped row of what's actually up:

```
up=148s sshd=LISTENING gateway=active telegram=no dns=FAIL session=none
up=158s sshd=LISTENING gateway=active telegram=no dns=ok    session=desktop
up=179s sshd=LISTENING gateway=active telegram=connected   session=desktop
```

Three observations:

1. **sshd wasn't listening until 148s** — on a healthy system it's up in 3–7s.
2. **DNS failed until 158s** — the network stack was still settling.
3. `session=none → desktop` at 158s is the login.

And the kicker: `systemctl list-jobs` showed `multi-user.target` **still `waiting`**
at 148s. The boot chain wasn't finished — so nothing that `Wants=multi-user.target`
(which is everything, including sshd) had started yet.

## Root cause: oneshot services that take 3–5 minutes

`multi-user.target` is considered *reached* only after all its `Requires`/`Wants` oneshot
services **complete**. Two distro services were burning the entire budget:

- a boot-reachability probe that polled for up to 5 minutes
- an SDDM greeter-blank service sleeping 60–120s probing Hyprland socket paths

So the login "fixed" it only because by the time you typed a password, the chain had
finally completed. The login was *correlated*, not causal.

## The fix: detach the slow work

Oneshot units that must run but shouldn't gate the boot chain should launch detached
work via a transient unit — the job completes instantly, the slow work runs in the
background:

```ini
[Service]
Type=oneshot
ExecStart=/usr/bin/systemd-run --no-block --unit=greeter-blank-detached --collect \
  /usr/local/sbin/greeter-blank.sh
```

Also fix the probe itself: the greeter's Hyprland compositor runs as **root**
(`sddm.conf.d/10-wayland.conf` → `CompositorCommand=start-hyprland`), so its socket
lives under `/tmp/hypr` (when `XDG_RUNTIME_DIR` is unset) or `/run/user/0/hypr` — with
a short 10s budget instead of 5 minutes. **Never probe `/run/user/<uid>`**: that is a
logged-in user's session. v2 fell back to `/run/user/1000` when root's
`XDG_RUNTIME_DIR` was unset, found the *user's* Hyprland socket (autologin kills the
greeter in ~1s), and blanked the user's desktop ~3min after boot — indistinguishable
from "suspending at login after reboot". v3 (2026-09-01): probes only `/tmp/hypr` +
`/run/user/0/hypr`, blanks at 30s, and re-checks the socket still belongs to the
greeter before dispatching `dpms off`.

## The general lesson: prove it with a probe before changing architecture

The first theory ("user-scope services need login, use lingering") was *partially*
wrong — the real blocker was upstream in the boot chain. A probe that records state
over time and a glance at `systemctl list-jobs` turned a "login dependency" myth into a
measurable boot-chain problem. On headless boxes, always:

1. Check `systemctl list-jobs` right after boot — what's still `waiting`?
2. Measure *when* sshd actually starts (`systemctl show -p ActiveEnterTimestamp sshd`).
3. Look for `Type=oneshot` units with long `ExecStart` in the chain — they gate
   everything below them.

## Related

- [`../02-power-fixes.md`](../02-power-fixes.md) — the boot-blocker section with the
  full working units
- [`../../scripts/fix-boot-blockers.sh`](../../scripts/fix-boot-blockers.sh)
