#!/usr/bin/env bash
set -uo pipefail
cd "$(dirname "$0")"
source lib/assert.sh

REPO_ROOT=$(cd .. && pwd)
SCRIPT=$REPO_ROOT/roles/dev-vms/files/vm-ip
FIXTURES=$(pwd)/fixtures/bin

setup() {
  SANDBOX=$(mktemp -d)
  export HOME=$SANDBOX/home
  export VM_CONNECT=stub:///test
  export STUB_LOG=$SANDBOX/stub.log
  export PATH=$FIXTURES:$PATH
  unset STUB_DOMIFADDR_IP
  mkdir -p "$HOME/.ssh/dev-vms.d"
}

teardown() { rm -rf "$SANDBOX"; }

echo "vm-ip: requires a name argument"
setup
OUT=$("$SCRIPT" 2>&1); STATUS=$?
assert_eq "exits non-zero" 1 "$STATUS"
assert_contains "prints usage" "$OUT" "usage"
teardown

echo "vm-ip: reports clearly when the VM has no IP yet"
setup
OUT=$("$SCRIPT" myvm 2>&1); STATUS=$?
assert_eq "exits non-zero" 1 "$STATUS"
assert_contains "reports no IP" "$OUT" "No IP for 'myvm'"
teardown

echo "vm-ip: refreshes an existing ssh config entry's HostName, leaves the rest alone"
setup
CONF=$HOME/.ssh/dev-vms.d/myvm.conf
cat > "$CONF" <<EOF
Host myvm
  HostName 203.0.113.1
  User dev
  IdentityFile $HOME/.ssh/dev-vm
  StrictHostKeyChecking accept-new
EOF
export STUB_DOMIFADDR_IP=203.0.113.99
OUT=$("$SCRIPT" myvm 2>&1); STATUS=$?
assert_eq "exits 0" 0 "$STATUS"
assert_contains "prints the new IP" "$OUT" "203.0.113.99"
CONTENT=$(cat "$CONF")
assert_contains "updates HostName to the new IP" "$CONTENT" "HostName 203.0.113.99"
assert_not_contains "drops the stale IP" "$CONTENT" "203.0.113.1"
assert_contains "leaves the User line untouched" "$CONTENT" "User dev"
assert_contains "leaves the IdentityFile line untouched" "$CONTENT" "IdentityFile $HOME/.ssh/dev-vm"
LOG=$(cat "$STUB_LOG")
assert_contains "passes the name via --domain, not positionally" "$LOG" "domifaddr --domain myvm"
teardown

echo "vm-ip: doesn't error when there's no ssh config fragment yet"
setup
export STUB_DOMIFADDR_IP=203.0.113.99
OUT=$("$SCRIPT" newvm 2>&1); STATUS=$?
assert_eq "exits 0" 0 "$STATUS"
assert_contains "still prints the IP" "$OUT" "203.0.113.99"
teardown

finish
