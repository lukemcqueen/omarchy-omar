# 08 — Wireless (BCM43602) on an old Mac: make it an option, keep it off

> **Search:** wifi not working · no wlan0 · broadcom wireless · BCM43602 ·
> brcmfmac · wl driver · broadcom-wl-dkms · DKMS linux-headers · wifi off by
> default · rfkill · nmcli radio · Apple MacBook wifi Linux · 802.11ac

## Goal

The Mac (BCM43602 802.11ac, Apple subsystem) has WiFi usable as an **option**
but **off by default** — off the same way a user toggles the switch, not
ripped out or blacklisted.

## Driver of record: brcmfmac (in-kernel — zero maintenance)

It just works on Omarchy: the module ships in the kernel and the firmware
already ships in `linux-firmware` (`brcmfmac43602-pcie.bin`). No install, no
build, survives kernel updates, auto-loads at boot via PCI modalias (firmware
is on the rootfs, not the initramfs).

```bash
sudo modprobe brcmfmac
lspci -k | grep -A2 -i "network controller"   # Kernel driver in use: brcmfmac
nmcli device status                           # wlp3s0 appears (PCI rename of wlan0)
```

A `no clm_blob available (err=-2), device may have limited channels` line in
dmesg is harmless. The device shows a MAC-address-based **altname**
(`wlx…`) — cosmetic.

**Apple WPA quirk:** the firmware's own supplicant fails the 4-way handshake
on Apple hardware (surfaces as a "rejected password"). Keep this modprobe.d
option — it's what makes WPA work:

```bash
cat /etc/modprobe.d/brcmfmac.conf
# options brcmfmac feature_disable=0x82000
```

## Avoid the wl driver (broadcom-wl-dkms)

The out-of-tree wl driver (AUR `broadcom-wl-dkms`) is a maintenance trap: it
only builds via DKMS, which needs `linux-headers` for **every** kernel — without
them, every kernel update logs a DKMS build error (`70-dkms-install.hook`,
"Missing ... kernel headers for module broadcom-wl/..."). brcmfmac covers the
same chip with none of that. If a stale install exists, remove it (and the
`dkms` package goes with it, killing the recurring hook error).

## Off by default — exactly like a user toggle

```bash
nmcli radio wifi off          # same as the GUI switch
nmcli radio                   # → WIFI disabled
rfkill list                   # Wireless LAN: Soft blocked: yes
```

The soft block **persists across reboots** via systemd-rfkill (per-device
state lands in `/var/lib/systemd/rfkill`). No wifi connection profile exists,
so even with the radio on, nothing auto-joins. Re-enable:
`nmcli radio wifi on`, then create a connection.