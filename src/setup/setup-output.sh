#!/bin/bash
# ==============================================================================
# setup-output.sh
# ВЫВОД ИТОГОВОЙ КОНФИГУРАЦИИ
# ==============================================================================
set -Ee

# Глобальные переменные по умолчанию
CREDS_FILE=${CREDS_FILE:-"/root/.vpn-credentials"}
FORWARDING_STATE_FILE=${FORWARDING_STATE_FILE:-"/etc/3x-fwd/rules.json"}
DEPLOY_MODE=${DEPLOY_MODE:-"target"}

# Цвета для вывода
GREEN='\e[32m'
YELLOW='\e[33m'
WHITE='\e[97m'
RED='\e[31m'
RESET='\e[0m'

# Логирование
log() { echo -e "\e[32m[INFO] $1\e[0m"; }
warn() { echo -e "\e[33m[WARN] $1\e[0m"; }
err() { echo -e "\e[31m[ERROR] $1\e[0m"; exit 1; }
mark_step() { log "Шаг: $1"; }

if [ "$EUID" -ne 0 ]; then
  err "Запустите скрипт от имени root (sudo -i)"
fi

read_cred_value() {
    local key="$1"
    local file="${2:-$CREDS_FILE}"
    local raw
    raw=$(grep "^${key}=" "$file" 2>/dev/null | head -n1 | cut -d'=' -f2- | xargs || true)
    printf '%s' "$raw" | tr -d '\r'
}

print_target_output() {
    echo -e "\n${GREEN}Target handoff для relay:${RESET}"
    echo -e "IP: ${SERVER_IP}"
    echo -e "AWG: ${SERVER_IP}:53/udp"
    echo -e "Reality: ${SERVER_IP}:443/tcp (ожидаемый)"
    echo -e "DNS endpoint: ${SERVER_IP}:${ADG_DNS_PORT}"
}

print_relay_output() {
    echo -e "\n${GREEN}Relay local direct stack:${RESET}"
    echo -e "IP: ${SERVER_IP}"
    echo -e "Локальный AWG: ${SERVER_IP}:53/udp"
    echo -e "Локальный Reality: ${SERVER_IP}:443/tcp (ожидаемый)"
    echo -e "Локальный DNS endpoint: ${SERVER_IP}:${ADG_DNS_PORT}"

    echo -e "\n${GREEN}Relay-forward endpoints:${RESET}"
    if [ -f "$FORWARDING_STATE_FILE" ]; then
        if jq -e '.rules | length > 0' "$FORWARDING_STATE_FILE" >/dev/null 2>&1; then
            echo -e "------------------------------------------------------------------------------------------"
            printf "${WHITE}%-30s${RESET} | ${WHITE}%-30s${RESET} | ${WHITE}%-10s${RESET}\n" "Local Endpoint" "Target Endpoint" "Status"
            echo -e "------------------------------------------------------------------------------------------"
            jq -r '.rules[] | "\(.target_ip)|\(.target_port)|\(.proto)|\(.external_port)|\(.id)"' "$FORWARDING_STATE_FILE" | \
            while IFS='|' read -r rule_target_ip rule_target_port rule_proto rule_external_port rule_id; do
                [ -n "$rule_target_ip" ] || continue
                
                local_ep="${SERVER_IP}:${rule_external_port}/${rule_proto}"
                target_ep="${rule_target_ip}:${rule_target_port}/${rule_proto}"
                
                if [ "$rule_external_port" -eq "$rule_target_port" ]; then
                    status="${GREEN}[MATCH]${RESET}"
                else
                    status="${YELLOW}[RANDOM]${RESET}"
                fi
                
                printf "%-30s | %-30s | %b\n" "$local_ep" "$target_ep" "$status"
            done
            echo -e "------------------------------------------------------------------------------------------"
        else
            echo -e "Проброс портов не настроен (файл правил пуст)."
        fi
    else
        echo -e "Проброс портов не настроен (состояние отсутствует)."
    fi
    echo -e "\nState-файл правил: ${YELLOW}${FORWARDING_STATE_FILE}${RESET}"
}

mark_step "Finalize: load credentials and print output"

# Загрузка переменных
SERVER_IP=$(curl -s https://api.ipify.org || wget -qO- https://api.ipify.org)
ADG_PORT=$(read_cred_value "ADG_PORT")
ADG_USER=$(read_cred_value "ADG_USER")
ADG_PASS=$(read_cred_value "ADG_PASS")
ADG_DNS_PORT=$(read_cred_value "ADG_DNS_PORT")

log "Установка и настройка успешно завершены!"
echo -e "\n=================================================================="
echo -e "${GREEN}SSH доступ:${RESET}"
echo -e "Порт: ${YELLOW}2244${RESET}"

echo -e "\n${GREEN}3x-ui / Reality:${RESET}"
echo -e "Reality порт зарезервирован: ${YELLOW}443${RESET}"
echo -e "Официальный installer 3x-ui уже был запущен интерактивно."
echo -e "Дальнейшая настройка панели, inbound Reality и клиентских ссылок выполняется ${YELLOW}вручную${RESET}."
echo -e "Если для панели выбран отдельный порт, откройте его в UFW вручную после настройки."

if [ "$DEPLOY_MODE" = "target" ]; then
    print_target_output
else
    print_relay_output
fi

echo -e "\n${GREEN}AdGuardHome:${RESET}"
if [ -n "$ADG_PORT" ]; then
    echo -e "Админка (Web UI): ${YELLOW}http://${SERVER_IP}:${ADG_PORT}/${RESET}"
    echo -e "DNS реальный порт: ${YELLOW}${ADG_DNS_PORT}${RESET} (клиент видит 10.8.0.1:53 через DNAT)"
    echo -e "User: ${YELLOW}${ADG_USER}${RESET} / Pass: ${YELLOW}${ADG_PASS}${RESET}"
    echo -e "Безопасный поиск: ${GREEN}ВКЛЮЧЕН${RESET}"
else
    echo -e "${YELLOW}AdGuardHome не настроен или credentials не найдены.${RESET}"
fi

echo -e "\n${GREEN}AmneziaWG:${RESET}"
if [ -f "/root/amnezia_client.conf" ]; then
    echo -e "Конфиг сохранен в: ${YELLOW}/root/amnezia_client.conf${RESET}"
    echo -e "${YELLOW}--- СОДЕРЖИМОЕ CONFIG-ФАЙЛА (для копирования) ---${RESET}"
    cat /root/amnezia_client.conf
    echo -e "${YELLOW}--- КОНЕЦ КОНФИГА ---${RESET}"
    
    if command -v qrencode >/dev/null 2>&1; then
        echo -e "\nQR-код для мобильного клиента:"
        qrencode -t ansiutf8 < /root/amnezia_client.conf
    fi
else
    echo -e "${YELLOW}AmneziaWG не настроен или конфиг не найден.${RESET}"
fi

echo -e "\n${GREEN}Все credentials сохранены:${RESET} ${YELLOW}${CREDS_FILE}${RESET}"
echo -e "==================================================================\n"
echo -e "${RED}ВНИМАНИЕ: Выполните 'sudo reboot' для окончательной активации AmneziaWG!${RESET}\n"
