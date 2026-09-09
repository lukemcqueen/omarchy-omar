#!/usr/bin/env bash
# fix-headless-luks.sh — auto-unlock LUKS root at boot with a keyfile on the
# ESP, so SSH/agents are reachable headlessly (no boot password prompt).
# Part of omarchy-omar. See docs/06-headless-boot.md.
# Run:  sudo bash fix-headless-luks.sh
# Idempotent: re-running regenerates the keyfile/keyslot cleanly.
set -euo pipefail

# Customize:
KEYFILE="${KEYFILE:-/boot/mykey.bin}"
UKI="${UKI:-/boot/EFI/Linux/omarchy_linux.efi}"
ENTRY="${ENTRY:-linux}"

say() { printf '\033[1;34m== %s ==\033[0m\n' "$*"; }
ok()  { printf '\033[1;32m  ok: %s\033[0m\n' "$*"; }
die() { printf '\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "run with sudo/root"
for c in cryptsetup limine-mkinitcpio limine-entry-tool objcopy strings lsinitcpio b2sum; do
  command -v "$c" >/dev/null || die "missing command: $c"
done

# 1. find the LUKS root device (crypto_LUKS, not a partition of another mapper)
LUKS_PART="$(lsblk -rno NAME,TYPE,FSTYPE | awk '$3=="crypto_LUKS" {print $1; exit}')"
[ -n "$LUKS_PART" ] || die "no crypto_LUKS device found (is root encrypted?)"
LUKS_PART="/dev/$LUKS_PART"
ok "LUKS device: $LUKS_PART"

say "1/6 keyfile on /boot"
head -c 512 /dev/urandom > "$KEYFILE"
chmod 400 "$KEYFILE"
ok "$KEYFILE ($(stat -c%s "$KEYFILE") bytes)"

say "2/6 add keyfile as SECOND keyslot (enter existing passphrase when prompted)"
cryptsetup luksAddKey "$LUKS_PART" "$KEYFILE" || die "luksAddKey failed"
ok "keyslot added — passphrase slot kept as backup"

say "3/6 prove keyfile unlocks before rebuilding"
cryptsetup open --test-passphrase --key-file "$KEYFILE" "$LUKS_PART" || die "keyfile does NOT unlock — aborting"
ok "keyfile unlocks the slot"

say "4/6 embed keyfile in initramfs (whole-line replace)"
sed -i "s|^FILES=.*|FILES=($KEYFILE)|" /etc/mkinitcpio.conf
ok "FILES=$(grep '^FILES=' /etc/mkinitcpio.conf)"

say "5/6 cryptkey on kernel cmdline (rootfs: prefix is critical)"
mkdir -p /etc/limine-entry-tool.d
cat > /etc/limine-entry-tool.d/cryptkey.conf <<EOF
KERNEL_CMDLINE[default]+=" cryptkey=rootfs:$KEYFILE"
EOF
ok "cryptkey=rootfs:$KEYFILE"

say "6/6 rebuild UKI + refresh Limine hash"
limine-mkinitcpio
limine-entry-tool --add-uki "$ENTRY" "$UKI"

# install pacman hook so future rebuilds auto-refresh the hash
mkdir -p /etc/pacman.d/hooks
cat > /etc/pacman.d/hooks/limine-hash-refresh.hook <<'EOF'
[Trigger]
Operation = Install
Operation = Upgrade
Type = Path
Target = usr/lib/limine/limine-mkinitcpio
Action = PostTransaction
Exec = /bin/sh -c 'limine-entry-tool --add-uki linux /boot/EFI/Linux/omarchy_linux.efi || true'
EOF
ok "pacman hook installed (auto-refresh hash on package updates)"

echo
echo "Verify from the deployed artifact (scratch files, rm after):"
echo "  objcopy --dump-section .initrd=/tmp/i.cpio \"$UKI\" && lsinitcpio -l /tmp/i.cpio | grep luks && rm -f /tmp/i.cpio"
echo "  objcopy --dump-section .cmdline=/tmp/c.bin \"$UKI\" && strings /tmp/c.bin | grep cryptkey && rm -f /tmp/c.bin"
echo "Then reboot and touch nothing — no prompt expected."