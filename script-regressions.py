#!/usr/bin/env python3
"""
Name: script regression checks
Description: Validates bootstrap baseline, helper split, manual 3x-ui flow, target
             topology, relay local stack, relay transparent forwarding, public
             AdGuardHome DNS endpoint, universal forwarding guardrails, and lifecycle/docs
             release sync.
Usage: python script-regressions.py
Returns: exit 0 on pass, exit 1 on regression.
"""

import os
import re
import sys

REPO_ROOT = os.path.dirname(os.path.abspath(__file__))
SOURCE_ROOT = os.path.join(REPO_ROOT, "src", "setup")

failures = []


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def read_text(path):
    if not os.path.exists(path):
        return ""
    with open(path, encoding="utf-8", errors="replace") as f:
        return f.read()


def assert_match(text, pattern, message, flags=re.DOTALL):
    if not re.search(pattern, text, flags):
        failures.append(message)


def assert_not_match(text, pattern, message, flags=re.DOTALL):
    if re.search(pattern, text, flags):
        failures.append(message)


def assert_contains(text, needle, message):
    if needle not in text:
        failures.append(message)


def assert_not_contains(text, needle, message):
    if needle in text:
        failures.append(message)


def assert_match_count(text, pattern, expected_count, message, flags=re.DOTALL):
    actual = len(re.findall(pattern, text, flags))
    if actual != expected_count:
        failures.append(f"{message} Expected {expected_count}, got {actual}.")


def assert_path_exists(path, message):
    if not os.path.exists(path):
        failures.append(message)


def assert_path_missing(path, message):
    if os.path.exists(path):
        failures.append(message)


# ---------------------------------------------------------------------------
# Load files
# ---------------------------------------------------------------------------

setup          = read_text(os.path.join(REPO_ROOT, "setup.sh"))
uninstall      = read_text(os.path.join(REPO_ROOT, "uninstall.sh"))
build_setup    = read_text(os.path.join(REPO_ROOT, "tools", "build-setup.ps1"))
setup_index    = read_text(os.path.join(SOURCE_ROOT, "README.md"))
readme         = read_text(os.path.join(REPO_ROOT, "readme.md"))
setup_meta     = read_text(os.path.join(REPO_ROOT, "setup.sh.meta.md"))
uninstall_meta = read_text(os.path.join(REPO_ROOT, "uninstall.sh.meta.md"))

helper_modules = [
    "10-common.sh",
    "11-awg-helpers.sh",
    "12-agh-helpers.sh",
    "13-3x-helpers.sh",
    "14-port-forwarding-helpers.sh",
]

ordered_modules = [
    "00-bootstrap.sh",
    "10-common.sh",
    "11-awg-helpers.sh",
    "12-agh-helpers.sh",
    "13-3x-helpers.sh",
    "14-port-forwarding-helpers.sh",
    "20-system.sh",
    "30-xray.sh",
    "40-awg.sh",
    "50-adguard.sh",
    "60-firewall.sh",
    "70-output.sh",
]

module_texts = {m: read_text(os.path.join(SOURCE_ROOT, m)) for m in helper_modules}

common_helpers      = module_texts["10-common.sh"]
awg_helpers         = module_texts["11-awg-helpers.sh"]
agh_helpers         = module_texts["12-agh-helpers.sh"]
three_x_helpers     = module_texts["13-3x-helpers.sh"]
forwarding_helpers  = module_texts["14-port-forwarding-helpers.sh"]
system_source       = read_text(os.path.join(SOURCE_ROOT, "20-system.sh"))
three_x_source      = read_text(os.path.join(SOURCE_ROOT, "30-xray.sh"))
awg_source          = read_text(os.path.join(SOURCE_ROOT, "40-awg.sh"))
adguard_source      = read_text(os.path.join(SOURCE_ROOT, "50-adguard.sh"))
firewall_source     = read_text(os.path.join(SOURCE_ROOT, "60-firewall.sh"))
output_source       = read_text(os.path.join(SOURCE_ROOT, "70-output.sh"))


# ---------------------------------------------------------------------------
# Stage 1: bootstrap baseline
# ---------------------------------------------------------------------------

assert_match(setup, r'SCRIPT_VERSION="3\.2\.0"',
    "setup.sh must expose installer version 3.2.0 after the universal forwarding firewall rebuild.")
assert_match(setup, r'DEPLOY_MODE="target"',
    "setup.sh must default DEPLOY_MODE to target.")
assert_match(setup, r'--mode\)',
    "setup.sh must accept --mode CLI argument.")
assert_contains(setup, "Версия скрипта: ${SCRIPT_VERSION}",
    "setup.sh must print the script version.")
assert_match(setup, r"Режим разв.ртывания: \$\{DEPLOY_MODE\}",
    "setup.sh must print the selected deploy mode.")
assert_contains(setup, "Assembled from source modules",
    "setup.sh must declare that it is built from modular source files.")
assert_match(setup, r'CURRENT_STEP="bootstrap"',
    "setup.sh must initialize the current step tracker early.")
assert_match(setup, r'mark_step\(\)',
    "setup.sh must define a helper for updating the current step.")
assert_contains(setup, "3x-ui requires manual interactive configuration after the installer finishes.",
    "setup.sh must include the stage-3 manual 3x-ui handoff notice.")

# ---------------------------------------------------------------------------
# Stage 2: modular source layout
# ---------------------------------------------------------------------------

for module in ordered_modules:
    assert_contains(setup, f"src/setup/{module}",
        f"setup.sh must list {module} in its assembled header.")
    assert_contains(build_setup, f"'{module}'",
        f"build-setup.ps1 must assemble {module}.")
    assert_contains(setup_index, module,
        f"src/setup/README.md must describe {module}.")

assert_not_match(setup, r"src/setup/10-helpers\.sh",
    "setup.sh must not reference the removed 10-helpers.sh source module.")
assert_not_contains(build_setup, "'10-helpers.sh'",
    "build-setup.ps1 must not assemble the removed 10-helpers.sh module.")
assert_not_match(setup_index, r"10-helpers\.sh",
    "src/setup/README.md must not document the removed 10-helpers.sh module.")

for module in helper_modules:
    assert_path_exists(os.path.join(SOURCE_ROOT, module),
        f"Missing source helper module: {module}")

assert_path_missing(os.path.join(SOURCE_ROOT, "10-helpers.sh"),
    "src/setup/10-helpers.sh must be removed after the helper split.")

# ---------------------------------------------------------------------------
# Stage 2: helper split invariants
# ---------------------------------------------------------------------------

assert_match(common_helpers, r"trim_cr_value\(\)", "10-common.sh must keep trim_cr_value")
assert_match(common_helpers, r"read_cred_value\(\)", "10-common.sh must keep read_cred_value")
assert_match(common_helpers, r"read_config_assignment\(\)", "10-common.sh must keep read_config_assignment")
assert_match(common_helpers, r"read_url_port\(\)", "10-common.sh must keep read_url_port")
assert_match(common_helpers, r"ensure_swapfile\(\)", "10-common.sh must keep ensure_swapfile")
assert_match(common_helpers, r"validate_stack\(\)", "10-common.sh must keep validate_stack")
assert_not_match(common_helpers,
    r"install_xray_core\(\)|load_existing_awg_credentials\(\)|cleanup_legacy_adguard_units\(\)|remove_legacy_xui\(\)|configure_cascade_mode\(\)",
    "10-common.sh must not keep service-specific helpers after the split")

assert_match(awg_helpers, r"resolve_awg_key_bin\(\)", "11-awg-helpers.sh must hold resolve_awg_key_bin")
assert_match(awg_helpers, r"ensure_awg_build_dependencies\(\)", "11-awg-helpers.sh must hold ensure_awg_build_dependencies")
assert_match(awg_helpers, r"load_existing_awg_credentials\(\)", "11-awg-helpers.sh must hold load_existing_awg_credentials")
assert_match(awg_helpers, r"cleanup_legacy_awg_dns_redirects\(\)", "11-awg-helpers.sh must hold cleanup_legacy_awg_dns_redirects")

assert_match(agh_helpers, r"cleanup_legacy_adguard_units\(\)", "12-agh-helpers.sh must hold cleanup_legacy_adguard_units")

assert_match(three_x_helpers, r"remove_legacy_xui\(\)", "13-3x-helpers.sh must hold remove_legacy_xui")
assert_match(three_x_helpers, r"install_3x_ui_interactive\(\)", "13-3x-helpers.sh must hold install_3x_ui_interactive")
assert_contains(three_x_helpers, "/dev/tty",
    "13-3x-helpers.sh must attach the official 3x-ui installer to /dev/tty.")
assert_contains(three_x_helpers, "3x-ui requires manual interactive configuration after the installer finishes.",
    "13-3x-helpers.sh must print the stage-3 manual configuration handoff.")

# ---------------------------------------------------------------------------
# Stage 3: manual 3x-ui flow
# ---------------------------------------------------------------------------

assert_not_match(three_x_helpers,
    r"install_xray_core\(\)|resolve_xray_bin\(\)|generate_reality_keys\(\)|write_xray_config\(\)",
    "13-3x-helpers.sh must drop legacy Xray helper functions in stage 3.")
assert_match(three_x_helpers, r"warn.*Официальный installer 3x-ui завершился с ошибкой",
    "13-3x-helpers.sh must use a warning instead of a hard error if the 3x-ui installer fails.")
assert_match(common_helpers, r"warn.*3x-ui/Reality.*пока не слушает",
    "10-common.sh must use a soft warning if the Reality port is not listening during stack validation.")
assert_not_match(forwarding_helpers,
    r"reset_cascade_state\(\)|parse_cascade_vless_uri\(\)|resolve_cascade_upstream_address\(\)|configure_cascade_mode\(\)",
    "14-port-forwarding-helpers.sh must drop legacy cascade helpers in stage 3.")
assert_not_match(setup,
    r"install_xray_core|write_xray_config|CASCADE_|ADG_HTTP_PROXY_PORT|VLESS_LINK|install-release\.sh|generate_reality_keys|resolve_xray_bin",
    "setup.sh must remove the legacy Xray/cascade implementation during stage 3.")
assert_not_match(setup_index,
    r"legacy cascade|VLESS|Xray config|bootstrap Xray-core|Reality keys",
    "src/setup/README.md must be updated for the stage-3 manual 3x-ui flow.")
assert_not_match(three_x_source,
    r'DEPLOY_MODE" = "relay"|Режим relay будет реализован',
    "30-xray.sh must not fail fast for relay after stage 5.")
assert_not_match(setup,
    r"Режим relay будет реализован на следующем этапе\. На этапе 3 он намеренно остановлен до начала настройки сервисов\.",
    "setup.sh must allow relay to run the local stack after stage 5.")

# ---------------------------------------------------------------------------
# Stage 4: target topology
# ---------------------------------------------------------------------------

assert_match(awg_source, r"AWG_PORT=53",
    "40-awg.sh must pin target AmneziaWG to UDP port 53.")
assert_match(setup, r"ListenPort = \$AWG_PORT",
    "setup.sh must write the selected AWG listen port into awg0.conf.")
assert_match_count(awg_source, r"MTU = 1280", 2,
    "40-awg.sh must write MTU 1280 into both server and client AWG configs.")
assert_match_count(setup, r"MTU = 1280", 2,
    "setup.sh must write MTU 1280 into both server and client AWG configs.")
assert_match(awg_source, r"ensure_awg_obfuscation_params",
    "40-awg.sh must use an idempotent AWG obfuscation parameter helper.")
assert_match(awg_helpers, r"ensure_awg_obfuscation_params\(\)",
    "11-awg-helpers.sh must own idempotent AWG obfuscation parameter generation.")

for param in ["JC", "JMIN", "JMAX", "S1", "S2", "H1", "H2", "H3", "H4"]:
    assert_match(awg_helpers, r'\[ -z "\$({)?' + param + r'(})?" \]',
        f"11-awg-helpers.sh must preserve existing {param} and generate it only when missing.")

assert_not_match(adguard_source,
    r"proxy|upstream_http_proxy|http_proxy|ADG_HTTP_PROXY_PORT",
    "50-adguard.sh must keep AdGuardHome direct and free of HTTP proxy dependencies.")
assert_contains(output_source, "Target handoff для relay",
    "70-output.sh must print a target-specific relay handoff block.")
assert_contains(output_source, "IP: ${SERVER_IP}",
    "70-output.sh must print target IP for relay setup.")
assert_contains(output_source, "AWG: ${SERVER_IP}:53/udp",
    "70-output.sh must print target AWG endpoint on UDP 53.")
assert_contains(output_source, "Reality: ${SERVER_IP}:${REALITY_PORT}/tcp",
    "70-output.sh must print target Reality endpoint on TCP 443.")
assert_contains(output_source, "DNS endpoint: ${SERVER_IP}:${ADG_DNS_PORT}",
    "70-output.sh must print target DNS endpoint for relay setup.")
assert_contains(firewall_source, "Firewall: target allow Reality 443/tcp",
    "60-firewall.sh must include a target-specific Reality firewall marker.")
assert_contains(firewall_source, "Firewall: target allow AWG 53/udp",
    "60-firewall.sh must include a target-specific AWG firewall marker.")
assert_contains(firewall_source, "Firewall: target allow AdGuardHome web",
    "60-firewall.sh must include a target-specific AdGuardHome web marker.")

# Task 6: public DNS endpoint
assert_match(firewall_source, r'ufw\s+allow\s+"?\$\{ADG_DNS_PORT\}/tcp"?',
    "60-firewall.sh must open the public AdGuardHome DNS TCP port via UFW.")
assert_match(firewall_source, r'ufw\s+allow\s+"?\$\{ADG_DNS_PORT\}/udp"?',
    "60-firewall.sh must open the public AdGuardHome DNS UDP port via UFW.")

assert_match(setup_index, r"40-awg\.sh.*53/udp.*MTU 1280",
    "src/setup/README.md must document the target AWG port and MTU.")
assert_match(setup_index, r"60-firewall\.sh.*target.*Reality 443.*AWG 53",
    "src/setup/README.md must document target firewall openings.")
assert_match(setup_index, r"70-output\.sh.*Target handoff.*relay",
    "src/setup/README.md must document target relay handoff output.")

# ---------------------------------------------------------------------------
# Stage 5: relay local stack
# ---------------------------------------------------------------------------

assert_match(forwarding_helpers, r"prompt_target_details\(\)",
    "14-port-forwarding-helpers.sh must define prompt_target_details for relay.")
assert_contains(forwarding_helpers, "/dev/tty",
    "prompt_target_details must read relay target details through /dev/tty.")
assert_contains(forwarding_helpers, "Настроить проброс портов с этого сервера? [y/N]",
    "prompt_target_details must ask whether forwarding should be configured before collecting targets.")
assert_match(forwarding_helpers,
    r"Настроить проброс портов с этого сервера\? \[y/N\].*(return 0|PORT_FORWARDING_ENABLED=0)",
    "prompt_target_details must treat no forwarding as a normal no-op path.")
assert_contains(forwarding_helpers, "Target IP",
    "prompt_target_details must ask for the first forwarding target IP after yes.")
assert_contains(forwarding_helpers, "Target port",
    "prompt_target_details must ask for the first target port without a separate continue question.")
assert_match(forwarding_helpers, r"tcp\|udp\|both|tcp, udp или both",
    "prompt_target_details must ask for forwarding protocol tcp, udp, or both.")
assert_match(forwarding_helpers, r"proto=.*both|PORT_FORWARD_PROTO=.*both|forward_proto=.*both",
    "prompt_target_details must default an empty protocol answer to both.")
assert_contains(forwarding_helpers, "Добавить еще порт для этого target? [y/N]",
    "prompt_target_details must ask whether to add another port for the same target after each port.")
assert_contains(forwarding_helpers, "Добавить еще target-сервер? [y/N]",
    "prompt_target_details must ask whether to add another target after finishing ports for one target.")
assert_not_match(forwarding_helpers, r"Target AWG UDP port|Target Reality TCP port|Target DNS port",
    "prompt_target_details must no longer hard-code AWG, Reality, or DNS target port prompts.")
assert_match(system_source,
    r'if \[ "\$DEPLOY_MODE" = "relay" \]; then\s+prompt_target_details\s+fi',
    "20-system.sh must prompt target details before relay local services are configured.")
assert_contains(output_source, "Relay local direct stack",
    "70-output.sh must print a relay-local direct stack block.")
assert_contains(output_source, "Status",
    "70-output.sh must print a Status column in the forwarding table.")
assert_contains(output_source, "State-файл правил",
    "70-output.sh must print the saved state file location.")
assert_contains(firewall_source, "Firewall: relay local allow Reality 443/tcp",
    "60-firewall.sh must include a relay-local Reality firewall marker.")
assert_contains(firewall_source, "Firewall: relay local allow AWG 53/udp",
    "60-firewall.sh must include a relay-local AWG firewall marker.")
assert_match(setup_index,
    r"14-port-forwarding-helpers\.sh.*prompt_target_details.*проброс портов.*target IP.*target port.*protocol",
    "src/setup/README.md must document the interactive forwarding rule collection flow.")
assert_match(setup_index,
    r"70-output\.sh.*Relay local direct stack.*Future relay-forward endpoints",
    "src/setup/README.md must document relay-specific output.")

# ---------------------------------------------------------------------------
# Stage 6: universal relay transparent forwarding
# ---------------------------------------------------------------------------

assert_match(forwarding_helpers, r"setup_port_forwarding\(\)",
    "14-port-forwarding-helpers.sh must define setup_port_forwarding for relay.")
assert_match(forwarding_helpers, r"cleanup_port_forwarding\(\)",
    "14-port-forwarding-helpers.sh must define cleanup_port_forwarding for relay.")
assert_match(forwarding_helpers,
    r"FORWARDING_RULES|PORT_FORWARDING_RULES|RELAY_FORWARDING_RULES",
    "14-port-forwarding-helpers.sh must store forwarding as a reusable rule list for multiple arbitrary ports and targets.")
assert_match(forwarding_helpers,
    r"setup_port_forwarding\(\).*(for|while).*(FORWARDING_RULES|PORT_FORWARDING_RULES|RELAY_FORWARDING_RULES)",
    "setup_port_forwarding must iterate over the forwarding rule list, not only fixed AWG/Reality ports.")
assert_match(forwarding_helpers,
    r"rule_target_ip|target_ip_from_rule|fwd_target_ip",
    "setup_port_forwarding must use a per-rule target IP so different rules can point to different targets.")
assert_match(forwarding_helpers,
    r"rule_target_port|target_port_from_rule|fwd_target_port",
    "setup_port_forwarding must use a per-rule target port so arbitrary service ports can be forwarded.")
assert_match(forwarding_helpers,
    r"rule_external_port|external_port_from_rule|fwd_external_port",
    "setup_port_forwarding must use a per-rule external port for each forwarded service.")
assert_match(forwarding_helpers,
    r"rule_proto|proto_from_rule|fwd_proto",
    "setup_port_forwarding must use a per-rule protocol so TCP, UDP, and mixed forwarding can be represented.")
assert_match(forwarding_helpers,
    r"prompt_forwarding_rules|collect_forwarding_rules|add_forwarding_rule|append_forwarding_rule",
    "14-port-forwarding-helpers.sh must collect multiple arbitrary forwarding rules interactively.")
assert_match(forwarding_helpers,
    r"(prompt_forwarding_rules|collect_forwarding_rules|add_forwarding_rule|append_forwarding_rule).*Добавить еще порт",
    "forwarding prompt flow must allow several arbitrary ports for one target.")
assert_match(forwarding_helpers,
    r"(prompt_forwarding_rules|collect_forwarding_rules|add_forwarding_rule|append_forwarding_rule).*Добавить еще target",
    "forwarding prompt flow must allow several target IPs.")

# DNAT/FORWARD/MASQUERADE generation
assert_match(forwarding_helpers,
    r"setup_port_forwarding.*iptables_ensure_rule nat PREROUTING.*rule_target_ip",
    "setup_port_forwarding must generate PREROUTING DNAT rules from each generic forwarding rule.")
assert_match(forwarding_helpers,
    r"setup_port_forwarding.*iptables_ensure_rule filter FORWARD.*rule_target_ip",
    "setup_port_forwarding must generate FORWARD rules from each generic forwarding rule.")
assert_match(forwarding_helpers,
    r"setup_port_forwarding.*iptables_ensure_rule nat POSTROUTING.*rule_target_ip",
    "setup_port_forwarding must generate MASQUERADE rules from each generic forwarding rule.")

assert_not_match(forwarding_helpers, r"setup_port_forwarding.*RELAY_FWD_AWG_PORT",
    "setup_port_forwarding must not be hard-wired to only AWG and Reality forwarding fields.")
assert_not_match(forwarding_helpers, r"cleanup_port_forwarding.*3x-awg relay fwd awg",
    "cleanup_port_forwarding must not delete only AWG/Reality fixed forwarding rules.")
assert_match(forwarding_helpers, r"iptables-save|netfilter-persistent",
    "setup_port_forwarding must persist iptables rules after reboot.")
assert_not_match(forwarding_helpers, r"setup_port_forwarding.*ss -H.*PREROUTING",
    "setup_port_forwarding must not use ss as a false NAT rule check.")

# Port selection
assert_match(forwarding_helpers, r'choose_relay_forward_port "\$rule_target_port" "\$rule_proto"',
    "ensure_relay_forward_ports must prefer the target port as the local external port.")
assert_match(forwarding_helpers, r"shuf -i 10000-65000 -n 1",
    "choose_relay_forward_port must pick a random fallback port in the 10000-65000 range.")
assert_match(forwarding_helpers, r"is_relay_forward_port_available.*both",
    "port availability checks for proto=both must require the port to be free for both TCP and UDP.")
assert_match(forwarding_helpers, r"FORWARDING_SELECTED_EXTERNAL_PORTS",
    "forwarding external port selection must track already selected forwarding ports.")

for port in ["22", "2244", "53", "443"]:
    assert_match(forwarding_helpers, f":{port}:",
        f"forwarding external port selection must reserve port {port}.")

# Firewall forwarding
assert_match(firewall_source,
    r'if \[ "\$\{PORT_FORWARDING_ENABLED:-0\}" -eq 1 \]; then\s+sed -i .*/etc/default/ufw\s+fi',
    "60-firewall.sh must keep DEFAULT_FORWARD_POLICY=ACCEPT conditional on enabled forwarding.")
assert_match(firewall_source,
    r'if \[ "\$DEPLOY_MODE" = "relay" \]; then\s+setup_port_forwarding\s+fi',
    "60-firewall.sh must install relay forwarding rules after local relay ports are known.")
assert_contains(firewall_source, "Firewall: relay forward allow external ports",
    "60-firewall.sh must open generic relay external forwarding ports.")
assert_not_match(firewall_source,
    r"Firewall: relay forward allow external AWG|Firewall: relay forward allow external Reality",
    "60-firewall.sh must not describe universal forwarding UFW openings as AWG/Reality-only.")
assert_match(firewall_source, r"ufw allow.*rule_external_port",
    "60-firewall.sh must open each external forwarding port from the universal rule list.")
assert_contains(output_source, "Relay-forward endpoints",
    "70-output.sh must print active relay-forward endpoints after stage 6.")
assert_match(setup_index,
    r"14-port-forwarding-helpers\.sh.*setup_port_forwarding.*cleanup_port_forwarding",
    "src/setup/README.md must document relay forwarding setup and cleanup helpers.")

# ---------------------------------------------------------------------------
# Stage 7: lifecycle / uninstall
# ---------------------------------------------------------------------------

assert_match(uninstall, r"</dev/tty",
    "uninstall.sh must keep reading confirmation from /dev/tty.")
assert_not_match(uninstall, r"ufw --force reset",
    "uninstall.sh must not globally reset UFW during stage 7 lifecycle cleanup.")
assert_match(uninstall, r"cleanup_port_forwarding_rules\(\)",
    "uninstall.sh must define a standalone owned forwarding cleanup helper.")
assert_match(uninstall, r"iptables_delete_rule\(\)",
    "uninstall.sh must delete specific iptables rules instead of flushing tables.")
assert_match(uninstall, r"delete_iptables_rules_by_comment_prefix \"3x-awg-fwd:\"",
    "uninstall.sh must remove owned forwarding rules using the universal comment prefix.")
assert_match(uninstall, r"persist_iptables_rules",
    "uninstall.sh must persist iptables after removing owned forwarding rules.")
assert_not_match(uninstall,
    r"iptables .* -F|iptables -t nat .* -F|ufw delete allow 53/udp|ufw delete allow 443/tcp",
    "uninstall.sh must not use destructive firewall cleanup or remove shared reserved ports blindly.")
assert_contains(uninstall,
    "3x-ui установлен интерактивно; uninstall удаляет файлы панели, но не управляет ручной конфигурацией Reality.",
    "uninstall.sh must document the manual 3x-ui lifecycle boundary.")
assert_not_match(uninstall,
    r"CASCADE_|VLESS_LINK|ADG_HTTP_PROXY_PORT|/usr/local/etc/xray/config\.json",
    "uninstall.sh must not carry legacy cascade credential fields or direct Xray config assumptions.")

# Stage 7: documentation
assert_contains(readme, "Transparent relay forwarding включён",
    "readme.md must describe active transparent relay forwarding in Russian.")
assert_contains(readme, "Transparent relay forwarding is enabled",
    "readme.md must describe active transparent relay forwarding in English.")
assert_contains(readme, "cleanup удаляет только owned forwarding-правила",
    "readme.md must document precise uninstall cleanup semantics.")
assert_not_match(readme,
    r"Stage-5 limitations|Ограничения этапа 5|future transparent forwarding|будущего transparent forwarding|Transparent port forwarding .*not enabled|planned for the next stage",
    "readme.md must not describe relay forwarding as a future stage after stage 7.")
assert_contains(setup_index, "lifecycle uninstall",
    "src/setup/README.md must mention lifecycle uninstall alignment after stage 7.")
assert_contains(setup_meta, "версии 3.1.2",
    "setup.sh.meta.md must describe the current assembled artifact version.")
assert_contains(uninstall_meta, "точечно удаляет owned forwarding-правила",
    "uninstall.sh.meta.md must describe precise forwarding cleanup.")

# Legacy fields must be absent from setup.sh
assert_not_match(setup, r"CASCADE_|VLESS_LINK|ADG_HTTP_PROXY_PORT|XRAY_",
    "setup.sh credentials and runtime must remain free of legacy cascade/Xray fields.")

# ---------------------------------------------------------------------------
# Report
# ---------------------------------------------------------------------------

if failures:
    print(f"script-regressions: {len(failures)} failure(s):")
    for f in failures:
        print(f"  - {f}")
    sys.exit(1)

print("script-regressions: OK")
