#!/bin/bash
# Name: vps-vpn-triad-uninstall
# Description: Uninstalls 3x-ui, AmneziaWG and AdGuardHome. Reverts OS changes.
# Usage: sudo bash uninstall.sh [-y | --yes]
# Behavior: Stops services, removes configs and binaries, resets UFW.
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

log() { echo -e "${GREEN}[INFO] $1${RESET}"; }
warn() { echo -e "${YELLOW}[WARN] $1${RESET}"; }
err() { echo -e "${RED}[ERROR] $1${RESET}"; exit 1; }

if [ "$EUID" -ne 0 ]; then
  err "Запустите скрипт от имени root (sudo -i)"
fi

if [ "$FORCE_UNINSTALL" -ne 1 ]; then
    if [ -e /dev/tty ]; then
        read -r -p "Эта операция полностью удалит VPN, DNS и панель управления. Продолжить? (y/n) " -n 1 REPLY </dev/tty
        echo >/dev/tty
    else
        err "Подтвердите удаление из интерактивного терминала или запустите uninstall.sh с --yes."
    fi

    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        exit 1
    fi
fi

log "Остановка и удаление сервисов..."
systemctl stop x-ui 2>/dev/null || true
systemctl disable x-ui 2>/dev/null || true
rm -rf /usr/local/x-ui /etc/x-ui /etc/systemd/system/x-ui.service

systemctl stop awg-quick@awg0 2>/dev/null || true
systemctl disable awg-quick@awg0 2>/dev/null || true
rm -rf /etc/amnezia/amneziawg /etc/systemd/system/awg-quick@.service

/opt/AdGuardHome/AdGuardHome -s uninstall 2>/dev/null || true
systemctl stop AdGuardHome 2>/dev/null || true
systemctl disable AdGuardHome 2>/dev/null || true
rm -rf /opt/AdGuardHome /etc/systemd/system/AdGuardHome.service /etc/systemd/system/AdGuardHome.service.d

log "Сброс настроек сети и фаервола..."
ufw --force reset
ufw allow 22/tcp
ufw allow 2244/tcp
ufw --force enable

# Восстановление systemd-resolved
if [ -f /etc/systemd/resolved.conf ]; then
    sed -i 's/DNSStubListener=no/DNSStubListener=yes/' /etc/systemd/resolved.conf
    systemctl restart systemd-resolved 2>/dev/null || true
fi

# Удаление кастомных настроек sysctl
rm -f /etc/sysctl.d/99-custom-net.conf
sysctl --system > /dev/null

log "Удаление учетных данных и логов..."
rm -f /root/.vpn-credentials
rm -f /var/log/vpn-setup.log
rm -f /root/amnezia_client.conf

warn "Удаление завершено."
warn "Порт SSH оставлен 2244 (если он был изменен). Чтобы вернуть 22, исправьте /etc/ssh/sshd_config вручную."
warn "Для полной очистки ядерных модулей рекомендуется выполнить 'sudo reboot'."
