#!/bin/bash
# Name: vps-vpn-triad-uninstall
# Description: Удаляет 3x-ui, AmneziaWG, AdGuardHome и owned lifecycle-настройки bundle.
# Usage: sudo bash uninstall.sh [-y | --yes]
# Behavior: Stops services, removes configs and binaries, deletes only owned forwarding rules, and keeps shared firewall ports intact.
# ==============================================================================

set -e

FORCE_UNINSTALL=0
while [[ "$#" -gt 0 ]]; do
    case $1 in
        --yes|-y) FORCE_UNINSTALL=1; shift ;;
        *) shift ;;
    esac
done

RED="\e[31m"
GREEN="\e[32m"
YELLOW="\e[33m"
RESET="\e[0m"
CREDS_FILE="/root/.vpn-credentials"

log() { echo -e "${GREEN}[INFO] $1${RESET}"; }
warn() { echo -e "${YELLOW}[WARN] $1${RESET}"; }
err() { echo -e "${RED}[ERROR] $1${RESET}"; exit 1; }

read_cred_value() {
    local key="$1"
    local file="$2"

    [ -f "$file" ] || return 0
    awk -F= -v key="$key" '$1 == key { sub(/\r$/, "", $2); print $2; exit }' "$file"
}

detect_public_interface() {
    ip route get 1.1.1.1 2>/dev/null | awk '{ for (i=1; i<=NF; i++) if ($i == "dev") { print $(i+1); exit } }'
}

iptables_delete_rule() {
    local table="$1"
    local chain="$2"
    shift 2

    if [ "$table" = "filter" ]; then
        iptables -D "$chain" "$@" 2>/dev/null || true
    else
        iptables -t "$table" -D "$chain" "$@" 2>/dev/null || true
    fi
}

persist_iptables_rules() {
    if command -v netfilter-persistent >/dev/null 2>&1; then
        netfilter-persistent save
    elif command -v iptables-save >/dev/null 2>&1; then
        mkdir -p /etc/iptables
        iptables-save > /etc/iptables/rules.v4
    fi
}

cleanup_port_forwarding_rules() {
    local target_ip target_awg_port target_reality_port relay_fwd_awg_port relay_fwd_reality_port pub_int

    target_ip=$(read_cred_value "TARGET_IP" "$CREDS_FILE")
    target_awg_port=$(read_cred_value "TARGET_AWG_PORT" "$CREDS_FILE")
    target_reality_port=$(read_cred_value "TARGET_REALITY_PORT" "$CREDS_FILE")
    relay_fwd_awg_port=$(read_cred_value "RELAY_FWD_AWG_PORT" "$CREDS_FILE")
    relay_fwd_reality_port=$(read_cred_value "RELAY_FWD_REALITY_PORT" "$CREDS_FILE")
    pub_int=$(detect_public_interface)

    [ -n "$pub_int" ] || pub_int="eth0"
    [ -n "$target_ip" ] || return 0

    iptables_delete_rule filter FORWARD -m conntrack --ctstate RELATED,ESTABLISHED -m comment --comment "3x-awg relay fwd established" -j ACCEPT

    if [ -n "$relay_fwd_awg_port" ] && [ -n "$target_awg_port" ]; then
        log "Удаление owned relay-forward правила AWG..."
        iptables_delete_rule nat PREROUTING -i "$pub_int" -p udp --dport "$relay_fwd_awg_port" -m comment --comment "3x-awg relay fwd awg prerouting" -j DNAT --to-destination "${target_ip}:${target_awg_port}"
        iptables_delete_rule filter FORWARD -i "$pub_int" -p udp -d "$target_ip" --dport "$target_awg_port" -m comment --comment "3x-awg relay fwd awg forward" -j ACCEPT
        iptables_delete_rule nat POSTROUTING -p udp -d "$target_ip" --dport "$target_awg_port" -m comment --comment "3x-awg relay fwd awg postrouting" -j MASQUERADE
        ufw delete allow "${relay_fwd_awg_port}/udp" 2>/dev/null || true
    fi

    if [ -n "$relay_fwd_reality_port" ] && [ -n "$target_reality_port" ]; then
        log "Удаление owned relay-forward правила Reality..."
        iptables_delete_rule nat PREROUTING -i "$pub_int" -p tcp --dport "$relay_fwd_reality_port" -m comment --comment "3x-awg relay fwd reality prerouting" -j DNAT --to-destination "${target_ip}:${target_reality_port}"
        iptables_delete_rule filter FORWARD -i "$pub_int" -p tcp -d "$target_ip" --dport "$target_reality_port" -m comment --comment "3x-awg relay fwd reality forward" -j ACCEPT
        iptables_delete_rule nat POSTROUTING -p tcp -d "$target_ip" --dport "$target_reality_port" -m comment --comment "3x-awg relay fwd reality postrouting" -j MASQUERADE
        ufw delete allow "${relay_fwd_reality_port}/tcp" 2>/dev/null || true
    fi

    persist_iptables_rules
}

if [ "$EUID" -ne 0 ]; then
  err "Запустите скрипт от имени root (sudo -i)"
fi

if [ "$FORCE_UNINSTALL" -ne 1 ]; then
    if [ -e /dev/tty ]; then
        read -r -p "Эта операция удалит VPN, DNS, 3x-ui и owned forwarding-правила. Продолжить? (y/n) " -n 1 REPLY </dev/tty
        echo >/dev/tty
    else
        err "Подтвердите удаление из интерактивного терминала или запустите uninstall.sh с --yes."
    fi

    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        exit 1
    fi
fi

log "Удаление owned relay forwarding..."
cleanup_port_forwarding_rules

log "Остановка и удаление 3x-ui..."
warn "3x-ui установлен интерактивно; uninstall удаляет файлы панели, но не управляет ручной конфигурацией Reality."
systemctl stop x-ui 2>/dev/null || true
systemctl disable x-ui 2>/dev/null || true
rm -rf /usr/local/x-ui /etc/x-ui /etc/systemd/system/x-ui.service

log "Удаление legacy direct Xray-артефактов от старых версий..."
systemctl stop xray 2>/dev/null || true
systemctl disable xray 2>/dev/null || true
rm -rf /usr/local/bin/xray /usr/local/etc/xray
rm -rf /etc/systemd/system/xray.service /etc/systemd/system/xray@.service /var/log/xray
systemctl daemon-reload 2>/dev/null || true

log "Остановка и удаление AmneziaWG..."
systemctl stop awg-quick@awg0 2>/dev/null || true
systemctl disable awg-quick@awg0 2>/dev/null || true
rm -rf /etc/amnezia/amneziawg /etc/systemd/system/awg-quick@.service

log "Остановка и удаление AdGuardHome..."
/opt/AdGuardHome/AdGuardHome -s uninstall 2>/dev/null || true
systemctl stop AdGuardHome 2>/dev/null || true
systemctl disable AdGuardHome 2>/dev/null || true
systemctl stop adguardhome 2>/dev/null || true
systemctl disable adguardhome 2>/dev/null || true
rm -rf /opt/AdGuardHome /etc/systemd/system/AdGuardHome.service /etc/systemd/system/AdGuardHome.service.d
rm -rf /etc/systemd/system/adguardhome.service /etc/systemd/system/adguardhome.service.d

rm -f /etc/fail2ban/jail.d/vpn-bundle.local
systemctl restart fail2ban 2>/dev/null || true

if grep -qF '/swapfile none swap sw 0 0 # 3x-awg-adg-bundle' /etc/fstab; then
    log "Удаление managed swapfile..."
    swapoff /swapfile 2>/dev/null || true
    rm -f /swapfile
    sed -i '\|^/swapfile none swap sw 0 0 # 3x-awg-adg-bundle$|d' /etc/fstab
fi

log "Снятие owned UFW-правил без глобального reset..."
adg_port=$(read_cred_value "ADG_PORT" "$CREDS_FILE")
adg_dns_port=$(read_cred_value "ADG_DNS_PORT" "$CREDS_FILE")
[ -n "$adg_port" ] && ufw delete allow "${adg_port}/tcp" 2>/dev/null || true
[ -n "$adg_dns_port" ] && ufw delete allow in on awg0 to any port "$adg_dns_port" 2>/dev/null || true
ufw allow 2244/tcp 2>/dev/null || true
ufw --force enable 2>/dev/null || true

if [ -f /etc/systemd/resolved.conf ]; then
    sed -i 's/DNSStubListener=no/DNSStubListener=yes/' /etc/systemd/resolved.conf
    systemctl restart systemd-resolved 2>/dev/null || true
fi

rm -f /etc/sysctl.d/99-custom-net.conf
sysctl --system > /dev/null 2>/dev/null || true

log "Удаление учетных данных и логов..."
rm -f "$CREDS_FILE"
rm -f /var/log/vpn-setup.log
rm -f /root/amnezia_client.conf

warn "Удаление завершено."
warn "Порт SSH оставлен 2244. Чтобы вернуть 22, исправьте /etc/ssh/sshd_config вручную."
warn "Для полной очистки ядерных модулей рекомендуется выполнить 'sudo reboot'."
