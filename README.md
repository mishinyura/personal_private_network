# IKEv2 VPN на StrongSwan

Автоматическая установка IKEv2 VPN на Ubuntu 24.04.

Схема:

- StrongSwan IKEv2;
- авторизация EAP-MSCHAPv2 по логину и паролю;
- серверный сертификат Let's Encrypt;
- полный туннель через IP сервера;
- встроенный клиент Windows;
- одновременные подключения с одним логином разрешены через `uniqueids=never`;
- повторный запуск `setup.sh` не перевыпускает существующий сертификат и не удаляет пользователей.

## Требования

- чистый сервер Ubuntu 24.04;
- публичный IPv4;
- домен с A-записью на IP сервера;
- открытые в панели хостинга TCP 22, TCP 80, UDP 500 и UDP 4500.

## Установка

```bash
git clone https://github.com/mishinyura/personal_private_network.git
cd personal_private_network
cp config.env.example config.env
nano config.env
chmod +x *.sh
sudo ./setup.sh
```

Пример `config.env`:

```env
DOMAIN="vpn.domain.ru"
LETSENCRYPT_EMAIL="mail@example.com"
VPN_POOL="10.10.10.0/24"
VPN_DNS="1.1.1.1,8.8.8.8"
EXT_IF="auto"
VPN_USER="user"
VPN_PASSWORD=""
OPEN_HTTP_PORT="1"
```

Если `VPN_PASSWORD` пустой, установщик спросит пароль скрыто.

## Windows

PowerShell от имени администратора:

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
.\windows-client-setup.ps1 -Name "VPN NAME" -Server "MYDOMEN"
rasphone.exe -d "VPN NAME"
```
Перед запуском команд нужно заполнить домент и наименование сервера, который придумали

Введите VPN-логин и пароль из конфигурации сервера.

## Пользователи

```bash
sudo ./user-management.sh add phone
sudo ./user-management.sh passwd phone
sudo ./user-management.sh delete phone
sudo ./user-management.sh list
```

Лучше использовать отдельный логин для каждого устройства. При необходимости один логин также может работать одновременно на нескольких устройствах.

## Проверка

```bash
sudo ./status.sh
sudo journalctl -u strongswan-starter -f
sudo certbot renew --dry-run
```

После подключения внешний IP клиента должен совпадать с IP сервера.

## Повторная установка

Повторный запуск:

```bash
sudo ./setup.sh
```

Установщик:

- проверит ОС, DNS и модули ядра;
- установит недостающие пакеты;
- использует уже существующий сертификат;
- сохранит существующих VPN-пользователей;
- обновит конфигурацию StrongSwan, NAT и UFW;
- создаст бэкап изменяемых файлов в `/root/ikev2-vpn-backup-*`.

## Удаление

```bash
sudo ./clean.sh
```

Сертификат Let's Encrypt при удалении сохраняется.
