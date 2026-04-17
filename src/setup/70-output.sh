# ==============================================================================
# 8. ОЧИСТКА И УДАЛЕНИЕ ИНСТРУМЕНТОВ СБОРКИ
# ==============================================================================
mark_step "Finalize: cleanup build tools"
log "Удаление инструментов сборки (Hardening) и очистка кэша..."
if [ "$SKIP_APT" -eq 0 ]; then
    # Удаляем пакеты сборки (dkms оставляем для пересборки модуля при обновлении ядра)
    apt purge -y git build-essential libelf-dev libmnl-dev > /dev/null 2>&1 || true
    apt autoremove -y > /dev/null 2>&1
    apt clean
    rm -rf /usr/src/amneziawg-linux-kernel-module
    rm -rf /usr/src/amneziawg-tools
else
    log "Пропуск очистки apt (fast mode)."
fi

# ==============================================================================
# 9. СОХРАНЕНИЕ CREDENTIALS И ФИНАЛЬНЫЙ ВЫВОД
# ==============================================================================
mark_step "Finalize: persist credentials and print output"
cat <<CREDS > "$CREDS_FILE"
# 3x-awg-adg-bundle credentials (v${SCRIPT_VERSION})
# Generated: $(date -Iseconds)
# ====================================
SSH_PORT=2244
XRAY_PORT=443
XRAY_UUID=${XRAY_UUID}
XRAY_PRIVATE_KEY=${XRAY_PRIVATE_KEY}
XRAY_PUBLIC_KEY=${XRAY_PUBLIC_KEY}
XRAY_SHORT_ID=${XRAY_SHORT_ID}
VLESS_LINK=${VLESS_LINK}
CASCADE_ENABLED=${CASCADE_ENABLED}
CASCADE_MODE=${CASCADE_MODE}
CASCADE_VLESS=${CASCADE_VLESS}
CASCADE_ADDRESS=${CASCADE_ADDRESS}
CASCADE_PORT=${CASCADE_PORT}
CASCADE_UUID=${CASCADE_UUID}
CASCADE_FLOW=${CASCADE_FLOW}
CASCADE_PBK=${CASCADE_PBK}
CASCADE_SNI=${CASCADE_SNI}
CASCADE_SID=${CASCADE_SID}
CASCADE_FP=${CASCADE_FP}
CASCADE_SPX=${CASCADE_SPX}
FINAL_MODE=${FINAL_MODE}
ADG_URL=http://${SERVER_IP}:${ADG_PORT}/
ADG_USER=${ADG_USER}
ADG_PASS=${ADG_PASS}
ADG_DNS_PORT=${ADG_DNS_PORT}
ADG_HTTP_PROXY_PORT=${ADG_HTTP_PROXY_PORT}
AWG_PORT=${AWG_PORT}
AWG_SERVER_PRIV=${SERVER_PRIV}
AWG_CLIENT_PRIV=${CLIENT_PRIV}
AWG_CLIENT_PSK=${CLIENT_PSK}
AWG_JC=${JC}
AWG_JMIN=${JMIN}
AWG_JMAX=${JMAX}
AWG_S1=${S1}
AWG_S2=${S2}
AWG_H1=${H1}
AWG_H2=${H2}
AWG_H3=${H3}
AWG_H4=${H4}
AWG_CLIENT_CONF=/root/amnezia_client.conf
CREDS
chmod 600 "$CREDS_FILE"


log "Установка и настройка успешно завершены!"
echo -e "\n=================================================================="
echo -e "${GREEN}SSH доступ:${RESET}"
echo -e "Порт: ${YELLOW}2244${RESET}"

echo -e "\n${GREEN}Xray Reality:${RESET}"
echo -e "Порт: ${YELLOW}443${RESET}"
echo -e "Конфиг: ${YELLOW}/usr/local/etc/xray/config.json${RESET}"
echo -e "Дефолтная ссылка VLESS (Reality): ${YELLOW}${VLESS_LINK}${RESET}"
echo -e "Режим маршрутизации: ${YELLOW}${FINAL_MODE}${RESET}"
echo -e "\n${GREEN}AdGuardHome:${RESET}"
echo -e "Админка (Web UI): ${YELLOW}http://${SERVER_IP}:${ADG_PORT}/${RESET}"
echo -e "DNS реальный порт: ${YELLOW}${ADG_DNS_PORT}${RESET} (клиент видит 10.8.0.1:53 через DNAT)"
echo -e "User: ${YELLOW}${ADG_USER}${RESET} / Pass: ${YELLOW}${ADG_PASS}${RESET}"
echo -e "Безопасный поиск: ${GREEN}ВКЛЮЧЕН${RESET}"

echo -e "\n${GREEN}AmneziaWG:${RESET}"
echo -e "Конфиг сохранен в: ${YELLOW}/root/amnezia_client.conf${RESET}"
echo -e "${YELLOW}--- СОДЕРЖИМОЕ CONFIG-ФАЙЛА (для копирования) ---${RESET}"
cat /root/amnezia_client.conf
echo -e "${YELLOW}--- КОНЕЦ КОНФИГА ---${RESET}"

echo -e "\nQR-код для мобильного клиента:"
qrencode -t ansiutf8 < /root/amnezia_client.conf

echo -e "\n${GREEN}Все credentials сохранены:${RESET} ${YELLOW}${CREDS_FILE}${RESET}"
echo -e "==================================================================\n"
echo -e "${RED}ВНИМАНИЕ: Выполните 'sudo reboot' для окончательной активации AmneziaWG!${RESET}\n"
