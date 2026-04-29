<#
Name: script regression checks
Description: Validates the stage-1 bootstrap baseline, the stage-2 helper split, the stage-3 manual 3x-ui flow, the stage-4 target topology, the stage-5 relay local stack, the stage-6 relay transparent forwarding, and the stage-7 lifecycle/docs release sync.
Usage: powershell -File .\script-regressions.ps1
Behavior: Reads setup.sh, uninstall.sh, source module index, top-level README, metadata, and the build script and fails if the modular source layout, target topology, relay local stack, relay transparent forwarding, uninstall lifecycle, or release documentation regresses.
Returns: Exit code 0 on pass, non-zero on regression.
Fails: When required stage-1 bootstrap guardrails, the stage-2 helper split, the stage-3 manual 3x-ui flow, the stage-4 target topology, the stage-5 relay flow, the stage-6 transparent forwarding, or stage-7 lifecycle/docs release sync are absent.
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
$readme = & $readText -LiteralPath (Join-Path $repoRoot 'readme.md')
$setupMeta = & $readText -LiteralPath (Join-Path $repoRoot 'setup.sh.meta.md')
$uninstallMeta = & $readText -LiteralPath (Join-Path $repoRoot 'uninstall.sh.meta.md')

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

function Assert-MatchCount {
    param(
        [string]$Text,
        [string]$Pattern,
        [int]$ExpectedCount,
        [string]$Message
    )

    $actualCount = ([regex]::Matches($Text, $Pattern)).Count
    if ($actualCount -ne $ExpectedCount) {
        throw "$Message Expected $ExpectedCount, got $actualCount."
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
$systemSource = Read-OptionalText -LiteralPath (Join-Path $sourceRoot '20-system.sh')
$threeXSource = Read-OptionalText -LiteralPath (Join-Path $sourceRoot '30-xray.sh')
$awgSource = Read-OptionalText -LiteralPath (Join-Path $sourceRoot '40-awg.sh')
$adguardSource = Read-OptionalText -LiteralPath (Join-Path $sourceRoot '50-adguard.sh')
$firewallSource = Read-OptionalText -LiteralPath (Join-Path $sourceRoot '60-firewall.sh')
$outputSource = Read-OptionalText -LiteralPath (Join-Path $sourceRoot '70-output.sh')

Assert-Match -Text $setup -Pattern 'SCRIPT_VERSION="3\.0\.6"' -Message 'setup.sh must expose installer version 3.0.6 after the stage-7 rebuild.'
Assert-Match -Text $setup -Pattern 'DEPLOY_MODE="target"' -Message 'setup.sh must default DEPLOY_MODE to target.'
Assert-Match -Text $setup -Pattern '--mode\)' -Message 'setup.sh must accept --mode CLI argument.'
Assert-Contains -Text $setup -Needle 'Версия скрипта: ${SCRIPT_VERSION}' -Message 'setup.sh must print the script version.'
Assert-Match -Text $setup -Pattern 'Режим разв.ртывания: \$\{DEPLOY_MODE\}' -Message 'setup.sh must print the selected deploy mode.'
Assert-Contains -Text $setup -Needle 'Assembled from source modules' -Message 'setup.sh must declare that it is built from modular source files.'
Assert-Match -Text $setup -Pattern 'CURRENT_STEP="bootstrap"' -Message 'setup.sh must initialize the current step tracker early.'
Assert-Match -Text $setup -Pattern 'mark_step\(\)' -Message 'setup.sh must define a helper for updating the current step.'
Assert-Contains -Text $setup -Needle '3x-ui requires manual interactive configuration after the installer finishes.' -Message 'setup.sh must include the stage-3 manual 3x-ui handoff notice.'

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
Assert-NotMatch -Text $threeXSource -Pattern 'DEPLOY_MODE" = "relay"|Режим relay будет реализован' -Message '30-xray.sh must not fail fast for relay after stage 5.'
Assert-NotMatch -Text $setup -Pattern 'Режим relay будет реализован на следующем этапе\. На этапе 3 он намеренно остановлен до начала настройки сервисов\.' -Message 'setup.sh must allow relay to run the local stack after stage 5.'

Assert-Match -Text $awgSource -Pattern 'AWG_PORT=53' -Message '40-awg.sh must pin target AmneziaWG to UDP port 53.'
Assert-Match -Text $setup -Pattern 'ListenPort = \$AWG_PORT' -Message 'setup.sh must write the selected AWG listen port into awg0.conf.'
Assert-MatchCount -Text $awgSource -Pattern 'MTU = 1280' -ExpectedCount 2 -Message '40-awg.sh must write MTU 1280 into both server and client AWG configs.'
Assert-MatchCount -Text $setup -Pattern 'MTU = 1280' -ExpectedCount 2 -Message 'setup.sh must write MTU 1280 into both server and client AWG configs.'
Assert-Match -Text $awgSource -Pattern 'ensure_awg_obfuscation_params' -Message '40-awg.sh must use an idempotent AWG obfuscation parameter helper.'
Assert-Match -Text $awgHelpers -Pattern 'ensure_awg_obfuscation_params\(\)' -Message '11-awg-helpers.sh must own idempotent AWG obfuscation parameter generation.'
foreach ($param in @('JC', 'JMIN', 'JMAX', 'S1', 'S2', 'H1', 'H2', 'H3', 'H4')) {
    Assert-Match -Text $awgHelpers -Pattern ('\[ -z "\${0}" \]' -f $param) -Message "11-awg-helpers.sh must preserve existing $param and generate it only when missing."
}
Assert-NotMatch -Text $adguardSource -Pattern 'proxy|upstream_http_proxy|http_proxy|ADG_HTTP_PROXY_PORT' -Message '50-adguard.sh must keep AdGuardHome direct and free of HTTP proxy dependencies.'
Assert-Contains -Text $outputSource -Needle 'Target handoff для relay' -Message '70-output.sh must print a target-specific relay handoff block.'
Assert-Contains -Text $outputSource -Needle 'IP: ${SERVER_IP}' -Message '70-output.sh must print target IP for relay setup.'
Assert-Contains -Text $outputSource -Needle 'AWG: ${SERVER_IP}:53/udp' -Message '70-output.sh must print target AWG endpoint on UDP 53.'
Assert-Contains -Text $outputSource -Needle 'Reality: ${SERVER_IP}:${REALITY_PORT}/tcp' -Message '70-output.sh must print target Reality endpoint on TCP 443.'
Assert-Contains -Text $outputSource -Needle 'DNS endpoint: ${SERVER_IP}:${ADG_DNS_PORT}' -Message '70-output.sh must print target DNS endpoint for relay setup.'
Assert-Contains -Text $firewallSource -Needle 'Firewall: target allow Reality 443/tcp' -Message '60-firewall.sh must include a target-specific Reality firewall marker.'
Assert-Contains -Text $firewallSource -Needle 'Firewall: target allow AWG 53/udp' -Message '60-firewall.sh must include a target-specific AWG firewall marker.'
Assert-Contains -Text $firewallSource -Needle 'Firewall: target allow AdGuardHome web' -Message '60-firewall.sh must include a target-specific AdGuardHome web marker.'
Assert-Match -Text $setupIndex -Pattern '40-awg\.sh.*53/udp.*MTU 1280' -Message 'src/setup/README.md must document the target AWG port and MTU.'
Assert-Match -Text $setupIndex -Pattern '60-firewall\.sh.*target.*Reality 443.*AWG 53' -Message 'src/setup/README.md must document target firewall openings.'
Assert-Match -Text $setupIndex -Pattern '70-output\.sh.*Target handoff.*relay' -Message 'src/setup/README.md must document target relay handoff output.'

Assert-Match -Text $forwardingHelpers -Pattern 'prompt_target_details\(\)' -Message '14-port-forwarding-helpers.sh must define prompt_target_details for relay.'
Assert-Contains -Text $forwardingHelpers -Needle '/dev/tty' -Message 'prompt_target_details must read relay target details through /dev/tty.'
foreach ($targetField in @('TARGET_IP', 'TARGET_AWG_PORT', 'TARGET_REALITY_PORT', 'TARGET_DNS_PORT')) {
    Assert-Match -Text $forwardingHelpers -Pattern ('read_cred_value "{0}"' -f $targetField) -Message "prompt_target_details must reuse existing $targetField from credentials."
    Assert-Contains -Text $outputSource -Needle "$targetField=`${$targetField}" -Message "70-output.sh must persist $targetField for future relay forwarding."
}
Assert-Match -Text $systemSource -Pattern 'if \[ "\$DEPLOY_MODE" = "relay" \]; then\s+prompt_target_details\s+fi' -Message '20-system.sh must prompt target details before relay local services are configured.'
Assert-Match -Text $awgSource -Pattern 'AWG_PORT=53' -Message '40-awg.sh must keep relay-local AmneziaWG on UDP port 53.'
Assert-Contains -Text $outputSource -Needle 'Relay local direct stack' -Message '70-output.sh must print a relay-local direct stack block.'
Assert-Contains -Text $outputSource -Needle 'Future relay-forward endpoints' -Message '70-output.sh must print a future relay-forward endpoints block.'
Assert-Contains -Text $outputSource -Needle 'Target для будущего forwarding' -Message '70-output.sh must print the saved target details for future forwarding.'
Assert-Contains -Text $firewallSource -Needle 'Firewall: relay local allow Reality 443/tcp' -Message '60-firewall.sh must include a relay-local Reality firewall marker.'
Assert-Contains -Text $firewallSource -Needle 'Firewall: relay local allow AWG 53/udp' -Message '60-firewall.sh must include a relay-local AWG firewall marker.'
Assert-Match -Text $setupIndex -Pattern '14-port-forwarding-helpers\.sh.*prompt_target_details.*TARGET_IP' -Message 'src/setup/README.md must document relay target detail collection.'
Assert-Match -Text $setupIndex -Pattern '70-output\.sh.*Relay local direct stack.*Future relay-forward endpoints' -Message 'src/setup/README.md must document relay-specific output.'

Assert-Match -Text $forwardingHelpers -Pattern 'setup_port_forwarding\(\)' -Message '14-port-forwarding-helpers.sh must define setup_port_forwarding for relay.'
Assert-Match -Text $forwardingHelpers -Pattern 'cleanup_port_forwarding\(\)' -Message '14-port-forwarding-helpers.sh must define cleanup_port_forwarding for relay.'
foreach ($forwardField in @('RELAY_FWD_AWG_PORT', 'RELAY_FWD_REALITY_PORT')) {
    Assert-Match -Text $forwardingHelpers -Pattern ('read_cred_value "{0}"' -f $forwardField) -Message "14-port-forwarding-helpers.sh must reuse existing $forwardField from credentials."
    Assert-Contains -Text $outputSource -Needle "$forwardField=`${$forwardField}" -Message "70-output.sh must persist $forwardField."
}
Assert-Match -Text $forwardingHelpers -Pattern 'PREROUTING.*RELAY_FWD_AWG_PORT.*TARGET_IP.*TARGET_AWG_PORT' -Message 'setup_port_forwarding must DNAT relay AWG UDP traffic to target.'
Assert-Match -Text $forwardingHelpers -Pattern 'PREROUTING.*RELAY_FWD_REALITY_PORT.*TARGET_IP.*TARGET_REALITY_PORT' -Message 'setup_port_forwarding must DNAT relay Reality TCP traffic to target.'
Assert-Match -Text $forwardingHelpers -Pattern 'FORWARD.*TARGET_IP.*TARGET_AWG_PORT' -Message 'setup_port_forwarding must allow forwarded AWG traffic.'
Assert-Match -Text $forwardingHelpers -Pattern 'FORWARD.*TARGET_IP.*TARGET_REALITY_PORT' -Message 'setup_port_forwarding must allow forwarded Reality traffic.'
Assert-Match -Text $forwardingHelpers -Pattern 'POSTROUTING.*TARGET_IP.*TARGET_AWG_PORT' -Message 'setup_port_forwarding must masquerade forwarded AWG traffic.'
Assert-Match -Text $forwardingHelpers -Pattern 'POSTROUTING.*TARGET_IP.*TARGET_REALITY_PORT' -Message 'setup_port_forwarding must masquerade forwarded Reality traffic.'
Assert-Match -Text $forwardingHelpers -Pattern 'iptables-save|netfilter-persistent' -Message 'setup_port_forwarding must persist iptables rules after reboot.'
Assert-NotMatch -Text $forwardingHelpers -Pattern 'setup_port_forwarding\(\)[\s\S]*ss .*PREROUTING|setup_port_forwarding\(\)[\s\S]*ss .*POSTROUTING|setup_port_forwarding\(\)[\s\S]*ss .*FORWARD' -Message 'setup_port_forwarding must not use ss as a false NAT rule check.'
Assert-Match -Text $firewallSource -Pattern 'if \[ "\$DEPLOY_MODE" = "relay" \]; then\s+setup_port_forwarding\s+fi' -Message '60-firewall.sh must install relay forwarding rules after local relay ports are known and before UFW opens them.'
Assert-Contains -Text $firewallSource -Needle 'Firewall: relay forward allow external AWG' -Message '60-firewall.sh must open relay external AWG forwarding port separately.'
Assert-Contains -Text $firewallSource -Needle 'Firewall: relay forward allow external Reality' -Message '60-firewall.sh must open relay external Reality forwarding port separately.'
Assert-Contains -Text $outputSource -Needle 'Relay-forward endpoints' -Message '70-output.sh must print active relay-forward endpoints after stage 6.'
Assert-Match -Text $setupIndex -Pattern '14-port-forwarding-helpers\.sh.*setup_port_forwarding.*cleanup_port_forwarding' -Message 'src/setup/README.md must document relay forwarding setup and cleanup helpers.'

Assert-Match -Text $uninstall -Pattern '</dev/tty' -Message 'uninstall.sh must keep reading confirmation from /dev/tty.'
Assert-NotMatch -Text $uninstall -Pattern 'ufw --force reset' -Message 'uninstall.sh must not globally reset UFW during stage 7 lifecycle cleanup.'
Assert-Match -Text $uninstall -Pattern 'cleanup_port_forwarding_rules\(\)' -Message 'uninstall.sh must define a standalone owned forwarding cleanup helper.'
Assert-Match -Text $uninstall -Pattern 'iptables_delete_rule\(\)' -Message 'uninstall.sh must delete specific iptables rules instead of flushing tables.'
Assert-Match -Text $uninstall -Pattern '3x-awg relay fwd awg prerouting' -Message 'uninstall.sh must remove the owned AWG relay PREROUTING rule by comment.'
Assert-Match -Text $uninstall -Pattern '3x-awg relay fwd reality prerouting' -Message 'uninstall.sh must remove the owned Reality relay PREROUTING rule by comment.'
Assert-Match -Text $uninstall -Pattern 'persist_iptables_rules' -Message 'uninstall.sh must persist iptables after removing owned forwarding rules.'
Assert-NotMatch -Text $uninstall -Pattern 'iptables .* -F|iptables -t nat .* -F|ufw delete allow 53/udp|ufw delete allow 443/tcp' -Message 'uninstall.sh must not use destructive firewall cleanup or remove shared reserved ports blindly.'
Assert-Contains -Text $uninstall -Needle '3x-ui установлен интерактивно; uninstall удаляет файлы панели, но не управляет ручной конфигурацией Reality.' -Message 'uninstall.sh must document the manual 3x-ui lifecycle boundary.'
Assert-NotMatch -Text $uninstall -Pattern 'CASCADE_|VLESS_LINK|ADG_HTTP_PROXY_PORT|/usr/local/etc/xray/config\.json' -Message 'uninstall.sh must not carry legacy cascade credential fields or direct Xray config assumptions.'

Assert-Contains -Text $readme -Needle 'Transparent relay forwarding включён' -Message 'readme.md must describe active transparent relay forwarding in Russian.'
Assert-Contains -Text $readme -Needle 'Transparent relay forwarding is enabled' -Message 'readme.md must describe active transparent relay forwarding in English.'
Assert-Contains -Text $readme -Needle 'cleanup удаляет только owned forwarding-правила' -Message 'readme.md must document precise uninstall cleanup semantics.'
Assert-NotMatch -Text $readme -Pattern 'Stage-5 limitations|Ограничения этапа 5|future transparent forwarding|будущего transparent forwarding|Transparent port forwarding .*not enabled|planned for the next stage' -Message 'readme.md must not describe relay forwarding as a future stage after stage 7.'
Assert-Contains -Text $setupIndex -Needle 'lifecycle uninstall' -Message 'src/setup/README.md must mention lifecycle uninstall alignment after stage 7.'
Assert-Contains -Text $setupMeta -Needle 'версии 3.0.6' -Message 'setup.sh.meta.md must describe the stage-7 assembled artifact version.'
Assert-Contains -Text $uninstallMeta -Needle 'точечно удаляет owned forwarding-правила' -Message 'uninstall.sh.meta.md must describe precise forwarding cleanup.'

Assert-NotMatch -Text $setup -Pattern 'CASCADE_|VLESS_LINK|ADG_HTTP_PROXY_PORT|XRAY_' -Message 'setup.sh credentials and runtime must remain free of legacy cascade/Xray fields.'

Write-Host 'script-regressions: OK'
