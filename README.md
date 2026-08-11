# Tor Transparent Proxy Setup

A toggle for routing this machine's HTTP/HTTPS/DNS traffic through Tor,
without touching anything else (SSH, other apps, LAN traffic).

## What's installed

- `tor` (running as a systemd service: `tor@default`, enabled at boot)
- `proxychains4` (for manually wrapping individual commands, see below)
- `torsocks` (installed alongside `tor`, not required by the toggle script)

## Installation steps (for reference / reproducing on another machine)

1. **Install packages**

   ```
   sudo apt-get update
   sudo apt-get install -y tor proxychains4
   ```

   (`torsocks` and `tor-geoipdb` come in as dependencies of `tor`.)

2. **Enable and start Tor's SOCKS proxy** (127.0.0.1:9050 by default,
   already active once the package is installed)

   ```
   sudo systemctl enable --now tor@default
   ```

3. **Point proxychains at Tor.** Edit `/etc/proxychains4.conf`, in the
   `[ProxyList]` section at the bottom, change:

   ```
   socks4  127.0.0.1 9050
   ```

   to:

   ```
   socks5  127.0.0.1 9050
   ```

   (`socks5` is used instead of the default `socks4` so DNS resolution
   also happens through Tor, not locally — avoids DNS leaks.)

4. **Add a transparent-proxy port to Tor.** Append to `/etc/tor/torrc`:

   ```
   ## Transparent proxying (system-wide torification via iptables NAT redirect)
   TransPort 127.0.0.1:9040
   DNSPort 127.0.0.1:5353
   AutomapHostsOnResolve 1
   VirtualAddrNetworkIPv4 10.192.0.0/10
   ```

   Then apply it:

   ```
   sudo systemctl restart tor@default
   ```

5. **Create the toggle script.** `tor-proxy-toggle.sh` in this folder
   contains the `iptables`/`ip6tables` rules described below — it's what
   actually turns system-wide redirection on and off. Nothing further to
   install; just run it (see Usage).

## How it works

`tor-proxy-toggle.sh` flips a set of `iptables`/`ip6tables` rules on and off.
It does **not** modify anything permanently — running `off` fully restores
normal routing.

### When ON

- Outbound TCP port 80 and 443 → redirected to Tor's `TransPort` (127.0.0.1:9040)
- DNS (TCP+UDP port 53) → redirected to Tor's `DNSPort` (127.0.0.1:5353)
- QUIC (UDP port 443, used by Chrome/HTTP3) → **blocked**, not proxied.
  Tor can only relay TCP streams and do DNS lookups — it cannot proxy raw
  UDP. Browsers that can't reach a site over QUIC automatically fall back
  to regular TCP+TLS on port 443, which *is* redirected through Tor above.
- IPv6 web/DNS traffic (TCP 80/443, UDP/TCP 53 over IPv6) → **blocked**.
  Tor's TransPort/DNSPort here only listen on IPv4. Since most software
  (Chrome included) prefers IPv6 when available ("Happy Eyeballs"), an
  IPv6-capable connection would otherwise bypass Tor completely and leak
  the real IPv6 address. Blocking it forces a fallback to IPv4, which is
  already routed through Tor.
- Everything else — SSH, custom app ports, ICMP, non-DNS/HTTP(S) UDP,
  loopback/LAN/Docker-bridge destinations — passes through **unmodified**.

### When OFF

All of the above rules (both the `iptables` NAT/filter chains and the
`ip6tables` filter chain) are removed. Normal routing resumes exactly as
before.

## Usage

```
./tor-proxy-toggle.sh on       # start routing HTTP/HTTPS/DNS through Tor
./tor-proxy-toggle.sh off      # stop, restore normal routing
./tor-proxy-toggle.sh status   # check current state + exit IP
```

The script needs root for `iptables`/`ip6tables` and will re-run itself
with `sudo` automatically if not already root — it'll prompt for your
password on `on`/`off`.

**After turning it on**, if you already had a browser open, do a hard
refresh (Ctrl+Shift+R) or restart the browser — existing QUIC/IPv6
connections opened before the toggle was flipped don't get retroactively
redirected; only new connections are affected.

## Manually proxying a single command (proxychains)

Independent of the toggle, any single command can be routed through Tor's
SOCKS5 proxy (127.0.0.1:9050, always available while `tor@default` is
running) without touching the system-wide rules:

```
proxychains4 curl https://example.com
proxychains4 <any other command>
```

Config: `/etc/proxychains4.conf` (set to `socks5 127.0.0.1 9050`).

## Verification performed

- `proxychains4 curl https://check.torproject.org/api/ip` → `IsTor: true`
- Plain `curl` (no wrapper) with the toggle ON → also `IsTor: true`,
  confirming the transparent redirect works
- `curl -6` with the toggle ON → times out (IPv6 correctly blocked),
  falls back to IPv4 automatically
- iptables rule counters confirmed to increment on matching traffic
  (QUIC/UDP-443 and IPv6 DROP rules actually firing, not just present)
- Toggling `off` restores the real IP immediately, and leaves Docker's own
  `iptables` NAT rules untouched

## Known limitations

- Only HTTP/HTTPS (80/443) and DNS (53) are proxied — this was scoped
  intentionally, not a full "kill switch" / whole-system anonymization
  setup. Any other protocol/port an app uses will go out directly, over
  IPv4 or IPv6, unproxied.
- This machine's network stack is shared system-wide: turning the proxy
  ON affects every user and process on the machine, not just one account.
- Not a substitute for the Tor Browser if strong anonymity (fingerprinting
  resistance, etc.) is the goal — this only anonymizes the network path.
