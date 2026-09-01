#!/usr/bin/env bash
# fix-power.sh — make an old Mac with a dead battery stop suspending itself.
#
# Part of omarchy-omar (Old Mac, Agentically Renewed).
# Root-cause writeup: docs/02-power-fixes.md
#
# Safe to re-run (idempotent). Supports:
#   sudo bash fix-power.sh          apply everything
#   sudo bash fix-power.sh --check  report current state, change nothing
set -euo pipefail

UPOWER_DROPIN="/etc/UPower/UPower.conf.d/20-dead-battery.conf"
SLEEP_DROPIN="/etc/systemd/sleep.conf.d/20-no-hibernate.conf"
NO_SUSPEND_DROPIN="/etc/systemd/sleep.conf.d/30-no-suspend.conf"
HIB_TARGETS=(hibernate.target hybrid-sleep.target suspend-then-hibernate.target)
CHECK_ONLY=0
[[ "${1:-}" == "--check" ]] && CHECK_ONLY=1

say()  { printf '\033[1;34m== %s ==\033[0m\n' "$*"; }
ok()   { printf '\033[1;32m  ✓\033[0m %s\n' "$*"; }
skip() { printf '\033[1;33m  - %s\033[0m\n' "$*"; }

# --- helpers ---------------------------------------------------------------
need_sudo() {
  if [[ $CHECK_ONLY -eq 1 ]]; then return 0; fi
  if ! sudo -n true 2>/dev/null; then
    echo "This script needs sudo (root). Run:  sudo bash $0"
    exit 1
  fi
}

# --- 1. UPower: never act on a dead battery --------------------------------
apply_upower() {
  say "UPower: ignore critical battery (dead pack at 0%)"
  local current=""
  if command -v busctl >/dev/null 2>&1; then
    current="$(busctl call org.freedesktop.UPower /org/freedesktop/UPower \
               org.freedesktop.UPower GetCriticalAction 2>/dev/null | tr -d 's "' || true)"
  fi
  if [[ "$current" == "Ignore" ]]; then
    ok "GetCriticalAction is already 'Ignore'"
  elif [[ -f "$UPOWER_DROPIN" ]] && grep -q '^CriticalPowerAction=Ignore' "$UPOWER_DROPIN"; then
    ok "drop-in present (upower restart needed to take effect): $UPOWER_DROPIN"
  else
    if [[ $CHECK_ONLY -eq 1 ]]; then
      echo "  MISSING: $UPOWER_DROPIN with CriticalPowerAction=Ignore"
      return 1
    fi
    sudo mkdir -p /etc/UPower/UPower.conf.d
    sudo tee "$UPOWER_DROPIN" >/dev/null <<'EOF'
# Dead-battery fix (omarchy-omar). UPower default CriticalPowerAction=Auto maps
# to "Sleep" in up-backend.c → boot-time suspend on a battery that reads 0%.
[UPower]
CriticalPowerAction=Ignore
AllowRiskyCriticalPowerAction=true
EOF
    sudo systemctl restart upower 2>/dev/null || true
    ok "drop-in written, upower restarted"
  fi
}

# --- 2. systemd: mask hibernate family + refuse ALL sleep (dead battery) ---
apply_hibernate() {
  say "systemd: mask hibernate/hybrid/suspend-then-hibernate targets"
  for t in "${HIB_TARGETS[@]}"; do
    local state=""
    state="$(systemctl is-enabled "$t" 2>/dev/null || true)"
    if [[ "$state" == "masked" ]]; then
      ok "$t is masked"
    else
      if [[ $CHECK_ONLY -eq 1 ]]; then
        echo "  MISSING: $t is not masked"
        return 1
      fi
      sudo systemctl mask "$t"
      ok "$t masked"
    fi
  done

  say "systemd: refuse hibernation at the config layer"
  if [[ -f "$SLEEP_DROPIN" ]] && grep -q '^AllowSuspendThenHibernate=no' "$SLEEP_DROPIN"; then
    ok "sleep.conf.d drop-in present"
  else
    if [[ $CHECK_ONLY -eq 1 ]]; then
      echo "  MISSING: $SLEEP_DROPIN"
      return 1
    fi
    sudo mkdir -p /etc/systemd/sleep.conf.d
    sudo tee "$SLEEP_DROPIN" >/dev/null <<'EOF'
# Dead-battery fix (omarchy-omar): never hibernate on a battery that can't
# hold charge. Suspend stays allowed.
[Sleep]
AllowHibernation=no
AllowHybridSleep=no
AllowSuspendThenHibernate=no
EOF
    sudo systemctl daemon-reload
    ok "sleep.conf.d drop-in written"
  fi

  # Layer 3 (dead-battery server only): refuse SUSPEND entirely.
  # On a WORKING-battery MacBook, skip this so the lid can still sleep the
  # laptop. On a dead-battery AC-only server, any sleep = a down server and
  # a power blip during sleep = crash on wake. All sleep must go.
  if [[ "${DISABLE_ALL_SLEEP:-1}" == "1" ]]; then
    say "systemd: refuse ALL suspend (dead-battery server — CanSuspend=no)"
    if [[ -f "$NO_SUSPEND_DROPIN" ]] && grep -q '^AllowSuspend=no' "$NO_SUSPEND_DROPIN"; then
      ok "no-suspend drop-in present"
    else
      if [[ $CHECK_ONLY -eq 1 ]]; then
        echo "  MISSING: $NO_SUSPEND_DROPIN"
        return 1
      fi
      sudo mkdir -p /etc/systemd/sleep.conf.d
      sudo tee "$NO_SUSPEND_DROPIN" >/dev/null <<'EOF'
# Dead-battery fix (omarchy-omar): refuse ALL sleep at the logind level.
# Dead battery = no power reserve during sleep; AC blip while suspended =
# hard power loss. This box is a server: on 24/7 or it's down.
# Working-battery laptop? Remove this file (keep 20-no-hibernate.conf only).
[Sleep]
AllowSuspend=no
AllowHibernation=no
AllowHybridSleep=no
AllowSuspendThenHibernate=no
EOF
      sudo systemctl daemon-reload
      ok "no-suspend drop-in written"
    fi
  else
    say "systemd: suspend stays ALLOWED (DISABLE_ALL_SLEEP=0)"
    ok "not touching suspend — working-battery mode"
  fi
}

# --- main ------------------------------------------------------------------
need_sudo
RC=0
apply_upower    || RC=1
apply_hibernate || RC=1
if [[ $CHECK_ONLY -eq 1 ]]; then
  echo
  if [[ $RC -eq 0 ]]; then
    echo "All power fixes are in place. ✔"
  else
    echo "Some fixes are missing — run:  sudo bash $0"
  fi
fi
exit $RC
