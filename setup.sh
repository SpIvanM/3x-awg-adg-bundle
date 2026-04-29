#!/bin/bash
# Name: vps-vpn-triad (assembled source bootstrap)
# Description: Bootstrap layer for the modular 3x-ui + AmneziaWG + AdGuardHome installer.
# Assembled from source modules:
#   - src/setup/00-bootstrap.sh
#   - src/setup/10-common.sh
#   - src/setup/11-awg-helpers.sh
#   - src/setup/12-agh-helpers.sh
#   - src/setup/13-3x-helpers.sh
#   - src/setup/14-port-forwarding-helpers.sh
#   - src/setup/20-system.sh
#   - src/setup/30-xray.sh
#   - src/setup/40-awg.sh
#   - src/setup/50-adguard.sh
#   - src/setup/60-firewall.sh
#   - src/setup/70-output.sh
# Usage: curl -fsSL https://raw.githubusercontent.com/SpIvanM/3x-awg-adg-bundle/main/setup.sh | sudo bash [--mode target|relay] [-r | --rotate]
# Behavior: Updates sysctl, installs OS packages, compiles AmneziaWG kernel module, sets up target or relay-local AdGuard Home and AmneziaWG endpoints, and launches the official interactive 3x-ui installer.
# Returns: Configured VPN stack with connection details.
# Fails: If run without root privileges or with an invalid --mode value.
# ==============================================================================
# Комплексный скрипт настройки Debian 11/Ubuntu: OS Optimization + 3x-ui + AmneziaWG + AdGuardHome
# ==============================================================================

set -Ee
export DEBIAN_FRONTEND=noninteractive
export RANDFILE=/tmp/.rnd

# Глобальные переменные и пути
SCRIPT_VERSION="3.0.8"
CREDS_FILE="/root/.vpn-credentials"
FORWARDING_STATE_FILE="/root/.vpn-forwarding-rules"
LOG_FILE="/var/log/vpn-setup.log"
LAST_RUN_FILE="/root/.vpn-setup-last-run"
DEPLOY_MODE="target"
CURRENT_STEP="bootstrap"
REALITY_PORT="443"
THREE_X_UI_INSTALLER_URL="https://raw.githubusercontent.com/mhsanaei/3x-ui/master/install.sh"

mark_step() {
    CURRENT_STEP="$1"
    log "Шаг: ${CURRENT_STEP}"
}

# Обработка аргументов
ROTATE_CREDS=0
while [[ "$#" -gt 0 ]]; do
    case $1 in
        --rotate|-r) ROTATE_CREDS=1; shift ;;
        --mode)
            if [ -z "${2:-}" ]; then
                echo "[ERROR] Аргумент --mode требует значение: target или relay" >&2
                exit 1
            fi
            if [ "$2" != "target" ] && [ "$2" != "relay" ]; then
                echo "[ERROR] Недопустимое значение --mode: $2. Используйте target или relay." >&2
                exit 1
            fi
            DEPLOY_MODE="$2"
            shift 2
            ;;
        *)
            echo "[ERROR] Неизвестный аргумент: $1" >&2
            exit 1
            ;;
    esac
done

# Логирование (перенаправление вывода в файл и консоль)
exec > >(tee -a "$LOG_FILE") 2>&1

# Цвета для вывода
GREEN="\e[32m"
RED="\e[31m"
YELLOW="\e[33m"
RESET="\e[0m"

log() { echo -e "${GREEN}[INFO] $1${RESET}"; }
warn() { echo -e "${YELLOW}[WARN] $1${RESET}"; }
err() { echo -e "${RED}[ERROR] [${CURRENT_STEP:-unknown}] $1${RESET}"; exit 1; }
on_script_error() {
    local exit_code="$1"
    local signal="$2"
    local failing_command="$3"

    warn "Скрипт прерван (${signal}) на шаге: ${CURRENT_STEP:-unknown}. Команда: ${failing_command:-unknown}. Код: ${exit_code}. Лог: $LOG_FILE"
}

log "Версия скрипта: ${SCRIPT_VERSION}"
log "Режим развёртывания: ${DEPLOY_MODE}"

trap 'on_script_error "$?" "ERR" "$BASH_COMMAND"' ERR
trap 'on_script_error 130 "INT" "$BASH_COMMAND"' INT
trap 'on_script_error 143 "TERM" "$BASH_COMMAND"' TERM

if [ "$EUID" -ne 0 ]; then
  err "Запустите скрипт от имени root (sudo -i)"
fi

# Проверяем, запускался ли скрипт уже сегодня (для пропуска apt-операций)
TODAY=$(date +%Y-%m-%d)
LAST_RUN=$(cat "$LAST_RUN_FILE" 2>/dev/null || echo "")
if [ "$LAST_RUN" = "$TODAY" ]; then
    SKIP_APT=1
    warn "Скрипт уже запускался сегодня ($TODAY). Пропускаем обновление OS (только перегенерация настроек)."
else
    SKIP_APT=0
fi

read_cred_value() {
    local key="$1"
    local file="$2"
    local raw

    raw=$(grep "^${key}=" "$file" 2>/dev/null | head -n1 | cut -d'=' -f2- | xargs || true)
    trim_cr_value "$raw"
}

read_config_assignment() {
    local prefix="$1"
    local file="$2"
    local raw

    raw=$(grep "^${prefix}" "$file" 2>/dev/null | head -n1 | cut -d'=' -f2- | xargs || true)
    trim_cr_value "$raw"
}

read_url_port() {
    local key="$1"
    local file="$2"
    local raw

    raw=$(grep "^${key}=" "$file" 2>/dev/null | head -n1 | sed -e 's|.*:| |' -e 's|/.*||' | xargs || true)
    trim_cr_value "$raw"
}

trim_cr_value() {
    printf '%s' "$1" | tr -d '\r'
}

validate_stack() {
    local agh_service_name="$1"

    log "Валидация AmneziaWG и AdGuardHome..."
    systemctl restart awg-quick@awg0 || err "Не удалось поднять awg0 после настройки."
    systemctl restart "$agh_service_name" || err "Не удалось перезапустить ${agh_service_name}."

    ss -lunp | grep -Eq ":${AWG_PORT} " || err "AmneziaWG не слушает UDP порт ${AWG_PORT}."
    dig @127.0.0.1 -p "${ADG_DNS_PORT}" example.com +short | grep -q . || err "AdGuardHome не отвечает на локальные DNS-запросы."
    awg show | grep -q '^interface: awg0' || err "AmneziaWG interface awg0 не поднялся."
}

ensure_swapfile() {
    local swapfile="/swapfile"
    local swap_size="1G"
    local fstab_line="/swapfile none swap sw 0 0 # 3x-awg-adg-bundle"

    if swapon --show --noheadings 2>/dev/null | grep -q .; then
        warn "Swap уже активен, пропускаем создание swapfile."
        return 0
    fi

    if [ -f "$swapfile" ]; then
        log "Используем существующий swapfile ${swapfile}."
    else
        log "Создание swapfile ${swapfile} (${swap_size})..."
        if command -v fallocate >/dev/null 2>&1; then
            if ! fallocate -l "$swap_size" "$swapfile"; then
                warn "fallocate не сработал, используем dd для создания swapfile."
                dd if=/dev/zero of="$swapfile" bs=1M count=1024 status=none
            fi
        else
            dd if=/dev/zero of="$swapfile" bs=1M count=1024 status=none
        fi
        chmod 600 "$swapfile"
        mkswap "$swapfile" >/dev/null
    fi

    chmod 600 "$swapfile"
    if ! grep -qF "$fstab_line" /etc/fstab; then
        echo "$fstab_line" >> /etc/fstab
    fi
    swapon "$swapfile"
    log "Swapfile активирован: ${swapfile}"
}

resolve_awg_key_bin() {
    # Prefer the stable WireGuard CLI for key material; fall back to awg if needed.
    command -v wg 2>/dev/null || command -v awg 2>/dev/null || true
}

ensure_awg_build_dependencies() {
    local header_pkg="linux-headers-$(uname -r)"

    apt install -y git build-essential dkms libmnl-dev libelf-dev "$header_pkg" \
        || err "Не удалось установить точные kernel headers (${header_pkg}) для сборки AmneziaWG."
}

load_existing_awg_credentials() {
    local awg_key_bin="${AWG_KEY_BIN:-}"

    if [ -z "$awg_key_bin" ]; then
        awg_key_bin="$(resolve_awg_key_bin || true)"
    fi

    if [ -f "$CREDS_FILE" ] && [ "$ROTATE_CREDS" -eq 0 ]; then
        log "Загрузка существующих credentials AmneziaWG из $CREDS_FILE..."
        SERVER_PRIV=$(read_cred_value "AWG_SERVER_PRIV" "$CREDS_FILE")
        CLIENT_PRIV=$(read_cred_value "AWG_CLIENT_PRIV" "$CREDS_FILE")
        CLIENT_PSK=$(read_cred_value "AWG_CLIENT_PSK" "$CREDS_FILE")
        AWG_PORT=$(read_cred_value "AWG_PORT" "$CREDS_FILE")
        JC=$(read_cred_value "AWG_JC" "$CREDS_FILE")
        JMIN=$(read_cred_value "AWG_JMIN" "$CREDS_FILE")
        JMAX=$(read_cred_value "AWG_JMAX" "$CREDS_FILE")
        S1=$(read_cred_value "AWG_S1" "$CREDS_FILE")
        S2=$(read_cred_value "AWG_S2" "$CREDS_FILE")
        H1=$(read_cred_value "AWG_H1" "$CREDS_FILE")
        H2=$(read_cred_value "AWG_H2" "$CREDS_FILE")
        H3=$(read_cred_value "AWG_H3" "$CREDS_FILE")
        H4=$(read_cred_value "AWG_H4" "$CREDS_FILE")
    fi

    if [ -z "$SERVER_PRIV" ] || [ -z "$CLIENT_PRIV" ] || [ -z "$CLIENT_PSK" ]; then
        if [ -f /etc/amnezia/amneziawg/awg0.conf ] && [ -f /root/amnezia_client.conf ] && [ "$ROTATE_CREDS" -eq 0 ]; then
            log "Восстанавливаем существующие credentials AmneziaWG из текущих конфигов..."
            SERVER_PRIV=$(read_config_assignment "PrivateKey = " /etc/amnezia/amneziawg/awg0.conf)
            CLIENT_PRIV=$(read_config_assignment "PrivateKey = " /root/amnezia_client.conf)
            CLIENT_PSK=$(read_config_assignment "PresharedKey = " /root/amnezia_client.conf)
            AWG_PORT=$(read_config_assignment "ListenPort = " /etc/amnezia/amneziawg/awg0.conf)
            JC=$(read_config_assignment "Jc = " /etc/amnezia/amneziawg/awg0.conf)
            JMIN=$(read_config_assignment "Jmin = " /etc/amnezia/amneziawg/awg0.conf)
            JMAX=$(read_config_assignment "Jmax = " /etc/amnezia/amneziawg/awg0.conf)
            S1=$(read_config_assignment "S1 = " /etc/amnezia/amneziawg/awg0.conf)
            S2=$(read_config_assignment "S2 = " /etc/amnezia/amneziawg/awg0.conf)
            H1=$(read_config_assignment "H1 = " /etc/amnezia/amneziawg/awg0.conf)
            H2=$(read_config_assignment "H2 = " /etc/amnezia/amneziawg/awg0.conf)
            H3=$(read_config_assignment "H3 = " /etc/amnezia/amneziawg/awg0.conf)
            H4=$(read_config_assignment "H4 = " /etc/amnezia/amneziawg/awg0.conf)
        fi
    fi

    [ -n "$awg_key_bin" ] || err "Не найден awg/wg для восстановления ключей AmneziaWG."

    if [ -n "$SERVER_PRIV" ]; then
        SERVER_PUB=$(printf '%s' "$SERVER_PRIV" | "$awg_key_bin" pubkey)
    fi

    if [ -n "$CLIENT_PRIV" ]; then
        CLIENT_PUB=$(printf '%s' "$CLIENT_PRIV" | "$awg_key_bin" pubkey)
    fi
}

cleanup_legacy_awg_dns_redirects() {
    iptables -t nat -D PREROUTING -i awg0 -p udp --dport 53 -j REDIRECT --to-port "${ADG_DNS_PORT}" 2>/dev/null || true
    iptables -t nat -D PREROUTING -i awg0 -p tcp --dport 53 -j REDIRECT --to-port "${ADG_DNS_PORT}" 2>/dev/null || true
}

ensure_awg_obfuscation_params() {
    # Preserve restored AmneziaWG noise parameters; fill only missing values.
    [ -z "$JC" ] && JC=$(shuf -i 3-12 -n 1)
    [ -z "$JMIN" ] && JMIN=$(shuf -i 40-70 -n 1)
    [ -z "$JMAX" ] && JMAX=$(shuf -i 700-1200 -n 1)
    [ -z "$S1" ] && S1=$(shuf -i 15-150 -n 1)
    [ -z "$S2" ] && S2=$(shuf -i 151-250 -n 1)
    [ -z "$H1" ] && H1=$(shuf -i 100000000-999999999 -n 1)
    [ -z "$H2" ] && H2=$(shuf -i 100000000-999999999 -n 1)
    [ -z "$H3" ] && H3=$(shuf -i 100000000-999999999 -n 1)
    [ -z "$H4" ] && H4=$(shuf -i 100000000-999999999 -n 1)
}

cleanup_legacy_adguard_units() {
    systemctl stop AdGuardHome 2>/dev/null || true
    systemctl stop adguardhome 2>/dev/null || true
    systemctl disable adguardhome 2>/dev/null || true
    rm -f /etc/systemd/system/adguardhome.service
    rm -rf /etc/systemd/system/adguardhome.service.d
    systemctl daemon-reload >/dev/null 2>&1 || true
}

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

is_yes_answer() {
    case "$1" in
        y|Y|yes|YES|Yes|д|Д|да|ДА|Да) return 0 ;;
        *) return 1 ;;
    esac
}

append_forwarding_rule() {
    local rule_target_ip="$1"
    local rule_target_port="$2"
    local rule_proto="$3"
    local rule_external_port="${4:-}"
    local rule_id="${5:-}"
    local rule_line

    rule_external_port="${rule_external_port:-$rule_target_port}"
    rule_id="${rule_id:-$(make_forwarding_rule_id "$rule_target_ip" "$rule_target_port" "$rule_proto" "$rule_external_port")}"
    rule_line="${rule_target_ip}|${rule_target_port}|${rule_proto}|${rule_external_port}|${rule_id}"

    if printf '%s\n' "${PORT_FORWARDING_RULES:-}" | awk -F'|' -v ip="$rule_target_ip" -v port="$rule_target_port" -v proto="$rule_proto" '$1 == ip && $2 == port && $3 == proto { found = 1 } END { exit found ? 0 : 1 }'; then
        return 0
    fi

    if [ -n "${PORT_FORWARDING_RULES:-}" ]; then
        PORT_FORWARDING_RULES="${PORT_FORWARDING_RULES}
${rule_line}"
    else
        PORT_FORWARDING_RULES="$rule_line"
    fi
}

make_forwarding_rule_id() {
    printf '%s-%s-%s-%s' "$1" "$2" "$3" "$4" | tr '.:/|' '----' | tr -cd 'A-Za-z0-9_-'
}

load_forwarding_rules_state() {
    PORT_FORWARDING_RULES=""
    PORT_FORWARDING_ENABLED=0

    if [ -f "${FORWARDING_STATE_FILE:-}" ] && [ "$ROTATE_CREDS" -eq 0 ]; then
        while IFS='|' read -r rule_target_ip rule_target_port rule_proto rule_external_port rule_id _rest; do
            case "$rule_target_ip" in ''|\#*) continue ;; esac
            [ -n "$rule_target_port" ] || continue
            [ -n "$rule_proto" ] || rule_proto="both"
            [ -n "$rule_external_port" ] || rule_external_port="$rule_target_port"
            append_forwarding_rule "$rule_target_ip" "$rule_target_port" "$rule_proto" "$rule_external_port" "$rule_id"
        done < "$FORWARDING_STATE_FILE"
    fi

    if [ -z "${PORT_FORWARDING_RULES:-}" ] && [ -f "$CREDS_FILE" ] && [ "$ROTATE_CREDS" -eq 0 ]; then
        local legacy_target_ip
        local legacy_awg_port
        local legacy_reality_port
        local legacy_fwd_awg_port
        local legacy_fwd_reality_port

        legacy_target_ip=$(read_cred_value "TARGET_IP" "$CREDS_FILE")
        legacy_awg_port=$(read_cred_value "TARGET_AWG_PORT" "$CREDS_FILE")
        legacy_reality_port=$(read_cred_value "TARGET_REALITY_PORT" "$CREDS_FILE")
        legacy_fwd_awg_port=$(read_cred_value "RELAY_FWD_AWG_PORT" "$CREDS_FILE")
        legacy_fwd_reality_port=$(read_cred_value "RELAY_FWD_REALITY_PORT" "$CREDS_FILE")

        if [ -n "$legacy_target_ip" ]; then
            [ -n "$legacy_awg_port" ] && append_forwarding_rule "$legacy_target_ip" "$legacy_awg_port" "udp" "${legacy_fwd_awg_port:-$legacy_awg_port}" "legacy-awg"
            [ -n "$legacy_reality_port" ] && append_forwarding_rule "$legacy_target_ip" "$legacy_reality_port" "tcp" "${legacy_fwd_reality_port:-$legacy_reality_port}" "legacy-reality"
        fi
    fi

    [ -n "${PORT_FORWARDING_RULES:-}" ] && PORT_FORWARDING_ENABLED=1
}

save_forwarding_rules_state() {
    if [ "${PORT_FORWARDING_ENABLED:-0}" -eq 1 ] && [ -n "${PORT_FORWARDING_RULES:-}" ]; then
        printf '%s\n' "${PORT_FORWARDING_RULES}" > "$FORWARDING_STATE_FILE"
        chmod 600 "$FORWARDING_STATE_FILE"
        return 0
    fi

    rm -f "$FORWARDING_STATE_FILE"
}

collect_forwarding_rules() {
    [ -c /dev/tty ] || err "Для настройки forwarding требуется интерактивный ввод через /dev/tty."

    local answer
    local target_ip
    local target_port
    local proto

    printf 'Настроить проброс портов с этого сервера? [y/N]: ' >/dev/tty
    IFS= read -r answer </dev/tty
    answer=$(trim_cr_value "$answer")
    if ! is_yes_answer "$answer"; then
        PORT_FORWARDING_RULES=""
        PORT_FORWARDING_ENABLED=0
        log "Port forwarding не настроен: оператор выбрал обычный direct-режим."
        return 0
    fi

    PORT_FORWARDING_ENABLED=1

    while true; do
        target_ip=""
        while true; do
            printf 'Target IP: ' >/dev/tty
            IFS= read -r target_ip </dev/tty
            target_ip=$(trim_cr_value "$target_ip")
            [ -n "$target_ip" ] && break
            warn "Target IP обязателен для forwarding."
        done

        while true; do
            target_port=""
            while true; do
                printf 'Target port: ' >/dev/tty
                IFS= read -r target_port </dev/tty
                target_port=$(trim_cr_value "$target_port")
                case "$target_port" in
                    ''|*[!0-9]*) warn "Target port должен быть числом." ;;
                    *) break ;;
                esac
            done

            printf 'Protocol [tcp, udp или both] (default both): ' >/dev/tty
            IFS= read -r proto </dev/tty
            proto=$(trim_cr_value "$proto")
            proto="${proto:-both}"
            case "$proto" in
                tcp|udp|both) ;;
                *) warn "Неизвестный protocol '${proto}', используется both."; proto="both" ;;
            esac

            append_forwarding_rule "$target_ip" "$target_port" "$proto"

            printf 'Добавить еще порт для этого target? [y/N]: ' >/dev/tty
            IFS= read -r answer </dev/tty
            answer=$(trim_cr_value "$answer")
            is_yes_answer "$answer" || break
        done

        printf 'Добавить еще target-сервер? [y/N]: ' >/dev/tty
        IFS= read -r answer </dev/tty
        answer=$(trim_cr_value "$answer")
        is_yes_answer "$answer" || break
    done
}

prompt_target_details() {
    log "Relay: интерактивная настройка optional port forwarding."
    load_forwarding_rules_state
    collect_forwarding_rules
}

is_relay_forward_port_available() {
    local port="$1"
    local proto="$2"
    local reserved_ports=":22:2244:53:${AWG_PORT:-}:443:${REALITY_PORT:-}:${ADG_PORT:-}:${ADG_DNS_PORT:-}:${FORWARDING_SELECTED_EXTERNAL_PORTS:-}:"

    case "$port" in
        ''|*[!0-9]*) return 1 ;;
    esac
    [ "$port" -ge 1 ] && [ "$port" -le 65535 ] || return 1

    case "$reserved_ports" in
        *":${port}:"*) return 1 ;;
    esac

    case "$proto" in
        udp)
            ! ss -H -lun "sport = :${port}" 2>/dev/null | grep -q .
            ;;
        tcp)
            ! ss -H -ltn "sport = :${port}" 2>/dev/null | grep -q .
            ;;
        both|'')
            ! ss -H -ltn "sport = :${port}" 2>/dev/null | grep -q . && \
            ! ss -H -lun "sport = :${port}" 2>/dev/null | grep -q .
            ;;
        *)
            return 1
            ;;
    esac
}

choose_relay_forward_port() {
    local preferred_port="$1"
    local proto="$2"
    local candidate

    if is_relay_forward_port_available "$preferred_port" "$proto"; then
        echo "$preferred_port"
        return
    fi

    for _i in $(seq 1 100); do
        candidate=$(shuf -i 10000-65000 -n 1)
        if is_relay_forward_port_available "$candidate" "$proto"; then
            echo "$candidate"
            return
        fi
    done

    err "Не удалось подобрать свободный внешний relay-forward порт для ${proto}."
}

iptables_ensure_rule() {
    local table="$1"
    local chain="$2"
    shift 2

    if [ "$table" = "filter" ]; then
        iptables -C "$chain" "$@" 2>/dev/null || iptables -A "$chain" "$@"
    else
        iptables -t "$table" -C "$chain" "$@" 2>/dev/null || iptables -t "$table" -A "$chain" "$@"
    fi
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
    else
        warn "iptables правила применены, но не сохранены: netfilter-persistent и iptables-save недоступны."
    fi
}

ensure_relay_forward_ports() {
    [ "$DEPLOY_MODE" = "relay" ] || return 0
    [ "${PORT_FORWARDING_ENABLED:-0}" -eq 1 ] || return 0
    [ -n "${PORT_FORWARDING_RULES:-}" ] || return 0

    local normalized_rules=""
    local rule_line
    local rule_target_ip
    local rule_target_port
    local rule_proto
    local rule_external_port
    local rule_id

    FORWARDING_SELECTED_EXTERNAL_PORTS=""

    while IFS= read -r rule_line; do
        [ -n "$rule_line" ] || continue
        IFS='|' read -r rule_target_ip rule_target_port rule_proto rule_external_port rule_id <<EOF
$rule_line
EOF
        rule_proto="${rule_proto:-both}"
        if [ -z "${rule_external_port:-}" ] || ! is_relay_forward_port_available "$rule_external_port" "$rule_proto"; then
            rule_external_port=$(choose_relay_forward_port "$rule_target_port" "$rule_proto")
        fi
        rule_id="${rule_id:-$(make_forwarding_rule_id "$rule_target_ip" "$rule_target_port" "$rule_proto" "$rule_external_port")}"

        if [ -z "$normalized_rules" ]; then
            normalized_rules="${rule_target_ip}|${rule_target_port}|${rule_proto}|${rule_external_port}|${rule_id}"
        else
            normalized_rules="${normalized_rules}
${rule_target_ip}|${rule_target_port}|${rule_proto}|${rule_external_port}|${rule_id}"
        fi
        FORWARDING_SELECTED_EXTERNAL_PORTS="${FORWARDING_SELECTED_EXTERNAL_PORTS:+${FORWARDING_SELECTED_EXTERNAL_PORTS}:}${rule_external_port}"
    done <<EOF
${PORT_FORWARDING_RULES}
EOF

    PORT_FORWARDING_RULES="$normalized_rules"
}

cleanup_port_forwarding() {
    [ "$DEPLOY_MODE" = "relay" ] || return 0
    [ "${PORT_FORWARDING_ENABLED:-0}" -eq 1 ] || return 0
    [ -n "${PORT_FORWARDING_RULES:-}" ] || return 0

    iptables_delete_rule filter FORWARD -m conntrack --ctstate RELATED,ESTABLISHED -m comment --comment "3x-awg relay fwd established" -j ACCEPT

    local rule_line
    local rule_target_ip
    local rule_target_port
    local rule_proto
    local rule_external_port
    local rule_id
    local fwd_proto
    local rule_comment

    while IFS= read -r rule_line; do
        [ -n "$rule_line" ] || continue
        IFS='|' read -r rule_target_ip rule_target_port rule_proto rule_external_port rule_id <<EOF
$rule_line
EOF
        rule_external_port="${rule_external_port:-$rule_target_port}"
        rule_id="${rule_id:-$(make_forwarding_rule_id "$rule_target_ip" "$rule_target_port" "$rule_proto" "$rule_external_port")}"
        for fwd_proto in $(forwarding_rule_protocols "$rule_proto"); do
            rule_comment="3x-awg-fwd:${rule_id}:${fwd_proto}"
            iptables_delete_rule nat PREROUTING -i "$PUB_INT" -p "$fwd_proto" --dport "$rule_external_port" -m comment --comment "$rule_comment prerouting" -j DNAT --to-destination "${rule_target_ip}:${rule_target_port}"
            iptables_delete_rule filter FORWARD -i "$PUB_INT" -p "$fwd_proto" -d "$rule_target_ip" --dport "$rule_target_port" -m comment --comment "$rule_comment forward" -j ACCEPT
            iptables_delete_rule nat POSTROUTING -p "$fwd_proto" -d "$rule_target_ip" --dport "$rule_target_port" -m comment --comment "$rule_comment postrouting" -j MASQUERADE
        done
    done <<EOF
${PORT_FORWARDING_RULES}
EOF
}

forwarding_rule_protocols() {
    case "$1" in
        tcp) echo "tcp" ;;
        udp) echo "udp" ;;
        both|'') echo "tcp udp" ;;
        *) echo "tcp udp" ;;
    esac
}

setup_port_forwarding() {
    [ "$DEPLOY_MODE" = "relay" ] || return 0
    [ "${PORT_FORWARDING_ENABLED:-0}" -eq 1 ] || return 0
    [ -n "${PORT_FORWARDING_RULES:-}" ] || return 0

    mark_step "Relay forwarding: cleanup old owned rules"
    cleanup_port_forwarding

    ensure_relay_forward_ports

    mark_step "Relay forwarding: install transparent NAT rules"
    iptables_ensure_rule filter FORWARD -m conntrack --ctstate RELATED,ESTABLISHED -m comment --comment "3x-awg relay fwd established" -j ACCEPT

    local rule_line
    local rule_target_ip
    local rule_target_port
    local rule_proto
    local rule_external_port
    local rule_id
    local fwd_proto
    local rule_comment

    while IFS= read -r rule_line; do
        [ -n "$rule_line" ] || continue
        IFS='|' read -r rule_target_ip rule_target_port rule_proto rule_external_port rule_id <<EOF
$rule_line
EOF
        rule_external_port="${rule_external_port:-$rule_target_port}"
        rule_id="${rule_id:-$(make_forwarding_rule_id "$rule_target_ip" "$rule_target_port" "$rule_proto" "$rule_external_port")}"
        for fwd_proto in $(forwarding_rule_protocols "$rule_proto"); do
            rule_comment="3x-awg-fwd:${rule_id}:${fwd_proto}"
            iptables_ensure_rule nat PREROUTING -i "$PUB_INT" -p "$fwd_proto" --dport "$rule_external_port" -m comment --comment "$rule_comment prerouting" -j DNAT --to-destination "${rule_target_ip}:${rule_target_port}"
            iptables_ensure_rule filter FORWARD -i "$PUB_INT" -p "$fwd_proto" -d "$rule_target_ip" --dport "$rule_target_port" -m comment --comment "$rule_comment forward" -j ACCEPT
            iptables_ensure_rule nat POSTROUTING -p "$fwd_proto" -d "$rule_target_ip" --dport "$rule_target_port" -m comment --comment "$rule_comment postrouting" -j MASQUERADE
        done
    done <<EOF
${PORT_FORWARDING_RULES}
EOF

    persist_iptables_rules
    save_forwarding_rules_state
}

# ==============================================================================
# 1. БАЗОВАЯ ОПТИМИЗАЦИЯ И БЕЗОПАСНОСТЬ OS
# ==============================================================================
mark_step "System: swapfile and OS packages"
ensure_swapfile

if [ "$SKIP_APT" -eq 0 ]; then
    mark_step "System: apt update and base packages"
    log "Очистка устаревших репозиториев (удаление bullseye-backports)..."
    sed -i '/bullseye-backports/d' /etc/apt/sources.list
    rm -f /etc/apt/sources.list.d/*backports*.list 2>/dev/null || true

    log "Обновление системы и установка базовых пакетов..."
    apt update && apt upgrade -y
    # Базовые пакеты и точные headers текущего ядра для детерминированной сборки AWG.
    apt install -y curl wget mc ufw fail2ban nano iptables iptables-persistent \
                   jq openssl whois qrencode dnsutils python3 wireguard-tools "linux-headers-$(uname -r)" \
        || err "Не удалось установить обязательные пакеты и точные kernel headers для $(uname -r)."
    # Обновляем дату последнего полного запуска
    date +%Y-%m-%d > "$LAST_RUN_FILE"
else
    log "Пропуск apt-операций (fast mode). Убеждаемся в наличии jq, openssl, python3 и dig..."
    command -v jq >/dev/null 2>&1 || apt install -y jq
    command -v openssl >/dev/null 2>&1 || apt install -y openssl
    command -v python3 >/dev/null 2>&1 || apt install -y python3
    command -v dig >/dev/null 2>&1 || apt install -y dnsutils
    command -v wg >/dev/null 2>&1 || apt install -y wireguard-tools
fi

if [ "$SKIP_APT" -eq 0 ]; then
    mark_step "System: editor defaults"
    log "Настройка редактора mcedit по умолчанию..."
    update-alternatives --set editor /usr/bin/mcedit || true
    export EDITOR=mcedit
    if ! grep -q "export EDITOR=mcedit" ~/.bashrc; then
        echo 'export EDITOR=mcedit' >> ~/.bashrc
    fi
fi

mark_step "System: sysctl hardening"
log "Оптимизация sysctl (сеть, BBR, лимиты)..."
# Удаляем устаревший файл (может содержать ключи из прошлых версий скрипта)
rm -f /etc/sysctl.d/99-custom-net.conf
cat <<EOF > /etc/sysctl.d/99-custom-net.conf
fs.file-max = 1048576
net.core.rmem_max = 67108864
net.core.wmem_max = 67108864
net.core.netdev_max_backlog = 10000
net.core.somaxconn = 4096
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_keepalive_time = 1200
net.ipv4.tcp_max_syn_backlog = 8192
net.ipv4.tcp_max_tw_buckets = 5000
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_mtu_probing = 1
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.ipv4.ip_forward = 1
EOF
sysctl --system 2>&1 | grep -v 'Invalid argument' | grep -v '^$' | head -20 || true

# ==============================================================================
# 2. ПОДГОТОВКА ОБЩИХ ПАРАМЕТРОВ УСТАНОВКИ
# ==============================================================================
mark_step "System: prepare runtime context"
log "Подготовка общих сетевых параметров..."
SERVER_IP=$(curl -s https://api.ipify.org || wget -qO- https://api.ipify.org)
PUB_INT=$(ip -4 route ls | grep default | grep -Po '(?<=dev )(\S+)' | head -1)

if [ -f "$CREDS_FILE" ] && [ "$ROTATE_CREDS" -eq 0 ]; then
    log "Загрузка существующего DNS порта AdGuardHome из $CREDS_FILE..."
    ADG_DNS_PORT=$(read_cred_value "ADG_DNS_PORT" "$CREDS_FILE")
fi

[ -z "$ADG_DNS_PORT" ] && ADG_DNS_PORT=$(shuf -i 10000-65000 -n 1)

if [ "$DEPLOY_MODE" = "relay" ]; then
    prompt_target_details
fi

# ==============================================================================
# 3. РУЧНОЙ HANDOFF ДЛЯ 3X-UI
# ==============================================================================
mark_step "3x-ui: cleanup legacy direct Xray artifacts"
log "Удаление legacy direct Xray-конфига от предыдущих версий..."
remove_legacy_xui

mark_step "3x-ui: run official interactive installer"
install_3x_ui_interactive

# ==============================================================================
# 5. УСТАНОВКА AMNEZIAWG
# ==============================================================================
log "Проверка AmneziaWG..."
mark_step "AmneziaWG: check installation state"
if command -v awg >/dev/null 2>&1 && [ -f /etc/amnezia/amneziawg/awg0.conf ]; then
    warn "AmneziaWG уже настроен, пропускаем переустановку."
else
    mark_step "AmneziaWG: install build dependencies"
    ensure_awg_build_dependencies
    if grep -qi "ubuntu" /etc/os-release; then
        mark_step "AmneziaWG: install Ubuntu package"
        log "Используем PPA для Ubuntu..."
        apt install -y software-properties-common python3-launchpadlib gnupg2
        add-apt-repository -y ppa:amnezia/ppa
        apt update
        apt install -y amneziawg
    else
        mark_step "AmneziaWG: build Debian module"
        log "Сборка AmneziaWG из исходников (Debian)..."
        (
            cd /usr/src
            rm -rf amneziawg-linux-kernel-module amneziawg-tools
            git clone https://github.com/amnezia-vpn/amneziawg-linux-kernel-module.git
            cd amneziawg-linux-kernel-module/src
            make dkms-install || make install
        )
        (
            cd /usr/src
            rm -rf amneziawg-tools
            git clone https://github.com/amnezia-vpn/amneziawg-tools.git
            cd amneziawg-tools/src
            make install
        )
    fi
fi
log "Генерация ключей и конфигурации AmneziaWG..."
mark_step "AmneziaWG: prepare config directory"
mkdir -p /etc/amnezia/amneziawg
chmod 700 /etc/amnezia/amneziawg

AWG_PORT=53
mark_step "AmneziaWG: resolve AWG key binary"
AWG_KEY_BIN="$(resolve_awg_key_bin || true)"
[ -n "$AWG_KEY_BIN" ] || err "Не найден awg/wg после установки AmneziaWG."
mark_step "AmneziaWG: load existing credentials"
load_existing_awg_credentials
AWG_PORT=53

# Параметры обфускации (Рандомизация для защиты от сигнатурного анализа ТСПУ 2026)
mark_step "AmneziaWG: generate obfuscation parameters"
ensure_awg_obfuscation_params
# Случайный порт DNS для AdGuardHome (не 53 — DNAT-редирект в awg0.conf)
[ -z "$ADG_DNS_PORT" ] && ADG_DNS_PORT=$(shuf -i 10000-65000 -n 1)

mark_step "AmneziaWG: generate server private key"
[ -z "$SERVER_PRIV" ] && SERVER_PRIV=$("$AWG_KEY_BIN" genkey)
mark_step "AmneziaWG: generate client private key"
[ -z "$CLIENT_PRIV" ] && CLIENT_PRIV=$("$AWG_KEY_BIN" genkey)
mark_step "AmneziaWG: generate client preshared key"
[ -z "$CLIENT_PSK" ] && CLIENT_PSK=$("$AWG_KEY_BIN" genpsk)
mark_step "AmneziaWG: derive public keys"
if [ -n "$SERVER_PRIV" ] && [ -z "$SERVER_PUB" ]; then
    SERVER_PUB=$(printf '%s' "$SERVER_PRIV" | "$AWG_KEY_BIN" pubkey)
fi

if [ -n "$CLIENT_PRIV" ] && [ -z "$CLIENT_PUB" ]; then
    CLIENT_PUB=$(printf '%s' "$CLIENT_PRIV" | "$AWG_KEY_BIN" pubkey)
fi

mark_step "AmneziaWG: write awg0.conf"
cat <<EOF > /etc/amnezia/amneziawg/awg0.conf
[Interface]
Address = 10.8.0.1/24
ListenPort = $AWG_PORT
PrivateKey = $SERVER_PRIV
MTU = 1280
Jc = $JC
Jmin = $JMIN
Jmax = $JMAX
S1 = $S1
S2 = $S2
H1 = $H1
H2 = $H2
H3 = $H3
H4 = $H4

# AWG-клиенты выходят напрямую через публичный интерфейс. DNS по-прежнему идёт в AdGuardHome.
PostUp = iptables -t nat -A POSTROUTING -s 10.8.0.0/24 -o $PUB_INT -j MASQUERADE
# DNAT: перенаправляем DNS от VPN-клиентов (порт 53) -> AdGuardHome (порт $ADG_DNS_PORT)
PostUp = iptables -t nat -A PREROUTING -i awg0 -p udp --dport 53 -j REDIRECT --to-port $ADG_DNS_PORT
PostUp = iptables -t nat -A PREROUTING -i awg0 -p tcp --dport 53 -j REDIRECT --to-port $ADG_DNS_PORT

PostDown = iptables -t nat -D POSTROUTING -s 10.8.0.0/24 -o $PUB_INT -j MASQUERADE 2>/dev/null || true
PostDown = iptables -t nat -D PREROUTING -i awg0 -p udp --dport 53 -j REDIRECT --to-port $ADG_DNS_PORT 2>/dev/null || true
PostDown = iptables -t nat -D PREROUTING -i awg0 -p tcp --dport 53 -j REDIRECT --to-port $ADG_DNS_PORT 2>/dev/null || true

[Peer]
PublicKey = $CLIENT_PUB
PresharedKey = $CLIENT_PSK
AllowedIPs = 10.8.0.2/32
EOF

mark_step "AmneziaWG: cleanup legacy DNS redirects"
cleanup_legacy_awg_dns_redirects
mark_step "AmneziaWG: enable awg-quick@awg0"
systemctl enable awg-quick@awg0
mark_step "AmneziaWG: restart awg-quick@awg0"
systemctl restart awg-quick@awg0 || err "Не удалось поднять awg0. Проверьте сборку модуля AmneziaWG для $(uname -r)."

# Конфигурация клиента
mark_step "AmneziaWG: write amnezia_client.conf"
cat <<EOF > /root/amnezia_client.conf
[Interface]
PrivateKey = $CLIENT_PRIV
Address = 10.8.0.2/32
DNS = 10.8.0.1
MTU = 1280
Jc = $JC
Jmin = $JMIN
Jmax = $JMAX
S1 = $S1
S2 = $S2
H1 = $H1
H2 = $H2
H3 = $H3
H4 = $H4

[Peer]
PublicKey = $SERVER_PUB
PresharedKey = $CLIENT_PSK
Endpoint = $SERVER_IP:$AWG_PORT
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25
EOF
chmod 600 /root/amnezia_client.conf

# ==============================================================================
# 6. УСТАНОВКА И НАСТРОЙКА ADGUARD HOME
# ==============================================================================
log "Установка AdGuardHome..."
mark_step "AdGuardHome: load credentials and install binary"
# DNS на случайном порту $ADG_DNS_PORT — systemd-resolved отключать не нужно

# Загружаем или генерируем новые credentials AdGuardHome
if [ -f "$CREDS_FILE" ] && [ "$ROTATE_CREDS" -eq 0 ]; then
    log "Загрузка существующих credentials AdGuardHome из $CREDS_FILE..."
    ADG_PORT=$(read_url_port "ADG_URL" "$CREDS_FILE")
    ADG_USER=$(read_cred_value "ADG_USER" "$CREDS_FILE")
    ADG_PASS=$(read_cred_value "ADG_PASS" "$CREDS_FILE")
    ADG_DNS_PORT=$(read_cred_value "ADG_DNS_PORT" "$CREDS_FILE")
fi

# Если пустые, генерируем заново
[ -z "$ADG_PORT" ] && ADG_PORT=$(shuf -i 10000-65000 -n 1)
[ -z "$ADG_USER" ] && ADG_USER=$(tr -dc A-Za-z0-9 </dev/urandom | head -c 8)
[ -z "$ADG_PASS" ] && ADG_PASS=$(tr -dc A-Za-z0-9 </dev/urandom | head -c 12)
[ -z "$ADG_DNS_PORT" ] && ADG_DNS_PORT=$(shuf -i 10000-65000 -n 1)
command -v mkpasswd >/dev/null || apt install -y whois
ADG_HASH=$(mkpasswd -m bcrypt "$ADG_PASS")

# Устанавливаем AdGuardHome только если бинарника нет
if [ ! -f "/opt/AdGuardHome/AdGuardHome" ]; then
    log "Установка AdGuardHome..."
    curl -s -S -L https://raw.githubusercontent.com/AdguardTeam/AdGuardHome/master/scripts/install.sh | sh -s -- -v
else
    warn "AdGuardHome бинарник уже существует, пропуск установки."
fi

# Всегда перезаписываем конфиг (новые порт, логин, пароль)
mark_step "AdGuardHome: write YAML config"
log "Применение конфигурации AdGuardHome..."

# Останавливаем активные инстансы и удаляем legacy lower-case unit.
cleanup_legacy_adguard_units

cat <<EOF > /opt/AdGuardHome/AdGuardHome.yaml
http:
  pprof:
    port: 6060
    enabled: false
  address: 0.0.0.0:$ADG_PORT
  session_ttl: 720h
users:
  - name: $ADG_USER
    password: $ADG_HASH
auth_attempts: 5
block_auth_min: 15
language: ru
theme: auto
dns:
  bind_hosts:
    - 0.0.0.0
  port: $ADG_DNS_PORT
  upstream_dns:
    - https://cloudflare-dns.com/dns-query
    - https://dns.google/dns-query
  cache_size: 4194304
filtering:
  safe_search:
    enabled: true
    bing: true
    duckduckgo: true
    google: true
    pixabay: true
    yandex: true
    youtube: true
filters:
  - enabled: true
    url: https://adguardteam.github.io/HostlistsRegistry/assets/filter_1.txt
    name: AdGuard DNS filter
    id: 1
  - enabled: true
    url: https://adguardteam.github.io/HostlistsRegistry/assets/filter_2.txt
    name: AdAway Default Blocklist
    id: 2
EOF

# Регистрируем systemd-юнит AdGuardHome. Используем одно canonical имя сервиса.
AGH_SVC_NAME="AdGuardHome"
mark_step "AdGuardHome: register systemd unit"
if ! systemctl list-unit-files 2>/dev/null | grep -qi 'AdGuardHome\.service'; then
    log "Регистрация AdGuardHome в systemd..."
    /opt/AdGuardHome/AdGuardHome -s install 2>/dev/null || true
    systemctl daemon-reload
fi

if ! systemctl list-unit-files 2>/dev/null | grep -qi 'AdGuardHome\.service'; then
    cat <<UNIT > /etc/systemd/system/AdGuardHome.service
[Unit]
Description=AdGuard Home: Network-level blocker
After=syslog.target network-online.target

[Service]
User=root
WorkingDirectory=/opt/AdGuardHome
ExecStart=/opt/AdGuardHome/AdGuardHome -s run
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
UNIT
    systemctl daemon-reload
fi

# Добавляем override: запускать ПОСЛЕ awg0
mark_step "AdGuardHome: configure after-awg override"
mkdir -p "/etc/systemd/system/${AGH_SVC_NAME}.service.d"
cat <<OVERRIDE > "/etc/systemd/system/${AGH_SVC_NAME}.service.d/after-awg.conf"
[Unit]
After=awg-quick@awg0.service network-online.target
Wants=awg-quick@awg0.service network-online.target
[Service]
Restart=on-failure
RestartSec=5
OVERRIDE

systemctl daemon-reload
mark_step "AdGuardHome: enable and restart service"
systemctl enable "${AGH_SVC_NAME}" 2>/dev/null || true

# Ждём интерфейс awg0 (до 15с), затем стартуем
for _i in $(seq 1 15); do ip link show awg0 > /dev/null 2>&1 && break; sleep 1; done
systemctl restart "${AGH_SVC_NAME}"

# Проверяем что AGH реально слушает на ADG_DNS_PORT
for _i in $(seq 1 10); do ss -ulnp | grep ":${ADG_DNS_PORT} " > /dev/null 2>&1 && break; sleep 1; done
if ss -ulnp | grep ":${ADG_DNS_PORT} " > /dev/null 2>&1; then
    log "AdGuardHome DNS (порт ${ADG_DNS_PORT}) слушает — OK"
else
    warn "AdGuardHome НЕ слушает на порту ${ADG_DNS_PORT}! Проверьте: journalctl -u ${AGH_SVC_NAME} -n 50"
fi

# ==============================================================================
# 7. НАСТРОЙКА SSH И ФАЕРВОЛА
# ==============================================================================
mark_step "Firewall: UFW and SSH"
log "Настройка UFW..."
if [ "$DEPLOY_MODE" = "relay" ]; then
    ensure_relay_forward_ports
fi

if ss -tlnp | grep -q ':2244'; then
    warn "SSH уже на порту 2244, настраиваем правила для него."
    ufw allow 2244/tcp 2>/dev/null || true
else
    ufw allow 22/tcp 2>/dev/null || true
fi

ufw default allow outgoing
if [ "$DEPLOY_MODE" = "relay" ]; then
    mark_step "Firewall: relay local allow Reality 443/tcp"
else
    mark_step "Firewall: target allow Reality 443/tcp"
fi
ufw allow 443/tcp
if [ "$DEPLOY_MODE" = "relay" ]; then
    mark_step "Firewall: relay local allow AdGuardHome web"
else
    mark_step "Firewall: target allow AdGuardHome web"
fi
ufw allow ${ADG_PORT}/tcp
if [ "$DEPLOY_MODE" = "relay" ]; then
    mark_step "Firewall: relay local allow AWG 53/udp"
else
    mark_step "Firewall: target allow AWG 53/udp"
fi
ufw allow ${AWG_PORT}/udp
if [ "$DEPLOY_MODE" = "relay" ]; then
    mark_step "Firewall: relay forward allow external AWG"
    while IFS='|' read -r rule_target_ip rule_target_port rule_proto rule_external_port rule_id; do
        [ -n "$rule_target_ip" ] || continue
        rule_external_port="${rule_external_port:-$rule_target_port}"
        for fwd_proto in $(forwarding_rule_protocols "$rule_proto"); do
            ufw allow ${rule_external_port}/${fwd_proto}
        done
    done <<EOF
${PORT_FORWARDING_RULES:-}
EOF
    mark_step "Firewall: relay forward allow external Reality"
fi
# Разрешаем трафик к AGH DNS порту от VPN-клиентов (DNAT: awg0:53 -> 0.0.0.0:ADG_DNS_PORT)
if [ "$DEPLOY_MODE" = "relay" ]; then
    mark_step "Firewall: relay local allow AdGuardHome DNS from awg0"
else
    mark_step "Firewall: target allow AdGuardHome DNS from awg0"
fi
ufw allow in on awg0 to any port ${ADG_DNS_PORT}
ufw allow ${ADG_DNS_PORT}/tcp
ufw allow ${ADG_DNS_PORT}/udp
sed -i 's/DEFAULT_FORWARD_POLICY="DROP"/DEFAULT_FORWARD_POLICY="ACCEPT"/' /etc/default/ufw
ufw --force enable
if [ "$DEPLOY_MODE" = "relay" ]; then
    setup_port_forwarding
fi

if ! ss -tlnp | grep -q ':2244'; then
    log "Изменение порта SSH на 2244..."
    sed -i '/^#\?Port /d' /etc/ssh/sshd_config
    echo "Port 2244" >> /etc/ssh/sshd_config
    mkdir -p /etc/ssh/sshd_config.d
    echo "Port 2244" > /etc/ssh/sshd_config.d/custom_port.conf 2>/dev/null || true
    systemctl restart sshd
    sleep 2
    if ss -tlnp | grep -q ':2244'; then
        ufw allow 2244/tcp 2>/dev/null || true
        ufw delete allow 22/tcp 2>/dev/null || true
        log "SSH порт 2244 активен"
    fi
fi

# Настройка Fail2Ban для SSH
mark_step "Firewall: Fail2Ban"
log "Настройка Fail2Ban (SSH)..."
cat <<EOF > /etc/fail2ban/jail.d/vpn-bundle.local
[sshd]
enabled = true
port = 2244
mode = aggressive
backend = systemd
maxretry = 5
findtime = 10m
bantime = 1h
EOF
systemctl restart fail2ban

mark_step "Firewall: validate stack"
validate_stack "${AGH_SVC_NAME}"

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
