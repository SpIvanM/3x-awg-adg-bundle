<#
Name: script regression checks
Description: Validates the stage-1 bootstrap baseline, the stage-2 helper split, and the stage-3 manual 3x-ui flow.
Usage: powershell -File .\script-regressions.ps1
Behavior: Reads setup.sh, uninstall.sh, source module index, and the build script and fails if the modular source layout regresses.
Returns: Exit code 0 on pass, non-zero on regression.
Fails: When required stage-1 bootstrap guardrails, the stage-2 helper split, or the stage-3 manual 3x-ui flow are absent.
#>

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$readText = 'C:\Users\ivanm\.codex\tools\windows-text-io\Read-Text.ps1'
$sourceRoot = Join-Path $repoRoot 'src\setup'

$setup = & $readText -LiteralPath (Join-Path $repoRoot 'setup.sh')
$uninstall = & $readText -LiteralPath (Join-Path $repoRoot 'uninstall.sh')
$buildSetup = & $readText -LiteralPath (Join-Path $repoRoot 'tools\build-setup.ps1')
$setupIndex = & $readText -LiteralPath (Join-Path $sourceRoot 'README.md')

function Read-OptionalText {
    param(
        [string]$LiteralPath
    )

    if (Test-Path -LiteralPath $LiteralPath) {
        return & $readText -LiteralPath $LiteralPath
    }

    return ''
}

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

function Assert-PathExists {
    param(
        [string]$LiteralPath,
        [string]$Message
    )

    if (-not (Test-Path -LiteralPath $LiteralPath)) {
        throw $Message
    }
}

function Assert-PathMissing {
    param(
        [string]$LiteralPath,
        [string]$Message
    )

    if (Test-Path -LiteralPath $LiteralPath) {
        throw $Message
    }
}

$helperModules = @(
    '10-common.sh',
    '11-awg-helpers.sh',
    '12-agh-helpers.sh',
    '13-3x-helpers.sh',
    '14-port-forwarding-helpers.sh'
)

$orderedModules = @(
    '00-bootstrap.sh',
    '10-common.sh',
    '11-awg-helpers.sh',
    '12-agh-helpers.sh',
    '13-3x-helpers.sh',
    '14-port-forwarding-helpers.sh',
    '20-system.sh',
    '30-xray.sh',
    '40-awg.sh',
    '50-adguard.sh',
    '60-firewall.sh',
    '70-output.sh'
)

$moduleTexts = @{}
foreach ($module in $helperModules) {
    $moduleTexts[$module] = Read-OptionalText -LiteralPath (Join-Path $sourceRoot $module)
}

$commonHelpers = $moduleTexts["10-common.sh"]
$awgHelpers = $moduleTexts["11-awg-helpers.sh"]
$aghHelpers = $moduleTexts["12-agh-helpers.sh"]
$threeXHelpers = $moduleTexts["13-3x-helpers.sh"]
$forwardingHelpers = $moduleTexts["14-port-forwarding-helpers.sh"]

Assert-Match -Text $setup -Pattern 'SCRIPT_VERSION="3\.0\.2"' -Message 'setup.sh must expose installer version 3.0.2 after the stage-3 rebuild.'
Assert-Match -Text $setup -Pattern 'DEPLOY_MODE="target"' -Message 'setup.sh must default DEPLOY_MODE to target.'
Assert-Match -Text $setup -Pattern '--mode\)' -Message 'setup.sh must accept --mode CLI argument.'
Assert-Contains -Text $setup -Needle 'Версия скрипта: ${SCRIPT_VERSION}' -Message 'setup.sh must print the script version.'
Assert-Match -Text $setup -Pattern 'Режим разв.ртывания: \$\{DEPLOY_MODE\}' -Message 'setup.sh must print the selected deploy mode.'
Assert-Contains -Text $setup -Needle 'Assembled from source modules' -Message 'setup.sh must declare that it is built from modular source files.'
Assert-Match -Text $setup -Pattern 'CURRENT_STEP="bootstrap"' -Message 'setup.sh must initialize the current step tracker early.'
Assert-Match -Text $setup -Pattern 'mark_step\(\)' -Message 'setup.sh must define a helper for updating the current step.'
Assert-Contains -Text $setup -Needle '3x-ui requires manual interactive configuration after the installer finishes.' -Message 'setup.sh must include the stage-3 manual 3x-ui handoff notice.'
Assert-Contains -Text $setup -Needle 'Режим relay будет реализован на следующем этапе. На этапе 3 он намеренно остановлен до начала настройки сервисов.' -Message 'setup.sh must fail fast for relay during stage 3.'

foreach ($module in $orderedModules) {
    Assert-Contains -Text $setup -Needle "src/setup/$module" -Message "setup.sh must list $module in its assembled header."
    Assert-Contains -Text $buildSetup -Needle "'$module'" -Message "build-setup.ps1 must assemble $module."
    Assert-Contains -Text $setupIndex -Needle $module -Message "src/setup/README.md must describe $module."
}

Assert-NotMatch -Text $setup -Pattern 'src/setup/10-helpers\.sh' -Message 'setup.sh must not reference the removed 10-helpers.sh source module.'
Assert-NotMatch -Text $buildSetup -Pattern "'10-helpers\.sh'" -Message 'build-setup.ps1 must not assemble the removed 10-helpers.sh module.'
Assert-NotMatch -Text $setupIndex -Pattern '10-helpers\.sh' -Message 'src/setup/README.md must not document the removed 10-helpers.sh module.'

foreach ($module in $helperModules) {
    Assert-PathExists -LiteralPath (Join-Path $sourceRoot $module) -Message "Missing source helper module: $module"
}

Assert-PathMissing -LiteralPath (Join-Path $sourceRoot '10-helpers.sh') -Message 'src/setup/10-helpers.sh must be removed after the helper split.'

Assert-Match -Text $commonHelpers -Pattern "trim_cr_value\(\)" -Message "10-common.sh must keep trim_cr_value"
Assert-Match -Text $commonHelpers -Pattern "read_cred_value\(\)" -Message "10-common.sh must keep read_cred_value"
Assert-Match -Text $commonHelpers -Pattern "read_config_assignment\(\)" -Message "10-common.sh must keep read_config_assignment"
Assert-Match -Text $commonHelpers -Pattern "read_url_port\(\)" -Message "10-common.sh must keep read_url_port"
Assert-Match -Text $commonHelpers -Pattern "ensure_swapfile\(\)" -Message "10-common.sh must keep ensure_swapfile"
Assert-Match -Text $commonHelpers -Pattern "validate_stack\(\)" -Message "10-common.sh must keep validate_stack"
Assert-NotMatch -Text $commonHelpers -Pattern "install_xray_core\(\)|load_existing_awg_credentials\(\)|cleanup_legacy_adguard_units\(\)|remove_legacy_xui\(\)|configure_cascade_mode\(\)" -Message "10-common.sh must not keep service-specific helpers after the split"

Assert-Match -Text $awgHelpers -Pattern "resolve_awg_key_bin\(\)" -Message "11-awg-helpers.sh must hold resolve_awg_key_bin"
Assert-Match -Text $awgHelpers -Pattern "ensure_awg_build_dependencies\(\)" -Message "11-awg-helpers.sh must hold ensure_awg_build_dependencies"
Assert-Match -Text $awgHelpers -Pattern "load_existing_awg_credentials\(\)" -Message "11-awg-helpers.sh must hold load_existing_awg_credentials"
Assert-Match -Text $awgHelpers -Pattern "cleanup_legacy_awg_dns_redirects\(\)" -Message "11-awg-helpers.sh must hold cleanup_legacy_awg_dns_redirects"

Assert-Match -Text $aghHelpers -Pattern "cleanup_legacy_adguard_units\(\)" -Message "12-agh-helpers.sh must hold cleanup_legacy_adguard_units"

Assert-Match -Text $threeXHelpers -Pattern "remove_legacy_xui\(\)" -Message "13-3x-helpers.sh must hold remove_legacy_xui"
Assert-Match -Text $threeXHelpers -Pattern "install_3x_ui_interactive\(\)" -Message "13-3x-helpers.sh must hold install_3x_ui_interactive"
Assert-Contains -Text $threeXHelpers -Needle '/dev/tty' -Message "13-3x-helpers.sh must attach the official 3x-ui installer to /dev/tty."
Assert-Contains -Text $threeXHelpers -Needle '3x-ui requires manual interactive configuration after the installer finishes.' -Message "13-3x-helpers.sh must print the stage-3 manual configuration handoff."

Assert-NotMatch -Text $threeXHelpers -Pattern "install_xray_core\(\)|resolve_xray_bin\(\)|generate_reality_keys\(\)|write_xray_config\(\)" -Message "13-3x-helpers.sh must drop legacy Xray helper functions in stage 3."
Assert-NotMatch -Text $forwardingHelpers -Pattern "reset_cascade_state\(\)|parse_cascade_vless_uri\(\)|resolve_cascade_upstream_address\(\)|configure_cascade_mode\(\)" -Message "14-port-forwarding-helpers.sh must drop legacy cascade helpers in stage 3."
Assert-NotMatch -Text $setup -Pattern 'install_xray_core|write_xray_config|CASCADE_|ADG_HTTP_PROXY_PORT|VLESS_LINK|install-release\.sh|generate_reality_keys|resolve_xray_bin' -Message 'setup.sh must remove the legacy Xray/cascade implementation during stage 3.'
Assert-NotMatch -Text $setupIndex -Pattern 'legacy cascade|VLESS|Xray config|bootstrap Xray-core|Reality keys' -Message 'src/setup/README.md must be updated for the stage-3 manual 3x-ui flow.'
Assert-Match -Text $setup -Pattern 'if \[ "\$DEPLOY_MODE" = "relay" \]; then\s+err "Режим relay будет реализован на следующем этапе\. На этапе 3 он намеренно остановлен до начала настройки сервисов\."\s+fi' -Message 'setup.sh must stop relay before partial service setup during stage 3.'

Assert-Match -Text $uninstall -Pattern '</dev/tty' -Message 'uninstall.sh must keep reading confirmation from /dev/tty.'

Write-Host 'script-regressions: OK'
