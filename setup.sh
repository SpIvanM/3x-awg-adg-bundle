#!/bin/bash
# Name: vps-vpn-triad (Xray Reality + AWG + AdGuard)
# Description: Configures OS networking, Xray Reality, AmneziaWG and AdGuardHome on Debian 11 and Ubuntu.
# Usage: curl -fsSL https://raw.githubusercontent.com/SpIvanM/3x-awg-adg-bundle/main/setup.sh | sudo bash [-r | --rotate]
# Behavior: Updates sysctl, installs OS packages, installs Xray-core, compiles AmneziaWG kernel module, sets up AdGuard. Use -r to rotate credentials.
# Returns: Complete VPN and DNS server proxy routing.
# Fails: If run without root privileges.
# ==============================================================================
# Комплексный скрипт настройки Debian 11/Ubuntu: OS Optimization + Xray Reality + AmneziaWG + AdGuardHome
# ==============================================================================

set -e
export DEBIAN_FRONTEND=noninteractive
export RANDFILE=/tmp/.rnd

# Глобальные переменные и пути
SCRIPT_VERSION="2.0.0"
CREDS_FILE="/root/.vpn-credentials"
LOG_FILE="/var/log/vpn-setup.log"
LAST_RUN_FILE="/root/.vpn-setup-last-run"

# Обработка аргументов
ROTATE_CREDS=0
while [[ "$#" -gt 0 ]]; do
    case $1 in
        --rotate|-r) ROTATE_CREDS=1; shift ;;
        *) shift ;;
    esac
done

# Логирование (перенаправление вывода в файл и консоль)
exec > >(tee -a "$LOG_FILE") 2>&1

# Цвета для вывода
GREEN="\e[32m"
RED="\e[31m"
YELLOW="\e[33m"
RESET="\e[0m"

log() { echo -e "${GREEN}[INFO] $1${RESET}"; }
warn() { echo -e "${YELLOW}[WARN] $1${RESET}"; }
err() { echo -e "${RED}[ERROR] $1${RESET}"; exit 1; }

install_xray_core() {
    if command -v xray >/dev/null 2>&1 && systemctl list-unit-files 2>/dev/null | grep -q '^xray\.service'; then
        systemctl enable xray >/dev/null 2>&1 || true
        return 0
    fi

    log "Установка Xray-core через официальный инсталлятор..."
    bash -c "$(curl -fsSL https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install
    systemctl daemon-reload
    systemctl enable xray >/dev/null 2>&1 || true
}

resolve_xray_bin() {
    command -v xray 2>/dev/null || true
}

trim_cr_value() {
    printf '%s' "$1" | tr -d '\r'
}

read_cred_value() {
    local key="$1"
    local file="$2"
    local raw

    raw=$(grep "^${key}=" "$file" 2>/dev/null | head -n1 | cut -d'=' -f2- | xargs || true)
    trim_cr_value "$raw"
}

read_config_assignment() {
    local prefix="$1"
    local file="$2"
    local raw

    raw=$(grep "^${prefix}" "$file" 2>/dev/null | head -n1 | cut -d'=' -f2- | xargs || true)
    trim_cr_value "$raw"
}

read_url_port() {
    local key="$1"
    local file="$2"
    local raw

    raw=$(grep "^${key}=" "$file" 2>/dev/null | head -n1 | sed -e 's|.*:| |' -e 's|/.*||' | xargs || true)
    trim_cr_value "$raw"
}

# Парсит вывод xray x25519 в переменные XRAY_PRIVATE_KEY и XRAY_PUBLIC_KEY.
# Поддерживает старый формат ("Private key:"/"Public key:") и
# новый формат xray >= v26.3 ("PrivateKey:"/"Password (PublicKey):").
_parse_x25519_output() {
    local raw
    # Нормализуем CRLF до парсинга (защита от Windows-переносов строк)
    raw=$(printf '%s' "$1" | tr -d '\r')
    local priv pub
    # Новый формат (v26.3+): "PrivateKey: <val>" / "Password (PublicKey): <val>"
    # Используем '|' как разделитель sed, чтобы '/' в классе символов не ломал паттерн
    priv=$(printf '%s\n' "$raw" | sed -nE 's|^PrivateKey:[[:space:]]*([A-Za-z0-9+/=_-]+).*|\1|p' | head -n1)
    pub=$(printf '%s\n'  "$raw" | sed -nE 's|^Password \(PublicKey\):[[:space:]]*([A-Za-z0-9+/=_-]+).*|\1|p' | head -n1)
    # Старый формат (до v26.3): "Private key: <val>" / "Public key: <val>"
    [ -n "$priv" ] || priv=$(printf '%s\n' "$raw" | sed -nE 's|^Private key:[[:space:]]*([A-Za-z0-9+/=_-]+).*|\1|p' | head -n1)
    [ -n "$pub"  ] || pub=$(printf '%s\n'  "$raw" | sed -nE 's|^Public key:[[:space:]]*([A-Za-z0-9+/=_-]+).*|\1|p'  | head -n1)
    printf '%s\n%s' "$priv" "$pub"
}

generate_reality_keys() {
    local raw_output priv_pub

    raw_output="$("$XRAY_BIN" x25519 2>&1 || true)"
    priv_pub=$(_parse_x25519_output "$raw_output")
    XRAY_PRIVATE_KEY=$(printf '%s\n' "$priv_pub" | sed -n '1p')
    XRAY_PUBLIC_KEY=$(printf '%s\n'  "$priv_pub" | sed -n '2p')

    if [ -n "$XRAY_PRIVATE_KEY" ] && [ -n "$XRAY_PUBLIC_KEY" ]; then
        return 0
    fi

    warn "xray x25519 вернул нераспознанный вывод. Пробуем openssl-fallback."
    warn "Сырой вывод: $(printf '%s' "$raw_output" | head -c 400)"
    local fallback_priv fallback_out fallback_pub
    fallback_priv=$(openssl rand -base64 32 | tr '+/' '-_' | tr -d '=')
    fallback_out="$("$XRAY_BIN" x25519 -i "$fallback_priv" 2>&1 || true)"
    fallback_pub=$(printf '%s\n' "$(_parse_x25519_output "$fallback_out")" | sed -n '2p')
    XRAY_PRIVATE_KEY="$fallback_priv"
    XRAY_PUBLIC_KEY="$fallback_pub"

    [ -n "$XRAY_PRIVATE_KEY" ] || err "Не удалось получить private key Reality."
    [ -n "$XRAY_PUBLIC_KEY" ] || err "Не удалось получить public key Reality. Вывод xray: $(printf '%s' "$fallback_out" | head -c 400)"
}

remove_legacy_xui() {
    systemctl stop x-ui 2>/dev/null || true
    systemctl disable x-ui 2>/dev/null || true
    rm -f /etc/systemd/system/x-ui.service
    rm -rf /usr/local/x-ui /etc/x-ui
    systemctl daemon-reload >/dev/null 2>&1 || true
}

write_xray_config() {
    mkdir -p /usr/local/etc/xray

    cat <<EOF > /usr/local/etc/xray/config.json
{
  "log": {
    "access": "none",
    "dnsLog": false,
    "error": "",
    "loglevel": "warning",
    "maskAddress": ""
  },
  "dns": {
    "servers": [
      "udp://127.0.0.1:${ADG_DNS_PORT}"
    ],
    "queryStrategy": "UseIPv4"
  },
  "inbounds": [
    {
      "listen": "0.0.0.0",
      "port": ${XRAY_PORT},
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "email": "reality-default",
            "flow": "xtls-rprx-vision",
            "id": "${XRAY_UUID}"
          }
        ],
        "decryption": "none"
      },
      "sniffing": {
        "destOverride": [
          "http",
          "tls",
          "quic",
          "fakedns"
        ],
        "enabled": true,
        "metadataOnly": true,
        "routeOnly": true
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "dest": "google.com:443",
          "privateKey": "${XRAY_PRIVATE_KEY}",
          "serverNames": [
            "google.com",
            "www.google.com"
          ],
          "shortIds": [
            "${XRAY_SHORT_ID}"
          ],
          "show": false,
          "xver": 0
        },
        "tcpSettings": {
          "header": {
            "type": "none"
          }
        }
      },
      "tag": "inbound-443"
    },
    {
      "listen": "0.0.0.0",
      "port": ${T_PORT},
      "protocol": "dokodemo-door",
      "settings": {
        "address": "127.0.0.1",
        "followRedirect": true,
        "network": "tcp,udp"
      },
      "sniffing": {
        "destOverride": [
          "http",
          "tls",
          "quic",
          "fakedns"
        ],
        "enabled": true,
        "metadataOnly": true,
        "routeOnly": true
      },
      "streamSettings": {
        "sockopt": {
          "mark": 1,
          "tproxy": "tproxy"
        }
      },
      "tag": "tproxy-in"
    }
  ],
  "outbounds": [
    {
      "protocol": "freedom",
      "settings": {
        "domainStrategy": "AsIs"
      },
      "tag": "direct"
    },
    {
      "protocol": "blackhole",
      "settings": {},
      "tag": "blocked"
    }
  ],
  "routing": {
    "domainStrategy": "AsIs",
    "rules": [
      {
        "type": "field",
        "inboundTag": [
          "tproxy-in"
        ],
        "outboundTag": "direct"
      },
      {
        "type": "field",
        "inboundTag": [
          "inbound-443"
        ],
        "outboundTag": "direct"
      },
      {
        "type": "field",
        "outboundTag": "blocked",
        "ip": [
          "geoip:private"
        ]
      },
      {
        "type": "field",
        "outboundTag": "blocked",
        "protocol": [
          "bittorrent"
        ]
      }
    ]
  }
}
EOF
}

cleanup_legacy_adguard_units() {
    systemctl stop AdGuardHome 2>/dev/null || true
    systemctl stop adguardhome 2>/dev/null || true
    systemctl disable adguardhome 2>/dev/null || true
    rm -f /etc/systemd/system/adguardhome.service
    rm -rf /etc/systemd/system/adguardhome.service.d
    systemctl daemon-reload >/dev/null 2>&1 || true
}

ensure_awg_build_dependencies() {
    local header_pkg="linux-headers-$(uname -r)"

    apt install -y git build-essential dkms libmnl-dev libelf-dev "$header_pkg" \
        || err "Не удалось установить точные kernel headers (${header_pkg}) для сборки AmneziaWG."
}

load_existing_awg_credentials() {
    if [ -f "$CREDS_FILE" ] && [ "$ROTATE_CREDS" -eq 0 ]; then
        log "Загрузка существующих credentials AmneziaWG из $CREDS_FILE..."
        SERVER_PRIV=$(read_cred_value "AWG_SERVER_PRIV" "$CREDS_FILE")
        CLIENT_PRIV=$(read_cred_value "AWG_CLIENT_PRIV" "$CREDS_FILE")
        CLIENT_PSK=$(read_cred_value "AWG_CLIENT_PSK" "$CREDS_FILE")
        AWG_PORT=$(read_cred_value "AWG_PORT" "$CREDS_FILE")
        JC=$(read_cred_value "AWG_JC" "$CREDS_FILE")
        JMIN=$(read_cred_value "AWG_JMIN" "$CREDS_FILE")
        JMAX=$(read_cred_value "AWG_JMAX" "$CREDS_FILE")
        S1=$(read_cred_value "AWG_S1" "$CREDS_FILE")
        S2=$(read_cred_value "AWG_S2" "$CREDS_FILE")
        H1=$(read_cred_value "AWG_H1" "$CREDS_FILE")
        H2=$(read_cred_value "AWG_H2" "$CREDS_FILE")
        H3=$(read_cred_value "AWG_H3" "$CREDS_FILE")
        H4=$(read_cred_value "AWG_H4" "$CREDS_FILE")
    fi

    if [ -z "$SERVER_PRIV" ] || [ -z "$CLIENT_PRIV" ] || [ -z "$CLIENT_PSK" ]; then
        if [ -f /etc/amnezia/amneziawg/awg0.conf ] && [ -f /root/amnezia_client.conf ] && [ "$ROTATE_CREDS" -eq 0 ]; then
            log "Восстанавливаем существующие credentials AmneziaWG из текущих конфигов..."
            SERVER_PRIV=$(read_config_assignment "PrivateKey = " /etc/amnezia/amneziawg/awg0.conf)
            CLIENT_PRIV=$(read_config_assignment "PrivateKey = " /root/amnezia_client.conf)
            CLIENT_PSK=$(read_config_assignment "PresharedKey = " /root/amnezia_client.conf)
            AWG_PORT=$(read_config_assignment "ListenPort = " /etc/amnezia/amneziawg/awg0.conf)
            JC=$(read_config_assignment "Jc = " /etc/amnezia/amneziawg/awg0.conf)
            JMIN=$(read_config_assignment "Jmin = " /etc/amnezia/amneziawg/awg0.conf)
            JMAX=$(read_config_assignment "Jmax = " /etc/amnezia/amneziawg/awg0.conf)
            S1=$(read_config_assignment "S1 = " /etc/amnezia/amneziawg/awg0.conf)
            S2=$(read_config_assignment "S2 = " /etc/amnezia/amneziawg/awg0.conf)
            H1=$(read_config_assignment "H1 = " /etc/amnezia/amneziawg/awg0.conf)
            H2=$(read_config_assignment "H2 = " /etc/amnezia/amneziawg/awg0.conf)
            H3=$(read_config_assignment "H3 = " /etc/amnezia/amneziawg/awg0.conf)
            H4=$(read_config_assignment "H4 = " /etc/amnezia/amneziawg/awg0.conf)
        fi
    fi

    [ -n "$SERVER_PRIV" ] && SERVER_PUB=$(printf '%s' "$SERVER_PRIV" | awg pubkey)
    [ -n "$CLIENT_PRIV" ] && CLIENT_PUB=$(printf '%s' "$CLIENT_PRIV" | awg pubkey)
}

validate_stack() {
    local agh_service_name="$1"

    log "Валидация Xray, AmneziaWG и AdGuardHome..."
    xray run -test -config /usr/local/etc/xray/config.json || err "Xray config validation failed."
    systemctl restart xray || err "Не удалось перезапустить xray."
    systemctl restart awg-quick@awg0 || err "Не удалось поднять awg0 после настройки."
    systemctl restart "$agh_service_name" || err "Не удалось перезапустить ${agh_service_name}."

    ss -lntup | grep -Eq ':443 ' || err "Xray не слушает порт 443."
    ss -lntup | grep -Eq ':12345 ' || err "Xray не слушает TProxy порт 12345."
    ss -lntup | grep -Eq ':51820 ' || err "AmneziaWG не слушает порт 51820."
    dig @127.0.0.1 -p "${ADG_DNS_PORT}" example.com +short | grep -q . || err "AdGuardHome не отвечает на локальные DNS-запросы."
    awg show | grep -q '^interface: awg0' || err "AmneziaWG interface awg0 не поднялся."
    sysctl -n net.ipv4.conf.all.src_valid_mark | grep -qx '1' || err "src_valid_mark не включён, TProxy-marked пакеты могут отбрасываться policy routing."
    iptables -C INPUT -i awg0 -m mark --mark 1 -m comment --comment awg-tproxy-input -j ACCEPT \
        || err "Нет INPUT-исключения для marked TProxy-пакетов awg0: UFW может дропать AWG интернет-трафик."
}
# Удаляет устаревшие статические правила iptables DNAT для DNS-порта 53 на awg0,
# которые могли остаться от предыдущих версий скрипта (до переноса правил в PostUp/PostDown).
cleanup_legacy_awg_dns_redirects() {
    iptables -t nat -D PREROUTING -i awg0 -p udp --dport 53 -j REDIRECT --to-port "${ADG_DNS_PORT}" 2>/dev/null || true
    iptables -t nat -D PREROUTING -i awg0 -p tcp --dport 53 -j REDIRECT --to-port "${ADG_DNS_PORT}" 2>/dev/null || true
}

ensure_swapfile() {
    local swapfile="/swapfile"
    local swap_size="1G"
    local fstab_line="/swapfile none swap sw 0 0 # 3x-awg-adg-bundle"

    if swapon --show --noheadings 2>/dev/null | grep -q .; then
        warn "Swap уже активен, пропускаем создание swapfile."
        return 0
    fi

    if [ -f "$swapfile" ]; then
        log "Используем существующий swapfile ${swapfile}."
    else
        log "Создание swapfile ${swapfile} (${swap_size})..."
        if command -v fallocate >/dev/null 2>&1; then
            if ! fallocate -l "$swap_size" "$swapfile"; then
                warn "fallocate не сработал, используем dd для создания swapfile."
                dd if=/dev/zero of="$swapfile" bs=1M count=1024 status=none
            fi
        else
            dd if=/dev/zero of="$swapfile" bs=1M count=1024 status=none
        fi
        chmod 600 "$swapfile"
        mkswap "$swapfile" >/dev/null
    fi

    chmod 600 "$swapfile"
    if ! grep -qF "$fstab_line" /etc/fstab; then
        echo "$fstab_line" >> /etc/fstab
    fi
    swapon "$swapfile"
    log "Swapfile активирован: ${swapfile}"
}

# Проверяем, запускался ли скрипт уже сегодня (для пропуска apt-операций)
TODAY=$(date +%Y-%m-%d)
LAST_RUN=$(cat "$LAST_RUN_FILE" 2>/dev/null || echo "")
if [ "$LAST_RUN" = "$TODAY" ]; then
    SKIP_APT=1
    warn "Скрипт уже запускался сегодня ($TODAY). Пропускаем обновление OS (только перегенерация настроек)."
else
    SKIP_APT=0
fi

trap 'warn "Скрипт прерван! Проверьте состояние вручную. Лог: $LOG_FILE"' ERR INT TERM

if [ "$EUID" -ne 0 ]; then
  err "Запустите скрипт от имени root (sudo -i)"
fi

# ==============================================================================
ensure_swapfile

# 1. БАЗОВАЯ ОПТИМИЗАЦИЯ И БЕЗОПАСНОСТЬ OS
# ==============================================================================
if [ "$SKIP_APT" -eq 0 ]; then
    log "Очистка устаревших репозиториев (удаление bullseye-backports)..."
    sed -i '/bullseye-backports/d' /etc/apt/sources.list
    rm -f /etc/apt/sources.list.d/*backports*.list 2>/dev/null || true

    log "Обновление системы и установка базовых пакетов..."
    apt update && apt upgrade -y
    # Базовые пакеты и точные headers текущего ядра для детерминированной сборки AWG.
    apt install -y curl wget mc ufw fail2ban nano iptables iptables-persistent \
                   jq openssl whois qrencode dnsutils "linux-headers-$(uname -r)" \
        || err "Не удалось установить обязательные пакеты и точные kernel headers для $(uname -r)."
    # Обновляем дату последнего полного запуска
    date +%Y-%m-%d > "$LAST_RUN_FILE"
else
    log "Пропуск apt-операций (fast mode). Убеждаемся в наличии jq, openssl и dig..."
    command -v jq >/dev/null 2>&1 || apt install -y jq
    command -v openssl >/dev/null 2>&1 || apt install -y openssl
    command -v dig >/dev/null 2>&1 || apt install -y dnsutils
fi

if [ "$SKIP_APT" -eq 0 ]; then
    log "Настройка редактора mcedit по умолчанию..."
    update-alternatives --set editor /usr/bin/mcedit || true
    export EDITOR=mcedit
    if ! grep -q "export EDITOR=mcedit" ~/.bashrc; then
        echo 'export EDITOR=mcedit' >> ~/.bashrc
    fi
fi

log "Оптимизация sysctl (сеть, BBR, лимиты)..."
# Удаляем устаревший файл (может содержать ключи из прошлых версий скрипта)
rm -f /etc/sysctl.d/99-custom-net.conf
cat <<EOF > /etc/sysctl.d/99-custom-net.conf
fs.file-max = 1048576
net.core.rmem_max = 67108864
net.core.wmem_max = 67108864
net.core.netdev_max_backlog = 10000
net.core.somaxconn = 4096
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_keepalive_time = 1200
net.ipv4.tcp_max_syn_backlog = 8192
net.ipv4.tcp_max_tw_buckets = 5000
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_mtu_probing = 1
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.ipv4.ip_forward = 1
# Требуется для TProxy: позволяет направлять трафик на loopback-адреса
net.ipv4.conf.all.route_localnet = 1
# Требуется для TProxy policy routing по fwmark, иначе ядро/UFW могут отбрасывать marked-пакеты.
net.ipv4.conf.all.src_valid_mark = 1
net.ipv4.conf.default.src_valid_mark = 1
EOF
sysctl --system 2>&1 | grep -v 'Invalid argument' | grep -v '^$' | head -20 || true

# ==============================================================================
# 2. УСТАНОВКА XRAY
# ==============================================================================
log "Проверка и установка Xray-core..."
SERVER_IP=$(curl -s https://api.ipify.org || wget -qO- https://api.ipify.org)
PUB_INT=$(ip -4 route ls | grep default | grep -Po '(?<=dev )(\S+)' | head -1)
XRAY_PORT=443
T_PORT=12345

# Загружаем или генерируем новые credentials Xray
if [ -f "$CREDS_FILE" ] && [ "$ROTATE_CREDS" -eq 0 ]; then
    log "Загрузка существующих credentials Xray из $CREDS_FILE..."
    XRAY_UUID=$(read_cred_value "XRAY_UUID" "$CREDS_FILE")
    XRAY_PRIVATE_KEY=$(read_cred_value "XRAY_PRIVATE_KEY" "$CREDS_FILE")
    XRAY_PUBLIC_KEY=$(read_cred_value "XRAY_PUBLIC_KEY" "$CREDS_FILE")
    XRAY_SHORT_ID=$(read_cred_value "XRAY_SHORT_ID" "$CREDS_FILE")
    ADG_DNS_PORT=$(read_cred_value "ADG_DNS_PORT" "$CREDS_FILE")
fi

# Если после загрузки переменные пустые, генерируем заново
[ -z "$XRAY_UUID" ] && XRAY_UUID=$(cat /proc/sys/kernel/random/uuid)
[ -z "$XRAY_SHORT_ID" ] && XRAY_SHORT_ID=$(openssl rand -hex 8)

# Prepare the AdGuard DNS listener port early so Xray can point to the final value.
[ -z "$ADG_DNS_PORT" ] && ADG_DNS_PORT=$(shuf -i 10000-65000 -n 1)

if systemctl is-active --quiet xray 2>/dev/null && [ -x /usr/local/bin/xray ]; then
    warn "Xray уже установлен и работает. Перегенерируем конфиг."
else
    install_xray_core
    # Ждём появления бинарника Xray (до 10 секунд)
    for i in $(seq 1 10); do command -v xray >/dev/null 2>&1 && break; sleep 1; done
    command -v xray >/dev/null 2>&1 || err "Бинарный файл xray не найден после установки"
fi

XRAY_BIN="$(resolve_xray_bin || true)"
[ -n "$XRAY_BIN" ] || err "Бинарный файл xray не найден после установки."

if [ -n "$XRAY_PRIVATE_KEY" ] && [ -z "$XRAY_PUBLIC_KEY" ]; then
    log "В credentials Xray найден private key Reality, восстанавливаем public key..."
    DERIVED_OUTPUT="$("$XRAY_BIN" x25519 -i "$XRAY_PRIVATE_KEY" 2>&1 || true)"
    XRAY_PUBLIC_KEY=$(printf '%s\n' "$(_parse_x25519_output "$DERIVED_OUTPUT")" | sed -n '2p')
fi

if [ -z "$XRAY_PRIVATE_KEY" ] || [ -z "$XRAY_PUBLIC_KEY" ]; then
    log "Генерация Reality credentials Xray..."
    generate_reality_keys
fi

[ -n "$XRAY_PRIVATE_KEY" ] || err "Не удалось получить private key Reality."
[ -n "$XRAY_PUBLIC_KEY" ] || err "Не удалось получить public key Reality."
[ -n "$XRAY_SHORT_ID" ] || err "Не удалось сгенерировать shortId Reality."

# ==============================================================================
# 3. ОЧИСТКА LEGACY XRAY CONTROL PLANE
# ==============================================================================
log "Удаление legacy x-ui, если он остался от предыдущих версий..."
remove_legacy_xui

VLESS_LINK="vless://$XRAY_UUID@$SERVER_IP:$XRAY_PORT?type=tcp&security=reality&encryption=none&flow=xtls-rprx-vision&pbk=$XRAY_PUBLIC_KEY&headerType=none&fp=chrome&spx=%2F&sni=google.com&sid=$XRAY_SHORT_ID#VLESS-Reality-Default"

# ==============================================================================
# 5. УСТАНОВКА AMNEZIAWG
# ==============================================================================
log "Проверка AmneziaWG..."
if command -v awg >/dev/null 2>&1 && [ -f /etc/amnezia/amneziawg/awg0.conf ]; then
    warn "AmneziaWG уже настроен, пропускаем переустановку."
else
    ensure_awg_build_dependencies
    if grep -qi "ubuntu" /etc/os-release; then
        log "Используем PPA для Ubuntu..."
        apt install -y software-properties-common python3-launchpadlib gnupg2
        add-apt-repository -y ppa:amnezia/ppa
        apt update
        apt install -y amneziawg
    else
        log "Сборка AmneziaWG из исходников (Debian)..."
        (
            cd /usr/src
            rm -rf amneziawg-linux-kernel-module amneziawg-tools
            git clone https://github.com/amnezia-vpn/amneziawg-linux-kernel-module.git
            cd amneziawg-linux-kernel-module/src
            make dkms-install || make install
        )
        (
            cd /usr/src
            rm -rf amneziawg-tools
            git clone https://github.com/amnezia-vpn/amneziawg-tools.git
            cd amneziawg-tools/src
            make install
        )
    fi
fi
log "Генерация ключей и конфигурации AmneziaWG..."
mkdir -p /etc/amnezia/amneziawg
chmod 700 /etc/amnezia/amneziawg

AWG_PORT=51820
load_existing_awg_credentials

# Параметры обфускации (Рандомизация для защиты от сигнатурного анализа ТСПУ 2026)
[ -z "$JC" ] && JC=$(shuf -i 3-12 -n 1)
[ -z "$JMIN" ] && JMIN=$(shuf -i 40-70 -n 1)
[ -z "$JMAX" ] && JMAX=$(shuf -i 700-1200 -n 1)
[ -z "$S1" ] && S1=$(shuf -i 15-150 -n 1)
[ -z "$S2" ] && S2=$(shuf -i 151-250 -n 1)
[ -z "$H1" ] && H1=$(shuf -i 100000000-999999999 -n 1)
[ -z "$H2" ] && H2=$(shuf -i 100000000-999999999 -n 1)
[ -z "$H3" ] && H3=$(shuf -i 100000000-999999999 -n 1)
[ -z "$H4" ] && H4=$(shuf -i 100000000-999999999 -n 1)
# Случайный порт DNS для AdGuardHome (не 53 — DNAT-редирект в awg0.conf)
[ -z "$ADG_DNS_PORT" ] && ADG_DNS_PORT=$(shuf -i 10000-65000 -n 1)

[ -z "$SERVER_PRIV" ] && SERVER_PRIV=$(awg genkey)
[ -z "$CLIENT_PRIV" ] && CLIENT_PRIV=$(awg genkey)
[ -z "$CLIENT_PSK" ] && CLIENT_PSK=$(awg genpsk)
[ -n "$SERVER_PRIV" ] && [ -z "$SERVER_PUB" ] && SERVER_PUB=$(printf '%s' "$SERVER_PRIV" | awg pubkey)
[ -n "$CLIENT_PRIV" ] && [ -z "$CLIENT_PUB" ] && CLIENT_PUB=$(printf '%s' "$CLIENT_PRIV" | awg pubkey)

cat <<EOF > /etc/amnezia/amneziawg/awg0.conf
[Interface]
Address = 10.8.0.1/24
ListenPort = $AWG_PORT
PrivateKey = $SERVER_PRIV
Jc = $JC
Jmin = $JMIN
Jmax = $JMAX
S1 = $S1
S2 = $S2
H1 = $H1
H2 = $H2
H3 = $H3
H4 = $H4

# Правила NAT и маршрутизации (TPROXY активен)
PostUp = iptables -t nat -A POSTROUTING -s 10.8.0.0/24 -o $PUB_INT -j MASQUERADE
# DNAT: перенаправляем DNS от VPN-клиентов (порт 53) -> AdGuardHome (порт $ADG_DNS_PORT)
PostUp = iptables -t nat -A PREROUTING -i awg0 -p udp --dport 53 -j REDIRECT --to-port $ADG_DNS_PORT
PostUp = iptables -t nat -A PREROUTING -i awg0 -p tcp --dport 53 -j REDIRECT --to-port $ADG_DNS_PORT

# TProxy Routing (REDIRECT AWG traffic to Xray)
PostUp = ip rule add fwmark 1 table 100 2>/dev/null || true
PostUp = ip route add local 0.0.0.0/0 dev lo table 100 2>/dev/null || true
PostUp = iptables -t mangle -N AWG_TPROXY 2>/dev/null || true
PostUp = iptables -t mangle -F AWG_TPROXY
PostUp = iptables -t mangle -A AWG_TPROXY -d 0.0.0.0/8 -j RETURN
PostUp = iptables -t mangle -A AWG_TPROXY -d 10.0.0.0/8 -j RETURN
PostUp = iptables -t mangle -A AWG_TPROXY -d 100.64.0.0/10 -j RETURN
PostUp = iptables -t mangle -A AWG_TPROXY -d 169.254.0.0/16 -j RETURN
PostUp = iptables -t mangle -A AWG_TPROXY -d 172.16.0.0/12 -j RETURN
PostUp = iptables -t mangle -A AWG_TPROXY -d 192.168.0.0/16 -j RETURN
PostUp = iptables -t mangle -A AWG_TPROXY -d 224.0.0.0/4 -j RETURN
PostUp = iptables -t mangle -A AWG_TPROXY -d 240.0.0.0/4 -j RETURN
PostUp = iptables -t mangle -A AWG_TPROXY -d $SERVER_IP -j RETURN
PostUp = iptables -t mangle -A AWG_TPROXY -d 127.0.0.0/8 -j RETURN
PostUp = iptables -t mangle -A AWG_TPROXY -p udp --dport 53 -j RETURN
PostUp = iptables -t mangle -A AWG_TPROXY -p tcp --dport 53 -j RETURN
PostUp = iptables -t mangle -A AWG_TPROXY -p tcp -j TPROXY --on-port 12345 --tproxy-mark 1
PostUp = iptables -t mangle -A AWG_TPROXY -p udp -j TPROXY --on-port 12345 --tproxy-mark 1
PostUp = iptables -t mangle -A PREROUTING -i awg0 -j AWG_TPROXY
# UFW видит TProxy-пакеты как non-local и может уронить их в ufw-not-local без явного allow по mark.
PostUp = iptables -I INPUT 1 -i awg0 -m mark --mark 1 -m comment --comment awg-tproxy-input -j ACCEPT

PostDown = iptables -t nat -D POSTROUTING -s 10.8.0.0/24 -o $PUB_INT -j MASQUERADE 2>/dev/null || true
PostDown = iptables -t nat -D PREROUTING -i awg0 -p udp --dport 53 -j REDIRECT --to-port $ADG_DNS_PORT 2>/dev/null || true
PostDown = iptables -t nat -D PREROUTING -i awg0 -p tcp --dport 53 -j REDIRECT --to-port $ADG_DNS_PORT 2>/dev/null || true
PostDown = iptables -t mangle -D PREROUTING -i awg0 -j AWG_TPROXY 2>/dev/null || true
PostDown = iptables -t mangle -F AWG_TPROXY 2>/dev/null || true
PostDown = iptables -t mangle -X AWG_TPROXY 2>/dev/null || true
PostDown = iptables -D INPUT -i awg0 -m mark --mark 1 -m comment --comment awg-tproxy-input -j ACCEPT 2>/dev/null || true
PostDown = ip rule del fwmark 1 table 100 2>/dev/null || true
PostDown = ip route del local 0.0.0.0/0 dev lo table 100 2>/dev/null || true

[Peer]
PublicKey = $CLIENT_PUB
PresharedKey = $CLIENT_PSK
AllowedIPs = 10.8.0.2/32
EOF

cleanup_legacy_awg_dns_redirects
systemctl enable awg-quick@awg0
systemctl restart awg-quick@awg0 || err "Не удалось поднять awg0. Проверьте сборку модуля AmneziaWG для $(uname -r)."

# Конфигурация клиента
cat <<EOF > /root/amnezia_client.conf
[Interface]
PrivateKey = $CLIENT_PRIV
Address = 10.8.0.2/32
DNS = 10.8.0.1
Jc = $JC
Jmin = $JMIN
Jmax = $JMAX
S1 = $S1
S2 = $S2
H1 = $H1
H2 = $H2
H3 = $H3
H4 = $H4

[Peer]
PublicKey = $SERVER_PUB
PresharedKey = $CLIENT_PSK
Endpoint = $SERVER_IP:$AWG_PORT
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25
EOF
chmod 600 /root/amnezia_client.conf

# ==============================================================================
# 6. УСТАНОВКА И НАСТРОЙКА ADGUARD HOME
# ==============================================================================
log "Установка AdGuardHome..."
# DNS на случайном порту $ADG_DNS_PORT — systemd-resolved отключать не нужно

# Загружаем или генерируем новые credentials AdGuardHome
if [ -f "$CREDS_FILE" ] && [ "$ROTATE_CREDS" -eq 0 ]; then
    log "Загрузка существующих credentials AdGuardHome из $CREDS_FILE..."
    ADG_PORT=$(read_url_port "ADG_URL" "$CREDS_FILE")
    ADG_USER=$(read_cred_value "ADG_USER" "$CREDS_FILE")
    ADG_PASS=$(read_cred_value "ADG_PASS" "$CREDS_FILE")
    ADG_DNS_PORT=$(read_cred_value "ADG_DNS_PORT" "$CREDS_FILE")
fi

# Если пустые, генерируем заново
[ -z "$ADG_PORT" ] && ADG_PORT=$(shuf -i 10000-65000 -n 1)
[ -z "$ADG_USER" ] && ADG_USER=$(tr -dc A-Za-z0-9 </dev/urandom | head -c 8)
[ -z "$ADG_PASS" ] && ADG_PASS=$(tr -dc A-Za-z0-9 </dev/urandom | head -c 12)
[ -z "$ADG_DNS_PORT" ] && ADG_DNS_PORT=$(shuf -i 10000-65000 -n 1)
command -v mkpasswd >/dev/null || apt install -y whois
ADG_HASH=$(mkpasswd -m bcrypt "$ADG_PASS")

# Устанавливаем AdGuardHome только если бинарника нет
if [ ! -f "/opt/AdGuardHome/AdGuardHome" ]; then
    log "Установка AdGuardHome..."
    curl -s -S -L https://raw.githubusercontent.com/AdguardTeam/AdGuardHome/master/scripts/install.sh | sh -s -- -v
else
    warn "AdGuardHome бинарник уже существует, пропуск установки."
fi

# Всегда перезаписываем конфиг (новые порт, логин, пароль)
log "Применение конфигурации AdGuardHome..."

# Останавливаем активные инстансы и удаляем legacy lower-case unit.
cleanup_legacy_adguard_units

cat <<EOF > /opt/AdGuardHome/AdGuardHome.yaml
http:
  pprof:
    port: 6060
    enabled: false
  address: 0.0.0.0:$ADG_PORT
  session_ttl: 720h
users:
  - name: $ADG_USER
    password: $ADG_HASH
auth_attempts: 5
block_auth_min: 15
http_proxy: ""
language: ru
theme: auto
dns:
  bind_hosts:
    - 0.0.0.0
  port: $ADG_DNS_PORT
  upstream_dns:
    - 1.1.1.1
    - 8.8.8.8
  cache_size: 4194304
filtering:
  safe_search:
    enabled: true
    bing: true
    duckduckgo: true
    google: true
    pixabay: true
    yandex: true
    youtube: true
filters:
  - enabled: true
    url: https://adguardteam.github.io/HostlistsRegistry/assets/filter_1.txt
    name: AdGuard DNS filter
    id: 1
  - enabled: true
    url: https://adguardteam.github.io/HostlistsRegistry/assets/filter_2.txt
    name: AdAway Default Blocklist
    id: 2
EOF

# Регистрируем systemd-юнит AdGuardHome. Используем одно canonical имя сервиса.
AGH_SVC_NAME="AdGuardHome"
if ! systemctl list-unit-files 2>/dev/null | grep -qi 'AdGuardHome\.service'; then
    log "Регистрация AdGuardHome в systemd..."
    /opt/AdGuardHome/AdGuardHome -s install 2>/dev/null || true
    systemctl daemon-reload
fi

if ! systemctl list-unit-files 2>/dev/null | grep -qi 'AdGuardHome\.service'; then
    cat <<UNIT > /etc/systemd/system/AdGuardHome.service
[Unit]
Description=AdGuard Home: Network-level blocker
After=syslog.target network-online.target

[Service]
User=root
WorkingDirectory=/opt/AdGuardHome
ExecStart=/opt/AdGuardHome/AdGuardHome -s run
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
UNIT
    systemctl daemon-reload
fi

# Добавляем override: запускать ПОСЛЕ awg0
mkdir -p "/etc/systemd/system/${AGH_SVC_NAME}.service.d"
cat <<OVERRIDE > "/etc/systemd/system/${AGH_SVC_NAME}.service.d/after-awg.conf"
[Unit]
After=awg-quick@awg0.service network-online.target
Wants=awg-quick@awg0.service network-online.target
[Service]
Restart=on-failure
RestartSec=5
OVERRIDE

systemctl daemon-reload
systemctl enable "${AGH_SVC_NAME}" 2>/dev/null || true

# Ждём интерфейс awg0 (до 15с), затем стартуем
for _i in $(seq 1 15); do ip link show awg0 > /dev/null 2>&1 && break; sleep 1; done
systemctl restart "${AGH_SVC_NAME}"

# Проверяем что AGH реально слушает на ADG_DNS_PORT
for _i in $(seq 1 10); do ss -ulnp | grep ":${ADG_DNS_PORT} " > /dev/null 2>&1 && break; sleep 1; done
if ss -ulnp | grep ":${ADG_DNS_PORT} " > /dev/null 2>&1; then
    log "AdGuardHome DNS (порт ${ADG_DNS_PORT}) слушает — OK"
else
    warn "AdGuardHome НЕ слушает на порту ${ADG_DNS_PORT}! Проверьте: journalctl -u ${AGH_SVC_NAME} -n 50"
fi

# Пишем прямой конфиг Xray после того, как известен финальный DNS-порт AGH.
log "Запись прямого конфига Xray..."
write_xray_config
xray run -test -config /usr/local/etc/xray/config.json || err "Xray config validation failed."
log "Перезапуск xray для применения конфигурации..."
systemctl restart xray
# Ждём поднятия Xray на порту 443
for _i in $(seq 1 15); do ss -tlnp | grep ':443 ' > /dev/null 2>&1 && break; sleep 1; done
if ss -tlnp | grep ':443 ' > /dev/null 2>&1; then
    log "Xray Reality (порт 443) слушает — OK"
else
    err "Xray НЕ слушает на порту 443! Проверьте: journalctl -u xray -n 50"
fi

# ==============================================================================
# 7. НАСТРОЙКА SSH И ФАЕРВОЛА
# ==============================================================================
log "Настройка UFW..."
if ss -tlnp | grep -q ':2244'; then
    warn "SSH уже на порту 2244, настраиваем правила для него."
    ufw allow 2244/tcp 2>/dev/null || true
else
    ufw allow 22/tcp 2>/dev/null || true
fi

ufw default allow outgoing
ufw allow 443/tcp
ufw allow ${ADG_PORT}/tcp
ufw allow ${AWG_PORT}/udp
# Разрешаем трафик к AGH DNS порту от VPN-клиентов (DNAT: awg0:53 -> 0.0.0.0:ADG_DNS_PORT)
ufw allow in on awg0 to any port ${ADG_DNS_PORT}
sed -i 's/DEFAULT_FORWARD_POLICY="DROP"/DEFAULT_FORWARD_POLICY="ACCEPT"/' /etc/default/ufw
ufw --force enable
if ! ss -tlnp | grep -q ':2244'; then
    log "Изменение порта SSH на 2244..."
    sed -i '/^#\?Port /d' /etc/ssh/sshd_config
    echo "Port 2244" >> /etc/ssh/sshd_config
    mkdir -p /etc/ssh/sshd_config.d
    echo "Port 2244" > /etc/ssh/sshd_config.d/custom_port.conf 2>/dev/null || true
    systemctl restart sshd
    sleep 2
    if ss -tlnp | grep -q ':2244'; then
        ufw allow 2244/tcp 2>/dev/null || true
        ufw delete allow 22/tcp 2>/dev/null || true
        log "SSH порт 2244 активен"
    fi
fi

# Настройка Fail2Ban для SSH
log "Настройка Fail2Ban (SSH)..."
cat <<EOF > /etc/fail2ban/jail.d/vpn-bundle.local
[sshd]
enabled = true
port = 2244
mode = aggressive
backend = systemd
maxretry = 5
findtime = 10m
bantime = 1h
EOF
systemctl restart fail2ban

validate_stack "${AGH_SVC_NAME}"

# 8. ОЧИСТКА И УДАЛЕНИЕ ИНСТРУМЕНТОВ СБОРКИ
# ==============================================================================
log "Удаление инструментов сборки (Hardening) и очистка кэша..."
if [ "$SKIP_APT" -eq 0 ]; then
    # Удаляем пакеты сборки (dkms оставляем для пересборки модуля при обновлении ядра)
    apt purge -y git build-essential libelf-dev libmnl-dev > /dev/null 2>&1 || true
    apt autoremove -y > /dev/null 2>&1
    apt clean
    rm -rf /usr/src/amneziawg-linux-kernel-module
    rm -rf /usr/src/amneziawg-tools
else
    log "Пропуск очистки apt (fast mode)."
fi

# ==============================================================================
# 9. СОХРАНЕНИЕ CREDENTIALS И ФИНАЛЬНЫЙ ВЫВОД
# ==============================================================================
cat <<CREDS > "$CREDS_FILE"
# 3x-awg-adg-bundle credentials (v${SCRIPT_VERSION})
# Generated: $(date -Iseconds)
# ====================================
SSH_PORT=2244
XRAY_PORT=443
XRAY_UUID=${XRAY_UUID}
XRAY_PRIVATE_KEY=${XRAY_PRIVATE_KEY}
XRAY_PUBLIC_KEY=${XRAY_PUBLIC_KEY}
XRAY_SHORT_ID=${XRAY_SHORT_ID}
VLESS_LINK=${VLESS_LINK}
ADG_URL=http://${SERVER_IP}:${ADG_PORT}/
ADG_USER=${ADG_USER}
ADG_PASS=${ADG_PASS}
ADG_DNS_PORT=${ADG_DNS_PORT}
AWG_PORT=${AWG_PORT}
AWG_SERVER_PRIV=${SERVER_PRIV}
AWG_CLIENT_PRIV=${CLIENT_PRIV}
AWG_CLIENT_PSK=${CLIENT_PSK}
AWG_JC=${JC}
AWG_JMIN=${JMIN}
AWG_JMAX=${JMAX}
AWG_S1=${S1}
AWG_S2=${S2}
AWG_H1=${H1}
AWG_H2=${H2}
AWG_H3=${H3}
AWG_H4=${H4}
AWG_CLIENT_CONF=/root/amnezia_client.conf
CREDS
chmod 600 "$CREDS_FILE"


log "Установка и настройка успешно завершены!"
echo -e "\n=================================================================="
echo -e "${GREEN}SSH доступ:${RESET}"
echo -e "Порт: ${YELLOW}2244${RESET}"

echo -e "\n${GREEN}Xray Reality:${RESET}"
echo -e "Порт: ${YELLOW}443${RESET}"
echo -e "Конфиг: ${YELLOW}/usr/local/etc/xray/config.json${RESET}"
echo -e "Дефолтная ссылка VLESS (Reality): ${YELLOW}${VLESS_LINK}${RESET}"
echo -e "\n${GREEN}AdGuardHome:${RESET}"
echo -e "Админка (Web UI): ${YELLOW}http://${SERVER_IP}:${ADG_PORT}/${RESET}"
echo -e "DNS реальный порт: ${YELLOW}${ADG_DNS_PORT}${RESET} (клиент видит 10.8.0.1:53 через DNAT)"
echo -e "User: ${YELLOW}${ADG_USER}${RESET} / Pass: ${YELLOW}${ADG_PASS}${RESET}"
echo -e "Безопасный поиск: ${GREEN}ВКЛЮЧЕН${RESET}"

echo -e "\n${GREEN}AmneziaWG:${RESET}"
echo -e "Конфиг сохранен в: ${YELLOW}/root/amnezia_client.conf${RESET}"
echo -e "${YELLOW}--- СОДЕРЖИМОЕ CONFIG-ФАЙЛА (для копирования) ---${RESET}"
cat /root/amnezia_client.conf
echo -e "${YELLOW}--- КОНЕЦ КОНФИГА ---${RESET}"

echo -e "\nQR-код для мобильного клиента:"
qrencode -t ansiutf8 < /root/amnezia_client.conf

echo -e "\n${GREEN}Все credentials сохранены:${RESET} ${YELLOW}${CREDS_FILE}${RESET}"
echo -e "==================================================================\n"
echo -e "${RED}ВНИМАНИЕ: Выполните 'sudo reboot' для окончательной активации AmneziaWG!${RESET}\n"
