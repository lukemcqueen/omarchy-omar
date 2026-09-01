#!/usr/bin/env bash
# install-hermes-first-class.sh — make Hermes a system-scope, first-class citizen.
#
# Part of omarchy-omar. Converts user-scope Hermes services into system units that
# start at boot (multi-user.target), survive reboot without login, and can't be
# double-started by a stale user-boot shim.
#
# Usage:
#   bash install-hermes-first-class.sh          # create system units + mask shim
#   bash install-hermes-first-class.sh --check  # report, change nothing
#
# Customize: set HERMES_USER / HERMES_HOME / units below for your install.
set -euo pipefail

HERMES_USER="${HERMES_USER:-$(id -un)}"
HERMES_HOME="${HERMES_HOME:-$HOME/.hermes}"
VENV_PY="${HERMES_HOME}/hermes-agent/venv/bin/python"
CHECK_ONLY=0
[[ "${1:-}" == "--check" ]] && CHECK_ONLY=1

# Unit name → ExecStart command
declare -A UNITS=(
  ["hermes-gateway"]="python -m hermes_cli.main gateway run"
  ["cortex-bus"]="python -m hermes_cli.main bus run"
  ["hermes-cortex-dashboard"]="python -m hermes_cli.main dashboard run"
  ["health-vector"]="python -m hermes_cli.main health-vector run"
)

say() { printf '\033[1;34m== %s ==\033[0m\n' "$*"; }
ok()  { printf '\033[1;32m  ✓\033[0m %s\n' "$*"; }
skip(){ printf '\033[1;33m  - %s\033[0m\n' "$*"; }

if [[ ! -x "$VENV_PY" ]]; then
  echo "Hermes venv python not found at $VENV_PY"
  echo "Install Hermes first (see https://hermes-agent.nousresearch.com), or set HERMES_HOME."
  exit 1
fi

need_sudo() {
  if [[ $CHECK_ONLY -eq 1 ]]; then return 0; fi
  if ! sudo -n true 2>/dev/null; then
    echo "This script needs sudo (root). Run:  sudo bash $0"
    exit 1
  fi
}

write_unit() {
  local name="$1" cmd="$2"
  local unit="/etc/systemd/system/${name}.service"
  if [[ -f "$unit" ]] && systemctl is-enabled "$name" >/dev/null 2>&1; then
    ok "$name already installed as system service"
    return 0
  fi
  if [[ $CHECK_ONLY -eq 1 ]]; then
    echo "  MISSING: $unit"
    return 1
  fi
  sudo tee "$unit" >/dev/null <<EOF
[Unit]
Description=Hermes ${name}
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${HERMES_USER}
ExecStart=${VENV_PY} -m hermes_cli.main ${cmd#python -m hermes_cli.main}
WorkingDirectory=${HERMES_HOME}
Environment="PATH=${HERMES_HOME}/hermes-agent/venv/bin:/usr/local/bin:/usr/bin:/bin"
Environment="HERMES_HOME=${HERMES_HOME}"
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
  sudo systemctl daemon-reload
  sudo systemctl enable "$name"
  ok "$name installed + enabled"
}

mask_user_boot_shim() {
  if systemctl is-enabled hermes-user-boot.service >/dev/null 2>&1 || \
     systemctl status hermes-user-boot.service >/dev/null 2>&1; then
    if [[ $CHECK_ONLY -eq 1 ]]; then
      echo "  ACTION NEEDED: hermes-user-boot.service exists — should be masked"
      return 1
    fi
    sudo systemctl mask hermes-user-boot.service
    ok "masked stale user-boot shim (prevents double-start)"
  else
    ok "no hermes-user-boot shim present"
  fi
}

need_sudo
RC=0
say "Hermes system-scope units"
for name in "${!UNITS[@]}"; do
  write_unit "$name" "${UNITS[$name]}" || RC=1
done

say "Double-start prevention"
mask_user_boot_shim || RC=1

if [[ $CHECK_ONLY -eq 1 ]]; then
  echo
  [[ $RC -eq 0 ]] && echo "Hermes is already first-class. ✔" || echo "Some units missing — run:  sudo bash $0"
fi
exit $RC
