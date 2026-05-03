#!/bin/bash
# Name: fwd.sh
# Description: Standalone port forwarding manager for 3x-awg-adg-bundle
# Version: 1.0.0

set -Ee

# Settings
FORWARDING_STATE_FILE="/root/.vpn-forwarding-rules"
DEPLOY_MODE="relay" # Tool is for relay management
PUB_INT=$(ip -4 route ls | grep default | grep -Po '(?<=dev )(\S+)' | head -n1)

# Colors
GREEN="\e[32m"
RED="\e[31m"
YELLOW="\e[33m"
RESET="\e[0m"

log() { echo -e "${GREEN}[INFO] $1${RESET}"; }
warn() { echo -e "${YELLOW}[WARN] $1${RESET}"; }
err() { echo -e "${RED}[ERROR] $1${RESET}"; exit 1; }

trim_cr_value() {
    printf '%s' "$1" | tr -d '\r'
}

is_yes_answer() {
    case "$1" in
        y|Y|yes|YES|Yes|д|Д|да|ДА|Да) return 0 ;;
        *) return 1 ;;
    esac
}

# --- Logic from 14-port-forwarding-helpers.sh ---

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

    if [ -f "$FORWARDING_STATE_FILE" ]; then
        while IFS='|' read -r rule_target_ip rule_target_port rule_proto rule_external_port rule_id _rest; do
            case "$rule_target_ip" in ''|\#*) continue ;; esac
            [ -n "$rule_target_port" ] || continue
            [ -n "$rule_proto" ] || rule_proto="both"
            [ -n "$rule_external_port" ] || rule_external_port="$rule_target_port"
            append_forwarding_rule "$rule_target_ip" "$rule_target_port" "$rule_proto" "$rule_external_port" "$rule_id"
        done < "$FORWARDING_STATE_FILE"
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

is_relay_forward_port_available() {
    local port="$1"
    local proto="$2"
    # Basic reservation check (can be expanded)
    local reserved_ports=":22:2244:53:443:"

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

delete_iptables_rules_by_comment_prefix() {
    local prefix="$1"
    local table
    local rule
    for table in nat filter; do
        iptables-save -t "$table" | grep "comment \"$prefix" | sed 's/-A/-D/' | while read -r rule; do
            [ -n "$rule" ] || continue
            iptables -t "$table" $rule
        done
    done
}

persist_iptables_rules() {
    if command -v netfilter-persistent >/dev/null 2>&1; then
        netfilter-persistent save
    elif command -v iptables-save >/dev/null 2>&1; then
        mkdir -p /etc/iptables
        iptables-save > /etc/iptables/rules.v4
    fi
}

cleanup_port_forwarding() {
    log "Очистка текущих правил iptables..."
    iptables -t filter -D FORWARD -m conntrack --ctstate RELATED,ESTABLISHED -m comment --comment "3x-awg relay fwd established" -j ACCEPT 2>/dev/null || true
    delete_iptables_rules_by_comment_prefix "3x-awg-fwd:"
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
    [ "${PORT_FORWARDING_ENABLED:-0}" -eq 1 ] || return 0
    [ -n "${PORT_FORWARDING_RULES:-}" ] || return 0

    log "Применение правил iptables..."
    iptables_ensure_rule filter FORWARD -m conntrack --ctstate RELATED,ESTABLISHED -m comment --comment "3x-awg relay fwd established" -j ACCEPT

    local rule_line
    while IFS= read -r rule_line; do
        [ -n "$rule_line" ] || continue
        IFS='|' read -r rule_target_ip rule_target_port rule_proto rule_external_port rule_id <<EOF
$rule_line
EOF
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

# --- New UI Logic ---

show_current_forwardings() {
    echo -e "\n${BOLD}Текущие пробросы портов:${RESET}"
    if [ -z "${PORT_FORWARDING_RULES:-}" ]; then
        echo " (нет активных правил)"
        return
    fi

    local rule_line
    while IFS= read -r rule_line; do
        [ -n "$rule_line" ] || continue
        IFS='|' read -r rule_target_ip rule_target_port rule_proto rule_external_port rule_id <<EOF
$rule_line
EOF
        printf " %-5s: %s:%s -> %s\n" "$rule_proto" "$rule_target_ip" "$rule_target_port" "$rule_external_port"
    done <<EOF
${PORT_FORWARDING_RULES}
EOF
    echo ""
}

main() {
    if [ "$EUID" -ne 0 ]; then
        err "Запустите скрипт от имени root (sudo -i)"
    fi

    load_forwarding_rules_state
    show_current_forwardings

    printf 'Удалить старые перенаправления? [y/N]: ' >/dev/tty
    IFS= read -r answer </dev/tty
    if is_yes_answer "$(trim_cr_value "$answer")"; then
        cleanup_port_forwarding
        PORT_FORWARDING_RULES=""
        PORT_FORWARDING_ENABLED=0
        save_forwarding_rules_state
        log "Старые правила удалены."
    fi

    while true; do
        printf 'Настроить новый сервер? [Y/n]: ' >/dev/tty
        IFS= read -r answer </dev/tty
        answer=$(trim_cr_value "$answer")
        # Default is Yes for "Configure new server?" as per user requirement (Y/n)
        [ -z "$answer" ] || is_yes_answer "$answer" || break

        while true; do
            printf ' Target IP: ' >/dev/tty
            IFS= read -r target_ip </dev/tty
            target_ip=$(trim_cr_value "$target_ip")
            [ -n "$target_ip" ] && break
            warn "Target IP обязателен."
        done

        while true; do
            while true; do
                printf ' Настроить новый порт? [Y/n]: ' >/dev/tty
                IFS= read -r answer </dev/tty
                answer=$(trim_cr_value "$answer")
                [ -z "$answer" ] || is_yes_answer "$answer" || break 2

                printf '  Target port: ' >/dev/tty
                IFS= read -r target_port </dev/tty
                target_port=$(trim_cr_value "$target_port")
                case "$target_port" in
                    ''|*[!0-9]*) warn "Target port должен быть числом." ; continue ;;
                esac

                printf '  Protocol [tcp, udp, both] (both): ' >/dev/tty
                IFS= read -r proto </dev/tty
                proto=$(trim_cr_value "$proto")
                proto="${proto:-both}"

                # Auto-choose external port
                ext_port=$(choose_relay_forward_port "$target_port" "$proto")
                append_forwarding_rule "$target_ip" "$target_port" "$proto" "$ext_port"
                PORT_FORWARDING_ENABLED=1
                log "Добавлено: $proto $target_ip:$target_port -> $ext_port"
            done
            break
        done
    done

    if [ "${PORT_FORWARDING_ENABLED:-0}" -eq 1 ]; then
        setup_port_forwarding
        log "Настройка завершена."
        show_current_forwardings
    fi
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
