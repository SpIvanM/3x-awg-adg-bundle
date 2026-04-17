#!/bin/bash
# Name: vps-vpn-triad (assembled source bootstrap)
# Description: Bootstrap layer for the modular Xray Reality + AmneziaWG + AdGuardHome installer.
# Assembled from source modules:
#   - src/setup/00-bootstrap.sh
#   - src/setup/10-helpers.sh
#   - src/setup/20-system.sh
#   - src/setup/30-xray.sh
#   - src/setup/40-awg.sh
#   - src/setup/50-adguard.sh
#   - src/setup/60-firewall.sh
#   - src/setup/70-output.sh
# Usage: curl -fsSL https://raw.githubusercontent.com/SpIvanM/3x-awg-adg-bundle/main/setup.sh | sudo bash [-r | --rotate] [--cascade-vless 'vless://...'] [--cascade-mode auto]
# Behavior: Updates sysctl, installs OS packages, installs pinned Xray-core via the official installer, compiles AmneziaWG kernel module, sets up AdGuard, can route non-RU AWG traffic through an upstream Reality exit, and proxies AdGuardHome DNS upstreams through local Xray.
# Returns: Complete VPN and DNS server proxy routing.
# Fails: If run without root privileges.
# ==============================================================================
# Комплексный скрипт настройки Debian 11/Ubuntu: OS Optimization + Xray Reality + AmneziaWG + AdGuardHome
# ==============================================================================

set -e
export DEBIAN_FRONTEND=noninteractive
export RANDFILE=/tmp/.rnd

# Глобальные переменные и пути
SCRIPT_VERSION="2.1.4"
XRAY_VERSION_PIN="25.1.30"
CREDS_FILE="/root/.vpn-credentials"
LOG_FILE="/var/log/vpn-setup.log"
LAST_RUN_FILE="/root/.vpn-setup-last-run"
CASCADE_VLESS_ARG=""
CASCADE_MODE_ARG=""
CASCADE_ENABLED=0
CASCADE_MODE=""
CASCADE_VLESS=""
CASCADE_ADDRESS=""
CASCADE_PORT=""
CASCADE_UUID=""
CASCADE_FLOW=""
CASCADE_PBK=""
CASCADE_SNI=""
CASCADE_SID=""
CASCADE_FP=""
CASCADE_SPX=""
CASCADE_ADDRESS_IP=""
FINAL_MODE="direct"

# Обработка аргументов
ROTATE_CREDS=0
while [[ "$#" -gt 0 ]]; do
    case $1 in
        --rotate|-r) ROTATE_CREDS=1; shift ;;
        --cascade-vless)
            if [ -z "${2:-}" ]; then
                echo "[ERROR] Аргумент --cascade-vless требует значение вида vless://..." >&2
                exit 1
            fi
            CASCADE_VLESS_ARG="$2"
            shift 2
            ;;
        --cascade-mode)
            if [ -z "${2:-}" ]; then
                echo "[ERROR] Аргумент --cascade-mode требует значение. В v1 поддерживается только auto." >&2
                exit 1
            fi
            CASCADE_MODE_ARG="$2"
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
err() { echo -e "${RED}[ERROR] $1${RESET}"; exit 1; }

log "Версия скрипта: ${SCRIPT_VERSION}"

trap 'warn "Скрипт прерван! Проверьте состояние вручную. Лог: $LOG_FILE"' ERR INT TERM

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
