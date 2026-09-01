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
  elif command -v brew >/dev/null 2>&1; then
    brew install fail2ban
  else
    echo "Unsupported package manager — install fail2ban manually."
    return 1
  fi
  ok "fail2ban installed"
}

# Arch's fail2ban package does NOT ship nginx filter files (Debian/Ubuntu
# do) — without them the nginx jails fail to load and the service exits.
# Ship the standard filters explicitly on every distro.
install_filters() {
  local filter_dir="/etc/fail2ban/filter.d"
  if command -v brew >/dev/null 2>&1; then
    filter_dir="$(brew --prefix 2>/dev/null || echo /usr/local)/etc/fail2ban/filter.d"
  fi
  if [[ -f "$filter_dir/nginx-badbots.conf" && -f "$filter_dir/nginx-http-auth.conf" ]]; then
    ok "nginx filters present"
    return 0
  fi
  if [[ $CHECK_ONLY -eq 1 ]]; then
    echo "  MISSING: nginx filters in $filter_dir"
    return 1
  fi
  sudo mkdir -p "$filter_dir"
  if [[ ! -f "$filter_dir/nginx-http-auth.conf" ]]; then
    sudo tee "$filter_dir/nginx-http-auth.conf" >/dev/null <<'EOF'
[Definition]

failregex = ^ \[error\] \d+#\d+: \*\d+ user "(?P<user>[^"]+)":? (?:password mismatch|was not found in "[^"]*"|user not found), client: <HOST>, server: \S*, request: "\S+ \S+ HTTP/\d+\.\d+", host: "\S+(?::\d+)?"(?:, referrer: "\S+")?\s*$

ignoreregex =

[Init]

# default port if not specified in jail.conf
port = http,https
EOF
  fi
  if [[ ! -f "$filter_dir/nginx-badbots.conf" ]]; then
    sudo tee "$filter_dir/nginx-badbots.conf" >/dev/null <<'EOF'
[Definition]

failregex = ^<HOST> -.*"(GET|POST|HEAD|PUT|DELETE|OPTIONS).*"(?:[12345]\d\d) .*"(?:Mozilla.*(?:BOT|bot|spider|crawl|curl|wget|scrapy|python-requests|Go-http-client)|curl|wget|Scrapy|python-requests|Go-http-client).*"$
            ^<HOST> -.*"(GET|POST|HEAD|PUT|DELETE|OPTIONS).*"(?:[12345]\d\d) .*"(?:${_badbotscustom})"$

ignoreregex =

[Init]

# List of bad bots to ban
_badbotscustom = 12345|Badbot|Baiduspider|Curl|Go-http-client|libwww-perl|Lwp-trivial|MJ12bot|python-requests|Scrapy|Wget|YandexBot

# default port if not specified in jail.conf
port = http,https
EOF
  fi
  ok "nginx filters written"
}

need_sudo
RC=0
install_pkg || RC=1
install_filters || RC=1

# Defaults: nftables backend (Linux) / pf (macOS), systemd backend
_BANACTION="nftables"
command -v brew >/dev/null 2>&1 && _BANACTION="pf"
write_jail "defaults-local.conf" \
"[DEFAULT]
banaction = ${_BANACTION}
banaction_allports = ${_BANACTION}[type=allports]
backend = systemd

[sshd]
enabled = true
" || RC=1

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
