<!--
Name: 3x setup source index
Description: Индекс модулей для сборки setup.sh. Этот файл нужен как карта разделения и не участвует в runtime.
-->

# Индекс source-модулей `setup.sh`

Сборка выполняется скриптом [`tools/build-setup.ps1`](../../tools/build-setup.ps1) и собирает публичный [`setup.sh`](../../setup.sh) из следующих файлов:

1. `00-bootstrap.sh`
1. `10-helpers.sh`
1. `20-system.sh`
1. `30-xray.sh`
1. `40-awg.sh`
1. `50-adguard.sh`
1. `60-firewall.sh`
1. `70-output.sh`

## Назначение модулей

- `00-bootstrap.sh` - shebang, глобальные переменные, CLI, логирование, step-aware trap и базовые инварианты запуска.
- `10-helpers.sh` - общие helper-функции для Xray, cascade DNS proxy, ключей AWG с fallback на `wg`, credentials, validation и cleanup, включая резолв upstream cascade в IP чтобы не ловить DNS-лупы.
- `20-system.sh` - системная подготовка, `apt`, `sysctl`, swapfile, Xray bootstrap, загрузка credentials и установка `wireguard-tools` для ключевого fallback AWG.
- `30-xray.sh` - cleanup legacy `x-ui` и построение дефолтной ссылки `VLESS`.
- `40-awg.sh` - установка и конфигурация AmneziaWG с direct NAT egress, DNS DNAT к AdGuardHome и явными step-маркерами для ключей, конфига и рестарта.
- `50-adguard.sh` - установка и конфигурация AdGuardHome и финальная запись Xray config.
- `60-firewall.sh` - `UFW`, `SSH`, `Fail2Ban` и системная валидация стека.
- `70-output.sh` - cleanup, сохранение credentials и финальный вывод оператору.
