#!/usr/bin/env bash
# fix-greeter-idle.sh — blank the monitor after 30s idle at the SDDM login
# screen. The greeter runs its own minimal Hyprland as user `sddm` with no
# idle daemon, so the screen stays on forever — this installs hypridle inside
# that session.
# Part of omarchy-omar. See docs/07-sddm-greeter-idle.md.
# Run:  sudo bash fix-greeter-idle.sh     (idempotent)
set -euo pipefail

say() { printf '\033[1;34m== %s ==\033[0m\n' "$*"; }
ok()  { printf '\033[1;32m  ok: %s\033[0m\n' "$*"; }
die() { printf '\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "run with sudo/root"

say "1/5 install hypridle"
if ! command -v hypridle >/dev/null; then
  pacman -S --noconfirm hypridle || die "pacman failed to install hypridle"
fi
ok "hypridle $(pacman -Q hypridle 2>/dev/null | awk '{print $2}')"

say "2/5 hypridle config (30s DPMS blank)"
mkdir -p /etc/sddm
cat > /etc/sddm/hypridle.conf <<'EOF'
listener {
    timeout = 30
    on-timeout = /usr/sbin/hyprctl dispatch 'hl.dsp.dpms({action = "disable"})'
    on-resume = /usr/sbin/hyprctl dispatch 'hl.dsp.dpms({action = "enable"})'
    ignore_inhibit = true
}
EOF
ok "/etc/sddm/hypridle.conf"

say "3/5 greeter wrapper config (stock + hypridle autostart)"
mkdir -p /usr/local/share/sddm
cat > /usr/local/share/sddm/hyprland-idle.lua <<'EOF'
dofile("/usr/share/sddm/hyprland.lua")

hl.on("hyprland.start", function()
    hl.exec_cmd("hypridle -q -c /etc/sddm/hypridle.conf &")
end)
EOF
ok "/usr/local/share/sddm/hyprland-idle.lua"

say "4/5 point CompositorCommand at the wrapper"
CONF=/etc/sddm.conf.d/10-wayland.conf
[ -f "$CONF" ] || die "expected $CONF — adjust CompositorCommand manually"
if grep -q 'hyprland-idle.lua' "$CONF"; then
  ok "already pointed at wrapper"
else
  cp "$CONF" "/root/10-wayland.conf.bak-$(date +%Y%m%d-%H%M%S)"
  sed -i 's|/usr/share/sddm/hyprland.lua|/usr/local/share/sddm/hyprland-idle.lua|' "$CONF"
  ok "backup saved outside the config dir (SDDM reads EVERY file in it — see doc)"
fi
grep CompositorCommand "$CONF"

say "5/5 cleanup: no backups/renamed files inside the config dir"
find /etc/sddm.conf.d/ -maxdepth 1 -type f ! -name '*.conf' | while read -r f; do
  echo "  removing (SDDM would parse it): $f"
  rm -f "$f"
done
ok "config dir contains only *.conf: $(ls /etc/sddm.conf.d/ | tr '\n' ' ')"

echo
echo "Reboot or: sudo systemctl restart sddm"
echo "Test: stay at the login screen 30s -> monitor blanks; any key wakes it."
echo "Verify: while at greeter -> pgrep -a hypridle (must show: sddm ... hypridle -q)"