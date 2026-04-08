#!/bin/bash
# Name: VPS Environment Setup Script
# Description: Configures OS networking, 3x-ui, AmneziaWG and AdGuardHome on Debian 11 and Ubuntu.
# Usage: sudo ./setup.sh
# Behavior: Updates sysctl, installs OS packages, compiles AmneziaWG kernel module, sets up AdGuard.
# Returns: Complete VPN and DNS server proxy routing.
# Fails: If run without root privileges.
# ==============================================================================
# Комплексный скрипт настройки Debian 11/Ubuntu: OS Optimization + 3x-ui + AmneziaWG + AdGuardHome
# ==============================================================================

set -e
export DEBIAN_FRONTEND=noninteractive
export RANDFILE=/tmp/.rnd

# Цвета для вывода
GREEN="\e[32m"
RED="\e[31m"
YELLOW="\e[33m"
RESET="\e[0m"

log() { echo -e "${GREEN}[INFO] $1${RESET}"; }
warn() { echo -e "${YELLOW}[WARN] $1${RESET}"; }
err() { echo -e "${RED}[ERROR] $1${RESET}"; exit 1; }

if [ "$EUID" -ne 0 ]; then
  err "Запустите скрипт от имени root (sudo -i)"
fi

# ==============================================================================
# 1. БАЗОВАЯ ОПТИМИЗАЦИЯ И БЕЗОПАСНОСТЬ OS
# ==============================================================================
log "Очистка устаревших репозиториев (удаление bullseye-backports)..."
sed -i '/bullseye-backports/d' /etc/apt/sources.list
rm -f /etc/apt/sources.list.d/*backports*.list 2>/dev/null || true

log "Обновление системы и установка базовых пакетов..."
apt update && apt upgrade -y
# Устанавливаем инструменты сборки (build-essential, git, libelf-dev) для AmneziaWG.
# Они будут удалены в конце скрипта для повышения безопасности.
if grep -qi "ubuntu" /etc/os-release; then
    LINUX_HEADERS="linux-headers-generic"
else
    LINUX_HEADERS="linux-headers-amd64"
fi

apt install -y curl wget git mc ufw fail2ban nano iptables iptables-persistent \
               build-essential dkms $LINUX_HEADERS jq openssl libmnl-dev sqlite3 libelf-dev

log "Настройка редактора mcedit по умолчанию..."
update-alternatives --set editor /usr/bin/mcedit || true
export EDITOR=mcedit
if ! grep -q "export EDITOR=mcedit" ~/.bashrc; then
    echo 'export EDITOR=mcedit' >> ~/.bashrc
fi

log "Оптимизация sysctl (сеть, BBR, лимиты)..."
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
sysctl --system > /dev/null

# ==============================================================================
# 2. УСТАНОВКА 3X-UI
# ==============================================================================
log "Установка 3x-ui..."
SERVER_IP=$(curl -s https://api.ipify.org || wget -qO- https://api.ipify.org)
PANEL_USER=$(tr -dc A-Za-z0-9 </dev/urandom | head -c 8)
PANEL_PASS=$(tr -dc A-Za-z0-9 </dev/urandom | head -c 12)
PANEL_PORT=2053
PANEL_PATH=$(tr -dc a-z0-9 </dev/urandom | head -c 16)

# Автоматизируем ответы на запросы инсталлятора 3x-ui
bash <(curl -Ls https://raw.githubusercontent.com/mhsanaei/3x-ui/master/install.sh) <<EOF
y
${PANEL_USER}
${PANEL_PASS}
${PANEL_PORT}
EOF

# Применение защитного пути в БД 3x-ui
sqlite3 /etc/x-ui/x-ui.db "UPDATE settings SET value = '/${PANEL_PATH}/' WHERE key = 'webBasePath';"
systemctl restart x-ui

# ==============================================================================
# 3. УСТАНОВКА AMNEZIAWG
# ==============================================================================
log "Установка AmneziaWG..."
if grep -qi "ubuntu" /etc/os-release; then
    log "Используем PPA для Ubuntu..."
    apt install -y software-properties-common python3-launchpadlib gnupg2
    add-apt-repository -y ppa:amnezia/ppa
    apt update
    apt install -y amneziawg
else
    log "Сборка AmneziaWG Kernel Module и Tools из исходников (Debian)..."
    cd /usr/src
    rm -rf amneziawg-linux-kernel-module amneziawg-tools
    git clone https://github.com/amnezia-vpn/amneziawg-linux-kernel-module.git
    cd amneziawg-linux-kernel-module/src
    make dkms-install || make install

    cd /usr/src
    git clone https://github.com/amnezia-vpn/amneziawg-tools.git
    cd amneziawg-tools/src
    make install
    cd /root
fi
log "Генерация ключей и конфигурации AmneziaWG..."
mkdir -p /etc/amnezia/amneziawg
chmod 700 /etc/amnezia/amneziawg

# Параметры обфускации (Рандомизация для защиты от сигнатурного анализа ТСПУ 2026)
JC=$(shuf -i 3-12 -n 1)
JMIN=$(shuf -i 40-70 -n 1)
JMAX=$(shuf -i 700-1200 -n 1)
S1=$(shuf -i 15-150 -n 1)
S2=$(shuf -i 151-250 -n 1)
H1=$(shuf -i 100000000-999999999 -n 1)
H2=$(shuf -i 100000000-999999999 -n 1)
H3=$(shuf -i 100000000-999999999 -n 1)
H4=$(shuf -i 100000000-999999999 -n 1)
AWG_PORT=51820

SERVER_PRIV=$(awg genkey)
SERVER_PUB=$(echo "$SERVER_PRIV" | awg pubkey)
CLIENT_PRIV=$(awg genkey)
CLIENT_PUB=$(echo "$CLIENT_PRIV" | awg pubkey)
CLIENT_PSK=$(awg genpsk)

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

# Правила маршрутизации AWG -> 3x-ui (TPROXY)
PostUp = ip rule add fwmark 1 table 100 2>/dev/null || true
PostUp = ip route add local 0.0.0.0/0 dev lo table 100 2>/dev/null || true
PostUp = iptables -t mangle -F AWG_TPROXY 2>/dev/null || true
PostUp = iptables -t mangle -X AWG_TPROXY 2>/dev/null || true
PostUp = iptables -t mangle -N AWG_TPROXY
PostUp = iptables -t mangle -A AWG_TPROXY -d 10.8.0.1/32 -j RETURN
PostUp = iptables -t mangle -A AWG_TPROXY -d 127.0.0.0/8 -j RETURN
PostUp = iptables -t mangle -A AWG_TPROXY -p tcp -j TPROXY --on-port 12345 --tproxy-mark 1
PostUp = iptables -t mangle -A AWG_TPROXY -p udp -j TPROXY --on-port 12345 --tproxy-mark 1
PostUp = iptables -t mangle -A PREROUTING -i awg0 -j AWG_TPROXY

PostDown = iptables -t mangle -D PREROUTING -i awg0 -j AWG_TPROXY 2>/dev/null || true
PostDown = iptables -t mangle -F AWG_TPROXY 2>/dev/null || true
PostDown = iptables -t mangle -X AWG_TPROXY 2>/dev/null || true
PostDown = ip rule del fwmark 1 table 100 2>/dev/null || true
PostDown = ip route del local 0.0.0.0/0 dev lo table 100 2>/dev/null || true

[Peer]
PublicKey = $CLIENT_PUB
PresharedKey = $CLIENT_PSK
AllowedIPs = 10.8.0.2/32
EOF

systemctl enable awg-quick@awg0
set +e
systemctl restart awg-quick@awg0 || warn "Модуль ядра не загружен. Требуется reboot!"
set -e

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
AllowedIPs = 0.0.0.0/0, ::/0
PersistentKeepalive = 25
EOF

# ==============================================================================
# 4. УСТАНОВКА И НАСТРОЙКА ADGUARD HOME
# ==============================================================================
log "Установка AdGuardHome..."
if [ ! -f "/opt/AdGuardHome/AdGuardHome" ]; then
    curl -s -S -L https://raw.githubusercontent.com/AdguardTeam/AdGuardHome/master/scripts/install.sh | sh -s -- -v
fi

systemctl stop AdGuardHome || true
cat <<EOF > /opt/AdGuardHome/AdGuardHome.yaml
bind_host: 0.0.0.0
bind_port: 5353
users:
  - name: admin
    password: \$2y\$05\$S.r2W/56l1D9.35U7Jp3I.vG9iH.z9/1R.Q/o6h9K8n.Y8l.Y/.G2
dns:
  bind_hosts:
    - 0.0.0.0
  port: 53
  upstream_dns:
    - https://dns.cloudflare.com/dns-query
    - https://dns.google/dns-query
  bootstrap_dns:
    - 1.1.1.1
    - 8.8.8.8
EOF
systemctl start AdGuardHome

# ==============================================================================
# 5. НАСТРОЙКА SSH И ФАЕРВОЛА
# ==============================================================================
log "Настройка UFW..."
ufw --force reset
ufw default deny incoming
ufw default allow outgoing
ufw allow 22/tcp
ufw allow 2244/tcp
ufw allow 80/tcp
ufw allow 443/tcp
ufw allow 5353/tcp
ufw allow 53/tcp
ufw allow 53/udp
ufw allow 2053/tcp
ufw allow 51820/udp
sed -i 's/DEFAULT_FORWARD_POLICY="DROP"/DEFAULT_FORWARD_POLICY="ACCEPT"/' /etc/default/ufw
ufw --force enable

log "Изменение порта SSH на 2244..."
sed -i '/^#\?Port /d' /etc/ssh/sshd_config
echo "Port 2244" >> /etc/ssh/sshd_config
mkdir -p /etc/ssh/sshd_config.d
echo "Port 2244" > /etc/ssh/sshd_config.d/custom_port.conf 2>/dev/null || true
systemctl restart sshd
ufw delete allow 22/tcp >/dev/null 2>&1 || true

# ==============================================================================
# 6. ОЧИСТКА И УДАЛЕНИЕ ИНСТРУМЕНТОВ СБОРКИ
# ==============================================================================
log "Удаление инструментов сборки (Hardening) и очистка кэша..."
# Удаляем тяжелые пакеты, которые больше не нужны для работы прокси
apt purge -y git > /dev/null 2>&1 || true
apt autoremove -y > /dev/null 2>&1
apt clean
rm -rf /usr/src/amneziawg-linux-kernel-module
rm -rf /usr/src/amneziawg-tools

# ==============================================================================
# 7. ФИНАЛЬНЫЙ ВЫВОД
# ==============================================================================
log "Установка и настройка успешно завершены!"
echo -e "\n=================================================================="
echo -e "${GREEN}SSH доступ:${RESET}"
echo -e "Порт: ${YELLOW}2244${RESET}"
echo -e "\n${GREEN}Панель 3x-ui:${RESET}"
echo -e "URL: ${YELLOW}http://${SERVER_IP}:${PANEL_PORT}/${PANEL_PATH}/${RESET}"
echo -e "User: ${YELLOW}${PANEL_USER}${RESET} / Pass: ${YELLOW}${PANEL_PASS}${RESET}"
echo -e "\n${GREEN}AdGuardHome:${RESET}"
echo -e "URL: ${YELLOW}http://${SERVER_IP}:5353${RESET} (admin / admin)"
echo -e "\n${GREEN}AmneziaWG:${RESET}"
echo -e "Конфиг: ${YELLOW}/root/amnezia_client.conf${RESET}"
echo -e "==================================================================\n"
echo -e "${RED}ВНИМАНИЕ: Выполните 'reboot' для окончательной активации AmneziaWG!${RESET}\n"