<#
Name: script regression checks
Description: Validates that setup and uninstall scripts keep the Xray Reality setup, optional cascade DNS proxying, direct AWG egress, AdGuard DNS config, safe piped execution, and managed swapfile cleanup.
Usage: powershell -File .\script-regressions.ps1
Behavior: Reads setup.sh and uninstall.sh and fails if required guardrails are absent or legacy 3x-ui plumbing remains.
Returns: Exit code 0 on pass, non-zero on regression.
Fails: When any required pattern is absent or legacy x-ui plumbing is still present.
#>

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$readText = 'C:\Users\ivanm\.codex\tools\windows-text-io\Read-Text.ps1'
$setup = & $readText -LiteralPath (Join-Path $repoRoot 'setup.sh')
$uninstall = & $readText -LiteralPath (Join-Path $repoRoot 'uninstall.sh')
$buildSetup = & $readText -LiteralPath (Join-Path $repoRoot 'tools\build-setup.ps1')
$setupIndex = & $readText -LiteralPath (Join-Path $repoRoot 'src\setup\README.md')

function Assert-Match {
    param(
        [string]$Text,
        [string]$Pattern,
        [string]$Message
    )

    if ($Text -notmatch $Pattern) {
        throw $Message
    }
}

function Assert-NotMatch {
    param(
        [string]$Text,
        [string]$Pattern,
        [string]$Message
    )

    if ($Text -match $Pattern) {
        throw $Message
    }
}

function Assert-Contains {
    param(
        [string]$Text,
        [string]$Needle,
        [string]$Message
    )

    if ($Text.IndexOf($Needle, [System.StringComparison]::Ordinal) -lt 0) {
        throw $Message
    }
}

Assert-Match -Text $setup -Pattern 'install-release\.sh' -Message 'setup.sh must use the official Xray installer.'
Assert-Match -Text $setup -Pattern 'SCRIPT_VERSION="3\.0\.0"' -Message 'setup.sh must expose the current installer version and bump it with each scripted change.'
Assert-Match -Text $setup -Pattern 'DEPLOY_MODE="target"' -Message 'setup.sh must default DEPLOY_MODE to target.'
Assert-Match -Text $setup -Pattern '--mode\)' -Message 'setup.sh must accept --mode CLI argument.'
Assert-Match -Text $setup -Pattern 'DEPLOY_MODE' -Message 'setup.sh must print the selected deploy mode.'
Assert-Contains -Text $setup -Needle 'Версия скрипта: ${SCRIPT_VERSION}' -Message 'setup.sh must print the script version so operators can verify the deployed revision.'
Assert-Contains -Text $setup -Needle 'Assembled from source modules' -Message 'setup.sh must declare that it is built from modular source files.'
Assert-Contains -Text $setup -Needle 'src/setup/00-bootstrap.sh' -Message 'setup.sh must document the modular source layout in its generated header.'
Assert-Contains -Text $setup -Needle 'src/setup/70-output.sh' -Message 'setup.sh must document the terminal output module in its generated header.'
Assert-Match -Text $setup -Pattern 'set -Ee' -Message 'setup.sh must keep ERR trap propagation enabled so step-aware failures surface inside functions.'
Assert-Match -Text $setup -Pattern 'CURRENT_STEP="bootstrap"' -Message 'setup.sh must initialize the current step tracker early.'
Assert-Match -Text $setup -Pattern 'mark_step\(\)' -Message 'setup.sh must define a helper for updating the current step.'
Assert-Contains -Text $setup -Needle '[${CURRENT_STEP:-unknown}]' -Message 'setup.sh must include the active step in explicit err() failures too.'
Assert-Contains -Text $setup -Needle 'on_script_error "$?" "ERR" "$BASH_COMMAND"' -Message 'setup.sh must report the failing command in its error trap.'
Assert-Contains -Text $setup -Needle 'mark_step "AmneziaWG: generate server private key"' -Message 'setup.sh must mark the server key generation step inside the AWG stage.'
Assert-Contains -Text $setup -Needle 'mark_step "AmneziaWG: write awg0.conf"' -Message 'setup.sh must mark the AWG config write step so failures identify the exact config point.'
Assert-Contains -Text $setup -Needle 'mark_step "AmneziaWG: restart awg-quick@awg0"' -Message 'setup.sh must mark the AWG restart step so failures identify the exact restart point.'
Assert-Match -Text $setup -Pattern 'XRAY_VERSION_PIN="25\.1\.30"' -Message 'setup.sh must pin the Xray version that currently avoids the transparent-listener regression.'
Assert-Contains -Text $setup -Needle '@ install --version "$XRAY_VERSION_PIN"' -Message 'setup.sh must install Xray through the official installer with the pinned stable version.'
Assert-Match -Text $setup -Pattern '/usr/local/etc/xray/config\.json' -Message 'setup.sh must write the Xray config to the official path.'
Assert-Match -Text $setup -Pattern 'systemctl enable xray' -Message 'setup.sh must enable the Xray service.'
Assert-Match -Text $setup -Pattern 'systemctl restart xray' -Message 'setup.sh must restart Xray after writing the config.'
Assert-Match -Text $setup -Pattern 'generate_reality_keys\(\)' -Message 'setup.sh must centralize Reality key generation in a helper so rotation can retry cleanly.'
Assert-Contains -Text $setup -Needle '"$XRAY_BIN" x25519 2>&1' -Message 'setup.sh must use the resolved Xray binary when generating Reality keys.'
Assert-Match -Text $setup -Pattern 'PrivateKey:|Private key:' -Message 'setup.sh must parse both new and old Reality private key output formats.'
Assert-Match -Text $setup -Pattern 'Password \(PublicKey\):|Public key:' -Message 'setup.sh must parse both new and old Reality public key output formats.'
Assert-Match -Text $setup -Pattern 'openssl rand -base64 32' -Message 'setup.sh must fall back to a locally generated Reality private key seed if xray output parsing fails.'
Assert-Contains -Text $setup -Needle '"$XRAY_BIN" x25519 -i "$fallback_priv" 2>&1' -Message 'setup.sh must derive the Reality public key from the fallback private key.'
Assert-NotMatch -Text $setup -Pattern "cut -d' ' -f3" -Message 'setup.sh must not parse Reality keys with fixed-space cut.'
Assert-Match -Text $setup -Pattern 'realitySettings' -Message 'setup.sh must generate a Reality inbound in the Xray config.'
Assert-NotMatch -Text $setup -Pattern 'parse_cascade_vless_uri' -Message 'setup.sh must not contain cascade VLESS URI parser (replaced by Port Forwarding).'
Assert-NotMatch -Text $setup -Pattern '--cascade-vless' -Message 'setup.sh must not accept --cascade-vless (deprecated).'
Assert-NotMatch -Text $setup -Pattern '--cascade-mode' -Message 'setup.sh must not accept --cascade-mode (deprecated).'
Assert-NotMatch -Text $setup -Pattern 'CASCADE_VLESS_ARG' -Message 'setup.sh must not contain CASCADE_VLESS_ARG variable.'
Assert-Match -Text $setup -Pattern 'PostUp = iptables -t nat -A POSTROUTING -s 10\.8\.0\.0/24 -o \$PUB_INT -j MASQUERADE' -Message 'setup.sh must NAT AWG client traffic directly to the public interface.'
Assert-Match -Text $setup -Pattern 'PostUp = iptables -t nat -A PREROUTING -i awg0 -p udp --dport 53 -j REDIRECT --to-port \$ADG_DNS_PORT' -Message 'setup.sh must keep DNS redirection from AWG clients to AdGuardHome.'
Assert-Match -Text $setup -Pattern 'PostUp = iptables -t nat -A PREROUTING -i awg0 -p tcp --dport 53 -j REDIRECT --to-port \$ADG_DNS_PORT' -Message 'setup.sh must keep TCP DNS redirection from AWG clients to AdGuardHome.'
Assert-NotMatch -Text $setup -Pattern 'AWG_TPROXY|TPROXY --on-port 12345|awg-tproxy-input|tproxy-in|dokodemo-door' -Message 'setup.sh must not route AWG traffic through Xray/TProxy anymore.'
Assert-Match -Text $setup -Pattern '"tag": "direct-out"' -Message 'setup.sh must generate the direct-out outbound for local egress.'
Assert-Match -Text $setup -Pattern '"tag": "block-out"' -Message 'setup.sh must keep the block-out outbound.'
Assert-NotMatch -Text $setup -Pattern '"tag": "exit-us"' -Message 'setup.sh must not generate cascade exit-us outbound (replaced by Port Forwarding).'
Assert-Match -Text $setup -Pattern '"domainStrategy": "IPIfNonMatch"' -Message 'setup.sh must use IPIfNonMatch routing for RU split rules.'
Assert-Match -Text $setup -Pattern '"ruleTag": "ru-domains"' -Message 'setup.sh must define RU domain bypass rules.'
Assert-Contains -Text $setup -Needle '"regexp:\\.ru$"' -Message 'setup.sh must bypass .ru domains locally.'
Assert-Match -Text $setup -Pattern '"ruleTag": "ru-ips"' -Message 'setup.sh must define RU IP bypass rules.'
Assert-Match -Text $setup -Pattern 'geoip:ru' -Message 'setup.sh must bypass RU IP ranges locally.'
Assert-Match -Text $setup -Pattern '"ruleTag": "entry-server-self"' -Message 'setup.sh must bypass traffic aimed at the entry VPS itself.'
Assert-Match -Text $setup -Pattern '"ruleTag": "reality-server-egress"' -Message 'setup.sh must force Reality ingress egress through direct-out.'
Assert-NotMatch -Text $setup -Pattern 'resolve_cascade_upstream_address' -Message 'setup.sh must not contain cascade upstream resolver (deprecated).'
Assert-NotMatch -Text $setup -Pattern 'CASCADE_ADDRESS_IP' -Message 'setup.sh must not reference CASCADE_ADDRESS_IP (deprecated).'
Assert-NotMatch -Text $setup -Pattern 'adg_http_proxy_rule' -Message 'setup.sh must not contain adg_http_proxy_rule (deprecated).'
Assert-NotMatch -Text $setup -Pattern '"ruleTag": "vpn-default"|vpn_default_rule\["outboundTag"\] = "exit-us"' -Message 'setup.sh must no longer route AWG traffic through the Xray cascade.'
Assert-NotMatch -Text $setup -Pattern '"tag": "bridge-exit"|''fallbackTag''|"type": "leastPing"|config\["observatory"\] = \{' -Message 'setup.sh must not rely on balancer startup health checks for cascade routing.'
Assert-Match -Text $setup -Pattern 'vless://' -Message 'setup.sh must still print a VLESS Reality link.'
Assert-Match -Text $setup -Pattern 'flow=xtls-rprx-vision' -Message 'setup.sh must export a VLESS Reality link with the Vision flow.'
Assert-NotMatch -Text $setup -Pattern 'ADG_HTTP_PROXY_PORT' -Message 'setup.sh must not use ADG_HTTP_PROXY_PORT (deprecated with cascade).'
Assert-NotMatch -Text $setup -Pattern 'adg-http-proxy-in' -Message 'setup.sh must not create adg-http-proxy-in inbound (deprecated).'
Assert-NotMatch -Text $setup -Pattern 'http_proxy:' -Message 'setup.sh must not set http_proxy in AdGuardHome config (deprecated).'
Assert-Match -Text $setup -Pattern 'upstream_dns:\r?\n\s+- https://cloudflare-dns\.com/dns-query\r?\n\s+- https://dns\.google/dns-query' -Message 'setup.sh must switch AdGuardHome to DoH upstreams so DNS can be proxied.'
Assert-Match -Text $setup -Pattern 'systemctl stop AdGuardHome' -Message 'setup.sh must stop AdGuardHome before rewriting its config.'
Assert-Match -Text $setup -Pattern '\[sshd\]' -Message 'setup.sh must keep a fail2ban jail for SSH after removing the panel.'
Assert-Match -Text $setup -Pattern 'linux-headers-\$\(uname -r\)' -Message 'setup.sh must request exact kernel headers for deterministic AmneziaWG builds.'
Assert-NotMatch -Text $setup -Pattern 'linux-headers-generic|linux-headers-amd64' -Message 'setup.sh must not rely on generic header meta-packages.'
Assert-NotMatch -Text $setup -Pattern 'net\.ipv4\.conf\.all\.src_valid_mark = 1|net\.ipv4\.conf\.default\.src_valid_mark = 1|route_localnet = 1' -Message 'setup.sh must not keep TProxy-only sysctls now that AWG bypasses Xray.'
Assert-NotMatch -Text $setup -Pattern 'iptables -I INPUT 1 -i awg0 -m mark --mark 1 -m comment --comment awg-tproxy-input -j ACCEPT|iptables -D INPUT -i awg0 -m mark --mark 1 -m comment --comment awg-tproxy-input -j ACCEPT' -Message 'setup.sh must not add or remove an INPUT mark exception for AWG because there is no TProxy path anymore.'
Assert-Match -Text $setup -Pattern 'xray run -test -config /usr/local/etc/xray/config\.json' -Message 'setup.sh must validate the generated Xray config before declaring success.'
Assert-Match -Text $setup -Pattern 'dig @127\.0\.0\.1 -p .*example\.com \+short' -Message 'setup.sh must validate local DNS resolution through AdGuardHome.'
Assert-Match -Text $setup -Pattern 'systemctl restart awg-quick@awg0' -Message 'setup.sh must restart AmneziaWG during validation.'
Assert-Match -Text $setup -Pattern 'awg show' -Message 'setup.sh must validate that the AWG interface is actually up.'
Assert-NotMatch -Text $setup -Pattern 'sysctl -n net\.ipv4\.conf\.all\.src_valid_mark \| grep -qx '\''1'\''' -Message 'setup.sh must not verify src_valid_mark after removing the AWG TProxy path.'
Assert-NotMatch -Text $setup -Pattern 'iptables -C INPUT -i awg0 -m mark --mark 1 -m comment --comment awg-tproxy-input -j ACCEPT' -Message 'setup.sh must not verify a marked-packet INPUT allow rule after removing the AWG TProxy path.'
Assert-Match -Text $setup -Pattern 'trim_cr_value\(\)' -Message 'setup.sh must centralize CRLF cleanup for persisted values so Windows line endings do not poison generated configs.'
Assert-Match -Text $setup -Pattern 'printf ''%s'' "\$1" \| tr -d ''\\r''' -Message 'setup.sh must strip carriage returns from imported values before reusing them in runtime configs.'
Assert-Match -Text $setup -Pattern 'read_cred_value\(\)' -Message 'setup.sh must read persisted credentials through a helper that can normalize CRLF-tainted values.'
Assert-Match -Text $setup -Pattern 'read_config_assignment\(\)' -Message 'setup.sh must read existing AWG config assignments through a helper that normalizes carriage returns.'
Assert-Match -Text $setup -Pattern 'resolve_awg_key_bin\(\)' -Message 'setup.sh must resolve an AWG key tool with a wg fallback before generating or restoring AmneziaWG keys.'
Assert-Contains -Text $setup -Needle 'wireguard-tools' -Message 'setup.sh must install wireguard-tools so the wg fallback is available if awg is missing or broken.'
Assert-Match -Text $setup -Pattern 'XRAY_UUID=\$\(read_cred_value "XRAY_UUID" "\$CREDS_FILE"\)' -Message 'setup.sh must sanitize XRAY_UUID when restoring it from the credentials file.'
Assert-Match -Text $setup -Pattern 'ADG_DNS_PORT=\$\(read_cred_value "ADG_DNS_PORT" "\$CREDS_FILE"\)' -Message 'setup.sh must sanitize ADG_DNS_PORT when restoring it from the credentials file.'
Assert-Match -Text $setup -Pattern 'DEPLOY_MODE=' -Message 'setup.sh must persist DEPLOY_MODE in credentials.'
Assert-Match -Text $setup -Pattern 'SERVER_PRIV=\$\(read_cred_value "AWG_SERVER_PRIV" "\$CREDS_FILE"\)' -Message 'setup.sh must sanitize the AWG server private key when restoring it from the credentials file.'
Assert-Match -Text $setup -Pattern 'SERVER_PRIV=\$\(read_config_assignment "PrivateKey = " /etc/amnezia/amneziawg/awg0\.conf\)' -Message 'setup.sh must sanitize AWG values recovered from the existing server config.'
Assert-Match -Text $setup -Pattern 'SERVER_PRIV=\$\(read_cred_value "AWG_SERVER_PRIV" "\$CREDS_FILE"\)' -Message 'setup.sh must load the existing AWG server private key from credentials on non-rotating re-runs.'
Assert-Match -Text $setup -Pattern 'CLIENT_PRIV=\$\(read_cred_value "AWG_CLIENT_PRIV" "\$CREDS_FILE"\)' -Message 'setup.sh must load the existing AWG client private key from credentials on non-rotating re-runs.'
Assert-Match -Text $setup -Pattern 'CLIENT_PSK=\$\(read_cred_value "AWG_CLIENT_PSK" "\$CREDS_FILE"\)' -Message 'setup.sh must load the existing AWG preshared key from credentials on non-rotating re-runs.'
Assert-Match -Text $setup -Pattern '/etc/amnezia/amneziawg/awg0\.conf.*?/root/amnezia_client\.conf.*?"\$ROTATE_CREDS" -eq 0' -Message 'setup.sh must fall back to the existing AWG server and client config files when credentials file lacks AWG keys.'
Assert-Match -Text $setup -Pattern '\[ -z "\$SERVER_PRIV" \] && SERVER_PRIV=\$\("\$AWG_KEY_BIN" genkey\)' -Message 'setup.sh must only generate a new AWG server private key when none was restored.'
Assert-Match -Text $setup -Pattern '\[ -z "\$CLIENT_PRIV" \] && CLIENT_PRIV=\$\("\$AWG_KEY_BIN" genkey\)' -Message 'setup.sh must only generate a new AWG client private key when none was restored.'
Assert-Match -Text $setup -Pattern '\[ -z "\$CLIENT_PSK" \] && CLIENT_PSK=\$\("\$AWG_KEY_BIN" genpsk\)' -Message 'setup.sh must only generate a new AWG preshared key when none was restored.'
Assert-Contains -Text $setup -Needle '"$AWG_KEY_BIN" pubkey' -Message 'setup.sh must derive AWG public keys through the resolved key tool.'
Assert-Contains -Text $setup -Needle 'if [ -n "$SERVER_PRIV" ]; then' -Message 'setup.sh must derive the AWG server public key through a safe conditional branch under set -e.'
Assert-Contains -Text $setup -Needle 'if [ -n "$CLIENT_PRIV" ]; then' -Message 'setup.sh must derive the AWG client public key through a safe conditional branch under set -e.'
Assert-NotMatch -Text $setup -Pattern '\[ -n "\$SERVER_PRIV" \] && SERVER_PUB=' -Message 'setup.sh must not use bare test-and-assignment for the AWG server public key under set -e.'
Assert-NotMatch -Text $setup -Pattern '\[ -n "\$CLIENT_PRIV" \] && CLIENT_PUB=' -Message 'setup.sh must not use bare test-and-assignment for the AWG client public key under set -e.'
Assert-NotMatch -Text $setup -Pattern 'CASCADE_ENABLED=\$\{CASCADE_ENABLED\}' -Message 'setup.sh must not persist CASCADE_ENABLED (deprecated).'
Assert-NotMatch -Text $setup -Pattern 'FINAL_MODE=\$\{FINAL_MODE\}' -Message 'setup.sh must not persist FINAL_MODE (deprecated).'
Assert-Match -Text $setup -Pattern 'AWG_SERVER_PRIV=\${SERVER_PRIV}' -Message 'setup.sh must persist the AWG server private key in the credentials file for safe re-runs.'
Assert-Match -Text $setup -Pattern 'AWG_CLIENT_PRIV=\${CLIENT_PRIV}' -Message 'setup.sh must persist the AWG client private key in the credentials file for safe re-runs.'
Assert-Match -Text $setup -Pattern 'AWG_CLIENT_PSK=\${CLIENT_PSK}' -Message 'setup.sh must persist the AWG preshared key in the credentials file for safe re-runs.'
Assert-NotMatch -Text $setup -Pattern 'T_PORT=12345' -Message 'setup.sh must not define a dedicated TProxy listener port when AWG bypasses Xray.'
Assert-NotMatch -Text $setup -Pattern '0\.0\.0\.0/0, ::/0' -Message 'setup.sh must ship an intentional IPv4-only client profile until IPv6 routing is implemented.'
Assert-Match -Text $setup -Pattern 'systemctl stop x-ui' -Message 'setup.sh must stop the legacy x-ui service when cleaning split-brain installs.'
Assert-Match -Text $setup -Pattern 'systemctl disable x-ui' -Message 'setup.sh must disable the legacy x-ui service when cleaning split-brain installs.'
Assert-Match -Text $setup -Pattern 'rm -rf /usr/local/x-ui /etc/x-ui' -Message 'setup.sh must remove the legacy x-ui runtime and database when cleaning split-brain installs.'
Assert-NotMatch -Text $setup -Pattern 'raw\.githubusercontent\.com/MHSanaei/3x-ui|configure_xray_via_xui_db\(' -Message 'setup.sh must not install or drive Xray through the legacy x-ui control plane.'
Assert-Match -Text $setup -Pattern 'DEPLOY_MODE' -Message 'setup.sh must reference DEPLOY_MODE for mode-aware behavior.'
Assert-Match -Text $uninstall -Pattern 'systemctl stop xray' -Message 'uninstall.sh must stop Xray during cleanup.'
Assert-Match -Text $uninstall -Pattern 'systemctl disable xray' -Message 'uninstall.sh must disable Xray during cleanup.'
Assert-Match -Text $uninstall -Pattern 'rm -rf /usr/local/etc/xray' -Message 'uninstall.sh must remove the Xray config directory.'
Assert-Match -Text $uninstall -Pattern 'rm -rf /usr/local/bin/xray' -Message 'uninstall.sh must remove the Xray binary.'
Assert-Match -Text $uninstall -Pattern 'systemctl stop x-ui' -Message 'uninstall.sh must stop the legacy x-ui service during cleanup.'
Assert-Match -Text $uninstall -Pattern 'systemctl disable x-ui' -Message 'uninstall.sh must disable the legacy x-ui service during cleanup.'
Assert-Match -Text $uninstall -Pattern 'rm -rf /usr/local/x-ui /etc/x-ui' -Message 'uninstall.sh must remove legacy x-ui files during cleanup.'
Assert-Match -Text $uninstall -Pattern '/swapfile none swap sw 0 0 # 3x-awg-adg-bundle' -Message 'uninstall.sh must remove the managed swapfile entry from /etc/fstab.'
Assert-Match -Text $uninstall -Pattern '</dev/tty' -Message 'uninstall.sh must read confirmation from /dev/tty so curl|bash does not corrupt the script stream.'

Assert-Contains -Text $buildSetup -Needle '00-bootstrap.sh' -Message 'build-setup.ps1 must assemble the bootstrap module first.'
Assert-Contains -Text $buildSetup -Needle '10-helpers.sh' -Message 'build-setup.ps1 must assemble the shared helper module.'
Assert-Contains -Text $buildSetup -Needle '20-system.sh' -Message 'build-setup.ps1 must assemble the base system module.'
Assert-Contains -Text $buildSetup -Needle '30-xray.sh' -Message 'build-setup.ps1 must assemble the Xray orchestration module.'
Assert-Contains -Text $buildSetup -Needle '40-awg.sh' -Message 'build-setup.ps1 must assemble the AmneziaWG module.'
Assert-Contains -Text $buildSetup -Needle '50-adguard.sh' -Message 'build-setup.ps1 must assemble the AdGuardHome module.'
Assert-Contains -Text $buildSetup -Needle '60-firewall.sh' -Message 'build-setup.ps1 must assemble the firewall module.'
Assert-Contains -Text $buildSetup -Needle '70-output.sh' -Message 'build-setup.ps1 must assemble the final output module.'
Assert-Contains -Text $setupIndex -Needle '00-bootstrap.sh' -Message 'src/setup/README.md must describe the module order.'
Assert-Contains -Text $setupIndex -Needle '70-output.sh' -Message 'src/setup/README.md must describe the terminal output module.'

Write-Host 'script-regressions: OK'
