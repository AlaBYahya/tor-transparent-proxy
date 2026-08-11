#!/bin/bash
# Toggle system-wide transparent Tor proxying for HTTP/HTTPS + DNS only.
# Everything else (SSH, custom ports, UDP other than DNS, ICMP, LAN/loopback
# traffic) passes through untouched.
#
# Usage: tor-proxy-toggle.sh {on|off|status}

set -euo pipefail

TRANS_PORT=9040
DNS_PORT=5353
CHAIN=TOR_PROXY
FILTER_CHAIN=TOR_PROXY_BLOCK
FILTER_CHAIN6=TOR_PROXY_BLOCK6
TOR_UID=$(id -u debian-tor)

# Never redirect traffic to local/private destinations.
LOCAL_NETS="127.0.0.0/8 10.0.0.0/8 172.16.0.0/12 192.168.0.0/16 169.254.0.0/16 224.0.0.0/4"
LOCAL_NETS6="::1/128 fe80::/10 fc00::/7 ff00::/8"

require_root() {
    if [ "$EUID" -ne 0 ]; then
        exec sudo "$0" "$@"
    fi
}

ensure_tor_running() {
    if ! systemctl is-active --quiet tor@default; then
        systemctl start tor@default
        sleep 2
    fi
}

enable_proxy() {
    ensure_tor_running

    iptables -t nat -N "$CHAIN" 2>/dev/null || iptables -t nat -F "$CHAIN"

    # Tor's own outbound connections must never be redirected into itself.
    iptables -t nat -A "$CHAIN" -m owner --uid-owner "$TOR_UID" -j RETURN

    for net in $LOCAL_NETS; do
        iptables -t nat -A "$CHAIN" -d "$net" -j RETURN
    done

    iptables -t nat -A "$CHAIN" -p udp --dport 53 -j REDIRECT --to-ports "$DNS_PORT"
    iptables -t nat -A "$CHAIN" -p tcp --dport 53 -j REDIRECT --to-ports "$DNS_PORT"
    iptables -t nat -A "$CHAIN" -p tcp --dport 80 -j REDIRECT --to-ports "$TRANS_PORT"
    iptables -t nat -A "$CHAIN" -p tcp --dport 443 -j REDIRECT --to-ports "$TRANS_PORT"

    if ! iptables -t nat -C OUTPUT -j "$CHAIN" 2>/dev/null; then
        iptables -t nat -A OUTPUT -j "$CHAIN"
    fi

    # Tor cannot proxy raw UDP (only TCP + DNS lookups). QUIC/HTTP3 runs over
    # UDP 443 and would otherwise bypass Tor entirely, leaking the real IP.
    # Block it in the filter table (nat table refuses DROP under nftables) so
    # browsers fall back to regular TCP/TLS on 443, which is redirected above.
    iptables -N "$FILTER_CHAIN" 2>/dev/null || iptables -F "$FILTER_CHAIN"
    for net in $LOCAL_NETS; do
        iptables -A "$FILTER_CHAIN" -d "$net" -j RETURN
    done
    iptables -A "$FILTER_CHAIN" -p udp --dport 443 -j DROP
    if ! iptables -C OUTPUT -j "$FILTER_CHAIN" 2>/dev/null; then
        iptables -A OUTPUT -j "$FILTER_CHAIN"
    fi

    # Tor's TransPort/DNSPort here are IPv4-only. Any IPv6-capable connection
    # (browsers prefer IPv6 via Happy Eyeballs) would bypass Tor completely
    # and leak the real IPv6 address. Block outbound IPv6 on the ports we
    # care about (80/443/53) so those connections fail over IPv6 and the OS
    # falls back to IPv4, where the redirect above applies.
    ip6tables -N "$FILTER_CHAIN6" 2>/dev/null || ip6tables -F "$FILTER_CHAIN6"
    for net in $LOCAL_NETS6; do
        ip6tables -A "$FILTER_CHAIN6" -d "$net" -j RETURN
    done
    ip6tables -A "$FILTER_CHAIN6" -p tcp --dport 80 -j DROP
    ip6tables -A "$FILTER_CHAIN6" -p tcp --dport 443 -j DROP
    ip6tables -A "$FILTER_CHAIN6" -p udp --dport 443 -j DROP
    ip6tables -A "$FILTER_CHAIN6" -p tcp --dport 53 -j DROP
    ip6tables -A "$FILTER_CHAIN6" -p udp --dport 53 -j DROP
    if ! ip6tables -C OUTPUT -j "$FILTER_CHAIN6" 2>/dev/null; then
        ip6tables -A OUTPUT -j "$FILTER_CHAIN6"
    fi

    echo "Tor transparent proxy: ON  (HTTP/HTTPS/DNS routed through Tor via IPv4; QUIC and IPv6 web/DNS traffic blocked to prevent leaks)"
}

disable_proxy() {
    iptables -t nat -D OUTPUT -j "$CHAIN" 2>/dev/null || true
    iptables -t nat -F "$CHAIN" 2>/dev/null || true
    iptables -t nat -X "$CHAIN" 2>/dev/null || true
    iptables -D OUTPUT -j "$FILTER_CHAIN" 2>/dev/null || true
    iptables -F "$FILTER_CHAIN" 2>/dev/null || true
    iptables -X "$FILTER_CHAIN" 2>/dev/null || true
    ip6tables -D OUTPUT -j "$FILTER_CHAIN6" 2>/dev/null || true
    ip6tables -F "$FILTER_CHAIN6" 2>/dev/null || true
    ip6tables -X "$FILTER_CHAIN6" 2>/dev/null || true
    echo "Tor transparent proxy: OFF (normal routing restored)"
}

status_proxy() {
    if iptables -t nat -C OUTPUT -j "$CHAIN" 2>/dev/null; then
        echo "Status: ON"
        echo "Verifying exit via check.torproject.org ..."
        curl -s --max-time 10 https://check.torproject.org/api/ip || echo "(check failed - Tor may still be bootstrapping)"
        echo
    else
        echo "Status: OFF"
    fi
}

case "${1:-}" in
    on)
        require_root "$@"
        enable_proxy
        ;;
    off)
        require_root "$@"
        disable_proxy
        ;;
    status)
        status_proxy
        ;;
    *)
        echo "Usage: $0 {on|off|status}"
        exit 1
        ;;
esac
