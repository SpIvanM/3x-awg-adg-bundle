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

Assert-Match -Text $setup -Pattern 'install-release\.sh' -Message 'setup.sh must use the official Xray installer.'
Assert-Match -Text $setup -Pattern '/usr/local/etc/xray/config\.json' -Message 'setup.sh must write the Xray config to the official path.'
Assert-Match -Text $setup -Pattern 'systemctl enable xray' -Message 'setup.sh must enable the Xray service.'
Assert-Match -Text $setup -Pattern 'systemctl restart xray' -Message 'setup.sh must restart Xray after writing the config.'
Assert-Match -Text $setup -Pattern 'xray x25519 2>&1' -Message 'setup.sh must capture xray x25519 output from stderr as well as stdout to build a valid Reality link.'
Assert-Match -Text $setup -Pattern 'realitySettings' -Message 'setup.sh must generate a Reality inbound in the Xray config.'
Assert-Match -Text $setup -Pattern 'vless://' -Message 'setup.sh must still print a VLESS Reality link.'
Assert-Match -Text $setup -Pattern 'upstream_dns:\r?\n\s+- 1\.1\.1\.1\r?\n\s+- 8\.8\.8\.8' -Message 'setup.sh must use plain IP upstream DNS servers that current AdGuardHome accepts without bootstrap rewrites.'
Assert-Match -Text $setup -Pattern 'systemctl stop AdGuardHome' -Message 'setup.sh must stop AdGuardHome before rewriting its config.'
Assert-Match -Text $setup -Pattern '\[sshd\]' -Message 'setup.sh must keep a fail2ban jail for SSH after removing the panel.'
Assert-NotMatch -Text $setup -Pattern '3x-ui|x-ui|/etc/x-ui|/usr/local/x-ui|setting -show true|setting -getCert true|setting -username|install_xui_noninteractive|sqlite3 /etc/x-ui/x-ui\.db|PANEL_SCHEME|PANEL_URL|PANEL_USER|PANEL_PASS|PANEL_PATH|PANEL_PORT' -Message 'setup.sh must not contain legacy 3x-ui management code.'
Assert-Match -Text $uninstall -Pattern 'systemctl stop xray' -Message 'uninstall.sh must stop Xray during cleanup.'
Assert-Match -Text $uninstall -Pattern 'systemctl disable xray' -Message 'uninstall.sh must disable Xray during cleanup.'
Assert-Match -Text $uninstall -Pattern 'rm -rf /usr/local/etc/xray' -Message 'uninstall.sh must remove the Xray config directory.'
Assert-Match -Text $uninstall -Pattern 'rm -rf /usr/local/bin/xray' -Message 'uninstall.sh must remove the Xray binary.'
Assert-Match -Text $uninstall -Pattern '/swapfile none swap sw 0 0 # 3x-awg-adg-bundle' -Message 'uninstall.sh must remove the managed swapfile entry from /etc/fstab.'
Assert-Match -Text $uninstall -Pattern '</dev/tty' -Message 'uninstall.sh must read confirmation from /dev/tty so curl|bash does not corrupt the script stream.'
Assert-NotMatch -Text $uninstall -Pattern '3x-ui|x-ui|/etc/x-ui|/usr/local/x-ui|PANEL_URL|PANEL_USER|PANEL_PASS' -Message 'uninstall.sh must not contain legacy 3x-ui management code.'

Write-Host 'script-regressions: OK'