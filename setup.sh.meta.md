<!--
Name: vps-vpn-triad setup script
Description: Описывает собранный setup.sh для поэтапного bundle из 3x-ui, AmneziaWG и AdGuardHome. Публичный артефакт генерируется из source-модулей в src/setup через tools/build-setup.ps1; в версии 3.0.4 завершён relay-local сценарий: relay интерактивно собирает target-параметры через /dev/tty, поднимает собственный AWG 53/udp, AdGuardHome и ручной 3x-ui flow, сохраняет TARGET_* для будущего forwarding и печатает отдельные блоки локального direct-стека и будущих relay-forward endpoints. Не коммитить.
-->
