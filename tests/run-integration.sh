#!/usr/bin/env bash
# Real, unstubbed checks of vm-new/vm-dispose against this machine's own
# libvirt: boots an actual VM, reaches it over SSH and disposes it again.
#
# Needs the dev-vms role provisioned here (site.yml), so it belongs on a
# machine made for the purpose: tests/run-integration-in-vm.sh builds a nested
# throwaway VM and runs this inside it, and CI runs it directly on the runner,
# which is a throwaway machine already.
set -euo pipefail

CONNECT=${VM_CONNECT:-qemu:///system}
POOL=${VM_POOL:-/var/lib/libvirt/images/dev-vms}
VM=integtest
# A non-interactive shell has not sourced ~/.profile, which is what normally
# puts ~/.local/bin (where the role installs vm-new/vm-dispose) on PATH.
PATH=$HOME/.local/bin:$PATH

fail() { echo "  FAIL - $1" >&2; exit 1; }
listed() { virsh --connect "$CONNECT" list --all --name | grep -qx "$VM"; }

if listed; then
  echo "A VM named '$VM' already exists here; not touching it." >&2
  exit 1
fi
trap 'vm-dispose "$VM" >/dev/null 2>&1 || true' EXIT

echo "Running the real vm-new..."
vm-new "$VM" --mem 1024 --vcpus 1 --disk 5G

echo "Verifying the VM is real (listed in libvirt, reachable over SSH)..."
listed || fail "'$VM' is not defined in libvirt"
# vm-new only waits for a DHCP lease, not for sshd inside the guest to finish starting.
reachable=0
for _ in $(seq 30); do
  if ssh -o ConnectTimeout=2 -o BatchMode=yes "$VM" true 2>/dev/null; then reachable=1; break; fi
  sleep 2
done
[[ $reachable == 1 ]] || fail "'$VM' is not reachable over SSH"
echo "  ok - VM is defined in libvirt and reachable over SSH"

echo "Running the real vm-dispose..."
vm-dispose "$VM"

echo "Verifying vm-dispose actually cleaned up the VM..."
if listed; then fail "'$VM' is still defined in libvirt"; fi
for leftover in "$POOL/$VM.qcow2" "/var/log/libvirt/qemu/$VM.log" "$HOME/.ssh/dev-vms.d/$VM.conf"; do
  [[ ! -e $leftover ]] || fail "$leftover is still there"
done
echo "  ok - domain, disk, qemu log, and ssh config are all gone"

echo "All integration checks passed."
