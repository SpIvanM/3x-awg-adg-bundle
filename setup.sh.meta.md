<!--
Name: vps-vpn-triad setup script
Description: Описывает собранный setup.sh для Reality, AmneziaWG и AdGuardHome. Публичный артефакт генерируется из source-модулей в src/setup через tools/build-setup.ps1; в версии 3.0.1 helper-монолит разделён на 10-common, 11-awg-helpers, 12-agh-helpers, 13-3x-helpers и 14-port-forwarding-helpers без изменения текущего runtime-поведения. Скрипт держит pin на Xray 25.1.30, сохраняет direct AWG egress через MASQUERADE, текущий cascade DNS flow для AdGuardHome, DNS DNAT для awg0, CRLF-санацию переиспользуемых credentials, fallback на wg для генерации и восстановления AWG-ключей, step-aware error reporting и встроенную валидацию. Не коммитить.
-->
