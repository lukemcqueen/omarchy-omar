# 07 — SDDM Greeter: blank the login screen after 30s idle

> **Search terms:** login screen monitor stays on · SDDM greeter DPMS · blank
> login screen · monitor off at login screen · screen never turns off before
> login · idle login screen power · hypridle greeter · hypridle sddm ·
> "hl.dispatch(dpms off)" error · Hyprland Lua dispatcher syntax · greeter
> compositor config

## Symptom

The monitor stays **on forever** at the SDDM login screen, burning power. The
desktop's idle/screensaver settings don't apply there — the **SDDM greeter is
its own minimal Hyprland session running as user `sddm`** with a separate
config (`/etc/sddm.conf.d/10-wayland.conf` →
`CompositorCommand=start-hyprland -- --config /usr/share/sddm/hyprland.lua`),
and it has **no idle daemon**. SDDM itself has no built-in screen-off option.

## Fix — one script

```bash
sudo bash scripts/fix-greeter-idle.sh
```

What it does (idempotent):

1. Installs `hypridle` (the idletime daemon for Hyprland; Arch: `pacman -S
   hypridle`)
2. Writes `/etc/sddm/hypridle.conf` — a 30s listener that dispatches DPMS off
   (below)
3. Writes `/usr/local/share/sddm/hyprland-idle.lua` — wraps the stock greeter
   config with `dofile()` and starts hypridle via `hl.on("hyprland.start", ...)`
   (the Omarchy autostart pattern from `helpers.lua`)
4. Seds `CompositorCommand` to the wrapper (backup **outside** the config dir)
5. Cleans the config dir of any non-`*.conf` files (see pitfall 1)

### The config that works

```ini
# /etc/sddm/hypridle.conf
listener {
    timeout = 30
    on-timeout = /usr/sbin/hyprctl dispatch 'hl.dsp.dpms({action = "disable"})'
    on-resume = /usr/sbin/hyprctl dispatch 'hl.dsp.dpms({action = "enable"})'
    ignore_inhibit = true
}
```

```lua
-- /usr/local/share/sddm/hyprland-idle.lua
dofile("/usr/share/sddm/hyprland.lua")

hl.on("hyprland.start", function()
    hl.exec_cmd("hypridle -q -c /etc/sddm/hypridle.conf &")
end)
```

Test: `sudo systemctl restart sddm` (no reboot needed), sit at the login
screen 30s → monitor blanks; any key/mouse wakes it.

## Pitfalls (each one cost a failed attempt)

1. **NEVER keep backups inside `/etc/sddm.conf.d/`.** SDDM 0.21 parses
   **every file** in the dir, not just `*.conf`. A `10-wayland.conf.bak-idle`
   sitting there silently overrode the live `CompositorCommand` — greeter
   ignored the wrapper entirely. Same trap hit the autologin config earlier.
   Backups go in `/root/` or anywhere outside the dir.
2. **`ignore_inhibit = true` is required.** The greeter/Qt session holds an
   idle-inhibit; without this flag hypridle registers the rule but it never
   fires — the screen just stays on even though hypridle is running.
3. **Hyprland 0.55+ Lua dispatchers reject legacy `hyprctl dispatch dpms off`.**
   The compositor compiles the arg as Lua and errors:
   `[string "return hl.dispatch(dpms off)"]:1: ')' expected near 'off'` →
   "dispatch in lua is a shorthand for hl.dispatch(...)". Use the new closure
   form: `hyprctl dispatch 'hl.dsp.dpms({action = "disable"})'` /
   `{action = "enable"}`.
4. **Absolute paths in greeter-run commands** (`/usr/sbin/hyprctl`) — the
   `sddm` user's PATH does not include `/usr/sbin`.
5. **Wake-on-input is default-on** in Hyprland (`key_press_enables_dpms`,
   `mouse_move_enables_dpms` default true) — no extra config needed; any key
   or mouse movement wakes the monitor.

## Verify

- Greeter uses the **wrapper**: `ps -eo user,args | grep [H]yprland --config`
  → shows `/usr/local/share/sddm/hyprland-idle.lua`
- hypridle alive in the greeter: `pgrep -a hypridle` → `sddm ... hypridle -q`
  (it dies on login — check while at the login screen)
- Verbose troubleshooting (temporary): change `-q` to `-v` and append
  `>/tmp/hypridle-greeter.log 2>&1`, restart sddm, wait 35s, read the log —
  it shows `[LOG] Idled: rule ...` when the timeout fires.