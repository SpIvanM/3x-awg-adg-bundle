#!/bin/bash
# Test script for fwd.sh logic

# Mock environment
mkdir -p /tmp/fwd-test
export FORWARDING_STATE_FILE="/tmp/fwd-test/forwarding.rules"
export PUB_INT="eth0"

# Mock iptables
iptables() { echo "iptables $*"; }
export -f iptables
iptables-save() { echo "iptables-save $*"; }
export -f iptables-save

# Mock ss (socket statistics)
ss() { return 1; } # No ports listening
export -f ss

# Mock /dev/tty
# We can't easily mock /dev/tty for interactive read in a script without expect
# But we can test the load/save functions directly

source ./tools/fwd.sh --source-only 2>/dev/null || true

test_load_save() {
    echo "Testing load/save..."
    echo "1.2.3.4|80|tcp|8080|test-rule" > "$FORWARDING_STATE_FILE"
    load_forwarding_rules_state
    if [[ "$PORT_FORWARDING_RULES" == *"1.2.3.4|80|tcp|8080|test-rule"* ]]; then
        echo "SUCCESS: Rules loaded correctly"
    else
        echo "FAILURE: Rules not loaded"
        exit 1
    fi
    
    append_forwarding_rule "5.6.7.8" "443" "both" "8443" "new-rule"
    PORT_FORWARDING_ENABLED=1
    save_forwarding_rules_state
    
    if grep -q "5.6.7.8|443|both|8443|new-rule" "$FORWARDING_STATE_FILE"; then
        echo "SUCCESS: Rules saved correctly"
    else
        echo "FAILURE: Rules not saved"
        exit 1
    fi
}

test_load_save
echo "All tests passed!"
