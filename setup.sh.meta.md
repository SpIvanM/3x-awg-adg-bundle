<!--
Name: vps-vpn-triad (3x-ui + AWG + AdGuard)
Description: Configures OS networking, 3x-ui, AmneziaWG and AdGuardHome on Debian 11 and Ubuntu.
Usage: curl -fsSL https://raw.githubusercontent.com/SpIvanM/3x-awg-adg-bundle/main/setup.sh | sudo bash
Behavior: Updates sysctl, installs OS packages, compiles AmneziaWG kernel module, sets up AdGuard.
Returns: Complete VPN and DNS server proxy routing.
Fails: If run without root privileges.
-->