<#
Name: script regression checks
Description: Validates that setup and uninstall scripts keep critical fixes for piped execution, non-interactive 3x-ui installation, DNS redirect cleanup, panel URL detection, and AdGuardHome config writes.
Usage: powershell -File .\script-regressions.ps1
Behavior: Reads setup.sh and uninstall.sh and fails if required guardrails are missing.
Returns: Exit code 0 on pass, non-zero on regression.
Fails: When any required pattern is absent.
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

Assert-Match -Text $setup -Pattern 'systemctl stop AdGuardHome' -Message 'setup.sh must stop AdGuardHome before rewriting its config.'
Assert-Match -Text $setup -Pattern 'iptables -t nat -S PREROUTING' -Message 'setup.sh must clean legacy awg DNS redirect rules before restart.'
Assert-Match -Text $setup -Pattern 'setting -show true' -Message 'setup.sh must read back the effective 3x-ui settings before printing credentials.'
Assert-Match -Text $setup -Pattern 'setting -getCert true' -Message 'setup.sh must inspect 3x-ui certificate settings before printing panel URLs.'
Assert-Match -Text $setup -Pattern 'install_xui_noninteractive' -Message 'setup.sh must install 3x-ui without the upstream interactive wizard.'
Assert-Match -Text $setup -Pattern 'setting -username .* -password .* -port .* -webBasePath' -Message 'setup.sh must apply 3x-ui credentials via the x-ui binary after installation.'
Assert-Match -Text $setup -Pattern 'PANEL_SCHEME=' -Message 'setup.sh must derive panel URL scheme dynamically instead of hardcoding https.'
Assert-Match -Text $setup -Pattern 'bootstrap_dns:\r?\n\s+- 1\.1\.1\.1\r?\n\s+- 8\.8\.8\.8' -Message 'setup.sh must write bootstrap_dns as a flat YAML sequence accepted by current AdGuardHome.'
Assert-NotMatch -Text $setup -Pattern 'bash <\(curl -Ls https://raw\.githubusercontent\.com/mhsanaei/3x-ui/master/install\.sh\) <<EOF' -Message 'setup.sh must not drive the upstream 3x-ui installer with a fixed heredoc; prompt order is unstable.'
Assert-NotMatch -Text $setup -Pattern 'command -v x-ui \|\| echo /usr/local/x-ui/x-ui' -Message 'setup.sh must target the x-ui binary directly; the /usr/bin/x-ui wrapper does not support setting commands.'
Assert-NotMatch -Text $setup -Pattern 'PANEL_URL=https://\$\{SERVER_IP\}' -Message 'setup.sh must not hardcode https in stored panel URLs.'
Assert-Match -Text $uninstall -Pattern '</dev/tty' -Message 'uninstall.sh must read confirmation from /dev/tty so curl|bash does not corrupt the script stream.'

Write-Host 'script-regressions: OK'