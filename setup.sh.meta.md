<!--
Name: vps-vpn-triad setup script
Description: Описывает собранный setup.sh для Reality, AmneziaWG и AdGuardHome. Публичный артефакт теперь генерируется из source-модулей в src/setup через tools/build-setup.ps1, держит pin на Xray 25.1.30, версию 2.2.0, direct AWG egress через MASQUERADE, optional cascade DNS routing для AdGuardHome, резолв cascade upstream hostnames в IP для обхода DNS-лупов, DNS DNAT для awg0, CRLF-санацию переиспользуемых credentials и встроенную валидацию. Не коммитить.
-->
