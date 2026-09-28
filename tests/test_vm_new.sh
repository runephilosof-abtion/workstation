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

echo "vm-new: copies Claude Code credentials into cloud-init when present on host"
setup
export STUB_DOMIFADDR_IP=203.0.113.21
export STUB_USERDATA=$SANDBOX/user-data.rendered
mkdir -p "$HOME/.claude"
echo '{"stub":"creds"}' > "$HOME/.claude/.credentials.json"
OUT=$("$SCRIPT" claudevm 2>&1); STATUS=$?
assert_eq "exits 0" 0 "$STATUS"
USERDATA=$(cat "$STUB_USERDATA")
assert_contains "writes the credentials file into the guest" "$USERDATA" "/home/dev/.claude/.credentials.json"
assert_contains "owns it as the dev user" "$USERDATA" "owner: dev:dev"
assert_contains "fixes up ~/.claude ownership afterwards" "$USERDATA" "chown -R dev:dev /home/dev/.claude"
[[ -e $VM_POOL/claudevm-seed.iso ]] && PERMS=$(stat -c%a "$VM_POOL/claudevm-seed.iso") || PERMS=missing
assert_eq "seed ISO is chmod 600 before libvirt touches it" "600" "$PERMS"
teardown

echo "vm-new: skips Claude credentials when none exist on host"
setup
export STUB_DOMIFADDR_IP=203.0.113.22
export STUB_USERDATA=$SANDBOX/user-data.rendered
OUT=$("$SCRIPT" nocredsvm 2>&1); STATUS=$?
assert_eq "exits 0" 0 "$STATUS"
assert_contains "warns that login will be manual" "$OUT" "login run manually"
USERDATA=$(cat "$STUB_USERDATA")
assert_not_contains "never references a credentials file" "$USERDATA" ".claude/.credentials.json"
teardown

echo "vm-new: requires a GitHub token file when --repo is given"
setup
OUT=$("$SCRIPT" needstoken --repo org/repo 2>&1); STATUS=$?
assert_eq "exits non-zero" 1 "$STATUS"
assert_contains "explains how to create the scoped PAT" "$OUT" "fine-grained PAT"
LOG=$(log_or_empty)
assert_not_contains "never gets as far as creating a disk" "$LOG" "qemu-img"
teardown

echo "vm-new: clones the repo via a scoped GitHub PAT when --repo is given"
setup
export STUB_DOMIFADDR_IP=203.0.113.23
export STUB_USERDATA=$SANDBOX/user-data.rendered
TOKEN_FILE=$SANDBOX/repo.token
echo "stub-pat-value" > "$TOKEN_FILE"
OUT=$("$SCRIPT" repovm --repo git@github.com:acme/widgets.git --github-token-file "$TOKEN_FILE" 2>&1); STATUS=$?
assert_eq "exits 0" 0 "$STATUS"
USERDATA=$(cat "$STUB_USERDATA")
assert_contains "writes the PAT into the guest" "$USERDATA" "/home/dev/.github-token"
assert_contains "installs the gh CLI" "$USERDATA" "apt-get install -y gh"
assert_contains "logs gh in with the token, not a password" "$USERDATA" "gh auth login --with-token"
assert_contains "clones the given repo" "$USERDATA" "gh repo clone git@github.com:acme/widgets.git /home/dev/work/widgets"
assert_contains "removes the token file after use" "$USERDATA" "rm -f /home/dev/.github-token"
teardown

echo "vm-new: installs the Claude Code VS Code extension over Remote-SSH"
setup
export STUB_DOMIFADDR_IP=203.0.113.24
OUT=$("$SCRIPT" codevm 2>&1); STATUS=$?
assert_eq "exits 0" 0 "$STATUS"
LOG=$(cat "$STUB_LOG")
assert_contains "targets the right ssh-remote alias" "$LOG" "--remote ssh-remote+codevm"
assert_contains "installs the Claude Code extension id" "$LOG" "--install-extension anthropic.claude-code"
assert_contains "reports success" "$OUT" "extension installed"
teardown

finish
