<!--
Name: VPS Environment Setup Script
Description: Configures OS networking, 3x-ui, AmneziaWG and AdGuardHome on Debian 11 and Ubuntu.
Usage: sudo ./setup.sh
Behavior: Updates sysctl, installs OS packages, compiles AmneziaWG kernel module, sets up AdGuard.
Returns: Complete VPN and DNS server proxy routing.
Fails: If run without root privileges.
-->