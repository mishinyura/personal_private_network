#!/usr/bin/env bash
set -Eeuo pipefail

SECRETS_FILE="/etc/ipsec.secrets"
ACTION="${1:-}"
USERNAME="${2:-}"

usage() {
  cat <<'USAGE'
Использование:
  sudo ./user-management.sh add USERNAME
  sudo ./user-management.sh passwd USERNAME
  sudo ./user-management.sh delete USERNAME
  sudo ./user-management.sh list
USAGE
  exit 1
}

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
[[ "${EUID}" -eq 0 ]] || die "Запусти через sudo"
[[ -f "${SECRETS_FILE}" ]] || die "Нет ${SECRETS_FILE}"

validate_username() {
  [[ "${USERNAME}" =~ ^[A-Za-z0-9._-]+$ ]] || die "Недопустимое имя пользователя"
}

user_exists() {
  grep -qE "^${USERNAME}[[:space:]]*:[[:space:]]*EAP" "${SECRETS_FILE}"
}

read_password() {
  local first second
  read -r -s -p "Новый пароль: " first
  echo
  read -r -s -p "Повтори пароль: " second
  echo
  [[ -n "${first}" ]] || die "Пароль пустой"
  [[ "${first}" == "${second}" ]] || die "Пароли не совпадают"
  [[ "${first}" != *$'\n'* && "${first}" != *$'\r'* ]] || die "Пароль содержит перенос строки"
  first="${first//\\/\\\\}"
  first="${first//\"/\\\"}"
  printf '%s' "${first}"
}

write_user() {
  local password="$1"
  local tmp
  tmp="$(mktemp)"
  awk -v user="${USERNAME}" '$0 !~ "^" user "[[:space:]]*:[[:space:]]*EAP" { print }' "${SECRETS_FILE}" > "${tmp}"
  printf '%s : EAP "%s"\n' "${USERNAME}" "${password}" >> "${tmp}"
  install -m 600 "${tmp}" "${SECRETS_FILE}"
  rm -f "${tmp}"
  ipsec rereadsecrets
}

case "${ACTION}" in
  add)
    [[ -n "${USERNAME}" ]] || usage
    validate_username
    user_exists && die "Пользователь уже существует"
    write_user "$(read_password)"
    printf 'Пользователь %s добавлен.\n' "${USERNAME}"
    ;;
  passwd)
    [[ -n "${USERNAME}" ]] || usage
    validate_username
    user_exists || die "Пользователь не найден"
    write_user "$(read_password)"
    printf 'Пароль пользователя %s обновлен.\n' "${USERNAME}"
    ;;
  delete)
    [[ -n "${USERNAME}" ]] || usage
    validate_username
    user_exists || die "Пользователь не найден"
    tmp="$(mktemp)"
    awk -v user="${USERNAME}" '$0 !~ "^" user "[[:space:]]*:[[:space:]]*EAP" { print }' "${SECRETS_FILE}" > "${tmp}"
    install -m 600 "${tmp}" "${SECRETS_FILE}"
    rm -f "${tmp}"
    ipsec rereadsecrets
    printf 'Пользователь %s удален.\n' "${USERNAME}"
    ;;
  list)
    awk -F: '/:[[:space:]]*EAP[[:space:]]/ { gsub(/[[:space:]]/, "", $1); print $1 }' "${SECRETS_FILE}" | sort
    ;;
  *) usage ;;
esac
