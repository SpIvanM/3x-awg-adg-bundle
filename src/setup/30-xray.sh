# ==============================================================================
# 3. ОЧИСТКА LEGACY XRAY CONTROL PLANE
# ==============================================================================
log "Удаление legacy x-ui, если он остался от предыдущих версий..."
remove_legacy_xui
configure_cascade_mode

if [ "$CASCADE_ENABLED" -eq 1 ]; then
    log "Cascade mode включён: non-RU AWG трафик пойдёт через upstream Reality exit-us."
else
    log "Cascade mode выключен: система работает в direct-exit режиме."
fi

VLESS_LINK="vless://$XRAY_UUID@$SERVER_IP:$XRAY_PORT?type=tcp&security=reality&encryption=none&flow=xtls-rprx-vision&pbk=$XRAY_PUBLIC_KEY&headerType=none&fp=chrome&spx=%2F&sni=google.com&sid=$XRAY_SHORT_ID#VLESS-Reality-Default"
