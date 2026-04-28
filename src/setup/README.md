<!--
Name: 3x setup source index
Description: Индекс модулей для сборки setup.sh. Этот файл нужен как карта разделения и не участвует в runtime.
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
- `10-common.sh` - общие helper-функции: чтение credentials и конфигов, CRLF-нормализация, разбор URL-порта, общий validation-хелпер и управление swapfile.
- `11-awg-helpers.sh` - helper-функции AmneziaWG: fallback на `wg`, подготовка build dependencies, восстановление существующих AWG credentials и cleanup legacy DNS redirect-правил.
- `12-agh-helpers.sh` - helper-функции AdGuardHome для cleanup legacy systemd units перед перезаписью канонического сервиса.
- `13-3x-helpers.sh` - helper-функции стека `3x-ui` / Xray Reality: bootstrap Xray-core, разбор и генерация Reality keys, cleanup legacy `x-ui` и запись текущего Xray config.
- `14-port-forwarding-helpers.sh` - helper-функции будущего relay / port-forwarding слоя; пока здесь изолирована текущая legacy cascade-логика, чтобы следующий сетевой этап не трогал общие и сервисные helper-ы.
- `20-system.sh` - системная подготовка, `apt`, `sysctl`, swapfile, Xray bootstrap, загрузка credentials и установка `wireguard-tools` для ключевого fallback AWG.
- `30-xray.sh` - cleanup legacy `x-ui` и построение дефолтной ссылки `VLESS`.
- `40-awg.sh` - установка и конфигурация AmneziaWG с direct NAT egress, DNS DNAT к AdGuardHome и явными step-маркерами для ключей, конфига и рестарта, с повторным использованием восстановленных ключей.
- `50-adguard.sh` - установка и конфигурация AdGuardHome и финальная запись Xray config.
- `60-firewall.sh` - `UFW`, `SSH`, `Fail2Ban` и системная валидация стека.
- `70-output.sh` - cleanup, сохранение credentials и финальный вывод оператору.
