# ==============================================================================
# 3. ОЧИСТКА LEGACY XRAY CONTROL PLANE
# ==============================================================================
mark_step "Xray: cleanup legacy x-ui and build VLESS link"
log "Удаление legacy x-ui, если он остался от предыдущих версий..."
remove_legacy_xui
configure_cascade_mode

if [ "$CASCADE_ENABLED" -eq 1 ]; then
    log "Cascade mode включён: upstream Reality exit-us используется только для DNS-выхода AdGuardHome."
else
    log "Cascade mode выключен: AWG идёт direct, а DNS upstream AdGuardHome остаётся на локальном Xray HTTP proxy."
fi

VLESS_LINK="vless://$XRAY_UUID@$SERVER_IP:$XRAY_PORT?type=tcp&security=reality&encryption=none&flow=xtls-rprx-vision&pbk=$XRAY_PUBLIC_KEY&headerType=none&fp=chrome&spx=%2F&sni=google.com&sid=$XRAY_SHORT_ID#VLESS-Reality-Default"
