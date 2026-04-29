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
