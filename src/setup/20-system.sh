# ==============================================================================
# 1. БАЗОВАЯ ОПТИМИЗАЦИЯ И БЕЗОПАСНОСТЬ OS
# ==============================================================================
ensure_swapfile

if [ "$SKIP_APT" -eq 0 ]; then
    log "Очистка устаревших репозиториев (удаление bullseye-backports)..."
    sed -i '/bullseye-backports/d' /etc/apt/sources.list
    rm -f /etc/apt/sources.list.d/*backports*.list 2>/dev/null || true

    log "Обновление системы и установка базовых пакетов..."
    apt update && apt upgrade -y
    # Базовые пакеты и точные headers текущего ядра для детерминированной сборки AWG.
    apt install -y curl wget mc ufw fail2ban nano iptables iptables-persistent \
                   jq openssl whois qrencode dnsutils python3 wireguard-tools "linux-headers-$(uname -r)" \
        || err "Не удалось установить обязательные пакеты и точные kernel headers для $(uname -r)."
    # Обновляем дату последнего полного запуска
    date +%Y-%m-%d > "$LAST_RUN_FILE"
else
    log "Пропуск apt-операций (fast mode). Убеждаемся в наличии jq, openssl, python3 и dig..."
    command -v jq >/dev/null 2>&1 || apt install -y jq
    command -v openssl >/dev/null 2>&1 || apt install -y openssl
    command -v python3 >/dev/null 2>&1 || apt install -y python3
    command -v dig >/dev/null 2>&1 || apt install -y dnsutils
    command -v wg >/dev/null 2>&1 || apt install -y wireguard-tools
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
EOF
sysctl --system 2>&1 | grep -v 'Invalid argument' | grep -v '^$' | head -20 || true

# ==============================================================================
# 2. УСТАНОВКА XRAY
# ==============================================================================
log "Проверка и установка Xray-core..."
SERVER_IP=$(curl -s https://api.ipify.org || wget -qO- https://api.ipify.org)
PUB_INT=$(ip -4 route ls | grep default | grep -Po '(?<=dev )(\S+)' | head -1)
XRAY_PORT=443

# Загружаем или генерируем новые credentials Xray
if [ -f "$CREDS_FILE" ] && [ "$ROTATE_CREDS" -eq 0 ]; then
    log "Загрузка существующих credentials Xray из $CREDS_FILE..."
    XRAY_UUID=$(read_cred_value "XRAY_UUID" "$CREDS_FILE")
    XRAY_PRIVATE_KEY=$(read_cred_value "XRAY_PRIVATE_KEY" "$CREDS_FILE")
    XRAY_PUBLIC_KEY=$(read_cred_value "XRAY_PUBLIC_KEY" "$CREDS_FILE")
    XRAY_SHORT_ID=$(read_cred_value "XRAY_SHORT_ID" "$CREDS_FILE")
    ADG_DNS_PORT=$(read_cred_value "ADG_DNS_PORT" "$CREDS_FILE")
    ADG_HTTP_PROXY_PORT=$(read_cred_value "ADG_HTTP_PROXY_PORT" "$CREDS_FILE")
    CASCADE_ENABLED=$(read_cred_value "CASCADE_ENABLED" "$CREDS_FILE")
    CASCADE_MODE=$(read_cred_value "CASCADE_MODE" "$CREDS_FILE")
    CASCADE_VLESS=$(read_cred_value "CASCADE_VLESS" "$CREDS_FILE")
    CASCADE_ADDRESS=$(read_cred_value "CASCADE_ADDRESS" "$CREDS_FILE")
    CASCADE_PORT=$(read_cred_value "CASCADE_PORT" "$CREDS_FILE")
    CASCADE_UUID=$(read_cred_value "CASCADE_UUID" "$CREDS_FILE")
    CASCADE_FLOW=$(read_cred_value "CASCADE_FLOW" "$CREDS_FILE")
    CASCADE_PBK=$(read_cred_value "CASCADE_PBK" "$CREDS_FILE")
    CASCADE_SNI=$(read_cred_value "CASCADE_SNI" "$CREDS_FILE")
    CASCADE_SID=$(read_cred_value "CASCADE_SID" "$CREDS_FILE")
    CASCADE_FP=$(read_cred_value "CASCADE_FP" "$CREDS_FILE")
    CASCADE_SPX=$(read_cred_value "CASCADE_SPX" "$CREDS_FILE")
    FINAL_MODE=$(read_cred_value "FINAL_MODE" "$CREDS_FILE")
fi

# Если после загрузки переменные пустые, генерируем заново
[ -z "$XRAY_UUID" ] && XRAY_UUID=$(cat /proc/sys/kernel/random/uuid)
[ -z "$XRAY_SHORT_ID" ] && XRAY_SHORT_ID=$(openssl rand -hex 8)

# Prepare the AdGuard DNS listener port early so Xray can point to the final value.
[ -z "$ADG_DNS_PORT" ] && ADG_DNS_PORT=$(shuf -i 10000-65000 -n 1)
[ -z "$ADG_HTTP_PROXY_PORT" ] && ADG_HTTP_PROXY_PORT=$(shuf -i 10000-65000 -n 1)

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
