#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${CONFIG_FILE:-${SCRIPT_DIR}/config.env}"
BACKUP_DIR="/root/ikev2-vpn-backup-$(date +%Y%m%d-%H%M%S)"

log() { printf '\n==> %s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

require_root() {
  [[ "${EUID}" -eq 0 ]] || die "Запусти: sudo bash setup.sh"
}

load_config() {
  [[ -f "${CONFIG_FILE}" ]] || die "Нет ${CONFIG_FILE}. Скопируй config.env.example в config.env"
  # shellcheck disable=SC1090
  source "${CONFIG_FILE}"

  DOMAIN="${DOMAIN:-}"
  LETSENCRYPT_EMAIL="${LETSENCRYPT_EMAIL:-}"
  VPN_POOL="${VPN_POOL:-10.10.10.0/24}"
  VPN_DNS="${VPN_DNS:-1.1.1.1,8.8.8.8}"
  EXT_IF="${EXT_IF:-auto}"
  VPN_USER="${VPN_USER:-yura}"
  VPN_PASSWORD="${VPN_PASSWORD:-}"
  OPEN_HTTP_PORT="${OPEN_HTTP_PORT:-1}"

  [[ -n "${DOMAIN}" ]] || die "DOMAIN пустой"
  [[ -n "${LETSENCRYPT_EMAIL}" ]] || die "LETSENCRYPT_EMAIL пустой"
  [[ "${DOMAIN}" != "vpn.example.com" ]] || die "Замени DOMAIN в config.env"
  [[ "${LETSENCRYPT_EMAIL}" != "admin@example.com" ]] || die "Замени LETSENCRYPT_EMAIL в config.env"
}

# validate_os() {
#   [[ -r /etc/os-release ]] || die "Не удалось определить ОС"
#   # shellcheck disable=SC1091
#   source /etc/os-release
#   [[ "${ID:-}" == "ubuntu" ]] || die "Поддерживается Ubuntu 24.04"
#   [[ "${VERSION_ID:-}" == "24.04" ]] || die "Поддерживается Ubuntu 24.04, найдена ${VERSION_ID:-unknown}"
# }

detect_interface() {
  if [[ "${EXT_IF}" == "auto" || -z "${EXT_IF}" ]]; then
    EXT_IF="$(ip route show default | awk '{print $5; exit}')"
  fi
  [[ -n "${EXT_IF}" ]] || die "Не удалось определить внешний интерфейс"
}

backup_file() {
  local file="$1"
  [[ -e "${file}" ]] || return 0
  mkdir -p "${BACKUP_DIR}$(dirname "${file}")"
  cp -a "${file}" "${BACKUP_DIR}${file}"
}

install_packages() {
  log "Установка пакетов"
  apt update
  DEBIAN_FRONTEND=noninteractive apt install -y \
    strongswan strongswan-pki strongswan-starter \
    libcharon-extra-plugins libcharon-extauth-plugins \
    certbot dnsutils ufw iptables iproute2 openssl curl
}

check_kernel_modules() {
  log "Проверка модулей ядра"
  local module
  for module in xfrm_user xfrm_algo af_key esp4 ah4; do
    modprobe "${module}" || die "Не удалось загрузить модуль ${module}"
  done
}

check_dns() {
  log "Проверка DNS"
  local dns_ip public_ip aaaa
  dns_ip="$(dig +short A "${DOMAIN}" | tail -n 1)"
  public_ip="$(curl -4 -fsSL https://ifconfig.me)"
  aaaa="$(dig +short AAAA "${DOMAIN}" | head -n 1 || true)"

  printf 'DOMAIN: %s\nDNS A: %s\nPublic IP: %s\n' "${DOMAIN}" "${dns_ip:-not found}" "${public_ip}"
  [[ -n "${dns_ip}" ]] || die "A-запись ${DOMAIN} не найдена"
  [[ "${dns_ip}" == "${public_ip}" ]] || die "DNS указывает на ${dns_ip}, сервер имеет ${public_ip}"
  [[ -z "${aaaa}" ]] || die "У домена есть AAAA-запись ${aaaa}, но установщик настраивает только IPv4"
}

configure_ufw_base() {
  log "Предварительная настройка UFW"
  ufw allow OpenSSH
  [[ "${OPEN_HTTP_PORT}" == "1" ]] && ufw allow 80/tcp
  ufw allow 500/udp
  ufw allow 4500/udp
}

issue_certificate() {
  log "Получение сертификата Let's Encrypt"
  if [[ -f "/etc/letsencrypt/live/${DOMAIN}/cert.pem" ]]; then
    certbot certificates | grep -q "Certificate Name: ${DOMAIN}" || die "Каталог сертификата найден, но Certbot его не видит"
    log "Сертификат уже существует, перевыпуск не требуется"
    return 0
  fi

  local stopped_services=()
  local service
  for service in nginx apache2; do
    if systemctl is-active --quiet "${service}" 2>/dev/null; then
      systemctl stop "${service}"
      stopped_services+=("${service}")
    fi
  done

  local certbot_status=0
  certbot certonly \
    --standalone \
    --preferred-challenges http \
    --key-type rsa \
    --rsa-key-size 4096 \
    --non-interactive \
    --agree-tos \
    --email "${LETSENCRYPT_EMAIL}" \
    -d "${DOMAIN}" || certbot_status=$?

  local item
  for item in "${stopped_services[@]}"; do
    systemctl start "${item}" || true
  done
  [[ "${certbot_status}" -eq 0 ]] || die "Certbot завершился с кодом ${certbot_status}"
}

install_certificate_hook() {
  log "Настройка сертификата StrongSwan"
  install -d -m 755 /etc/ipsec.d/certs /etc/ipsec.d/private /etc/ipsec.d/cacerts
  install -d -m 755 /etc/letsencrypt/renewal-hooks/deploy

  cat > /usr/local/sbin/update-strongswan-cert <<EOF_HOOK
#!/usr/bin/env bash
set -Eeuo pipefail
DOMAIN="${DOMAIN}"
LIVE_DIR="/etc/letsencrypt/live/\${DOMAIN}"
install -m 0644 "\${LIVE_DIR}/cert.pem" /etc/ipsec.d/certs/server-cert.pem
install -m 0600 "\${LIVE_DIR}/privkey.pem" /etc/ipsec.d/private/server-key.pem
rm -f /etc/ipsec.d/cacerts/le-chain-*.pem
awk '/-----BEGIN CERTIFICATE-----/ { n++ } n > 0 { print > sprintf("/etc/ipsec.d/cacerts/le-chain-%02d.pem", n) }' "\${LIVE_DIR}/chain.pem"
chmod 0644 /etc/ipsec.d/cacerts/le-chain-*.pem
if systemctl is-active --quiet strongswan-starter; then
  systemctl restart strongswan-starter
fi
EOF_HOOK

  chmod 700 /usr/local/sbin/update-strongswan-cert
  ln -sfn /usr/local/sbin/update-strongswan-cert /etc/letsencrypt/renewal-hooks/deploy/strongswan
  /usr/local/sbin/update-strongswan-cert

  local cert_hash key_hash
  cert_hash="$(openssl x509 -in /etc/ipsec.d/certs/server-cert.pem -pubkey -noout | openssl pkey -pubin -outform DER | sha256sum | awk '{print $1}')"
  key_hash="$(openssl pkey -in /etc/ipsec.d/private/server-key.pem -pubout -outform DER | sha256sum | awk '{print $1}')"
  [[ "${cert_hash}" == "${key_hash}" ]] || die "Сертификат и ключ не совпадают"
}

configure_strongswan() {
  log "Настройка StrongSwan"
  backup_file /etc/ipsec.conf
  backup_file /etc/ipsec.secrets

  cat > /etc/ipsec.conf <<EOF_IPSEC
config setup
    uniqueids=never
    charondebug="ike 1, knl 1, cfg 1"

conn ikev2-vpn
    auto=add
    type=tunnel
    keyexchange=ikev2
    fragmentation=yes
    forceencaps=yes
    mobike=yes
    dpdaction=clear
    dpddelay=30s
    rekey=no
    reauth=no

    left=%any
    leftid=@${DOMAIN}
    leftauth=pubkey
    leftcert=server-cert.pem
    leftsendcert=always
    leftsubnet=0.0.0.0/0

    right=%any
    rightid=%any
    rightauth=eap-mschapv2
    rightsourceip=${VPN_POOL}
    rightdns=${VPN_DNS}
    rightsendcert=never
    eap_identity=%identity

    ike=aes256-sha256-modp2048!
    esp=aes256-sha256-modp2048!
EOF_IPSEC

  if [[ ! -f /etc/ipsec.secrets ]]; then
    printf ': RSA "server-key.pem"\n\n' > /etc/ipsec.secrets
  elif ! grep -q '^: RSA "server-key.pem"' /etc/ipsec.secrets; then
    local secrets_tmp
    secrets_tmp="$(mktemp)"
    printf ': RSA "server-key.pem"\n\n' > "${secrets_tmp}"
    cat /etc/ipsec.secrets >> "${secrets_tmp}"
    install -m 600 "${secrets_tmp}" /etc/ipsec.secrets
    rm -f "${secrets_tmp}"
  fi
  chmod 600 /etc/ipsec.secrets

  systemctl stop xl2tpd 2>/dev/null || true
  systemctl disable xl2tpd 2>/dev/null || true
  systemctl enable strongswan-starter
}

ensure_user() {
  [[ -n "${VPN_USER}" ]] || return 0
  if grep -qE "^${VPN_USER}[[:space:]]*:[[:space:]]*EAP" /etc/ipsec.secrets; then
    log "Пользователь ${VPN_USER} уже существует"
    return 0
  fi

  if [[ -z "${VPN_PASSWORD}" ]]; then
    read -r -s -p "Пароль VPN для ${VPN_USER}: " VPN_PASSWORD
    echo
  fi
  [[ -n "${VPN_PASSWORD}" ]] || die "Пароль VPN пустой"
  [[ "${VPN_PASSWORD}" != *$'\n'* && "${VPN_PASSWORD}" != *$'\r'* ]] || die "Пароль содержит перенос строки"

  local escaped
  escaped="${VPN_PASSWORD//\\/\\\\}"
  escaped="${escaped//\"/\\\"}"
  printf '%s : EAP "%s"\n' "${VPN_USER}" "${escaped}" >> /etc/ipsec.secrets
  chmod 600 /etc/ipsec.secrets
  unset VPN_PASSWORD escaped
}

configure_network() {
  log "Настройка маршрутизации и UFW"
  backup_file /etc/ufw/before.rules
  backup_file /etc/default/ufw

  cat > /etc/sysctl.d/99-ikev2-vpn.conf <<'EOF_SYSCTL'
net.ipv4.ip_forward=1
net.ipv4.conf.all.accept_redirects=0
net.ipv4.conf.all.send_redirects=0
net.ipv4.conf.default.accept_redirects=0
net.ipv4.conf.default.send_redirects=0
EOF_SYSCTL
  sysctl --system >/dev/null

  sed -i '/^# BEGIN IKEV2 VPN NAT$/,/^# END IKEV2 VPN NAT$/d' /etc/ufw/before.rules
  cat >> /etc/ufw/before.rules <<EOF_NAT

# BEGIN IKEV2 VPN NAT
*nat
:POSTROUTING ACCEPT [0:0]
-A POSTROUTING -s ${VPN_POOL} -o ${EXT_IF} -m policy --pol ipsec --dir out -j ACCEPT
-A POSTROUTING -s ${VPN_POOL} -o ${EXT_IF} -j MASQUERADE
COMMIT
# END IKEV2 VPN NAT
EOF_NAT

  ufw default deny incoming
  ufw default allow outgoing
  ufw default deny routed
  configure_ufw_base
  ufw route allow from "${VPN_POOL}"
  ufw --force enable
}

validate_installation() {
  log "Финальная проверка"
  systemctl restart strongswan-starter
  sleep 2
  systemctl is-active --quiet strongswan-starter || die "StrongSwan не запустился"
  ipsec statusall | grep -q 'ikev2-vpn' || die "Конфигурация ikev2-vpn не загружена"
  sysctl -n net.ipv4.ip_forward | grep -qx '1' || die "IPv4 forwarding выключен"
  iptables -t nat -S POSTROUTING | grep -Fq -- "-s ${VPN_POOL} -o ${EXT_IF} -j MASQUERADE" || die "Правило NAT не найдено"
  ss -lunp | grep -qE ':500[[:space:]]' || die "UDP 500 не слушается"
  ss -lunp | grep -qE ':4500[[:space:]]' || die "UDP 4500 не слушается"

  openssl x509 -in /etc/ipsec.d/certs/server-cert.pem -noout -subject -issuer -dates -ext subjectAltName
  ipsec statusall
  ufw status verbose

  printf '\nУстановка завершена.\n'
  printf 'Домен: %s\n' "${DOMAIN}"
  printf 'Пользователь: %s\n' "${VPN_USER}"
  printf 'Windows: запусти windows-client-setup.ps1 от администратора.\n'
  printf 'Бэкап измененных файлов: %s\n' "${BACKUP_DIR}"
}

main() {
  require_root
  load_config
  # validate_os
  install_packages
  detect_interface
  check_kernel_modules
  check_dns
  configure_ufw_base
  issue_certificate
  install_certificate_hook
  configure_strongswan
  ensure_user
  configure_network
  validate_installation
}

main "$@"
