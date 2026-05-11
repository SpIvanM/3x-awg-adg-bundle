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

### Новая архитектура (Оркестратор и самостоятельные скрипты)
- `setup-orchestrator.sh` - новый модульный оркестратор, скачивающий и запускающий остальные модули по очереди. Заменяет собой старый `setup.sh`.
- `setup-vps.sh` - самостоятельный исполняемый скрипт для системной подготовки, настройки `apt`, `sysctl`, swapfile, и базовых сетевых параметров. Создан в рамках перехода к модульному оркестратору.
- `setup-3x.sh` - самостоятельный исполняемый скрипт для очистки старых артефактов Xray и запуска официального интерактивного installer `3x-ui` (без silent install).
- `setup-awg.sh` - самостоятельный исполняемый скрипт для компиляции, установки и конфигурации AmneziaWG, с генерацией obfuscation-параметров и ключей.
- `setup-agh.sh` - самостоятельный исполняемый скрипт для скачивания, установки и конфигурации AdGuardHome, настройки правил DNS-фильтрации и создания systemd-сервиса.
- `setup-output.sh` - самостоятельный скрипт для вывода сводной информации о созданных эндпоинтах, портах и сгенерированных паролях.

### Классические source-модули
- `00-bootstrap.sh` - shebang, глобальные переменные, CLI, логирование, step-aware trap/err, assembled header и базовые инварианты запуска.
- `10-common.sh` - общие helper-функции: чтение credentials и конфигов, CRLF-нормализация, разбор URL-порта, soft-validation AWG/AGH/3x-ui и управление swapfile.
- `11-awg-helpers.sh` - helper-функции AmneziaWG: fallback на `wg`, подготовка build dependencies, восстановление существующих AWG credentials, идемпотентная генерация obfuscation-параметров и cleanup legacy DNS redirect-правил.
- `12-agh-helpers.sh` - helper-функции AdGuardHome для cleanup legacy systemd units перед перезаписью канонического сервиса.
- `13-3x-helpers.sh` - helper-функции ручного `3x-ui` flow: cleanup legacy direct Xray-артефактов и запуск официального интерактивного installer через `/dev/tty`.
- `14-port-forwarding-helpers.sh` - helper-модуль relay / port-forwarding слоя: `prompt_target_details` интерактивно через `/dev/tty` спрашивает, нужен ли проброс портов с текущего сервера, и при согласии собирает список forwarding-правил через циклы target IP -> target port -> protocol (`tcp`, `udp` или default `both`) -> дополнительные порты -> дополнительные target-серверы; правила хранятся в структурированном state-файле `/root/.vpn-forwarding-rules` с правами `600`; для каждого правила внешний порт выбирается как target-порт, если он свободен для нужного протокола, иначе подбирается случайный свободный порт `10000-65000` с учетом TCP/UDP, reserved-портов и уже выбранных forwarding-портов; `setup_port_forwarding` и `cleanup_port_forwarding` проходят по универсальному списку правил и используют именованные префиксы комментариев `3x-awg-fwd:` для атомарной очистки owned-правил.
- `20-system.sh` - системная подготовка, `apt`, `sysctl`, swapfile, определение сетевого контекста, подготовка общего DNS-порта для AdGuardHome и AWG, а для relay - сбор target-параметров до настройки локального стека.
- `30-xray.sh` - ручной handoff `3x-ui`: cleanup legacy direct Xray-конфига и запуск официального интерактивного installer для `target` и relay-local direct-стека.
- `40-awg.sh` - установка и конфигурация AmneziaWG для `target` и relay-local direct-стека на `53/udp`, `MTU 1280`, direct NAT egress, DNS DNAT к AdGuardHome и явными step-маркерами для ключей, конфига и рестарта, с повторным использованием восстановленных ключей и obfuscation-параметров.
- `50-adguard.sh` - установка и конфигурация AdGuardHome в direct-режиме, без HTTP proxy и без автоконфигурации `3x-ui`.
- `60-firewall.sh` - `UFW`, `SSH`, `Fail2Ban`, установка relay transparent forwarding после выбора локальных портов, target firewall openings для `Reality 443`, `AWG 53/udp`, AdGuardHome (включая публичный DNS endpoint), relay-local openings для собственного direct-стека, универсальные relay-forward openings для внешних портов из state-файла, условное включение `DEFAULT_FORWARD_POLICY="ACCEPT"` только при активном forwarding и системная валидация стека.
- `70-output.sh` - cleanup, сохранение credentials, финальный вывод оператору с ручным handoff по `3x-ui`, блок `Target handoff` для настройки `relay`, а также relay-вывод `Relay local direct stack`, активные `Relay-forward endpoints` на месте прежнего блока `Future relay-forward endpoints` и сохранённые target-параметры.

## Lifecycle uninstall

- [`../../uninstall.sh`](../../uninstall.sh) синхронизирован с текущим набором модулей: удаляет 3x-ui после ручного installer-flow, AmneziaWG, AdGuardHome, credentials и логи.
- Relay cleanup удаляет только owned forwarding-правила с comment-префиксами `3x-awg-fwd:`, сохраняет iptables через `netfilter-persistent` или `iptables-save` и не выполняет глобальный flush/reset фаервола.
- Устаревшая cascade-автоматизация и связанные поля прежних credentials не возвращаются в runtime или lifecycle.
