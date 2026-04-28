remove_legacy_xui() {
    systemctl stop xray 2>/dev/null || true
    systemctl disable xray 2>/dev/null || true
    rm -f /usr/local/etc/xray/config.json
    rm -f /etc/systemd/system/xray.service /lib/systemd/system/xray.service
    systemctl daemon-reload >/dev/null 2>&1 || true
}

install_3x_ui_interactive() {
    [ -c /dev/tty ] || err "Для интерактивной установки 3x-ui требуется /dev/tty."

    log "Запуск официального интерактивного installer 3x-ui..."
    if ! bash <(curl -fsSL "$THREE_X_UI_INSTALLER_URL") </dev/tty >/dev/tty 2>/dev/tty; then
        err "Официальный installer 3x-ui завершился с ошибкой."
    fi

    log "3x-ui requires manual interactive configuration after the installer finishes."
    warn "Дальнейшая настройка 3x-ui, Reality inbound и панели выполняется вручную вне setup.sh."
    warn "Скрипт намеренно не делает silent install и не меняет конфигурацию 3x-ui автоматически."
}
