<#
Name: script regression checks
Description: Validates that setup and uninstall scripts keep the Xray-only Reality setup, AdGuard DNS config, AWG routing, safe piped execution, and managed swapfile cleanup.
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
Assert-Match -Text $setup -Pattern 'vless://' -Message 'setup.sh must still print a VLESS Reality link.'
Assert-Match -Text $setup -Pattern 'flow=xtls-rprx-vision' -Message 'setup.sh must export a VLESS Reality link with the Vision flow.'
Assert-Match -Text $setup -Pattern 'upstream_dns:\r?\n\s+- 1\.1\.1\.1\r?\n\s+- 8\.8\.8\.8' -Message 'setup.sh must use plain IP upstream DNS servers that current AdGuardHome accepts without bootstrap rewrites.'
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
Assert-Match -Text $setup -Pattern 'SERVER_PRIV=\$\(read_cred_value "AWG_SERVER_PRIV" "\$CREDS_FILE"\)' -Message 'setup.sh must sanitize the AWG server private key when restoring it from the credentials file.'
Assert-Match -Text $setup -Pattern 'SERVER_PRIV=\$\(read_config_assignment "PrivateKey = " /etc/amnezia/amneziawg/awg0\.conf\)' -Message 'setup.sh must sanitize AWG values recovered from the existing server config.'
Assert-Match -Text $setup -Pattern 'SERVER_PRIV=\$\(read_cred_value "AWG_SERVER_PRIV" "\$CREDS_FILE"\)' -Message 'setup.sh must load the existing AWG server private key from credentials on non-rotating re-runs.'
Assert-Match -Text $setup -Pattern 'CLIENT_PRIV=\$\(read_cred_value "AWG_CLIENT_PRIV" "\$CREDS_FILE"\)' -Message 'setup.sh must load the existing AWG client private key from credentials on non-rotating re-runs.'
Assert-Match -Text $setup -Pattern 'CLIENT_PSK=\$\(read_cred_value "AWG_CLIENT_PSK" "\$CREDS_FILE"\)' -Message 'setup.sh must load the existing AWG preshared key from credentials on non-rotating re-runs.'
Assert-Match -Text $setup -Pattern '/etc/amnezia/amneziawg/awg0\.conf.*?/root/amnezia_client\.conf.*?"\$ROTATE_CREDS" -eq 0' -Message 'setup.sh must fall back to the existing AWG server and client config files when credentials file lacks AWG keys.'
Assert-Match -Text $setup -Pattern '\[ -z "\$SERVER_PRIV" \] && SERVER_PRIV=\$\(awg genkey\)' -Message 'setup.sh must only generate a new AWG server private key when none was restored.'
Assert-Match -Text $setup -Pattern '\[ -z "\$CLIENT_PRIV" \] && CLIENT_PRIV=\$\(awg genkey\)' -Message 'setup.sh must only generate a new AWG client private key when none was restored.'
Assert-Match -Text $setup -Pattern '\[ -z "\$CLIENT_PSK" \] && CLIENT_PSK=\$\(awg genpsk\)' -Message 'setup.sh must only generate a new AWG preshared key when none was restored.'
Assert-Match -Text $setup -Pattern 'AWG_SERVER_PRIV=\${SERVER_PRIV}' -Message 'setup.sh must persist the AWG server private key in the credentials file for safe re-runs.'
Assert-Match -Text $setup -Pattern 'AWG_CLIENT_PRIV=\${CLIENT_PRIV}' -Message 'setup.sh must persist the AWG client private key in the credentials file for safe re-runs.'
Assert-Match -Text $setup -Pattern 'AWG_CLIENT_PSK=\${CLIENT_PSK}' -Message 'setup.sh must persist the AWG preshared key in the credentials file for safe re-runs.'
Assert-NotMatch -Text $setup -Pattern '0\.0\.0\.0/0, ::/0' -Message 'setup.sh must ship an intentional IPv4-only client profile until IPv6 routing is implemented.'
Assert-Match -Text $setup -Pattern 'systemctl stop x-ui' -Message 'setup.sh must stop the legacy x-ui service when cleaning split-brain installs.'
Assert-Match -Text $setup -Pattern 'systemctl disable x-ui' -Message 'setup.sh must disable the legacy x-ui service when cleaning split-brain installs.'
Assert-Match -Text $setup -Pattern 'rm -rf /usr/local/x-ui /etc/x-ui' -Message 'setup.sh must remove the legacy x-ui runtime and database when cleaning split-brain installs.'
Assert-NotMatch -Text $setup -Pattern 'raw\.githubusercontent\.com/MHSanaei/3x-ui|configure_xray_via_xui_db\(' -Message 'setup.sh must not install or drive Xray through the legacy x-ui control plane.'
Assert-Match -Text $uninstall -Pattern 'systemctl stop xray' -Message 'uninstall.sh must stop Xray during cleanup.'
Assert-Match -Text $uninstall -Pattern 'systemctl disable xray' -Message 'uninstall.sh must disable Xray during cleanup.'
Assert-Match -Text $uninstall -Pattern 'rm -rf /usr/local/etc/xray' -Message 'uninstall.sh must remove the Xray config directory.'
Assert-Match -Text $uninstall -Pattern 'rm -rf /usr/local/bin/xray' -Message 'uninstall.sh must remove the Xray binary.'
Assert-Match -Text $uninstall -Pattern 'systemctl stop x-ui' -Message 'uninstall.sh must stop the legacy x-ui service during cleanup.'
Assert-Match -Text $uninstall -Pattern 'systemctl disable x-ui' -Message 'uninstall.sh must disable the legacy x-ui service during cleanup.'
Assert-Match -Text $uninstall -Pattern 'rm -rf /usr/local/x-ui /etc/x-ui' -Message 'uninstall.sh must remove legacy x-ui files during cleanup.'
Assert-Match -Text $uninstall -Pattern '/swapfile none swap sw 0 0 # 3x-awg-adg-bundle' -Message 'uninstall.sh must remove the managed swapfile entry from /etc/fstab.'
Assert-Match -Text $uninstall -Pattern '</dev/tty' -Message 'uninstall.sh must read confirmation from /dev/tty so curl|bash does not corrupt the script stream.'

Write-Host 'script-regressions: OK'
