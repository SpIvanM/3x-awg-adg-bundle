<!--
Name: vps-vpn-triad setup script
Description: Описывает собранный setup.sh для поэтапного bundle из 3x-ui, AmneziaWG и AdGuardHome. Публичный артефакт генерируется из source-модулей в src/setup через tools/build-setup.ps1; в версии 3.0.3 завершён target-сценарий: AWG закреплён на 53/udp, MTU 1280 пишется в серверный и клиентский конфиг, helper `11-awg-helpers.sh` идемпотентно сохраняет obfuscation-параметры, AdGuardHome остаётся direct без HTTP proxy, а финальный вывод печатает target handoff для будущего relay. Relay-режим намеренно останавливается fail-fast до следующего этапа. Не коммитить.
-->
