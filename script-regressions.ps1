<#
Name: script regression checks
Description: Validates that setup and uninstall scripts keep critical fixes for piped execution, panel path sync, DNS redirect cleanup, and AdGuardHome config writes.
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

Assert-Match -Text $setup -Pattern 'systemctl stop AdGuardHome' -Message 'setup.sh must stop AdGuardHome before rewriting its config.'
Assert-Match -Text $setup -Pattern 'iptables -t nat -S PREROUTING' -Message 'setup.sh must clean legacy awg DNS redirect rules before restart.'
Assert-Match -Text $setup -Pattern 'setting -show true' -Message 'setup.sh must read back the effective 3x-ui webBasePath before printing credentials.'
Assert-Match -Text $uninstall -Pattern '</dev/tty' -Message 'uninstall.sh must read confirmation from /dev/tty so curl|bash does not corrupt the script stream.'

Write-Host 'script-regressions: OK'