<#
Name: script regression checks
Description: Validates the stage-1 bootstrap baseline, the stage-2 helper split, the stage-3 manual 3x-ui flow, the stage-4 target topology, the stage-5 relay local stack, the stage-6 relay transparent forwarding, the public AdGuardHome DNS endpoint, universal forwarding guardrails, and the stage-7 lifecycle/docs release sync.
Usage: powershell -File .\script-regressions.ps1
Behavior: Reads setup.sh, uninstall.sh, source module index, top-level README, metadata, and the build script and fails if the modular source layout, target topology, relay local stack, relay transparent forwarding, public DNS exposure, universal forwarding model, uninstall lifecycle, or release documentation regresses.
Returns: Exit code 0 on pass, non-zero on regression.
Fails: When required stage-1 bootstrap guardrails, the stage-2 helper split, the stage-3 manual 3x-ui flow, the stage-4 target topology, the stage-5 relay flow, the stage-6 transparent forwarding, public AdGuardHome DNS UFW openings, universal multi-target forwarding, or stage-7 lifecycle/docs release sync are absent.
#>

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$script:Failures = [System.Collections.Generic.List[string]]::new()

$repoRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$readText = 'C:\Users\ivanm\.codex\tools\windows-text-io\Read-Text.ps1'
$sourceRoot = Join-Path $repoRoot 'src\setup'

$setup = & $readText -LiteralPath (Join-Path $repoRoot 'setup.sh')
$uninstall = & $readText -LiteralPath (Join-Path $repoRoot 'uninstall.sh')
$buildSetup = & $readText -LiteralPath (Join-Path $repoRoot 'tools\build-setup.ps1')
$setupIndex = & $readText -LiteralPath (Join-Path $sourceRoot 'README.md')
$readme = & $readText -LiteralPath (Join-Path $repoRoot 'readme.md')
$setupMetaPath = Join-Path $repoRoot 'setup.sh.meta.md'
$uninstallMetaPath = Join-Path $repoRoot 'uninstall.sh.meta.md'
$setupMeta = if (Test-Path -LiteralPath $setupMetaPath) { & $readText -LiteralPath $setupMetaPath } else { '' }
$uninstallMeta = if (Test-Path -LiteralPath $uninstallMetaPath) { & $readText -LiteralPath $uninstallMetaPath } else { '' }

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
        $script:Failures.Add($Message)
    }
}

function Assert-NotMatch {
    param(
        [string]$Text,
        [string]$Pattern,
        [string]$Message
    )

    if ($Text -match $Pattern) {
        $script:Failures.Add($Message)
    }
}

function Assert-Contains {
    param(
        [string]$Text,
        [string]$Needle,
        [string]$Message
    )

    if ($Text.IndexOf($Needle, [System.StringComparison]::Ordinal) -lt 0) {
        $script:Failures.Add($Message)
    }
}

function Assert-PathExists {
    param(
        [string]$LiteralPath,
        [string]$Message
    )

    if (-not (Test-Path -LiteralPath $LiteralPath)) {
        $script:Failures.Add($Message)
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
        $script:Failures.Add("$Message Expected $ExpectedCount, got $actualCount.")
    }
}

function Assert-PathMissing {
    param(
        [string]$LiteralPath,
        [string]$Message
    )

    if (Test-Path -LiteralPath $LiteralPath) {
        $script:Failures.Add($Message)
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

Assert-Match -Text $setup -Pattern 'SCRIPT_VERSION="3\.0\.9"' -Message 'setup.sh must expose installer version 3.0.9 after the universal forwarding firewall rebuild.'
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
Assert-Match -Text $firewallSource -Pattern 'ufw\s+allow\s+"?\$\{ADG_DNS_PORT\}/tcp"?' -Message '60-firewall.sh must open the public AdGuardHome DNS TCP port via UFW.'
Assert-Match -Text $firewallSource -Pattern 'ufw\s+allow\s+"?\$\{ADG_DNS_PORT\}/udp"?' -Message '60-firewall.sh must open the public AdGuardHome DNS UDP port via UFW.'
Assert-Match -Text $setupIndex -Pattern '40-awg\.sh.*53/udp.*MTU 1280' -Message 'src/setup/README.md must document the target AWG port and MTU.'
Assert-Match -Text $setupIndex -Pattern '60-firewall\.sh.*target.*Reality 443.*AWG 53' -Message 'src/setup/README.md must document target firewall openings.'
Assert-Match -Text $setupIndex -Pattern '70-output\.sh.*Target handoff.*relay' -Message 'src/setup/README.md must document target relay handoff output.'

Assert-Match -Text $forwardingHelpers -Pattern 'prompt_target_details\(\)' -Message '14-port-forwarding-helpers.sh must define prompt_target_details for relay.'
Assert-Contains -Text $forwardingHelpers -Needle '/dev/tty' -Message 'prompt_target_details must read relay target details through /dev/tty.'
Assert-Contains -Text $forwardingHelpers -Needle 'Настроить проброс портов с этого сервера? [y/N]' -Message 'prompt_target_details must ask whether forwarding should be configured before collecting targets.'
Assert-Match -Text $forwardingHelpers -Pattern '(?s)Настроить проброс портов с этого сервера\? \[y/N\].*(return 0|PORT_FORWARDING_ENABLED=0)' -Message 'prompt_target_details must treat no forwarding as a normal no-op path.'
Assert-Contains -Text $forwardingHelpers -Needle 'Target IP' -Message 'prompt_target_details must ask for the first forwarding target IP after yes.'
Assert-Contains -Text $forwardingHelpers -Needle 'Target port' -Message 'prompt_target_details must ask for the first target port without a separate continue question.'
Assert-Match -Text $forwardingHelpers -Pattern 'tcp\|udp\|both|tcp, udp или both' -Message 'prompt_target_details must ask for forwarding protocol tcp, udp, or both.'
Assert-Match -Text $forwardingHelpers -Pattern 'proto=.*both|PORT_FORWARD_PROTO=.*both|forward_proto=.*both' -Message 'prompt_target_details must default an empty protocol answer to both.'
Assert-Contains -Text $forwardingHelpers -Needle 'Добавить еще порт для этого target? [y/N]' -Message 'prompt_target_details must ask whether to add another port for the same target after each port.'
Assert-Contains -Text $forwardingHelpers -Needle 'Добавить еще target-сервер? [y/N]' -Message 'prompt_target_details must ask whether to add another target after finishing ports for one target.'
Assert-NotMatch -Text $forwardingHelpers -Pattern 'Target AWG UDP port|Target Reality TCP port|Target DNS port' -Message 'prompt_target_details must no longer hard-code AWG, Reality, or DNS target port prompts.'
Assert-Match -Text $systemSource -Pattern 'if \[ "\$DEPLOY_MODE" = "relay" \]; then\s+prompt_target_details\s+fi' -Message '20-system.sh must prompt target details before relay local services are configured.'
Assert-Match -Text $awgSource -Pattern 'AWG_PORT=53' -Message '40-awg.sh must keep relay-local AmneziaWG on UDP port 53.'
Assert-Contains -Text $outputSource -Needle 'Relay local direct stack' -Message '70-output.sh must print a relay-local direct stack block.'
Assert-Contains -Text $outputSource -Needle 'Future relay-forward endpoints' -Message '70-output.sh must print a future relay-forward endpoints block.'
Assert-Contains -Text $outputSource -Needle 'Target для будущего forwarding' -Message '70-output.sh must print the saved target details for future forwarding.'
Assert-Contains -Text $firewallSource -Needle 'Firewall: relay local allow Reality 443/tcp' -Message '60-firewall.sh must include a relay-local Reality firewall marker.'
Assert-Contains -Text $firewallSource -Needle 'Firewall: relay local allow AWG 53/udp' -Message '60-firewall.sh must include a relay-local AWG firewall marker.'
Assert-Match -Text $setupIndex -Pattern '14-port-forwarding-helpers\.sh.*prompt_target_details.*проброс портов.*target IP.*target port.*protocol' -Message 'src/setup/README.md must document the interactive forwarding rule collection flow.'
Assert-Match -Text $setupIndex -Pattern '70-output\.sh.*Relay local direct stack.*Future relay-forward endpoints' -Message 'src/setup/README.md must document relay-specific output.'

Assert-Match -Text $forwardingHelpers -Pattern 'setup_port_forwarding\(\)' -Message '14-port-forwarding-helpers.sh must define setup_port_forwarding for relay.'
Assert-Match -Text $forwardingHelpers -Pattern 'cleanup_port_forwarding\(\)' -Message '14-port-forwarding-helpers.sh must define cleanup_port_forwarding for relay.'
Assert-Match -Text $forwardingHelpers -Pattern 'FORWARDING_RULES|PORT_FORWARDING_RULES|RELAY_FORWARDING_RULES' -Message '14-port-forwarding-helpers.sh must store forwarding as a reusable rule list for multiple arbitrary ports and targets.'
Assert-Match -Text $forwardingHelpers -Pattern '(?s)setup_port_forwarding\(\).*(for|while).*(FORWARDING_RULES|PORT_FORWARDING_RULES|RELAY_FORWARDING_RULES)' -Message 'setup_port_forwarding must iterate over the forwarding rule list, not only fixed AWG/Reality ports.'
Assert-Match -Text $forwardingHelpers -Pattern 'rule_target_ip|target_ip_from_rule|fwd_target_ip' -Message 'setup_port_forwarding must use a per-rule target IP so different rules can point to different targets.'
Assert-Match -Text $forwardingHelpers -Pattern 'rule_target_port|target_port_from_rule|fwd_target_port' -Message 'setup_port_forwarding must use a per-rule target port so arbitrary service ports can be forwarded.'
Assert-Match -Text $forwardingHelpers -Pattern 'rule_external_port|external_port_from_rule|fwd_external_port' -Message 'setup_port_forwarding must use a per-rule external port for each forwarded service.'
Assert-Match -Text $forwardingHelpers -Pattern 'rule_proto|proto_from_rule|fwd_proto' -Message 'setup_port_forwarding must use a per-rule protocol so TCP, UDP, and mixed forwarding can be represented.'
Assert-Match -Text $forwardingHelpers -Pattern 'prompt_forwarding_rules|collect_forwarding_rules|add_forwarding_rule|append_forwarding_rule' -Message '14-port-forwarding-helpers.sh must collect multiple arbitrary forwarding rules interactively.'
Assert-Match -Text $forwardingHelpers -Pattern '(?s)(prompt_forwarding_rules|collect_forwarding_rules|add_forwarding_rule|append_forwarding_rule).*Добавить еще порт' -Message 'forwarding prompt flow must allow several arbitrary ports for one target.'
Assert-Match -Text $forwardingHelpers -Pattern '(?s)(prompt_forwarding_rules|collect_forwarding_rules|add_forwarding_rule|append_forwarding_rule).*Добавить еще target' -Message 'forwarding prompt flow must allow several target IPs.'
Assert-Match -Text $forwardingHelpers -Pattern '(?s)setup_port_forwarding\(\).*iptables_ensure_rule nat PREROUTING.*rule_target_ip|(?s)setup_port_forwarding\(\).*iptables_ensure_rule nat PREROUTING.*fwd_target_ip|(?s)setup_port_forwarding\(\).*iptables_ensure_rule nat PREROUTING.*target_ip_from_rule' -Message 'setup_port_forwarding must generate PREROUTING DNAT rules from each generic forwarding rule.'
Assert-Match -Text $forwardingHelpers -Pattern '(?s)setup_port_forwarding\(\).*iptables_ensure_rule filter FORWARD.*rule_target_ip|(?s)setup_port_forwarding\(\).*iptables_ensure_rule filter FORWARD.*fwd_target_ip|(?s)setup_port_forwarding\(\).*iptables_ensure_rule filter FORWARD.*target_ip_from_rule' -Message 'setup_port_forwarding must generate FORWARD rules from each generic forwarding rule.'
Assert-Match -Text $forwardingHelpers -Pattern '(?s)setup_port_forwarding\(\).*iptables_ensure_rule nat POSTROUTING.*rule_target_ip|(?s)setup_port_forwarding\(\).*iptables_ensure_rule nat POSTROUTING.*fwd_target_ip|(?s)setup_port_forwarding\(\).*iptables_ensure_rule nat POSTROUTING.*target_ip_from_rule' -Message 'setup_port_forwarding must generate MASQUERADE rules from each generic forwarding rule.'
Assert-NotMatch -Text $forwardingHelpers -Pattern '(?s)setup_port_forwarding\(\)[\s\S]*RELAY_FWD_AWG_PORT[\s\S]*RELAY_FWD_REALITY_PORT[\s\S]*TARGET_AWG_PORT[\s\S]*TARGET_REALITY_PORT' -Message 'setup_port_forwarding must not be hard-wired to only AWG and Reality forwarding fields.'
Assert-NotMatch -Text $forwardingHelpers -Pattern '(?s)cleanup_port_forwarding\(\)[\s\S]*3x-awg relay fwd awg[\s\S]*3x-awg relay fwd reality' -Message 'cleanup_port_forwarding must not delete only AWG/Reality fixed forwarding rules.'
Assert-Match -Text $forwardingHelpers -Pattern 'iptables-save|netfilter-persistent' -Message 'setup_port_forwarding must persist iptables rules after reboot.'
Assert-NotMatch -Text $forwardingHelpers -Pattern 'setup_port_forwarding\(\)[\s\S]*ss .*PREROUTING|setup_port_forwarding\(\)[\s\S]*ss .*POSTROUTING|setup_port_forwarding\(\)[\s\S]*ss .*FORWARD' -Message 'setup_port_forwarding must not use ss as a false NAT rule check.'
Assert-Match -Text $forwardingHelpers -Pattern 'choose_relay_forward_port "\$rule_target_port" "\$rule_proto"' -Message 'ensure_relay_forward_ports must prefer the target port as the local external port.'
Assert-Match -Text $forwardingHelpers -Pattern 'shuf -i 10000-65000 -n 1' -Message 'choose_relay_forward_port must pick a random fallback port in the 10000-65000 range.'
Assert-Match -Text $forwardingHelpers -Pattern '(?s)is_relay_forward_port_available\(\).*both.*ss -H -ltn.*ss -H -lun' -Message 'port availability checks for proto=both must require the port to be free for both TCP and UDP.'
Assert-Match -Text $forwardingHelpers -Pattern 'FORWARDING_SELECTED_EXTERNAL_PORTS' -Message 'forwarding external port selection must track already selected forwarding ports.'
foreach ($reservedPort in @('22', '2244', '53', '443')) {
    Assert-Match -Text $forwardingHelpers -Pattern (':{0}:' -f $reservedPort) -Message "forwarding external port selection must reserve port $reservedPort."
}
Assert-Match -Text $firewallSource -Pattern 'if \[ "\$\{PORT_FORWARDING_ENABLED:-0\}" -eq 1 \]; then\s+sed -i ''s/DEFAULT_FORWARD_POLICY="DROP"/DEFAULT_FORWARD_POLICY="ACCEPT"/'' /etc/default/ufw\s+fi' -Message '60-firewall.sh must keep DEFAULT_FORWARD_POLICY=ACCEPT conditional on enabled forwarding.'
Assert-Match -Text $firewallSource -Pattern 'if \[ "\$DEPLOY_MODE" = "relay" \]; then\s+setup_port_forwarding\s+fi' -Message '60-firewall.sh must install relay forwarding rules after local relay ports are known.'
Assert-Contains -Text $firewallSource -Needle 'Firewall: relay forward allow external ports' -Message '60-firewall.sh must open generic relay external forwarding ports.'
Assert-NotMatch -Text $firewallSource -Pattern 'Firewall: relay forward allow external AWG|Firewall: relay forward allow external Reality' -Message '60-firewall.sh must not describe universal forwarding UFW openings as AWG/Reality-only.'
Assert-Match -Text $firewallSource -Pattern '(?s)while IFS=.*ufw allow \$\{rule_external_port\}/\$\{fwd_proto\}.*PORT_FORWARDING_RULES' -Message '60-firewall.sh must open each external forwarding port from the universal rule list.'
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
Assert-Contains -Text $setupMeta -Needle 'версии 3.0.9' -Message 'setup.sh.meta.md must describe the current assembled artifact version.'
Assert-Contains -Text $uninstallMeta -Needle 'точечно удаляет owned forwarding-правила' -Message 'uninstall.sh.meta.md must describe precise forwarding cleanup.'

Assert-NotMatch -Text $setup -Pattern 'CASCADE_|VLESS_LINK|ADG_HTTP_PROXY_PORT|XRAY_' -Message 'setup.sh credentials and runtime must remain free of legacy cascade/Xray fields.'

if ($script:Failures.Count -gt 0) {
    Write-Error ("script-regressions: {0} failure(s):`n- {1}" -f $script:Failures.Count, ($script:Failures -join "`n- "))
    exit 1
}

Write-Host 'script-regressions: OK'
