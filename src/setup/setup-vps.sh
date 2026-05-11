#!/bin/bash
# ==============================================================================
# setup-vps.sh
# 1. БАЗОВАЯ ОПТИМИЗАЦИЯ И БЕЗОПАСНОСТЬ OS
# ==============================================================================
set -Ee

# Глобальные переменные по умолчанию
LAST_RUN_FILE=${LAST_RUN_FILE:-"/root/.vpn-setup-last-run"}
CREDS_FILE=${CREDS_FILE:-"/root/.vpn-credentials"}
DEPLOY_MODE=${DEPLOY_MODE:-"target"}
ROTATE_CREDS=${ROTATE_CREDS:-0}

# Логирование
log() { echo -e "\e[32m[INFO] $1\e[0m"; }
warn() { echo -e "\e[33m[WARN] $1\e[0m"; }
err() { echo -e "\e[31m[ERROR] $1\e[0m"; exit 1; }
mark_step() { log "Шаг: $1"; }

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

if [ -f "$SCRIPT_DIR/10-common.sh" ]; then
    source "$SCRIPT_DIR/10-common.sh"
else
    # Fallback для ensure_swapfile если хелпер не загрузился
    ensure_swapfile() {
        local swapfile="/swapfile"
        local swap_size="1G"
        local fstab_line="/swapfile none swap sw 0 0 # 3x-awg-adg-bundle"

        if swapon --show --noheadings 2>/dev/null | grep -q .; then
            warn "Swap уже активен, пропускаем создание swapfile."
            return 0
        fi

        log "Создание swapfile ${swapfile} (${swap_size})..."
        if command -v fallocate >/dev/null 2>&1; then
            fallocate -l "$swap_size" "$swapfile" || dd if=/dev/zero of="$swapfile" bs=1M count=1024 status=none
        else
            dd if=/dev/zero of="$swapfile" bs=1M count=1024 status=none
        fi
        chmod 600 "$swapfile"
        mkswap "$swapfile" >/dev/null
        if ! grep -qF "$fstab_line" /etc/fstab; then
            echo "$fstab_line" >> /etc/fstab
        fi
        swapon "$swapfile"
        log "Swapfile активирован: ${swapfile}"
    }
fi

if [ -f "$SCRIPT_DIR/14-port-forwarding-helpers.sh" ]; then
    source "$SCRIPT_DIR/14-port-forwarding-helpers.sh"
fi

TODAY=$(date +%Y-%m-%d)
LAST_RUN=$(cat "$LAST_RUN_FILE" 2>/dev/null || echo "")
if [ "$LAST_RUN" = "$TODAY" ]; then
    SKIP_APT=1
else
    SKIP_APT=0
fi

mark_step "System: swapfile and OS packages"
ensure_swapfile

if [ "$SKIP_APT" -eq 0 ]; then
    mark_step "System: apt update and base packages"
    log "Очистка устаревших репозиториев (удаление bullseye-backports)..."
    sed -i '/bullseye-backports/d' /etc/apt/sources.list
    rm -f /etc/apt/sources.list.d/*backports*.list 2>/dev/null || true

    log "Обновление системы и установка базовых пакетов..."
    apt update && DEBIAN_FRONTEND=noninteractive apt upgrade -y
    # Базовые пакеты и точные headers текущего ядра для детерминированной сборки AWG.
    DEBIAN_FRONTEND=noninteractive apt install -y curl wget mc ufw fail2ban nano iptables iptables-persistent \
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
    mark_step "System: editor defaults"
    log "Настройка редактора mcedit по умолчанию..."
    update-alternatives --set editor /usr/bin/mcedit || true
    export EDITOR=mcedit
    if ! grep -q "export EDITOR=mcedit" ~/.bashrc; then
        echo 'export EDITOR=mcedit' >> ~/.bashrc
    fi
fi

mark_step "System: sysctl hardening"
log "Оптимизация sysctl (сеть, BBR, лимиты)..."
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

mark_step "System: prepare runtime context"
log "Подготовка общих сетевых параметров..."
export SERVER_IP=$(curl -s https://api.ipify.org || wget -qO- https://api.ipify.org)
export PUB_INT=$(ip -4 route ls | grep default | grep -Po '(?<=dev )(\S+)' | head -1)

if [ -f "$CREDS_FILE" ] && [ "$ROTATE_CREDS" -eq 0 ]; then
    log "Загрузка существующего DNS порта AdGuardHome из $CREDS_FILE..."
    ADG_DNS_PORT=$(grep "^ADG_DNS_PORT=" "$CREDS_FILE" 2>/dev/null | head -n1 | cut -d'=' -f2- | tr -d '\r' || true)
fi

[ -z "$ADG_DNS_PORT" ] && ADG_DNS_PORT=$(shuf -i 10000-65000 -n 1)
export ADG_DNS_PORT

if [ "$DEPLOY_MODE" = "relay" ]; then
    if command -v prompt_target_details >/dev/null 2>&1; then
        prompt_target_details
    else
        warn "prompt_target_details not found, skipping relay target prompt."
    fi
fi
