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

- `00-bootstrap.sh` - shebang, глобальные переменные, CLI, логирование, trap и базовые инварианты запуска.
- `10-helpers.sh` - общие helper-функции для Xray, cascade, credentials, validation и cleanup.
- `20-system.sh` - системная подготовка, `apt`, `sysctl`, swapfile, Xray bootstrap и загрузка credentials.
- `30-xray.sh` - cleanup legacy `x-ui`, cascade mode и построение дефолтной ссылки `VLESS`.
- `40-awg.sh` - установка и конфигурация AmneziaWG.
- `50-adguard.sh` - установка и конфигурация AdGuardHome и финальная запись Xray config.
- `60-firewall.sh` - `UFW`, `SSH`, `Fail2Ban` и системная валидация стека.
- `70-output.sh` - cleanup, сохранение credentials и финальный вывод оператору.
