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
  # vm-new reads the host's git identity; keep the real ~/.gitconfig out of it.
  export GIT_CONFIG_GLOBAL=$SANDBOX/gitconfig GIT_CONFIG_NOSYSTEM=1
  touch "$GIT_CONFIG_GLOBAL"
  unset STUB_DOMIFADDR_IP STUB_VIRSH_DOMIFADDR_EXIT COMPOSER_HOME VM_COMPOSER_AUTH VM_CLAUDE_TOKEN
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

echo "vm-new: passes the Claude Code token into the VM's environment when present on host"
setup
export STUB_DOMIFADDR_IP=203.0.113.21
export STUB_USERDATA=$SANDBOX/user-data.rendered
mkdir -p "$HOME/.config/dev-vms" "$HOME/.claude"
echo 'sk-ant-oat01-stub' > "$HOME/.config/dev-vms/claude.token"
echo '{"stub":"creds"}' > "$HOME/.claude/.credentials.json"
OUT=$("$SCRIPT" claudevm 2>&1); STATUS=$?
assert_eq "exits 0" 0 "$STATUS"
USERDATA=$(cat "$STUB_USERDATA")
assert_contains "sets the token in /etc/environment" "$USERDATA" "      CLAUDE_CODE_OAUTH_TOKEN=sk-ant-oat01-stub"
assert_not_contains "never copies the host's rotating login session" "$USERDATA" ".claude/.credentials.json"
assert_contains "installs Claude Code as dev, so it can self-update" "$USERDATA" "su - dev -c 'curl -fsSL https://claude.ai/install.sh | bash'"
assert_not_contains "never installs Claude Code root-owned via npm" "$USERDATA" "npm install -g @anthropic-ai/claude-code"
[[ -e $VM_POOL/claudevm-seed.iso ]] && PERMS=$(stat -c%a "$VM_POOL/claudevm-seed.iso") || PERMS=missing
assert_eq "seed ISO is chmod 600 before libvirt touches it" "600" "$PERMS"
teardown

echo "vm-new: reads the Claude Code token from VM_CLAUDE_TOKEN"
setup
export STUB_DOMIFADDR_IP=203.0.113.29
export STUB_USERDATA=$SANDBOX/user-data.rendered
export VM_CLAUDE_TOKEN=$SANDBOX/other.token
echo 'sk-ant-oat01-other' > "$VM_CLAUDE_TOKEN"
OUT=$("$SCRIPT" claudeenvvm 2>&1); STATUS=$?
assert_eq "exits 0" 0 "$STATUS"
assert_contains "carries that file's token" "$(cat "$STUB_USERDATA")" "CLAUDE_CODE_OAUTH_TOKEN=sk-ant-oat01-other"
teardown

echo "vm-new: skips the Claude Code token when none exists on host"
setup
export STUB_DOMIFADDR_IP=203.0.113.22
export STUB_USERDATA=$SANDBOX/user-data.rendered
OUT=$("$SCRIPT" nocredsvm 2>&1); STATUS=$?
assert_eq "exits 0" 0 "$STATUS"
assert_contains "warns that login will be manual" "$OUT" "login run manually"
assert_contains "says how to create the token" "$OUT" "claude setup-token"
USERDATA=$(cat "$STUB_USERDATA")
assert_not_contains "never sets a token" "$USERDATA" "CLAUDE_CODE_OAUTH_TOKEN"
assert_not_contains "never references a Composer auth file" "$USERDATA" "composer/auth.json"
teardown

echo "vm-new: copies Composer auth into cloud-init when present on host"
setup
export STUB_DOMIFADDR_IP=203.0.113.23
export STUB_USERDATA=$SANDBOX/user-data.rendered
mkdir -p "$HOME/.config/composer"
echo '{"http-basic":{}}' > "$HOME/.config/composer/auth.json"
OUT=$("$SCRIPT" composervm 2>&1); STATUS=$?
assert_eq "exits 0" 0 "$STATUS"
USERDATA=$(cat "$STUB_USERDATA")
assert_contains "writes the auth file into the guest" "$USERDATA" "/home/dev/.config/composer/auth.json"
assert_contains "carries the host file's content" "$USERDATA" "$(base64 -w0 "$HOME/.config/composer/auth.json")"
assert_contains "fixes up ~/.config ownership afterwards" "$USERDATA" "chown -R dev:dev /home/dev/.config"
assert_contains "keeps asdf-php from moving COMPOSER_HOME off the copied file" "$USERDATA" "      COMPOSER_HOME=/home/dev/.config/composer"
teardown

echo "vm-new: reads Composer auth from the host's COMPOSER_HOME"
setup
export STUB_DOMIFADDR_IP=203.0.113.24
export STUB_USERDATA=$SANDBOX/user-data.rendered
export COMPOSER_HOME=$HOME/.asdf/installs/php/8.4.25/.composer
mkdir -p "$COMPOSER_HOME"
echo '{"http-basic":{"example.com":{}}}' > "$COMPOSER_HOME/auth.json"
OUT=$("$SCRIPT" composerhomevm 2>&1); STATUS=$?
assert_eq "exits 0" 0 "$STATUS"
USERDATA=$(cat "$STUB_USERDATA")
assert_contains "carries that file's content" "$USERDATA" "$(base64 -w0 "$COMPOSER_HOME/auth.json")"
teardown

echo "vm-new: says when there's no Composer auth to copy"
setup
export STUB_DOMIFADDR_IP=203.0.113.25
OUT=$("$SCRIPT" nocomposervm 2>&1); STATUS=$?
assert_eq "exits 0" 0 "$STATUS"
assert_contains "names the file it looked for" "$OUT" "no $HOME/.config/composer/auth.json on host"
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
assert_contains "defers the PAT write until the dev user exists" "$USERDATA" "    defer: true"
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

echo "vm-new: sets up the VM's own SSH key, git identity and GPG signing key"
setup
export STUB_DOMIFADDR_IP=203.0.113.25
export STUB_USERDATA=$SANDBOX/user-data.rendered
git config --global user.name "Ada O'Lovelace"
git config --global user.email ada@example.com
OUT=$("$SCRIPT" keysvm 2>&1); STATUS=$?
assert_eq "exits 0" 0 "$STATUS"
USERDATA=$(cat "$STUB_USERDATA")
assert_contains "installs gnupg" "$USERDATA" "  - gnupg"
assert_contains "runs the setup as the dev user" "$USERDATA" "su - dev -c vm-git-setup"
SETUP=$(awk '/path: \/usr\/local\/bin\/vm-git-setup/ { f = 1 } f && /content:/ { print $2; exit }' "$STUB_USERDATA" | base64 -d)
assert_contains "carries the host's git identity, shell-quoted" "$SETUP" "GIT_NAME=Ada\ O\'Lovelace GIT_EMAIL=ada@example.com"
assert_contains "generates a passphrase-less SSH key in the VM" "$SETUP" "ssh-keygen -q -t ed25519 -N ''"
assert_contains "generates an expiring per-VM GPG signing key" "$SETUP" "ed25519 sign 1y"
assert_contains "signs commits by default" "$SETUP" "commit.gpgsign true"
SETUP_FILE=$SANDBOX/vm-git-setup
printf '%s\n' "$SETUP" > "$SETUP_FILE"
bash -n "$SETUP_FILE"; assert_eq "setup script is valid bash" 0 "$?"
assert_contains "points at vm-keys" "$OUT" "vm-keys keysvm"
teardown

echo "vm-new: without a host git identity, still gives the VM an SSH key"
setup
export STUB_DOMIFADDR_IP=203.0.113.26
export STUB_USERDATA=$SANDBOX/user-data.rendered
OUT=$("$SCRIPT" noidvm 2>&1); STATUS=$?
assert_eq "exits 0" 0 "$STATUS"
assert_contains "says signing is skipped" "$OUT" "no git identity or GPG signing key"
assert_contains "still runs the setup" "$(cat "$STUB_USERDATA")" "su - dev -c vm-git-setup"
teardown

echo "vm-new: --copy-repos rejects a missing directory before creating anything"
setup
OUT=$("$SCRIPT" copyvm --copy-repos "$SANDBOX/missing" 2>&1); STATUS=$?
assert_eq "exits non-zero" 1 "$STATUS"
assert_contains "names the problem" "$OUT" "no such directory"
LOG=$(log_or_empty)
assert_not_contains "never creates a disk" "$LOG" "qemu-img"
teardown

echo "vm-new: --copy-repos waits for cloud-init, then runs vm-copy-repos"
setup
export STUB_DOMIFADDR_IP=203.0.113.27
mkdir -p "$SANDBOX/empty-repos"
OUT=$("$SCRIPT" copyvm --copy-repos "$SANDBOX/empty-repos" 2>&1); STATUS=$?
assert_eq "exits 0" 0 "$STATUS"
LOG=$(cat "$STUB_LOG")
assert_contains "waits for cloud-init in the VM" "$LOG" "ssh copyvm cloud-init status --wait"
assert_contains "runs vm-copy-repos" "$OUT" "done: 0 repos/worktrees copied into copyvm"
teardown

echo "vm-new: without --copy-repos, never touches the VM over ssh"
setup
export STUB_DOMIFADDR_IP=203.0.113.28
"$SCRIPT" plainvm >/dev/null 2>&1
LOG=$(cat "$STUB_LOG")
assert_not_contains "no ssh calls" "$LOG" "ssh plainvm"
teardown

finish
