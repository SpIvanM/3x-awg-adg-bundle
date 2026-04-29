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
DEPLOY_MODE=${DEPLOY_MODE}
SERVER_IP=${SERVER_IP}
REALITY_PORT=${REALITY_PORT}
ADG_URL=http://${SERVER_IP}:${ADG_PORT}/
ADG_USER=${ADG_USER}
ADG_PASS=${ADG_PASS}
ADG_DNS_PORT=${ADG_DNS_PORT}
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
TARGET_IP=${TARGET_IP}
TARGET_AWG_PORT=${TARGET_AWG_PORT}
TARGET_REALITY_PORT=${TARGET_REALITY_PORT}
TARGET_DNS_PORT=${TARGET_DNS_PORT}
RELAY_FWD_AWG_PORT=${RELAY_FWD_AWG_PORT}
RELAY_FWD_REALITY_PORT=${RELAY_FWD_REALITY_PORT}
PORT_FORWARDING_ENABLED=${PORT_FORWARDING_ENABLED:-0}
FORWARDING_STATE_FILE=${FORWARDING_STATE_FILE}
CREDS
chmod 600 "$CREDS_FILE"
save_forwarding_rules_state


log "Установка и настройка успешно завершены!"
echo -e "\n=================================================================="
echo -e "${GREEN}SSH доступ:${RESET}"
echo -e "Порт: ${YELLOW}2244${RESET}"

echo -e "\n${GREEN}3x-ui / Reality:${RESET}"
echo -e "Reality порт зарезервирован: ${YELLOW}${REALITY_PORT}${RESET}"
echo -e "Официальный installer 3x-ui уже был запущен интерактивно."
echo -e "Дальнейшая настройка панели, inbound Reality и клиентских ссылок выполняется ${YELLOW}вручную${RESET}."
echo -e "Если для панели выбран отдельный порт, откройте его в UFW вручную после настройки."

if [ "$DEPLOY_MODE" = "target" ]; then
    echo -e "\n${GREEN}Target handoff для relay:${RESET}"
    echo -e "IP: ${SERVER_IP}"
    echo -e "AWG: ${SERVER_IP}:53/udp"
    echo -e "Reality: ${SERVER_IP}:${REALITY_PORT}/tcp"
    echo -e "DNS endpoint: ${SERVER_IP}:${ADG_DNS_PORT}"
else
    echo -e "\n${GREEN}Relay local direct stack:${RESET}"
    echo -e "IP: ${SERVER_IP}"
    echo -e "Локальный AWG: ${SERVER_IP}:53/udp"
    echo -e "Локальный Reality: ${SERVER_IP}:${REALITY_PORT}/tcp"
    echo -e "Локальный DNS endpoint: ${SERVER_IP}:${ADG_DNS_PORT}"

    echo -e "\n${GREEN}Relay-forward endpoints:${RESET}"
    echo -e "Future relay-forward endpoints из прошлых этапов теперь активны."
    if [ "${PORT_FORWARDING_ENABLED:-0}" -eq 1 ] && [ -n "${PORT_FORWARDING_RULES:-}" ]; then
        while IFS='|' read -r rule_target_ip rule_target_port rule_proto rule_external_port rule_id; do
            [ -n "$rule_target_ip" ] || continue
            rule_external_port="${rule_external_port:-$rule_target_port}"
            echo -e "${SERVER_IP}:${rule_external_port}/${rule_proto} -> ${rule_target_ip}:${rule_target_port}/${rule_proto}"
        done <<EOF
${PORT_FORWARDING_RULES}
EOF
    else
        echo -e "Проброс портов не настроен."
    fi
    echo -e "Target для будущего forwarding: см. ${FORWARDING_STATE_FILE}"
fi

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
