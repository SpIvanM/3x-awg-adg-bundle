prompt_target_details() {
    [ -c /dev/tty ] || err "Для настройки relay требуется интерактивный ввод target-параметров через /dev/tty."

    if [ -f "$CREDS_FILE" ] && [ "$ROTATE_CREDS" -eq 0 ]; then
        TARGET_IP=$(read_cred_value "TARGET_IP" "$CREDS_FILE")
        TARGET_AWG_PORT=$(read_cred_value "TARGET_AWG_PORT" "$CREDS_FILE")
        TARGET_REALITY_PORT=$(read_cred_value "TARGET_REALITY_PORT" "$CREDS_FILE")
        TARGET_DNS_PORT=$(read_cred_value "TARGET_DNS_PORT" "$CREDS_FILE")
    fi

    TARGET_AWG_PORT="${TARGET_AWG_PORT:-53}"
    TARGET_REALITY_PORT="${TARGET_REALITY_PORT:-443}"

    log "Relay: ввод параметров target-сервера для будущего forwarding."

    local entered_value
    while true; do
        printf 'Target IP [%s]: ' "${TARGET_IP:-required}" >/dev/tty
        IFS= read -r entered_value </dev/tty
        entered_value=$(trim_cr_value "$entered_value")
        [ -n "$entered_value" ] && TARGET_IP="$entered_value"
        [ -n "${TARGET_IP:-}" ] && break
    done

    printf 'Target AWG UDP port [%s]: ' "$TARGET_AWG_PORT" >/dev/tty
    IFS= read -r entered_value </dev/tty
    entered_value=$(trim_cr_value "$entered_value")
    [ -n "$entered_value" ] && TARGET_AWG_PORT="$entered_value"

    printf 'Target Reality TCP port [%s]: ' "$TARGET_REALITY_PORT" >/dev/tty
    IFS= read -r entered_value </dev/tty
    entered_value=$(trim_cr_value "$entered_value")
    [ -n "$entered_value" ] && TARGET_REALITY_PORT="$entered_value"

    while true; do
        printf 'Target DNS port [%s]: ' "${TARGET_DNS_PORT:-required}" >/dev/tty
        IFS= read -r entered_value </dev/tty
        entered_value=$(trim_cr_value "$entered_value")
        [ -n "$entered_value" ] && TARGET_DNS_PORT="$entered_value"
        [ -n "${TARGET_DNS_PORT:-}" ] && break
    done

    case "$TARGET_AWG_PORT:$TARGET_REALITY_PORT:$TARGET_DNS_PORT" in
        *[!0-9:]*|'') err "Target-порты должны быть числовыми: AWG=${TARGET_AWG_PORT}, Reality=${TARGET_REALITY_PORT}, DNS=${TARGET_DNS_PORT}." ;;
    esac
}
