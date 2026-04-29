<!--
Name: 3x setup source index
Description: Индекс модулей для сборки setup.sh и lifecycle uninstall. Этот файл нужен как карта разделения и не участвует в runtime.
-->

# Индекс source-модулей `setup.sh`

Сборка выполняется скриптом [`tools/build-setup.ps1`](../../tools/build-setup.ps1) и собирает публичный [`setup.sh`](../../setup.sh) из следующих файлов:

1. `00-bootstrap.sh`
1. `10-common.sh`
1. `11-awg-helpers.sh`
1. `12-agh-helpers.sh`
1. `13-3x-helpers.sh`
1. `14-port-forwarding-helpers.sh`
1. `20-system.sh`
1. `30-xray.sh`
1. `40-awg.sh`
1. `50-adguard.sh`
1. `60-firewall.sh`
1. `70-output.sh`

## Назначение модулей

- `00-bootstrap.sh` - shebang, глобальные переменные, CLI, логирование, step-aware trap/err, assembled header и базовые инварианты запуска.
- `10-common.sh` - общие helper-функции: чтение credentials и конфигов, CRLF-нормализация, разбор URL-порта, validation AWG/AGH и управление swapfile.
- `11-awg-helpers.sh` - helper-функции AmneziaWG: fallback на `wg`, подготовка build dependencies, восстановление существующих AWG credentials, идемпотентная генерация obfuscation-параметров и cleanup legacy DNS redirect-правил.
- `12-agh-helpers.sh` - helper-функции AdGuardHome для cleanup legacy systemd units перед перезаписью канонического сервиса.
- `13-3x-helpers.sh` - helper-функции ручного `3x-ui` flow: cleanup legacy direct Xray-артефактов и запуск официального интерактивного installer через `/dev/tty`.
- `14-port-forwarding-helpers.sh` - helper-модуль relay / port-forwarding слоя: `prompt_target_details` интерактивно через `/dev/tty` собирает и переиспользует `TARGET_IP`, `TARGET_AWG_PORT`, `TARGET_REALITY_PORT`, `TARGET_DNS_PORT`, подбирает внешние `RELAY_FWD_AWG_PORT` и `RELAY_FWD_REALITY_PORT`; `setup_port_forwarding` идемпотентно ставит прозрачные DNAT/FORWARD/MASQUERADE правила, сохраняет их через `netfilter-persistent` или `iptables-save`, а `cleanup_port_forwarding` удаляет только собственные правила без глобального flush.
- `20-system.sh` - системная подготовка, `apt`, `sysctl`, swapfile, определение сетевого контекста, подготовка общего DNS-порта для AdGuardHome и AWG, а для relay - сбор target-параметров до настройки локального стека.
- `30-xray.sh` - ручной handoff `3x-ui`: cleanup legacy direct Xray-конфига и запуск официального интерактивного installer для `target` и relay-local direct-стека.
- `40-awg.sh` - установка и конфигурация AmneziaWG для `target` и relay-local direct-стека на `53/udp`, `MTU 1280`, direct NAT egress, DNS DNAT к AdGuardHome и явными step-маркерами для ключей, конфига и рестарта, с повторным использованием восстановленных ключей и obfuscation-параметров.
- `50-adguard.sh` - установка и конфигурация AdGuardHome в direct-режиме, без HTTP proxy и без автоконфигурации `3x-ui`.
- `60-firewall.sh` - `UFW`, `SSH`, `Fail2Ban`, установка relay transparent forwarding после выбора локальных портов, target firewall openings для `Reality 443`, `AWG 53/udp`, AdGuardHome, relay-local openings для собственного direct-стека, отдельные relay-forward openings для внешних AWG/Reality портов и системная валидация стека.
- `70-output.sh` - cleanup, сохранение credentials, финальный вывод оператору с ручным handoff по `3x-ui`, блок `Target handoff` для настройки `relay`, а также relay-вывод `Relay local direct stack`, активные `Relay-forward endpoints` на месте прежнего блока `Future relay-forward endpoints` и сохранённые target-параметры.

## Lifecycle uninstall

- [`../../uninstall.sh`](../../uninstall.sh) синхронизирован с текущим набором модулей: удаляет 3x-ui после ручного installer-flow, AmneziaWG, AdGuardHome, credentials и логи.
- Relay cleanup удаляет только owned forwarding-правила с comment-маркерами `3x-awg relay fwd ...`, сохраняет iptables через `netfilter-persistent` или `iptables-save` и не выполняет глобальный flush/reset фаервола.
- Устаревшая cascade-автоматизация и связанные поля прежних credentials не возвращаются в runtime или lifecycle.
