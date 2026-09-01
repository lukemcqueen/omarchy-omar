#!/usr/bin/env bash
# setup-fail2ban.sh — fail2ban with an nftables ban backend (sshd + nginx jails).
#
# Part of omarchy-omar. Ported from the reference fleet config:
#   - banaction = nftables (composes with ufw/nftables firewalls)
#   - backend = systemd (no log-file polling races)
#   - jails: sshd, nginx-http-auth, nginx-badbots
#
# Usage:  sudo bash setup-fail2ban.sh [--check]
set -euo pipefail

JAIL_DIR="/etc/fail2ban/jail.d"
CHECK_ONLY=0
[[ "${1:-}" == "--check" ]] && CHECK_ONLY=1

say() { printf '\033[1;34m== %s ==\033[0m\n' "$*"; }
ok()  { printf '\033[1;32m  ✓\033[0m %s\n' "$*"; }

need_sudo() {
  if [[ $CHECK_ONLY -eq 1 ]]; then return 0; fi
  if ! sudo -n true 2>/dev/null; then
    echo "This script needs sudo (root). Run:  sudo bash $0"
    exit 1
  fi
}

write_jail() {
  local file="$1" content="$2"
  if [[ -f "$JAIL_DIR/$file" ]]; then
    ok "$file already present"
    return 0
  fi
  if [[ $CHECK_ONLY -eq 1 ]]; then
    echo "  MISSING: $JAIL_DIR/$file"
    return 1
  fi
  sudo tee "$JAIL_DIR/$file" >/dev/null <<EOF
$content
EOF
  ok "wrote $file"
}

install_pkg() {
  if command -v fail2ban-server >/dev/null 2>&1; then
    ok "fail2ban installed"
    return 0
  fi
  if [[ $CHECK_ONLY -eq 1 ]]; then
    echo "  MISSING: fail2ban package"
    return 1
  fi
  if command -v pacman >/dev/null 2>&1; then
    sudo pacman -S --needed --noconfirm fail2ban
  elif command -v apt-get >/dev/null 2>&1; then
    sudo apt-get install -y fail2ban
  else
    echo "Unsupported package manager — install fail2ban manually."
    return 1
  fi
  ok "fail2ban installed"
}

need_sudo
RC=0
install_pkg || RC=1

# Defaults: nftables backend, systemd backend
write_jail "defaults-local.conf" \
'[DEFAULT]
banaction = nftables
banaction_allports = nftables[type=allports]
backend = systemd

[sshd]
enabled = true
' || RC=1

# nginx auth failures → 1h ban
write_jail "nginx-auth.local" \
'[nginx-http-auth]
enabled  = true
port     = http,https
filter   = nginx-http-auth
logpath  = /var/log/nginx/*error.log
maxretry = 5
bantime  = 3600
' || RC=1

# known bad bots → 24h ban on first hit
write_jail "nginx-badbots.local" \
'[nginx-badbots]
enabled  = true
port     = http,https
filter   = nginx-badbots
logpath  = /var/log/nginx/access.log
maxretry = 1
bantime  = 86400
findtime = 86400
' || RC=1

if [[ $CHECK_ONLY -eq 1 ]]; then
  echo
  [[ $RC -eq 0 ]] && echo "fail2ban config complete. ✔" || echo "Some pieces missing — run:  sudo bash $0"
  exit $RC
fi

say "Restarting fail2ban"
sudo systemctl enable --now fail2ban
sudo systemctl restart fail2ban
sleep 1
echo
sudo fail2ban-client status
exit 0
