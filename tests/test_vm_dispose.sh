#!/usr/bin/env bash
set -uo pipefail
cd "$(dirname "$0")"
source lib/assert.sh

REPO_ROOT=$(cd .. && pwd)
SCRIPT=$REPO_ROOT/roles/dev-vms/files/vm-dispose
FIXTURES=$(pwd)/fixtures/bin

setup() {
  SANDBOX=$(mktemp -d)
  export HOME=$SANDBOX/home
  export VM_POOL=$SANDBOX/pool
  export VM_CONNECT=stub:///test
  export STUB_LOG=$SANDBOX/stub.log
  export PATH=$FIXTURES:$PATH
  unset STUB_VIRSH_DESTROY_EXIT STUB_VIRSH_UNDEFINE_EXIT
  mkdir -p "$HOME/.ssh" "$VM_POOL"
}

teardown() { rm -rf "$SANDBOX"; }

echo "vm-dispose: normal dispose removes everything vm-new created"
setup
touch "$VM_POOL/myvm.qcow2" "$VM_POOL/myvm-seed.iso"
mkdir -p "$HOME/.ssh/dev-vms.d"
cat > "$HOME/.ssh/dev-vms.d/myvm.conf" <<EOF
Host myvm
  HostName 203.0.113.10
  User dev
  IdentityFile $HOME/.ssh/dev-vm
  StrictHostKeyChecking accept-new
EOF
OUT=$("$SCRIPT" myvm 2>&1); STATUS=$?
assert_eq "exits 0" 0 "$STATUS"
assert_contains "prints disposed message" "$OUT" "VM 'myvm' disposed."
assert_file_absent "removes qcow2" "$VM_POOL/myvm.qcow2"
assert_file_absent "removes seed iso" "$VM_POOL/myvm-seed.iso"
assert_file_absent "removes ssh config fragment" "$HOME/.ssh/dev-vms.d/myvm.conf"
LOG=$(cat "$STUB_LOG")
assert_contains "destroy removes the (root-owned) qemu log too" "$LOG" "destroy --domain myvm --remove-logs"
assert_contains "undefine removes the nvram file too" "$LOG" "undefine --domain myvm --nvram"
assert_contains "clears the known_hosts entry for the recorded IP" "$LOG" "ssh-keygen -R 203.0.113.10"
assert_contains "clears the known_hosts entry for the name" "$LOG" "ssh-keygen -R myvm"
teardown

echo "vm-dispose: a flag-like VM name can't be misparsed as a virsh option"
setup
touch "$VM_POOL/--help.qcow2" "$VM_POOL/--help-seed.iso"
OUT=$("$SCRIPT" --help 2>&1); STATUS=$?
assert_eq "exits 0" 0 "$STATUS"
assert_file_absent "removes the flag-like-named disk" "$VM_POOL/--help.qcow2"
assert_file_absent "removes the flag-like-named seed" "$VM_POOL/--help-seed.iso"
LOG=$(cat "$STUB_LOG")
assert_contains "destroy passes the name via --domain, never positionally" "$LOG" "destroy --domain --help --remove-logs"
assert_contains "undefine passes the name via --domain, never positionally" "$LOG" "undefine --domain --help --nvram"
teardown

echo "vm-dispose: still cleans up local state when virsh has nothing to destroy/undefine"
setup
export STUB_VIRSH_DESTROY_EXIT=1
export STUB_VIRSH_UNDEFINE_EXIT=1
touch "$VM_POOL/ghost.qcow2" "$VM_POOL/ghost-seed.iso"
OUT=$("$SCRIPT" ghost 2>&1); STATUS=$?
assert_eq "exits 0 even though the domain didn't exist" 0 "$STATUS"
assert_file_absent "still removes the disk" "$VM_POOL/ghost.qcow2"
assert_file_absent "still removes the seed" "$VM_POOL/ghost-seed.iso"
teardown

echo "vm-dispose: no pre-existing ssh config fragment doesn't error"
setup
touch "$VM_POOL/noconf.qcow2" "$VM_POOL/noconf-seed.iso"
OUT=$("$SCRIPT" noconf 2>&1); STATUS=$?
assert_eq "exits 0" 0 "$STATUS"
teardown

echo "vm-dispose: requires a name argument"
setup
OUT=$("$SCRIPT" 2>&1); STATUS=$?
assert_eq "exits non-zero" 1 "$STATUS"
assert_contains "prints usage" "$OUT" "usage"
teardown

finish
