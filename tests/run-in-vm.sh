#!/usr/bin/env bash
# Runs the test suite inside a throwaway dev VM instead of on the host.
#
# tests/run.sh is already hermetic on its own (stubs virsh/qemu-img/cloud-localds/
# virt-install/ssh-keygen, sandboxes HOME/VM_POOL — see tests/fixtures/bin/ and
# README's Tests section). This wrapper adds a second, independent layer: even if
# a stub were wrong or PATH ordering broke somehow, there is no real virsh/qemu-img
# binary inside the guest to fall through to, and no real ~/.ssh/known_hosts or
# /var/log/libvirt/qemu belonging to the host user to touch. The VM is disposed
# unconditionally on exit, so nothing it did survives either.
#
# Costs a couple of minutes (VM boot) instead of under a second — use tests/run.sh
# for day-to-day iteration and this for extra assurance (e.g. before trusting a
# change to the stubs themselves).
set -euo pipefail
cd "$(dirname "$0")/.."

VM=wstest-$$
echo "Creating throwaway VM '$VM'..."
vm-new "$VM" --mem 2048 --vcpus 2 --disk 10G

cleanup() {
  echo "Disposing '$VM'..."
  vm-dispose "$VM" >/dev/null 2>&1 || true
}
trap cleanup EXIT

echo "Waiting for SSH..."
for _ in $(seq 30); do
  ssh -o ConnectTimeout=2 -o BatchMode=yes "$VM" true 2>/dev/null && break
  sleep 2
done

echo "Copying the repo into '$VM'..."
tar cf - --exclude=.git . | ssh "$VM" 'rm -rf ~/workstation && mkdir ~/workstation && tar xf - -C ~/workstation'

echo "Running tests inside '$VM'..."
ssh "$VM" 'bash ~/workstation/tests/run.sh'
