<!--
Name: vps-vpn-triad setup script
Description: Описывает собранный setup.sh для поэтапного bundle из 3x-ui, AmneziaWG и AdGuardHome. Публичный артефакт генерируется из source-модулей в src/setup через tools/build-setup.ps1; в версии 3.0.2 удалена legacy Xray/cascade-логика, helper `13-3x-helpers.sh` запускает официальный интерактивный installer 3x-ui через /dev/tty, а relay-режим намеренно останавливается fail-fast до следующего этапа. Скрипт сохраняет direct AWG egress через MASQUERADE, direct DNS flow AdGuardHome, DNS DNAT для awg0, CRLF-санацию переиспользуемых credentials, fallback на wg для генерации и восстановления AWG-ключей, step-aware error reporting и встроенную валидацию AWG/AGH. Не коммитить.
-->
