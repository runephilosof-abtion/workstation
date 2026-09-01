#!/usr/bin/env bash
set -uo pipefail
cd "$(dirname "$0")"
source lib/assert.sh

REPO_ROOT=$(cd .. && pwd)
SCRIPT=$REPO_ROOT/roles/dev-vms/files/vm-new
FIXTURES=$(pwd)/fixtures/bin

setup() {
  SANDBOX=$(mktemp -d)
  export HOME=$SANDBOX/home
  export VM_POOL=$SANDBOX/pool
  export VM_CONNECT=stub:///test
  export STUB_LOG=$SANDBOX/stub.log
  export PATH=$FIXTURES:$PATH
  unset STUB_DOMIFADDR_IP STUB_VIRSH_DOMIFADDR_EXIT
  mkdir -p "$HOME/.ssh" "$VM_POOL"
  # vm-new hardcodes KEY=$HOME/.ssh/dev-vm; a real deployment has this from the
  # role's "Generate SSH key for dev VMs" task.
  echo "ssh-ed25519 AAAAstubpubkey dev-vms" > "$HOME/.ssh/dev-vm.pub"
}

teardown() { rm -rf "$SANDBOX"; }

log_or_empty() { [[ -f $STUB_LOG ]] && cat "$STUB_LOG" || true; }

echo "vm-new: requires a name argument"
setup
OUT=$("$SCRIPT" 2>&1); STATUS=$?
assert_eq "exits non-zero" 1 "$STATUS"
assert_contains "prints usage" "$OUT" "usage"
teardown

echo "vm-new: rejects a flag-like name instead of creating a stray VM"
setup
OUT=$("$SCRIPT" --help 2>&1); STATUS=$?
assert_eq "exits non-zero" 1 "$STATUS"
assert_contains "prints usage" "$OUT" "usage"
LOG=$(log_or_empty)
assert_not_contains "never touches qemu-img for a rejected name" "$LOG" "qemu-img"
teardown

echo "vm-new: refuses to overwrite an existing disk"
setup
touch "$VM_POOL/dupe.qcow2"
OUT=$("$SCRIPT" dupe 2>&1); STATUS=$?
assert_eq "exits non-zero" 1 "$STATUS"
assert_contains "reports the disk already exists" "$OUT" "already exists"
LOG=$(log_or_empty)
assert_not_contains "never attempts qemu-img on an existing disk" "$LOG" "qemu-img"
teardown

echo "vm-new: happy path creates disk, domain, and ssh config entry"
setup
export STUB_DOMIFADDR_IP=203.0.113.20
OUT=$("$SCRIPT" happyvm 2>&1); STATUS=$?
assert_eq "exits 0" 0 "$STATUS"
assert_contains "reports the assigned IP" "$OUT" "203.0.113.20"
LOG=$(cat "$STUB_LOG")
assert_contains "creates a qcow2 overlay disk" "$LOG" "qemu-img create -q -f qcow2 -b"
assert_contains "builds the cloud-init seed" "$LOG" "cloud-localds"
assert_contains "installs with the right name" "$LOG" "--name happyvm"
assert_contains "boots UEFI on q35 (trixie cloud image requirement)" "$LOG" "--machine q35"
assert_contains "attaches the egress-lockdown nwfilter" "$LOG" "filterref.filter=vm-egress-lockdown"
assert_contains "polls the IP via --domain, not positionally" "$LOG" "domifaddr --domain happyvm"
CONF=$HOME/.ssh/dev-vms.d/happyvm.conf
assert_file_exists "writes the ssh config fragment" "$CONF"
CONTENT=$(cat "$CONF")
assert_contains "ssh config has the right Host" "$CONTENT" "Host happyvm"
assert_contains "ssh config has the assigned IP" "$CONTENT" "HostName 203.0.113.20"
teardown

echo "vm-new: times out cleanly if the VM never gets an IP"
setup
OUT=$("$SCRIPT" noip 2>&1); STATUS=$?
assert_eq "exits non-zero" 1 "$STATUS"
assert_contains "reports the timeout" "$OUT" "Timed out waiting for an IP"
teardown

finish
