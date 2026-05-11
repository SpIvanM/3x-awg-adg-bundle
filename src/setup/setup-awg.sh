#!/bin/bash
# ==============================================================================
# setup-awg.sh
# 5. УСТАНОВКА AMNEZIAWG
# ==============================================================================
set -Ee

# Глобальные переменные по умолчанию
CREDS_FILE=${CREDS_FILE:-"/root/.vpn-credentials"}
ROTATE_CREDS=${ROTATE_CREDS:-0}
SERVER_IP=${SERVER_IP:-$(curl -s https://api.ipify.org || wget -qO- https://api.ipify.org)}
PUB_INT=${PUB_INT:-$(ip route get 8.8.8.8 2>/dev/null | grep -Po '(?<=dev )(\S+)' | head -n1 || echo "eth0")}
[ -z "$PUB_INT" ] && PUB_INT="eth0"
ADG_DNS_PORT=${ADG_DNS_PORT:-$(shuf -i 10000-65000 -n 1)}
AWG_PORT=53

# Логирование
log() { echo -e "\e[32m[INFO] $1\e[0m"; }
warn() { echo -e "\e[33m[WARN] $1\e[0m"; }
err() { echo -e "\e[31m[ERROR] $1\e[0m"; exit 1; }
mark_step() { log "Шаг: $1"; }

if [ "$EUID" -ne 0 ]; then
  err "Запустите скрипт от имени root (sudo -i)"
fi

# Встроенные helper-функции
read_cred_value() {
    local key="$1"
    local file="$2"
    local raw
    raw=$(grep "^${key}=" "$file" 2>/dev/null | head -n1 | cut -d'=' -f2- | xargs || true)
    printf '%s' "$raw" | tr -d '\r'
}

read_config_assignment() {
    local prefix="$1"
    local file="$2"
    local raw
    raw=$(grep "^${prefix}" "$file" 2>/dev/null | head -n1 | cut -d'=' -f2- | xargs || true)
    printf '%s' "$raw" | tr -d '\r'
}

save_cred() {
    local key="$1"
    local val="$2"
    local file="${3:-$CREDS_FILE}"
    touch "$file"
    if grep -q "^${key}=" "$file" 2>/dev/null; then
        sed -i "s|^${key}=.*|${key}=${val}|" "$file"
    else
        echo "${key}=${val}" >> "$file"
    fi
}

resolve_awg_key_bin() {
    command -v wg 2>/dev/null || command -v awg 2>/dev/null || true
}

ensure_awg_build_dependencies() {
    local header_pkg="linux-headers-$(uname -r)"
    apt install -y git build-essential dkms libmnl-dev libelf-dev "$header_pkg" \
        || err "Не удалось установить точные kernel headers (${header_pkg}) для сборки AmneziaWG."
}

load_existing_awg_credentials() {
    local awg_key_bin="${AWG_KEY_BIN:-}"
    if [ -z "$awg_key_bin" ]; then
        awg_key_bin="$(resolve_awg_key_bin || true)"
    fi

    if [ -f "$CREDS_FILE" ] && [ "$ROTATE_CREDS" -eq 0 ]; then
        log "Загрузка существующих credentials AmneziaWG из $CREDS_FILE..."
        SERVER_PRIV=$(read_cred_value "AWG_SERVER_PRIV" "$CREDS_FILE")
        CLIENT_PRIV=$(read_cred_value "AWG_CLIENT_PRIV" "$CREDS_FILE")
        CLIENT_PSK=$(read_cred_value "AWG_CLIENT_PSK" "$CREDS_FILE")
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

    [ -n "$awg_key_bin" ] || err "Не найден awg/wg для восстановления ключей AmneziaWG."

    if [ -n "$SERVER_PRIV" ]; then
        SERVER_PUB=$(printf '%s' "$SERVER_PRIV" | "$awg_key_bin" pubkey)
    fi

    if [ -n "$CLIENT_PRIV" ]; then
        CLIENT_PUB=$(printf '%s' "$CLIENT_PRIV" | "$awg_key_bin" pubkey)
    fi
}

cleanup_legacy_awg_dns_redirects() {
    iptables -t nat -D PREROUTING -i awg0 -p udp --dport 53 -j REDIRECT --to-port "${ADG_DNS_PORT}" 2>/dev/null || true
    iptables -t nat -D PREROUTING -i awg0 -p tcp --dport 53 -j REDIRECT --to-port "${ADG_DNS_PORT}" 2>/dev/null || true
}

ensure_awg_obfuscation_params() {
    [ -z "$JC" ] && JC=$(shuf -i 3-12 -n 1)
    [ -z "$JMIN" ] && JMIN=$(shuf -i 40-70 -n 1)
    [ -z "$JMAX" ] && JMAX=$(shuf -i 700-1200 -n 1)
    [ -z "$S1" ] && S1=$(shuf -i 15-150 -n 1)
    [ -z "$S2" ] && S2=$(shuf -i 151-250 -n 1)
    [ -z "$H1" ] && H1=$(shuf -i 100000000-999999999 -n 1)
    [ -z "$H2" ] && H2=$(shuf -i 100000000-999999999 -n 1)
    [ -z "$H3" ] && H3=$(shuf -i 100000000-999999999 -n 1)
    [ -z "$H4" ] && H4=$(shuf -i 100000000-999999999 -n 1)
}

# ==============================================================================
# ОСНОВНАЯ ЛОГИКА
# ==============================================================================

log "Проверка AmneziaWG..."
mark_step "AmneziaWG: check installation state"
if command -v awg >/dev/null 2>&1 && [ -f /etc/amnezia/amneziawg/awg0.conf ] && (lsmod | grep -q amneziawg || modprobe amneziawg 2>/dev/null); then
    warn "AmneziaWG уже настроен и модуль ядра загружен, пропускаем переустановку."
else
    mark_step "AmneziaWG: install build dependencies"
    ensure_awg_build_dependencies
    if grep -qi "ubuntu" /etc/os-release; then
        mark_step "AmneziaWG: install Ubuntu package"
        log "Используем PPA для Ubuntu..."
        apt install -y software-properties-common python3-launchpadlib gnupg2
        add-apt-repository -y ppa:amnezia/ppa
        apt update
        apt install -y amneziawg
    else
        mark_step "AmneziaWG: build Debian module"
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
mark_step "AmneziaWG: prepare config directory"
mkdir -p /etc/amnezia/amneziawg
chmod 700 /etc/amnezia/amneziawg

mark_step "AmneziaWG: resolve AWG key binary"
AWG_KEY_BIN="$(resolve_awg_key_bin || true)"
[ -n "$AWG_KEY_BIN" ] || err "Не найден awg/wg после установки AmneziaWG."

mark_step "AmneziaWG: load existing credentials"
load_existing_awg_credentials

mark_step "AmneziaWG: generate obfuscation parameters"
ensure_awg_obfuscation_params

mark_step "AmneziaWG: generate server private key"
[ -z "$SERVER_PRIV" ] && SERVER_PRIV=$("$AWG_KEY_BIN" genkey)
mark_step "AmneziaWG: generate client private key"
[ -z "$CLIENT_PRIV" ] && CLIENT_PRIV=$("$AWG_KEY_BIN" genkey)
mark_step "AmneziaWG: generate client preshared key"
[ -z "$CLIENT_PSK" ] && CLIENT_PSK=$("$AWG_KEY_BIN" genpsk)

mark_step "AmneziaWG: derive public keys"
if [ -n "$SERVER_PRIV" ] && [ -z "$SERVER_PUB" ]; then
    SERVER_PUB=$(printf '%s' "$SERVER_PRIV" | "$AWG_KEY_BIN" pubkey)
fi

if [ -n "$CLIENT_PRIV" ] && [ -z "$CLIENT_PUB" ]; then
    CLIENT_PUB=$(printf '%s' "$CLIENT_PRIV" | "$AWG_KEY_BIN" pubkey)
fi

mark_step "AmneziaWG: write awg0.conf"
cat <<EOF > /etc/amnezia/amneziawg/awg0.conf
[Interface]
Address = 10.8.0.1/24
ListenPort = $AWG_PORT
PrivateKey = $SERVER_PRIV
MTU = 1280
Jc = $JC
Jmin = $JMIN
Jmax = $JMAX
S1 = $S1
S2 = $S2
H1 = $H1
H2 = $H2
H3 = $H3
H4 = $H4

# AWG-клиенты выходят напрямую через публичный интерфейс. DNS по-прежнему идёт в AdGuardHome.
PostUp = iptables -t nat -A POSTROUTING -s 10.8.0.0/24 -o $PUB_INT -j MASQUERADE
# DNAT: перенаправляем DNS от VPN-клиентов (порт 53) -> AdGuardHome (порт $ADG_DNS_PORT)
PostUp = iptables -t nat -A PREROUTING -i awg0 -p udp --dport 53 -j REDIRECT --to-port $ADG_DNS_PORT
PostUp = iptables -t nat -A PREROUTING -i awg0 -p tcp --dport 53 -j REDIRECT --to-port $ADG_DNS_PORT

PostDown = iptables -t nat -D POSTROUTING -s 10.8.0.0/24 -o $PUB_INT -j MASQUERADE 2>/dev/null || true
PostDown = iptables -t nat -D PREROUTING -i awg0 -p udp --dport 53 -j REDIRECT --to-port $ADG_DNS_PORT 2>/dev/null || true
PostDown = iptables -t nat -D PREROUTING -i awg0 -p tcp --dport 53 -j REDIRECT --to-port $ADG_DNS_PORT 2>/dev/null || true

[Peer]
PublicKey = $CLIENT_PUB
PresharedKey = $CLIENT_PSK
AllowedIPs = 10.8.0.2/32
EOF

mark_step "AmneziaWG: cleanup legacy DNS redirects"
cleanup_legacy_awg_dns_redirects

mark_step "AmneziaWG: enable awg-quick@awg0"
systemctl enable awg-quick@awg0

mark_step "AmneziaWG: restart awg-quick@awg0"
systemctl restart awg-quick@awg0 || err "Не удалось поднять awg0. Проверьте сборку модуля AmneziaWG."

mark_step "AmneziaWG: write amnezia_client.conf"
cat <<EOF > /root/amnezia_client.conf
[Interface]
PrivateKey = $CLIENT_PRIV
Address = 10.8.0.2/32
DNS = 10.8.0.1
MTU = 1280
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

mark_step "AmneziaWG: save credentials"
save_cred "AWG_PORT" "$AWG_PORT"
save_cred "AWG_SERVER_PRIV" "$SERVER_PRIV"
save_cred "AWG_CLIENT_PRIV" "$CLIENT_PRIV"
save_cred "AWG_CLIENT_PSK" "$CLIENT_PSK"
save_cred "AWG_JC" "$JC"
save_cred "AWG_JMIN" "$JMIN"
save_cred "AWG_JMAX" "$JMAX"
save_cred "AWG_S1" "$S1"
save_cred "AWG_S2" "$S2"
save_cred "AWG_H1" "$H1"
save_cred "AWG_H2" "$H2"
save_cred "AWG_H3" "$H3"
save_cred "AWG_H4" "$H4"
save_cred "AWG_CLIENT_CONF" "/root/amnezia_client.conf"

log "Настройка AmneziaWG завершена."
