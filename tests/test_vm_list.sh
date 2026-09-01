#!/usr/bin/env bash
set -uo pipefail
cd "$(dirname "$0")"
source lib/assert.sh

REPO_ROOT=$(cd .. && pwd)
SCRIPT=$REPO_ROOT/roles/dev-vms/files/vm-list
FIXTURES=$(pwd)/fixtures/bin

setup() {
  SANDBOX=$(mktemp -d)
  export HOME=$SANDBOX/home
  export VM_CONNECT=stub:///test
  export STUB_LOG=$SANDBOX/stub.log
  export PATH=$FIXTURES:$PATH
  unset STUB_LIST_NAMES STUB_DOMSTATE STUB_DOMIFADDR_IP
  unset STUB_STATE_RUNNING_VM STUB_STATE_STOPPED_VM STUB_IP_RUNNING_VM
}

teardown() { rm -rf "$SANDBOX"; }

echo "vm-list: reports clearly when there are no VMs"
setup
OUT=$("$SCRIPT" 2>&1); STATUS=$?
assert_eq "exits 0" 0 "$STATUS"
assert_contains "reports no VMs" "$OUT" "No VMs."
teardown

echo "vm-list: lists a mix of running and shut-off VMs, with IPs only for running ones"
setup
export STUB_LIST_NAMES=$'running-vm\nstopped-vm'
export STUB_STATE_RUNNING_VM=running
export STUB_STATE_STOPPED_VM='shut off'
export STUB_IP_RUNNING_VM=203.0.113.42
OUT=$("$SCRIPT" 2>&1); STATUS=$?
assert_eq "exits 0" 0 "$STATUS"
assert_contains "prints header" "$OUT" "NAME"
assert_contains "lists the running VM" "$OUT" "running-vm"
assert_contains "shows its state" "$OUT" "running"
assert_contains "shows its IP" "$OUT" "203.0.113.42"
assert_contains "lists the shut-off VM" "$OUT" "stopped-vm"
assert_contains "shows its state" "$OUT" "shut off"
LOG=$(cat "$STUB_LOG")
assert_not_contains "never queries the shut-off VM's IP" "$LOG" "domifaddr --domain stopped-vm"
assert_contains "queries the running VM's IP" "$LOG" "domifaddr --domain running-vm"
teardown

echo "vm-list: a shut-off VM shows a placeholder instead of an IP"
setup
export STUB_LIST_NAMES=stopped-vm
export STUB_STATE_STOPPED_VM='shut off'
OUT=$("$SCRIPT" 2>&1); STATUS=$?
assert_eq "exits 0" 0 "$STATUS"
LINE=$(grep stopped-vm <<< "$OUT")
assert_contains "prints a placeholder, not a blank field" "$LINE" "-"

finish
