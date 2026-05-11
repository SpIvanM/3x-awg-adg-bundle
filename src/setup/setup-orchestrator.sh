#!/bin/bash
# ==============================================================================
# setup-orchestrator.sh
# ОРКЕСТРАТОР УСТАНОВКИ 3X-UI + AMNEZIAWG + ADGUARDHOME
# ==============================================================================
set -Ee
export DEBIAN_FRONTEND=noninteractive

# Глобальные переменные по умолчанию
export SCRIPT_VERSION="4.0.0"
export CREDS_FILE="/root/.vpn-credentials"
export FORWARDING_STATE_FILE="/root/.vpn-forwarding-rules"
export DEPLOY_MODE="target"
export ROTATE_CREDS=0
export BASE_URL="https://raw.githubusercontent.com/SpIvanM/3x-awg-adg-bundle/main/src/setup"

# Цвета
GREEN="\e[32m"
RED="\e[31m"
YELLOW="\e[33m"
RESET="\e[0m"

log() { echo -e "${GREEN}[INFO] $1${RESET}"; }
warn() { echo -e "${YELLOW}[WARN] $1${RESET}"; }
err() { echo -e "${RED}[ERROR] $1${RESET}"; exit 1; }

# Парсинг аргументов
while [[ "$#" -gt 0 ]]; do
    case $1 in
        --rotate|-r) export ROTATE_CREDS=1; shift ;;
        --mode)
            if [ -z "${2:-}" ]; then err "Аргумент --mode требует значение: target или relay"; fi
            if [ "$2" != "target" ] && [ "$2" != "relay" ]; then err "Недопустимое значение --mode: $2"; fi
            export DEPLOY_MODE="$2"
            shift 2
            ;;
        *) err "Неизвестный аргумент: $1" ;;
    esac
done

if [ "$EUID" -ne 0 ]; then
  err "Запустите скрипт от имени root (sudo -i)"
fi

log "Запуск оркестратора v${SCRIPT_VERSION} в режиме ${DEPLOY_MODE}..."

WORKDIR=$(mktemp -d)
trap 'rm -rf "$WORKDIR"' EXIT

run_module() {
    local module="$1"
    local local_path="$module"
    local script_path="$WORKDIR/$module"
    
    if [ -f "$local_path" ]; then
        log "Запуск локального модуля $module..."
        bash "$local_path" || err "Модуль $module завершился с ошибкой"
    elif [ -f "src/setup/$module" ]; then
        log "Запуск локального модуля src/setup/$module..."
        bash "src/setup/$module" || err "Модуль $module завершился с ошибкой"
    else
        log "Скачивание и запуск удаленного модуля $module..."
        curl -fsSL "$BASE_URL/$module" -o "$script_path" || err "Не удалось скачать $module"
        bash "$script_path" || err "Модуль $module завершился с ошибкой"
    fi
}

run_module "setup-vps.sh"
run_module "setup-3x.sh"
run_module "setup-awg.sh"
run_module "setup-agh.sh"
run_module "setup-output.sh"

log "Оркестратор успешно завершил работу."
