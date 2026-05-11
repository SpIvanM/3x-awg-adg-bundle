#!/bin/bash
# ==============================================================================
# setup-3x.sh
# 3. РУЧНОЙ HANDOFF ДЛЯ 3X-UI
# ==============================================================================
set -Ee

# Логирование
log() { echo -e "\e[32m[INFO] $1\e[0m"; }
warn() { echo -e "\e[33m[WARN] $1\e[0m"; }
err() { echo -e "\e[31m[ERROR] $1\e[0m"; exit 1; }
mark_step() { log "Шаг: $1"; }

if [ "$EUID" -ne 0 ]; then
  err "Запустите скрипт от имени root (sudo -i)"
fi

remove_legacy_xui() {
    systemctl stop xray 2>/dev/null || true
    systemctl disable xray 2>/dev/null || true
    rm -f /usr/local/etc/xray/config.json
    rm -f /etc/systemd/system/xray.service /lib/systemd/system/xray.service
    systemctl daemon-reload >/dev/null 2>&1 || true
}

install_3x_ui_interactive() {
    [ -c /dev/tty ] || err "Для интерактивной установки 3x-ui требуется /dev/tty."

    local THREE_X_UI_INSTALLER_URL="https://raw.githubusercontent.com/mhsanaei/3x-ui/master/install.sh"

    log "Запуск официального интерактивного installer 3x-ui..."
    if ! bash <(curl -fsSL "$THREE_X_UI_INSTALLER_URL") </dev/tty >/dev/tty 2>/dev/tty; then
        warn "Официальный installer 3x-ui завершился с ошибкой. Это не критично для работы AWG и AdGuardHome."
    fi

    log "3x-ui requires manual interactive configuration after the installer finishes."
    warn "Дальнейшая настройка 3x-ui, Reality inbound и панели выполняется вручную вне setup.sh."
    warn "Скрипт намеренно не делает silent install и не меняет конфигурацию 3x-ui автоматически."
}

mark_step "3x-ui: cleanup legacy direct Xray artifacts"
log "Удаление legacy direct Xray-конфига от предыдущих версий..."
remove_legacy_xui

mark_step "3x-ui: run official interactive installer"
install_3x_ui_interactive
