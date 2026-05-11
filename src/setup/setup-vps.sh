#!/bin/bash
# ==============================================================================
# setup-vps.sh
# Базовая оптимизация OS и безопасность
# ==============================================================================
set -Ee
export DEBIAN_FRONTEND=noninteractive

# Глобальные переменные по умолчанию
LAST_RUN_FILE=${LAST_RUN_FILE:-"/root/.vpn-setup-last-run"}

# Логирование
log() { echo -e "\e[32m[INFO] $1\e[0m"; }
warn() { echo -e "\e[33m[WARN] $1\e[0m"; }
err() { echo -e "\e[31m[ERROR] $1\e[0m"; exit 1; }
mark_step() { log "Шаг: $1"; }

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

if [ "$EUID" -ne 0 ]; then
  err "Запустите скрипт от имени root (sudo -i)"
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
    apt update && apt upgrade -y
    apt install -y curl wget mc ufw fail2ban nano iptables iptables-persistent \
                   jq openssl whois qrencode dnsutils python3 wireguard-tools "linux-headers-$(uname -r)" \
        || err "Не удалось установить обязательные пакеты."
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
    update-alternatives --set editor /usr/bin/mcedit 2>/dev/null || true
    export EDITOR=mcedit
fi

mark_step "System: sysctl hardening"
log "Оптимизация sysctl (сеть, BBR, лимиты)..."
cat <<EOF > /etc/sysctl.d/99-vpn-server.conf
# Отключение IPv6
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 1

# BBR + fq
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr

# Оптимизация сети
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_mtu_probing = 1
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.ipv4.ip_forward = 1
EOF
sysctl -p /etc/sysctl.d/99-vpn-server.conf

log "Настройка VPS завершена."
