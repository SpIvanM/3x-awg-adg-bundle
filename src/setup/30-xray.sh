# ==============================================================================
# 3. РУЧНОЙ HANDOFF ДЛЯ 3X-UI
# ==============================================================================
mark_step "3x-ui: cleanup legacy direct Xray artifacts"
log "Удаление legacy direct Xray-конфига от предыдущих версий..."
remove_legacy_xui

mark_step "3x-ui: run official interactive installer"
install_3x_ui_interactive
