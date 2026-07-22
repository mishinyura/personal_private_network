#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${CONFIG_FILE:-${SCRIPT_DIR}/config.env}"
VPN_POOL="10.10.10.0/24"
if [[ -f "${CONFIG_FILE}" ]]; then
  # shellcheck disable=SC1090
  source "${CONFIG_FILE}"
fi

[[ "${EUID}" -eq 0 ]] || { echo "Запусти через sudo" >&2; exit 1; }
read -r -p "Удалить конфигурацию IKEv2 StrongSwan? Введи YES: " CONFIRM
[[ "${CONFIRM}" == "YES" ]] || exit 1

BACKUP_DIR="/root/ikev2-vpn-remove-backup-$(date +%Y%m%d-%H%M%S)"
mkdir -p "${BACKUP_DIR}"
cp -a /etc/ipsec.conf /etc/ipsec.secrets /etc/ufw/before.rules /etc/sysctl.d/99-ikev2-vpn.conf "${BACKUP_DIR}/" 2>/dev/null || true

systemctl stop strongswan-starter 2>/dev/null || true
systemctl disable strongswan-starter 2>/dev/null || true
rm -f /etc/ipsec.conf /etc/ipsec.secrets
rm -f /etc/ipsec.d/certs/server-cert.pem
rm -f /etc/ipsec.d/private/server-key.pem
rm -f /etc/ipsec.d/cacerts/le-chain-*.pem
rm -f /etc/sysctl.d/99-ikev2-vpn.conf
rm -f /usr/local/sbin/update-strongswan-cert
rm -f /etc/letsencrypt/renewal-hooks/deploy/strongswan
sed -i '/^# BEGIN IKEV2 VPN NAT$/,/^# END IKEV2 VPN NAT$/d' /etc/ufw/before.rules
ufw route delete allow from "${VPN_POOL}" 2>/dev/null || true
ufw delete allow 500/udp 2>/dev/null || true
ufw delete allow 4500/udp 2>/dev/null || true
ufw reload || true
sysctl --system >/dev/null

echo "Конфигурация удалена. Сертификат Let's Encrypt сохранен."
echo "Бэкап: ${BACKUP_DIR}"
