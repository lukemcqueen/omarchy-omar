# 06 — Headless Boot: auto-unlock LUKS root, kill the boot password prompt

> **Search:** headless boot · no SSH until login · ssh hangs before login ·
> services only start after login · Omarchy login screen · lock icon password
> input before boot · LUKS passphrase every boot · encrypted root auto unlock ·
> "Keyfile could not be opened. Reverting to passphrase" · cryptkey rootfs ·
> FILES mkinitcpio keyfile · limine "Blake2b hash does not match" · "Press Y to
> continue" limine · limine-entry-tool --add-uki · headless mac server · old
> MacBook Omarchy remote access · encrypted drive boots to password prompt

## Symptom

Every boot shows **Omarchy logo + lock icon + password field** — and SSH/agents
are unreachable until you type a password at the machine. The screen is
**Plymouth's LUKS drive-unlock dialog** (theme `omarchy`: `lock.png`, `entry.png`)
in the initramfs, **before root is decrypted**. No OS/network/sshd exists until
the drive opens → SSH *hangs* → "works after login" because login = drive
decrypt = whole stack comes up together.

Not a desktop login, not autologin, not a screensaver. It's the disk.

## Fix

Put a keyfile on `/boot` (EFI partition, already unencrypted), add it as LUKS
keyslot #2, embed in initramfs via `FILES=`, point the kernel at it with
**`cryptkey=rootfs:/boot/KEYFILE`** — the `rootfs:` prefix is what makes the
legacy `encrypt` hook use it. Rebuild UKI, refresh Limine hash. Done.

```bash
# 0. identify your LUKS device
lsblk -o NAME,TYPE,FSTYPE | grep crypto_LUKS     # e.g. nvme0n1p2

# 1. keyfile on the ESP
sudo head -c 512 /dev/urandom > /boot/mykey.bin
sudo chmod 400 /boot/mykey.bin

# 2. add as SECOND keyslot (enter your existing passphrase once — it stays as backup)
sudo cryptsetup luksAddKey /dev/nvme0n1p2 /boot/mykey.bin

# 3. PROVE it unlocks BEFORE rebuilding — never skip
sudo cryptsetup open --test-passphrase --key-file /boot/mykey.bin /dev/nvme0n1p2 && echo UNLOCKS

# 4. embed keyfile in initramfs — replace the WHOLE line
sudo sed -i 's|^FILES=.*|FILES=(/boot/mykey.bin)|' /etc/mkinitcpio.conf

# 5. cryptkey on kernel cmdline (limine drop-in) — rootfs: prefix is critical
sudo tee /etc/limine-entry-tool.d/cryptkey.conf >/dev/null <<'EOF'
KERNEL_CMDLINE[default]+=" cryptkey=rootfs:/boot/mykey.bin"
EOF

# 6. rebuild UKI + refresh Limine hash (rebuild alone makes boot warn "Press Y")
sudo limine-mkinitcpio
sudo limine-entry-tool --add-uki linux /boot/EFI/Linux/omarchy_linux.efi
```

Or one-shot: `sudo bash scripts/fix-headless-luks.sh` (does all 6 + auto-installs
the pacman hook so future rebuilds also refresh the hash).

## Verify (deployed artifact, not source)

```bash
# keyfile is inside the UKI initramfs — use lsinitcpio, never bsdtar (it
# false-negatives on the zstd member)
sudo objcopy --dump-section .initrd=/tmp/i.cpio /boot/EFI/Linux/omarchy_linux.efi
lsinitcpio -l /tmp/i.cpio | grep luks            # → /boot/mykey.bin = GOOD
rm -f /tmp/i.cpio                                # scratch only — not part of the fix

# cryptkey in the UKI cmdline
sudo objcopy --dump-section .cmdline=/tmp/c.bin /boot/EFI/Linux/omarchy_linux.efi
strings /tmp/c.bin | grep cryptkey               # → cryptkey=rootfs:/boot/mykey.bin
rm -f /tmp/c.bin

# Limine hash: stored == actual (else boot warns "Blake2b ... does not match")
sudo b2sum -l 512 /boot/EFI/Linux/omarchy_linux.efi
sudo grep -oE 'omarchy_linux\.efi#[0-9a-f]{128}' /boot/limine.conf
```

Reboot, touch nothing → no prompt, no Y-warning, SSH up ~30s after power-on.

## Avoid

1. **`cryptkey=/boot/mykey.bin` without `rootfs:`** — the hook splits cryptkey
   on `:` as `<device>:<path>`; a bare path is treated as a block device, fails
   `resolve_device`, falls back to default `/crypto_keyfile.bin` (not in your
   initramfs), prints "Keyfile could not be opened. Reverting to passphrase.",
   and prompts every boot. `rootfs:` = "path is inside the initramfs" — the fix.
2. **sed-wrapping the default `FILES=()` line** — `FILES=(() "/boot/x")` is a
   bash syntax error the build silently sources; keyfile is silently absent.
   Whole-line replace only.
3. **`bsdtar -tf` on the UKI or its `.initrd`** — "Unrecognized archive
   format"/early-member-only = false negative. `lsinitcpio -l` is the real
   reader.
4. **Rebuilding the UKI and not refreshing the hash** — `limine-mkinitcpio`
   changes UKI bytes but leaves the entry `#hash` stale → "Blake2b hash does
   not match! Press Y" at every boot. Always
   `limine-entry-tool --add-uki linux ...efi` after, or install the pacman hook
   (bundled in the fix script).
5. **Considering this a login/screensaver/autologin/scope problem** — it's the
   disk. Journal timestamps look scrambled (RTC offset) and services "appear
   up" after unlock only because everything starts together post-decrypt.
   Diagnose by reading the code that draws the screen: Plymouth theme
   `omarchy.script` (`show_password_dialog()`) + initcpio `hooks/encrypt`.
6. **Removing your passphrase keyslot** — don't. The keyfile is slot #2;
   passphrase stays as a working backup. Revert = `cryptsetup luksRemoveKey` +
   `rm /boot/mykey.bin` + restore `FILES=()` + rebuild.
7. **Keys on `/boot` with a serious threat model** — anyone with the ESP can
   read the keyfile and unlock root. Fine for a personally-owned box; the ESP
   already holds the kernel. No TPM on 2015 Macs, so this is the tradeoff.