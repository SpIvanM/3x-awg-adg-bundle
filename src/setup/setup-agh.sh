#!/bin/bash
# ==============================================================================
# setup-agh.sh
# УСТАНОВКА И НАСТРОЙКА ADGUARD HOME
# ==============================================================================
set -Ee

# Глобальные переменные по умолчанию
CREDS_FILE=${CREDS_FILE:-"/root/.vpn-credentials"}
ROTATE_CREDS=${ROTATE_CREDS:-0}

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

read_url_port() {
    local key="$1"
    local file="$2"
    local raw
    raw=$(grep "^${key}=" "$file" 2>/dev/null | head -n1 | sed -e 's|.*:| |' -e 's|/.*||' | xargs || true)
    printf '%s' "$raw" | tr -d '\r'
}

cleanup_legacy_adguard_units() {
    systemctl stop AdGuardHome 2>/dev/null || true
    systemctl stop adguardhome 2>/dev/null || true
    systemctl disable adguardhome 2>/dev/null || true
    rm -f /etc/systemd/system/adguardhome.service
    rm -rf /etc/systemd/system/adguardhome.service.d
    systemctl daemon-reload >/dev/null 2>&1 || true
}

install_adguardhome() {
    mark_step "AdGuardHome: load credentials and install binary"
    if [ -f "$CREDS_FILE" ] && [ "$ROTATE_CREDS" -eq 0 ]; then
        log "Загрузка существующих credentials AdGuardHome из $CREDS_FILE..."
        ADG_PORT=$(read_url_port "ADG_URL" "$CREDS_FILE")
        ADG_USER=$(read_cred_value "ADG_USER" "$CREDS_FILE")
        ADG_PASS=$(read_cred_value "ADG_PASS" "$CREDS_FILE")
        ADG_DNS_PORT=$(read_cred_value "ADG_DNS_PORT" "$CREDS_FILE")
    fi

    [ -z "$ADG_PORT" ] && ADG_PORT=$(shuf -i 10000-65000 -n 1)
    [ -z "$ADG_USER" ] && ADG_USER=$(tr -dc A-Za-z0-9 </dev/urandom | head -c 8)
    [ -z "$ADG_PASS" ] && ADG_PASS=$(tr -dc A-Za-z0-9 </dev/urandom | head -c 12)
    [ -z "$ADG_DNS_PORT" ] && ADG_DNS_PORT=$(shuf -i 10000-65000 -n 1)
    
    command -v mkpasswd >/dev/null || apt install -y whois
    ADG_HASH=$(mkpasswd -m bcrypt "$ADG_PASS")

    if [ ! -f "/opt/AdGuardHome/AdGuardHome" ]; then
        log "Установка AdGuardHome..."
        curl -s -S -L https://raw.githubusercontent.com/AdguardTeam/AdGuardHome/master/scripts/install.sh | sh -s -- -v
    else
        warn "AdGuardHome бинарник уже существует, пропуск установки."
    fi
}

configure_adguardhome() {
    mark_step "AdGuardHome: write YAML config"
    log "Применение конфигурации AdGuardHome..."

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
language: ru
theme: auto
dns:
  bind_hosts:
    - 0.0.0.0
  port: $ADG_DNS_PORT
  upstream_dns:
    - https://cloudflare-dns.com/dns-query
    - https://dns.google/dns-query
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

    AGH_SVC_NAME="AdGuardHome"
    mark_step "AdGuardHome: register systemd unit"
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

    mark_step "AdGuardHome: configure after-awg override"
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
    mark_step "AdGuardHome: enable and restart service"
    systemctl enable "${AGH_SVC_NAME}" 2>/dev/null || true

    for _i in $(seq 1 15); do ip link show awg0 > /dev/null 2>&1 && break; sleep 1; done
    systemctl restart "${AGH_SVC_NAME}"

    for _i in $(seq 1 10); do ss -ulnp | grep ":${ADG_DNS_PORT} " > /dev/null 2>&1 && break; sleep 1; done
    if ss -ulnp | grep ":${ADG_DNS_PORT} " > /dev/null 2>&1; then
        log "AdGuardHome DNS (порт ${ADG_DNS_PORT}) слушает — OK"
    else
        warn "AdGuardHome НЕ слушает на порту ${ADG_DNS_PORT}! Проверьте: journalctl -u ${AGH_SVC_NAME} -n 50"
    fi
}

# ==============================================================================
# ОСНОВНАЯ ЛОГИКА
# ==============================================================================

install_adguardhome
configure_adguardhome

log "Настройка AdGuardHome завершена."
