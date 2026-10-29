#!/usr/bin/env bash
set -uo pipefail
cd "$(dirname "$0")"
source lib/assert.sh

REPO_ROOT=$(cd .. && pwd)
SCRIPT=$REPO_ROOT/roles/dev-vms/files/vm-copy-repos
FIXTURES=$(pwd)/fixtures/bin

setup() {
  SANDBOX=$(mktemp -d)
  export HOME=$SANDBOX/home
  export STUB_LOG=$SANDBOX/stub.log
  export PATH=$FIXTURES:$PATH
  # The fake ssh runs "remote" commands locally, so the VM's repos land here.
  export STUB_SSH_EXEC=1
  export VM_REPOS_DEST=$SANDBOX/vm/repos
  export GIT_CONFIG_GLOBAL=$SANDBOX/gitconfig GIT_CONFIG_NOSYSTEM=1
  export GIT_AUTHOR_NAME=Test GIT_AUTHOR_EMAIL=test@example.com
  export GIT_COMMITTER_NAME=Test GIT_COMMITTER_EMAIL=test@example.com
  mkdir -p "$HOME" "$VM_REPOS_DEST"
  touch "$GIT_CONFIG_GLOBAL"
  SRC=$SANDBOX/repos
  make_host_repos
}

teardown() { rm -rf "$SANDBOX"; }

# A host ~/repos with: a repo on a branch with uncommitted tracked changes, a
# second branch, a tag, an origin remote, gitignored .env/secret files and a
# worktree; plus a nested repo with a detached HEAD.
make_host_repos() {
  local app=$SRC/app
  mkdir -p "$app"
  git -C "$app" init -q -b main
  printf '.env\n*.key\nnode_modules/\n' > "$app/.gitignore"
  echo one > "$app/file.txt"
  echo two > "$app/staged.txt"
  git -C "$app" add -A && git -C "$app" commit -qm first
  git -C "$app" tag v1
  git -C "$app" branch feature
  git -C "$app" remote add origin git@github.com:acme/app.git
  git -C "$app" update-ref refs/remotes/origin/main HEAD
  echo changed > "$app/file.txt"
  echo staged-change > "$app/staged.txt" && git -C "$app" add staged.txt
  echo 'DEV_VAR=1' > "$app/.env"
  echo 'PRIVATE' > "$app/prod.key"
  mkdir -p "$app/node_modules/pkg" && echo 'X=1' > "$app/node_modules/pkg/.env"
  printf '#!/bin/sh\ntouch %q\n' "$SANDBOX/pre-push-ran" > "$app/.git/hooks/pre-push"
  chmod +x "$app/.git/hooks/pre-push"

  git -C "$app" worktree add -q "$SRC/app.worktrees/feat" feature
  echo wt-change > "$SRC/app.worktrees/feat/file.txt"
  echo 'WT_VAR=1' > "$SRC/app.worktrees/feat/.env"

  local lib=$SRC/group/lib
  mkdir -p "$lib"
  git -C "$lib" init -q -b main
  echo a > "$lib/a" && git -C "$lib" add a && git -C "$lib" commit -qm a
  echo b > "$lib/b" && git -C "$lib" add b && git -C "$lib" commit -qm b
  git -C "$lib" checkout -q --detach HEAD~1

  mkdir -p "$SRC/not-a-repo" && echo 'TOKEN=x' > "$SRC/not-a-repo/.env"
}

echo "vm-copy-repos: requires a name and a directory"
SANDBOX=$(mktemp -d)
OUT=$("$SCRIPT" onlyname 2>&1); STATUS=$?
assert_eq "exits non-zero" 1 "$STATUS"
assert_contains "prints usage" "$OUT" "usage"
OUT=$("$SCRIPT" vm "$SANDBOX/missing" 2>&1); STATUS=$?
assert_eq "exits non-zero for a missing directory" 1 "$STATUS"
assert_contains "names the missing directory" "$OUT" "no such directory"
rm -rf "$SANDBOX"

echo "vm-copy-repos: copies committed git content, checkouts, worktrees and uncommitted tracked changes"
setup
OUT=$("$SCRIPT" testvm "$SRC" 2>&1); STATUS=$?
assert_eq "exits 0" 0 "$STATUS"
assert_contains "reports the result" "$OUT" "done: 3 repos/worktrees copied"
DST=$VM_REPOS_DEST
assert_eq "same branch checked out" "main" "$(git -C "$DST/app" symbolic-ref --short HEAD)"
assert_eq "same commit" "$(git -C "$SRC/app" rev-parse HEAD)" "$(git -C "$DST/app" rev-parse HEAD)"
assert_contains "other local branches come along" "$(git -C "$DST/app" branch --format='%(refname:short)')" "feature"
assert_eq "tags come along" "v1" "$(git -C "$DST/app" tag)"
assert_eq "remote-tracking refs come along" "$(git -C "$SRC/app" rev-parse origin/main)" "$(git -C "$DST/app" rev-parse origin/main)"
assert_eq "remote URLs match the host's" "git@github.com:acme/app.git" "$(git -C "$DST/app" remote get-url origin)"
assert_eq "unstaged tracked change applied" "changed" "$(cat "$DST/app/file.txt")"
assert_eq "staged tracked change applied" "staged-change" "$(cat "$DST/app/staged.txt")"
assert_eq "placeholder branch left no trace" "" "$(git -C "$DST/app" branch --list __vm_copy_repos__)"
assert_eq "worktree on its branch" "feature" "$(git -C "$DST/app.worktrees/feat" symbolic-ref --short HEAD)"
assert_eq "worktree change applied" "wt-change" "$(cat "$DST/app.worktrees/feat/file.txt")"
assert_eq "nested repo keeps its detached HEAD" "$(git -C "$SRC/group/lib" rev-parse HEAD)" "$(git -C "$DST/group/lib" rev-parse HEAD)"
assert_file_absent "host pre-push hook never runs" "$SANDBOX/pre-push-ran"
teardown

echo "vm-copy-repos: copies .env files but no other untracked files"
setup
"$SCRIPT" testvm "$SRC" >/dev/null 2>&1
DST=$VM_REPOS_DEST
assert_eq "repo .env copied" "DEV_VAR=1" "$(cat "$DST/app/.env" 2>/dev/null)"
assert_eq "worktree .env copied" "WT_VAR=1" "$(cat "$DST/app.worktrees/feat/.env" 2>/dev/null)"
assert_file_absent "other untracked files stay on the host" "$DST/app/prod.key"
assert_file_absent "node_modules is skipped" "$DST/app/node_modules"
assert_file_absent "directories that aren't repos are skipped" "$DST/not-a-repo"
teardown

echo "vm-copy-repos: re-running skips repos already in the VM and keeps their .env"
setup
"$SCRIPT" testvm "$SRC" >/dev/null 2>&1
echo 'EDITED_IN_VM=1' > "$VM_REPOS_DEST/app/.env"
git -C "$SRC" init -q -b main newrepo
echo n > "$SRC/newrepo/n" && git -C "$SRC/newrepo" add n && git -C "$SRC/newrepo" commit -qm n
OUT=$("$SCRIPT" testvm "$SRC" 2>&1); STATUS=$?
assert_eq "exits 0" 0 "$STATUS"
assert_contains "skips the existing repo" "$OUT" "skip app (already in VM)"
assert_contains "skips the existing worktree" "$OUT" "skip worktree app.worktrees/feat (already in VM)"
assert_contains "copies only the new repo" "$OUT" "done: 1 repos/worktrees copied"
assert_eq "new repo arrives" "$(git -C "$SRC/newrepo" rev-parse HEAD)" "$(git -C "$VM_REPOS_DEST/newrepo" rev-parse HEAD)"
assert_eq "VM-side .env not overwritten" "EDITED_IN_VM=1" "$(cat "$VM_REPOS_DEST/app/.env")"
teardown

finish
