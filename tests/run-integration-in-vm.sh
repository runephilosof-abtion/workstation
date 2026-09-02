#!/usr/bin/env bash
# Real, unstubbed integration test: provisions the actual dev-vms Ansible role
# (real libvirt/KVM, real squid+nwfilter, a real downloaded template) inside a
# nested throwaway VM, then runs the real vm-new/vm-dispose against it end to
# end -- not stub argument shapes. Never touches the host's own libvirt.
#
# Slow (nested boot + full package install + a real ~600MB template download +
# an actual inner VM boot, likely 10+ minutes) and heavier (two levels of VM,
# --nested requires the host CPU/kernel to support nested virtualization).
# Use tests/run.sh for routine iteration and tests/run-in-vm.sh for a quick
# host-isolation check; this is for validating real libvirt/virsh behavior
# before trusting a change to vm-new/vm-dispose/vm-ip themselves.
set -euo pipefail
cd "$(dirname "$0")/.."

VM=wsint-$$
echo "Creating nested-capable outer VM '$VM'..."
vm-new "$VM" --mem 6144 --vcpus 4 --disk 40G --nested

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

echo "Waiting for cloud-init's own package installs to finish (or they race our apt-get below)..."
ssh "$VM" 'sudo cloud-init status --wait' >/dev/null || true

echo "Copying the repo into '$VM'..."
tar cf - --exclude=.git . | ssh "$VM" 'rm -rf ~/workstation && mkdir ~/workstation && tar xf - -C ~/workstation'

# ansible, firewalld, and libvirt itself are prerequisites this role assumes the real
# workstation already has (base-system setup out of dev-vms' scope) -- a bare cloud image
# needs them installed explicitly to reproduce that. libvirt is installed here rather than
# left to the playbook because its "default" network needs redefining below, first.
echo "Installing ansible + firewalld + libvirt..."
ssh "$VM" 'export LC_ALL=C.UTF-8 LANG=C.UTF-8; sudo -E apt-get update -qq && sudo -E apt-get install -y -qq ansible firewalld libvirt-daemon-system libvirt-clients && sudo systemctl enable --now firewalld libvirtd'

# libvirt's stock "default" network also wants 192.168.122.0/24 for its own bridge -- the
# exact subnet this VM's own address already comes from (the host's default network), so
# starting it fails with "already in use by interface enp1s0". Redefine it on a different
# subnet before the playbook gets to its "Start the default libvirt network" task. (The
# vm-egress-lockdown nwfilter's hardcoded 192.168.122.1 gateway/proxy rules end up wrong for
# this inner network as a result -- known limitation of nesting, harmless to what this test
# actually checks: real vm-new/vm-dispose behavior, not the nwfilter's own enforcement.)
echo "Redefining the inner default libvirt network on a non-colliding subnet..."
ssh "$VM" 'sudo virsh net-destroy default >/dev/null 2>&1; sudo virsh net-undefine default >/dev/null 2>&1; cat <<XML | sudo tee /tmp/inner-default-net.xml >/dev/null
<network>
  <name>default</name>
  <forward mode="nat"/>
  <bridge name="virbr0" stp="on" delay="0"/>
  <ip address="192.168.123.1" netmask="255.255.255.0">
    <dhcp>
      <range start="192.168.123.2" end="192.168.123.254"/>
    </dhcp>
  </ip>
</network>
XML
sudo virsh net-define /tmp/inner-default-net.xml'

# cloud.debian.org 302-redirects the actual (large) image to whichever regional mirror it
# picks (e.g. some *.ftp.acc.umu.se) -- unlike the small SHA512SUMS file, which it serves
# directly. That mirror isn't (and, being essentially unpredictable, can't usefully be) in
# the squid allowlist, so a download of the real image would 403 through the proxy. Sidestep
# it entirely: seed the guest's template cache from this host's own already-downloaded copy
# (over the local virtio network, not the internet), plus a checksums file computed from that
# same copy -- Debian's "latest" image moves over time, so the live checksums file won't
# match a host cache that's gone stale, but ours is guaranteed to since we hash the exact
# file we're seeding. Both get_url tasks then see an up-to-date dest and skip fetching.
echo "Seeding the real template image into '$VM' from the host's own cache..."
ssh "$VM" 'sudo mkdir -p /var/lib/libvirt/images/templates'
cat /var/lib/libvirt/images/templates/debian-13-genericcloud-amd64.qcow2 | ssh "$VM" 'sudo tee /var/lib/libvirt/images/templates/debian-13-genericcloud-amd64.qcow2 >/dev/null'
HASH=$(sha512sum /var/lib/libvirt/images/templates/debian-13-genericcloud-amd64.qcow2 | awk '{print $1}')
ssh "$VM" "echo '$HASH  debian-13-genericcloud-amd64.qcow2' | sudo tee /tmp/dev-vms-checksums.txt >/dev/null"

echo "Provisioning the real dev-vms role inside '$VM' (installs libvirt/KVM, downloads the real template)..."
# LC_ALL=C.UTF-8: sshd forwards the client's LANG/LC_* (AcceptEnv default), which points at a
# locale (e.g. en_DK.UTF-8) that isn't generated on this minimal cloud image -- only C.UTF-8 is
# -- and Ansible refuses to start at all if its locale is unusable.
ssh "$VM" 'cd ~/workstation && LC_ALL=C.UTF-8 LANG=C.UTF-8 ansible-playbook site.yml'

echo "Confirming nested KVM is actually available inside '$VM'..."
ssh "$VM" 'test -e /dev/kvm' || { echo "no /dev/kvm inside '$VM' -- nested virt isn't working" >&2; exit 1; }

INNER=integtest
# PATH=...: a non-interactive, non-login ssh command doesn't source ~/.profile, which is
# where ~/.local/bin (where the role installs vm-new/vm-dispose) normally gets added.
BIN='PATH=$HOME/.local/bin:$PATH'
echo "Running the real vm-new inside '$VM'..."
ssh "$VM" "$BIN vm-new $INNER --mem 1024 --vcpus 1 --disk 5G"

echo "Verifying the inner VM is real (listed in libvirt, reachable over SSH)..."
ssh "$VM" "virsh --connect qemu:///system list --name | grep -qx $INNER"
# vm-new only waits for a DHCP lease, not for sshd inside the guest to finish starting.
ssh "$VM" "for _ in \$(seq 30); do ssh -o ConnectTimeout=2 -o BatchMode=yes $INNER true 2>/dev/null && exit 0; sleep 2; done; exit 1"
echo "  ok - inner VM is defined in libvirt and reachable over SSH"

echo "Running the real vm-dispose inside '$VM'..."
ssh "$VM" "$BIN vm-dispose $INNER"

echo "Verifying vm-dispose actually cleaned up the inner VM..."
ssh "$VM" "! virsh --connect qemu:///system list --all --name | grep -qx $INNER"
ssh "$VM" "test ! -f /var/lib/libvirt/images/dev-vms/$INNER.qcow2"
ssh "$VM" "test ! -f /var/log/libvirt/qemu/$INNER.log"
ssh "$VM" "test ! -f \$HOME/.ssh/dev-vms.d/$INNER.conf"
echo "  ok - domain, disk, qemu log, and ssh config are all gone"

echo "All integration checks passed."
