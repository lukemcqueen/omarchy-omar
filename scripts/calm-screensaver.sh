#!/usr/bin/env bash
# calm-screensaver.sh — calm the Omarchy screensaver (ttfx 120fps random → 30fps calm).
#
# Part of omarchy-omar. Does NOT edit system files: installs a user-level shadow
# in ~/.local/bin which beats /usr/bin in PATH and survives package updates.
# Revert:  rm ~/.local/bin/omarchy-screensaver
set -euo pipefail

SYSTEM_SCRIPT="/usr/bin/omarchy-screensaver"
SHADOW_SCRIPT="$HOME/.local/bin/omarchy-screensaver"
CHECK_ONLY=0
[[ "${1:-}" == "--check" ]] && CHECK_ONLY=1

say() { printf '\033[1;34m== %s ==\033[0m\n' "$*"; }
ok()  { printf '\033[1;32m  ✓\033[0m %s\n' "$*"; }

if [[ ! -f "$SYSTEM_SCRIPT" ]]; then
  echo "System screensaver script not found at $SYSTEM_SCRIPT — nothing to calm."
  exit 0
fi

if [[ -f "$SHADOW_SCRIPT" ]] && grep -q -- '--frame-rate 30' "$SHADOW_SCRIPT"; then
  ok "calm shadow already installed: $SHADOW_SCRIPT"
  exit 0
fi

if [[ $CHECK_ONLY -eq 1 ]]; then
  echo "MISSING: calm screensaver shadow at $SHADOW_SCRIPT"
  echo "Run:  bash $0"
  exit 1
fi

say "Installing calm screensaver shadow (no root needed)"
mkdir -p "$HOME/.local/bin"

# Start from the stock script and swap the ttfx invocation.
sed -e 's/--frame-rate 120/--frame-rate 30/' \
    -e 's/--random-effect/--random-effect --include-effects print wipe sweep highlight colorshift pour slide slice expand scattered middleout/' \
    "$SYSTEM_SCRIPT" > "$SHADOW_SCRIPT"
chmod +x "$SHADOW_SCRIPT"

ok "shadow installed: $SHADOW_SCRIPT"

# Verify the shadow actually wins.
if [[ "$(command -v omarchy-screensaver)" == "$SHADOW_SCRIPT" ]]; then
  ok "PATH resolves omarchy-screensaver → $SHADOW_SCRIPT"
else
  echo "  note: PATH resolves to $(command -v omarchy-screensaver)."
  echo "  If ~/.local/bin isn't before /usr/bin, add it:"
  echo "    export PATH=\"\$HOME/.local/bin:\$PATH\""
fi
