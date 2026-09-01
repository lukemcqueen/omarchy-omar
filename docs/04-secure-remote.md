# 04 — Secure Remote Access: VNC + SSH + Tailscale

An old Mac turned server needs three remote paths: **SSH** (admin), **VNC** (the desktop),
and a **private network** that makes both safe from the internet. The secure-VNC recipe
below is the one that works on Hyprland/Wayland.

## Layer 1: Tailscale (the private network)

Install and join your tailnet. This gives every box a stable, encrypted, firewall-proof
IP that only your devices can reach — no port forwarding, no exposed SSH on the WAN.

```bash
sudo pacman -S tailscale
sudo systemctl enable --now tailscaled
sudo tailscale up          # follow the auth URL
tailscale ip -4            # → 100.x.y.z, your private address
```

Tailscale is the *security boundary*: VNC and admin ports bind to the tailnet or are
firewalled to it, so the raw internet never sees them.

## Layer 2: SSH (must-have)

Already listening on 22. Harden it — see [`05-hardening.md`](05-hardening.md) for the
full recipe (keys only, no passwords, fail2ban). SSH is your lifeline if VNC breaks;
test it first.

## Layer 3: VNC — the secure Wayland way (wayvnc)

Hyprland is Wayland-native, so `x11vnc` is the wrong tool (it can only capture XWayland
surfaces, not the real desktop). The correct choice is **`wayvnc`**, a wlroots-native
VNC server. "The way DHH does it" on Omarchy is exactly this: **wayvnc + Tailscale**.

### Install + configure

```bash
sudo pacman -S wayvnc
mkdir -p ~/.config/wayvnc
```

VNC itself is unencrypted and password-only — that's fine **inside Tailscale**, but we
add TLS anyway for belt-and-braces. Generate a self-signed cert (fine for a private
tailnet; the cert is about encrypting the wire, not identity):

```bash
cd ~/.config/wayvnc
openssl req -x509 -newkey rsa:2048 -keyout key.pem -out cert.pem -days 365 -nodes \
  -subj "/CN=wayvnc"
```

Create `~/.config/wayvnc/config`:

```ini
address=0.0.0.0
port=5900
enable_auth=true
password=REPLACE_WITH_STRONG_PASSWORD
certificate_file=/home/YOURUSER/.config/wayvnc/cert.pem
private_key_file=/home/YOURUSER/.config/wayvnc/key.pem
use_relative_paths=false
```

### Run it (test first, then autostart)

```bash
wayvnc -C ~/.config/wayvnc/config
```

Connect from any VNC client to `<tailnet-ip>:5900` (macOS Screen Sharing,
RealVNC/TigerVNC, phone apps). Note: `enable_auth=true` on wayvnc **requires** the TLS
cert/key pair — that's why we generated them.

**Autostart** (Omarchy/Hyprland): add to `~/.config/hypr/autostart.lua`:

```lua
o.launch_on_start("wayvnc -C /home/YOURUSER/.config/wayvnc/config")
```

### Hardening choices, explained

| Choice | Why |
|---|---|
| Tailscale instead of port-forward | No public exposure; encrypted transport; zero-config ACLs |
| `wayvnc` over `x11vnc` | Captures the full Wayland desktop, not just XWayland windows |
| TLS cert + password (`enable_auth=true`) | wayvnc's auth requires it; encrypts the RFB stream even on the tailnet |
| Bind to tailnet IP (optional) | Tighter than `0.0.0.0` if you also firewall the LAN side |

### Even tighter option: tunnel VNC over SSH

If you don't want VNC listening at all, forward it through SSH — VNC binds to
`127.0.0.1` only, and the client connects via an SSH tunnel:

```bash
ssh -L 5900:127.0.0.1:5900 user@box   # then connect to localhost:5900
```

Requires SSH to be reachable (it is) and no extra listening port (cleaner footprint).
Downside: no phone-app auto-reconnect when the tunnel drops.

## Order of operations

1. Tailscale up — get the private IP.
2. SSH confirmed working.
3. wayvnc test-run, connect once, then autostart.
4. Firewall (05) so nothing sensitive listens on the WAN interface.

## Verification

```bash
ss -tlnp | grep 5900              # wayvnc listening
tailscale status                   # box reachable on tailnet
# from another device:
#   vnc://<tailnet-ip>:5900        → prompt for password → desktop appears
```
