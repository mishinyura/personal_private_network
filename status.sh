#!/usr/bin/env bash
set -Eeuo pipefail

echo "=== StrongSwan ==="
systemctl status strongswan-starter --no-pager -l || true

echo
echo "=== Connections ==="
ipsec statusall || true

echo
echo "=== Ports ==="
ss -lunp | grep -E ':500|:4500' || true

echo
echo "=== Forwarding ==="
sysctl net.ipv4.ip_forward || true

echo
echo "=== UFW ==="
ufw status verbose || true

echo
echo "=== NAT ==="
iptables -t nat -S POSTROUTING || true

echo
echo "=== Recent logs ==="
journalctl -u strongswan-starter -n 100 --no-pager || true
