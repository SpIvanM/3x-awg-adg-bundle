<#
Name: script regression checks
Description: Validates that setup and uninstall scripts keep the Xray-only Reality setup, optional cascade routing, combined TProxy handling, AdGuard DNS config, AWG routing, safe piped execution, and managed swapfile cleanup.
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
Assert-Match -Text $setup -Pattern 'SCRIPT_VERSION="2\.1\.3"' -Message 'setup.sh must expose the current installer version and bump it with each scripted change.'
Assert-Contains -Text $setup -Needle 'Версия скрипта: ${SCRIPT_VERSION}' -Message 'setup.sh must print the script version so operators can verify the deployed revision.'
Assert-Contains -Text $setup -Needle 'Assembled from source modules' -Message 'setup.sh must declare that it is built from modular source files.'
Assert-Contains -Text $setup -Needle 'src/setup/00-bootstrap.sh' -Message 'setup.sh must document the modular source layout in its generated header.'
Assert-Contains -Text $setup -Needle 'src/setup/70-output.sh' -Message 'setup.sh must document the terminal output module in its generated header.'
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
Assert-Match -Text $setup -Pattern 'dokodemo-door' -Message 'setup.sh must configure a direct dokodemo-door TProxy inbound for AWG traffic.'
Assert-Match -Text $setup -Pattern 'parse_cascade_vless_uri\(\)' -Message 'setup.sh must centralize cascade URI parsing in a helper.'
Assert-Match -Text $setup -Pattern 'python3 - <<'\''PY'\''' -Message 'setup.sh must parse the cascade VLESS URI with embedded Python.'
Assert-Match -Text $setup -Pattern 'from urllib\.parse import parse_qs, unquote, urlparse|from urllib\.parse import urlparse, parse_qs, unquote' -Message 'setup.sh must parse cascade VLESS URIs through urllib.parse helpers.'
Assert-Match -Text $setup -Pattern 'u\.scheme != "vless"' -Message 'setup.sh must reject unsupported upstream URI schemes.'
Assert-Match -Text $setup -Pattern 'q\.get\("type"\) != "tcp"' -Message 'setup.sh must reject non-TCP VLESS cascade links in v1.'
Assert-Match -Text $setup -Pattern 'q\.get\("security"\) != "reality"|q\["security"\] != "reality"' -Message 'setup.sh must reject non-Reality VLESS cascade links in v1.'
Assert-Match -Text $setup -Pattern 'q\.get\("encryption"\) != "none"' -Message 'setup.sh must reject VLESS cascade links that do not use encryption=none in v1.'
Assert-Match -Text $setup -Pattern 'Missing required VLESS query field: \{key\}' -Message 'setup.sh must raise a precise error when required cascade query fields are missing.'
Assert-Match -Text $setup -Pattern '--cascade-vless' -Message 'setup.sh must support the --cascade-vless CLI parameter.'
Assert-Match -Text $setup -Pattern '--cascade-mode' -Message 'setup.sh must support the --cascade-mode CLI parameter.'
Assert-Match -Text $setup -Pattern 'Only --cascade-mode auto is supported' -Message 'setup.sh must fail fast for unsupported cascade modes.'
Assert-Match -Text $setup -Pattern '"tag": "tproxy-in"' -Message 'setup.sh must keep a single combined TProxy inbound.'
Assert-Match -Text $setup -Pattern '"network": "tcp,udp"' -Message 'setup.sh must configure the combined TProxy inbound for both TCP and UDP.'
Assert-NotMatch -Text $setup -Pattern '"tag": "tproxy-tcp"|"tag": "tproxy-udp"' -Message 'setup.sh must stop generating split TCP/UDP TProxy inbounds.'
Assert-Match -Text $setup -Pattern '"tproxy": "tproxy"' -Message 'setup.sh must keep the TProxy inbound in transparent proxy mode.'
Assert-NotMatch -Text $setup -Pattern '"sockopt": \{\r?\n\s+"mark": 1,\r?\n\s+"tproxy": "tproxy"\r?\n\s+\}' -Message 'setup.sh must not set sockopt.mark=1 on TProxy inbounds because that can re-route transparent TCP into a local loop.'
Assert-Match -Text $setup -Pattern '"tag": "direct-out"' -Message 'setup.sh must generate the direct-out outbound for local egress.'
Assert-Match -Text $setup -Pattern '"tag": "block-out"' -Message 'setup.sh must keep the block-out outbound.'
Assert-Match -Text $setup -Pattern '"tag": "exit-us"' -Message 'setup.sh must generate the cascade exit-us outbound.'
Assert-Match -Text $setup -Pattern '"domainStrategy": "IPIfNonMatch"' -Message 'setup.sh must use IPIfNonMatch routing for RU split rules.'
Assert-Match -Text $setup -Pattern '"ruleTag": "ru-domains"' -Message 'setup.sh must define RU domain bypass rules.'
Assert-Contains -Text $setup -Needle '"regexp:\\\\.ru$"' -Message 'setup.sh must bypass .ru domains locally.'
Assert-Match -Text $setup -Pattern '"ruleTag": "ru-ips"' -Message 'setup.sh must define RU IP bypass rules.'
Assert-Match -Text $setup -Pattern 'geoip:ru' -Message 'setup.sh must bypass RU IP ranges locally.'
Assert-Match -Text $setup -Pattern '"ruleTag": "entry-server-self"' -Message 'setup.sh must bypass traffic aimed at the entry VPS itself.'
Assert-Match -Text $setup -Pattern '"ruleTag": "reality-server-egress"' -Message 'setup.sh must force Reality ingress egress through direct-out.'
Assert-Match -Text $setup -Pattern '"ruleTag": "vpn-default"' -Message 'setup.sh must define the default VPN routing rule.'
Assert-Match -Text $setup -Pattern 'vpn_default_rule\["outboundTag"\] = "exit-us"' -Message 'setup.sh must send default AWG traffic directly to the cascade exit in cascade mode.'
Assert-NotMatch -Text $setup -Pattern '"tag": "bridge-exit"|''fallbackTag''|"type": "leastPing"|config\["observatory"\] = \{' -Message 'setup.sh must not rely on balancer startup health checks for cascade routing.'
Assert-Match -Text $setup -Pattern 'vless://' -Message 'setup.sh must still print a VLESS Reality link.'
Assert-Match -Text $setup -Pattern 'flow=xtls-rprx-vision' -Message 'setup.sh must export a VLESS Reality link with the Vision flow.'
Assert-Match -Text $setup -Pattern 'ADG_HTTP_PROXY_PORT' -Message 'setup.sh must allocate a dedicated local HTTP proxy port for AdGuardHome.'
Assert-Match -Text $setup -Pattern 'ADG_HTTP_PROXY_PORT=\$\(read_cred_value "ADG_HTTP_PROXY_PORT" "\$CREDS_FILE"\)' -Message 'setup.sh must restore the AdGuardHome proxy port on re-runs.'
Assert-Match -Text $setup -Pattern '"tag": "adg-http-proxy-in"' -Message 'setup.sh must create a local HTTP proxy inbound for AdGuardHome.'
Assert-Match -Text $setup -Pattern 'http_proxy: "http://127\.0\.0\.1:\$ADG_HTTP_PROXY_PORT/?"' -Message 'setup.sh must point AdGuardHome HTTP client traffic at the local Xray proxy.'
Assert-Match -Text $setup -Pattern 'upstream_dns:\r?\n\s+- https://cloudflare-dns\.com/dns-query\r?\n\s+- https://dns\.google/dns-query' -Message 'setup.sh must switch AdGuardHome to DoH upstreams so DNS can be proxied.'
Assert-Match -Text $setup -Pattern 'systemctl stop AdGuardHome' -Message 'setup.sh must stop AdGuardHome before rewriting its config.'
Assert-Match -Text $setup -Pattern '\[sshd\]' -Message 'setup.sh must keep a fail2ban jail for SSH after removing the panel.'
Assert-Match -Text $setup -Pattern 'linux-headers-\$\(uname -r\)' -Message 'setup.sh must request exact kernel headers for deterministic AmneziaWG builds.'
Assert-NotMatch -Text $setup -Pattern 'linux-headers-generic|linux-headers-amd64' -Message 'setup.sh must not rely on generic header meta-packages.'
Assert-Match -Text $setup -Pattern '-p udp --dport 53 -j RETURN' -Message 'setup.sh must exempt UDP DNS from the TProxy chain when AGH owns DNS.'
Assert-Match -Text $setup -Pattern '-p tcp --dport 53 -j RETURN' -Message 'setup.sh must exempt TCP DNS from the TProxy chain when AGH owns DNS.'
Assert-Match -Text $setup -Pattern 'net\.ipv4\.conf\.all\.src_valid_mark = 1' -Message 'setup.sh must enable src_valid_mark globally so TProxy-marked packets survive policy routing.'
Assert-Match -Text $setup -Pattern 'net\.ipv4\.conf\.default\.src_valid_mark = 1' -Message 'setup.sh must enable src_valid_mark for future interfaces such as awg0.'
Assert-Match -Text $setup -Pattern '-I INPUT 1 -i awg0 -m mark --mark 1 -m comment --comment awg-tproxy-input -j ACCEPT' -Message 'setup.sh must insert an INPUT allow rule for awg0 packets already marked for TProxy before ufw-not-local can drop them.'
Assert-Match -Text $setup -Pattern '-D INPUT -i awg0 -m mark --mark 1 -m comment --comment awg-tproxy-input -j ACCEPT' -Message 'setup.sh must remove the awg0 marked-packet INPUT allow rule during teardown.'
Assert-Match -Text $setup -Pattern 'xray run -test -config /usr/local/etc/xray/config\.json' -Message 'setup.sh must validate the generated Xray config before declaring success.'
Assert-Match -Text $setup -Pattern 'dig @127\.0\.0\.1 -p .*example\.com \+short' -Message 'setup.sh must validate local DNS resolution through AdGuardHome.'
Assert-Match -Text $setup -Pattern 'systemctl restart awg-quick@awg0' -Message 'setup.sh must restart AmneziaWG during validation.'
Assert-Match -Text $setup -Pattern 'awg show' -Message 'setup.sh must validate that the AWG interface is actually up.'
Assert-Match -Text $setup -Pattern 'sysctl -n net\.ipv4\.conf\.all\.src_valid_mark \| grep -qx '\''1'\''' -Message 'setup.sh must verify that src_valid_mark is enabled after applying sysctl settings.'
Assert-Match -Text $setup -Pattern 'iptables -C INPUT -i awg0 -m mark --mark 1 -m comment --comment awg-tproxy-input -j ACCEPT' -Message 'setup.sh must verify that the marked-packet INPUT allow rule exists after awg0 starts.'
Assert-Match -Text $setup -Pattern 'trim_cr_value\(\)' -Message 'setup.sh must centralize CRLF cleanup for persisted values so Windows line endings do not poison generated configs.'
Assert-Match -Text $setup -Pattern 'printf ''%s'' "\$1" \| tr -d ''\\r''' -Message 'setup.sh must strip carriage returns from imported values before reusing them in runtime configs.'
Assert-Match -Text $setup -Pattern 'read_cred_value\(\)' -Message 'setup.sh must read persisted credentials through a helper that can normalize CRLF-tainted values.'
Assert-Match -Text $setup -Pattern 'read_config_assignment\(\)' -Message 'setup.sh must read existing AWG config assignments through a helper that normalizes carriage returns.'
Assert-Match -Text $setup -Pattern 'XRAY_UUID=\$\(read_cred_value "XRAY_UUID" "\$CREDS_FILE"\)' -Message 'setup.sh must sanitize XRAY_UUID when restoring it from the credentials file.'
Assert-Match -Text $setup -Pattern 'ADG_DNS_PORT=\$\(read_cred_value "ADG_DNS_PORT" "\$CREDS_FILE"\)' -Message 'setup.sh must sanitize ADG_DNS_PORT when restoring it from the credentials file.'
Assert-Match -Text $setup -Pattern 'CASCADE_ENABLED=\$\(read_cred_value "CASCADE_ENABLED" "\$CREDS_FILE"\)' -Message 'setup.sh must sanitize CASCADE_ENABLED when restoring cascade state from the credentials file.'
Assert-Match -Text $setup -Pattern 'CASCADE_VLESS=\$\(read_cred_value "CASCADE_VLESS" "\$CREDS_FILE"\)' -Message 'setup.sh must sanitize CASCADE_VLESS when restoring cascade state from the credentials file.'
Assert-Match -Text $setup -Pattern 'SERVER_PRIV=\$\(read_cred_value "AWG_SERVER_PRIV" "\$CREDS_FILE"\)' -Message 'setup.sh must sanitize the AWG server private key when restoring it from the credentials file.'
Assert-Match -Text $setup -Pattern 'SERVER_PRIV=\$\(read_config_assignment "PrivateKey = " /etc/amnezia/amneziawg/awg0\.conf\)' -Message 'setup.sh must sanitize AWG values recovered from the existing server config.'
Assert-Match -Text $setup -Pattern 'SERVER_PRIV=\$\(read_cred_value "AWG_SERVER_PRIV" "\$CREDS_FILE"\)' -Message 'setup.sh must load the existing AWG server private key from credentials on non-rotating re-runs.'
Assert-Match -Text $setup -Pattern 'CLIENT_PRIV=\$\(read_cred_value "AWG_CLIENT_PRIV" "\$CREDS_FILE"\)' -Message 'setup.sh must load the existing AWG client private key from credentials on non-rotating re-runs.'
Assert-Match -Text $setup -Pattern 'CLIENT_PSK=\$\(read_cred_value "AWG_CLIENT_PSK" "\$CREDS_FILE"\)' -Message 'setup.sh must load the existing AWG preshared key from credentials on non-rotating re-runs.'
Assert-Match -Text $setup -Pattern '/etc/amnezia/amneziawg/awg0\.conf.*?/root/amnezia_client\.conf.*?"\$ROTATE_CREDS" -eq 0' -Message 'setup.sh must fall back to the existing AWG server and client config files when credentials file lacks AWG keys.'
Assert-Match -Text $setup -Pattern '\[ -z "\$SERVER_PRIV" \] && SERVER_PRIV=\$\(awg genkey\)' -Message 'setup.sh must only generate a new AWG server private key when none was restored.'
Assert-Match -Text $setup -Pattern '\[ -z "\$CLIENT_PRIV" \] && CLIENT_PRIV=\$\(awg genkey\)' -Message 'setup.sh must only generate a new AWG client private key when none was restored.'
Assert-Match -Text $setup -Pattern '\[ -z "\$CLIENT_PSK" \] && CLIENT_PSK=\$\(awg genpsk\)' -Message 'setup.sh must only generate a new AWG preshared key when none was restored.'
Assert-Match -Text $setup -Pattern 'CASCADE_ENABLED=\${CASCADE_ENABLED}' -Message 'setup.sh must persist whether cascade mode is enabled.'
Assert-Match -Text $setup -Pattern 'CASCADE_MODE=\${CASCADE_MODE}' -Message 'setup.sh must persist the selected cascade mode.'
Assert-Match -Text $setup -Pattern 'CASCADE_VLESS=\${CASCADE_VLESS}' -Message 'setup.sh must persist the original cascade VLESS URI.'
Assert-Match -Text $setup -Pattern 'CASCADE_ADDRESS=\${CASCADE_ADDRESS}' -Message 'setup.sh must persist the parsed cascade upstream host.'
Assert-Match -Text $setup -Pattern 'CASCADE_PORT=\${CASCADE_PORT}' -Message 'setup.sh must persist the parsed cascade upstream port.'
Assert-Match -Text $setup -Pattern 'CASCADE_UUID=\${CASCADE_UUID}' -Message 'setup.sh must persist the parsed cascade UUID.'
Assert-Match -Text $setup -Pattern 'CASCADE_FLOW=\${CASCADE_FLOW}' -Message 'setup.sh must persist the parsed cascade flow.'
Assert-Match -Text $setup -Pattern 'CASCADE_PBK=\${CASCADE_PBK}' -Message 'setup.sh must persist the parsed cascade public key.'
Assert-Match -Text $setup -Pattern 'CASCADE_SNI=\${CASCADE_SNI}' -Message 'setup.sh must persist the parsed cascade SNI.'
Assert-Match -Text $setup -Pattern 'CASCADE_SID=\${CASCADE_SID}' -Message 'setup.sh must persist the parsed cascade short ID.'
Assert-Match -Text $setup -Pattern 'CASCADE_FP=\${CASCADE_FP}' -Message 'setup.sh must persist the parsed cascade fingerprint.'
Assert-Match -Text $setup -Pattern 'CASCADE_SPX=\${CASCADE_SPX}' -Message 'setup.sh must persist the parsed cascade spiderX path.'
Assert-Match -Text $setup -Pattern 'FINAL_MODE=\${FINAL_MODE}' -Message 'setup.sh must persist the final routing mode.'
Assert-Match -Text $setup -Pattern 'AWG_SERVER_PRIV=\${SERVER_PRIV}' -Message 'setup.sh must persist the AWG server private key in the credentials file for safe re-runs.'
Assert-Match -Text $setup -Pattern 'AWG_CLIENT_PRIV=\${CLIENT_PRIV}' -Message 'setup.sh must persist the AWG client private key in the credentials file for safe re-runs.'
Assert-Match -Text $setup -Pattern 'AWG_CLIENT_PSK=\${CLIENT_PSK}' -Message 'setup.sh must persist the AWG preshared key in the credentials file for safe re-runs.'
Assert-NotMatch -Text $setup -Pattern '0\.0\.0\.0/0, ::/0' -Message 'setup.sh must ship an intentional IPv4-only client profile until IPv6 routing is implemented.'
Assert-Match -Text $setup -Pattern 'systemctl stop x-ui' -Message 'setup.sh must stop the legacy x-ui service when cleaning split-brain installs.'
Assert-Match -Text $setup -Pattern 'systemctl disable x-ui' -Message 'setup.sh must disable the legacy x-ui service when cleaning split-brain installs.'
Assert-Match -Text $setup -Pattern 'rm -rf /usr/local/x-ui /etc/x-ui' -Message 'setup.sh must remove the legacy x-ui runtime and database when cleaning split-brain installs.'
Assert-NotMatch -Text $setup -Pattern 'raw\.githubusercontent\.com/MHSanaei/3x-ui|configure_xray_via_xui_db\(' -Message 'setup.sh must not install or drive Xray through the legacy x-ui control plane.'
Assert-Match -Text $setup -Pattern 'echo -e ".*\$\{FINAL_MODE\}.*"' -Message 'setup.sh must print the final routing mode at the end of the run.'
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
