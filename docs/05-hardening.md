# 05 — Hardening: firewall, nginx, fail2ban, SSH

A machine that runs SSH, a web-facing agent gateway, and VNC needs layers. This is the
full hardening recipe used on the reference box — firewall first, then SSH, then the web
stack, then fail2ban watching all of it.

## The stack, in one picture

| Layer | Tool | Job |
|---|---|---|
| Private network | Tailscale | Encrypted overlay; nothing sensitive exposed on the WAN |
| Firewall | nftables (via ufw) | Default-deny on WAN; allow only 22 + web ports |
| SSH | OpenSSH + keys | Admin access; passwords off; fail2ban watching |
| Web | nginx | Reverse proxy for agent services; rate limits; headers |
| Intrusion detection | fail2ban (nftables backend) | Bans scanners/brute-forcers on sshd + nginx |
| Remote desktop | wayvnc | TLS + password, reachable only on tailnet (see 04) |

## 1. Firewall (ufw / nftables)

Omarchy ships Arch's nftables. The friendly front-end is `ufw`. Default-deny incoming on
the WAN interface, allow only what must be public:

```bash
sudo pacman -S ufw
sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw allow 22/tcp          # SSH
sudo ufw allow 80,443/tcp      # web (if public)
# web-facing agent services on their own ports? allow explicitly, one line each.
sudo ufw enable
sudo ufw status verbose
```

Tailscale traffic rides the tailnet interface and is **not** subject to the WAN rules —
that's the point of the overlay. (If you prefer raw nftables, the fail2ban setup below
already uses `nftables` as its ban backend, so the two compose cleanly.)

## 2. SSH hardening

The reference box runs stock OpenSSH with the Arch defaults. The hardening set:

```bash
# /etc/ssh/sshd_config.d/99-hardening.conf
PermitRootLogin no
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
MaxAuthTries 3
LoginGraceTime 30
AllowUsers YOURUSER
```

Then:

```bash
sudo systemctl reload sshd
```

Key-only auth kills the password-guessing class entirely; fail2ban (below) is the
second net for the key-scanning noise you'll still see.

> Real-world note: you WILL see constant brute-force noise in the journal the moment
> the box is reachable — `Invalid user ...` from random IPs. That's normal; fail2ban
> turns the noise into bans. Don't panic, don't disable logging.

## 3. nginx hardening

If the agent services are exposed via nginx (reverse proxy), apply:

- **Version hiding:** `server_tokens off;`
- **Rate limits** per zone for auth and general endpoints (`limit_req_zone` +
  `limit_req burst=... nodelay`)
- **Headers:** `X-Frame-Options`, `X-Content-Type-Options: nosniff`, `Referrer-Policy`
- **TLS:** modern protocols only (`TLSv1.2 TLSv1.3`), no weak ciphers
- **Single listener rule:** exactly one `listen` directive per server block; never mix a
  plain listener with an `ssl` listener on the same port (plain catches TLS handshakes
  → 400s)
- **Deny-all default** on internal paths

Sketch:

```nginx
http {
    server_tokens off;
    limit_req_zone $binary_remote_addr zone=auth:10m rate=10r/m;
    limit_req_zone $binary_remote_addr zone=general:10m rate=20r/s;

    server {
        listen 443 ssl;
        server_name example.com;
        ssl_protocols TLSv1.2 TLSv1.3;
        add_header X-Frame-Options DENY always;
        add_header X-Content-Type-Options nosniff always;
        location /auth/ {
            limit_req zone=auth burst=5 nodelay;
            proxy_pass http://backend_auth;
        }
        location / {
            limit_req zone=general burst=40 nodelay;
            proxy_pass http://backend_main;
        }
    }
}
```

## 4. fail2ban — the exact working recipe

This is the configuration proven on the reference fleet (nftables ban backend —
works whether or not ufw is active, and composes with the firewall above):

```bash
sudo pacman -S fail2ban
sudo systemctl enable --now fail2ban
```

### Base jail (sshd)

```ini
# /etc/fail2ban/jail.d/defaults-local.conf
[DEFAULT]
banaction = nftables
banaction_allports = nftables[type=allports]
backend = systemd

[sshd]
enabled = true
```

### nginx jails (if nginx is in the picture)

```ini
# /etc/fail2ban/jail.d/nginx-auth.local
[nginx-http-auth]
enabled  = true
port     = http,https
filter   = nginx-http-auth
logpath  = /var/log/nginx/*error.log
maxretry = 5
bantime  = 3600
```

```ini
# /etc/fail2ban/jail.d/nginx-badbots.local
[nginx-badbots]
enabled  = true
port     = http,https
filter   = nginx-badbots
logpath  = /var/log/nginx/access.log
maxretry = 1
bantime  = 86400
findtime = 86400
```

### Verify

```bash
sudo systemctl restart fail2ban
sudo fail2ban-client status        # → sshd, nginx-http-auth, nginx-badbots
sudo fail2ban-client status sshd   # → banned IP list
sudo nft list set inet f2b-table addr-set f2b-sshd   # → the ban set, live
```

The nftables backend means bans show up as nft sets — inspectable and unloadable
(`nft flush set inet f2b-table ...`) if you ever need to unban manually.

### ⚠️ Known pitfall: Arch's fail2ban package ships NO nginx filters

**Discovered live (2026-09-01):** Arch's `fail2ban` package does **not** include
`filter.d/nginx-http-auth.conf` or `filter.d/nginx-badbots.conf` (Debian/Ubuntu do).
Referencing those jails without installing the filters makes the jail fail to load —
the service logs `Found no accessible config files for 'filter.d/nginx-badbots'` and
exits 255 on restart. Symptom: `fail2ban-client status` shows sshd but the nginx jails
are missing, or the service is crash-looping.

**Fix:** `scripts/setup-fail2ban.sh` now writes both standard filter files before
enabling the jails (the `install_filters()` step). If you configured fail2ban by hand,
copy the filters from the script or from a Debian/Ubuntu install of fail2ban into
`/etc/fail2ban/filter.d/`, then `systemctl restart fail2ban`. macOS (brew) has the
same gap — the script handles it via the brew prefix path.

## 5. Keep it from going stale

- `sudo pacman -Syu` regularly — old Macs can't afford known CVEs either.
- Check `fail2ban-client status` weekly; if a jail is `0 banned`, confirm its logpath
  is still valid (log rotation renames can silently starve a jail).
- After nginx config changes: `nginx -t` before reload, always.
- `sudo tailscale status` — if the tailnet is your security boundary, a vanished
  machine is a dropped rule.

## Reference box reality check

On the box this was built from: SSH noise is constant, fail2ban bans dozens of IPs a
day, and nginx serves the agent stack with `deny all` + rate limits on internal paths.
Tailscale carries VNC and admin traffic; the WAN sees only 22 + the web ports. That
combination has held for weeks without a compromise event.
