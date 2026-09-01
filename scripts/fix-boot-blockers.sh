#!/usr/bin/env bash
# fix-boot-blockers.sh — stop distro oneshot services from blocking the boot chain.
#
# Part of omarchy-omar. When Type=oneshot services in the multi-user.target chain
# take 3-5 minutes (probes, greeter-blank sleeps), systemd considers the target
# unreached, so sshd + everything below it starts late or not at all — looking
# like "services wait for login". Fix: detach the slow work with systemd-run.
#
# Customize UNIT_OVERRIDES for the units on your distro.
# Usage:  sudo bash fix-boot-blockers.sh [--check]
set -euo pipefail

# name → the oneshot that must not block the boot chain
declare -A UNIT_OVERRIDES=(
  # Example from the 2015 MacBook reference box. Adjust to your distro:
  ["sddm-greeter-blank.service"]="/usr/local/sbin/sddm-greeter-blank.sh"
)

CHECK_ONLY=0
[[ "${1:-}" == "--check" ]] && CHECK_ONLY=1

say() { printf '\033[1;34m== %s ==\033[0m\n' "$*"; }
ok()  { printf '\033[1;32m  ✓\033[0m %s\n' "$*"; }
skip(){ printf '\033[1;33m  - %s\033[0m\n' "$*"; }

need_sudo() {
  if [[ $CHECK_ONLY -eq 1 ]]; then return 0; fi
  if ! sudo -n true 2>/dev/null; then
    echo "This script needs sudo (root). Run:  sudo bash $0"
    exit 1
  fi
}

detach_one() {
  local name="$1" script="$2"
  local override="/etc/systemd/system/${name}.d/detach.conf"
  if [[ -d "/etc/systemd/system/${name}.d" ]] && \
     grep -q 'systemd-run --no-block' "$override" 2>/dev/null; then
    ok "$name already detached"
    return 0
  fi
  if [[ $CHECK_ONLY -eq 1 ]]; then
    echo "  MISSING: $override detaches $name from the boot chain"
    return 1
  fi
  sudo mkdir -p "/etc/systemd/system/${name}.d"
  sudo tee "$override" >/dev/null <<EOF
[Service]
ExecStart=
ExecStart=/usr/bin/systemd-run --no-block --unit=${name%.service}-detached --collect ${script}
EOF
  sudo systemctl daemon-reload
  ok "$name detached (${script} now runs in background)"
}

need_sudo
if [[ ${#UNIT_OVERRIDES[@]} -eq 0 ]]; then
  echo "No units configured — edit UNIT_OVERRIDES in this script for your distro."
  exit 0
fi

RC=0
for name in "${!UNIT_OVERRIDES[@]}"; do
  detach_one "$name" "${UNIT_OVERRIDES[$name]}" || RC=1
done

if [[ $CHECK_ONLY -eq 1 ]]; then
  echo
  [[ $RC -eq 0 ]] && echo "Boot chain is clear. ✔" || echo "Some blockers remain — run:  sudo bash $0"
fi
exit $RC
