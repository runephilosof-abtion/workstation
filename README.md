# Workstation

Reproducible, Ansible-managed setup for this machine. The first role, `dev-vms`,
provides Qubes-style per-project development VMs on KVM/libvirt so coding
agents (Claude Code etc.) run behind a hardware virtualization boundary instead
of a shared-kernel container.

## Threat model

An agent inside a project VM may run arbitrary hostile code, and may get root
inside that VM. Containment comes from:

- a separate guest kernel (KVM), not Linux namespaces
- **no shared filesystem** — the repo is cloned *inside* the VM; work comes
  back to the host only through git, where you review the diff before merging
- a dedicated SSH keypair (`~/.ssh/dev-vm`) used only toward dev VMs
- **host-enforced network egress**, independent of anything running inside
  the guest — see below

The host-side `git` never executes anything the VM wrote: hooks and config
changes arrive as reviewable diff, not as live files.

### Network egress

Anything enforced only *inside* a VM (its own nftables, iptables, a UID that's
"supposed to" have no network access) can be disabled by root inside that VM —
which is exactly the privilege level a hostile process might reach. So the
real enforcement point is the **host**, which the guest can't see or modify:

- Every VM's network interface carries a libvirt `nwfilter`
  (`vm-egress-lockdown`, defined in `roles/dev-vms/files/network-lockdown/`),
  attached automatically by `vm-new`. It default-denies egress except DNS to
  the gateway, NTP, SSH, and HTTP/HTTPS — and HTTP/HTTPS only to a squid proxy
  on the host (`192.168.122.1:3128`), not directly to the internet. It also
  blocks all traffic between VMs on the same libvirt network (no lateral
  movement from one project VM to another).
- Squid is domain-allowlisted (`roles/dev-vms/files/network-lockdown/allowed_domains.txt`)
  — apt, GitHub/Copilot, VS Code, Anthropic, etc. Add a domain there and
  re-run the playbook (`--tags system`) when new legitimate tooling needs
  reaching. Check `sudo tail -f /var/log/squid/access.log` on the host for
  `TCP_DENIED` entries to find what a VM tried to reach that isn't allowed.
- Inside a VM, `apt` and the shell environment are pre-configured
  (`http_proxy`/`https_proxy` in `/etc/environment`, `/etc/apt/apt.conf.d/95proxy`)
  to use that proxy — this is set up by `vm-new`'s cloud-init, not by the
  nwfilter, so a VM created before this existed needs it added by hand.
- **This is a backstop, not a substitute for per-project containment.** A
  project running something like a web server as its own dedicated low-priv
  system user (see `example-project`'s `vm-notes/` for a worked
  example: a `wpsrv` user with zero network access at the guest level, since
  the host can't tell WordPress's traffic apart from your own shell's by IP
  alone) still needs that set up inside the VM itself. The host layer catches
  what guest-level containment misses or has disabled; it can't replicate a
  UID-based split it has no visibility into.

Recovering a VM that's lost network reachability (e.g. after a live interface
change) sometimes needs `virsh shutdown` + `virsh start` rather than
`virsh reboot` (ACPI reboot isn't reliably handled by these images), or in
the worst case editing the disk offline with `virt-customize`/`virt-copy-out`
(`apt install libguestfs-tools`) while it's shut off. Avoid `virsh reset` —
it's equivalent to pulling power and risks filesystem corruption.

## Fresh install bootstrap

```sh
sudo apt install git ansible
git clone <this-repo> ~/repos/workstation
cd ~/repos/workstation
ansible-playbook site.yml -K
```

Log out and back in once after the first run so the `libvirt` group
membership takes effect.

Tasks are tagged `system` (needs root) and `user`. Without a sudo password
available (e.g. driven by an agent), the system half can run through a
polkit GUI prompt instead:

```sh
pkexec ansible-playbook -i inventory.ini site.yml --tags system -e dev_vms_user=$USER
ansible-playbook site.yml --tags user
```

## Daily use

```sh
vm-new myproject              # create a VM (options: --mem MB --vcpus N --disk SIZE)
ssh myproject                 # or connect VSCode via Remote-SSH to host "myproject"
vm-list                         # show every dev VM, its state, and its IP if running
vm-ip myproject               # refresh the SSH config entry if the DHCP lease changed
vm-dispose myproject          # destroy the VM and delete its disk
```

Inside the VM, clone the project over HTTPS (or a read-only deploy key) and
work there. Push to a branch; fetch and review on the host.

`vm-new` boots a copy-on-write overlay of a shared Debian template image, so
creation costs seconds and only the delta in disk. Node.js is installed by
cloud-init on first boot (`VM_NODE_MAJOR` env var overrides the version,
default 22).

## Layout

- `site.yml` — entry point; add future roles (packages, dotfiles, …) here
- `roles/dev-vms/` — virtualization packages, libvirt network, template image
  download, and the `vm-new`/`vm-dispose`/`vm-ip`/`vm-list` scripts
- `tests/` — test suite for those scripts (see below)

Paths (template dir, VM pool dir, SSH key) are defined in
`roles/dev-vms/defaults/main.yml`; the scripts in `roles/dev-vms/files/`
default to the same paths (overridable per-invocation via `VM_CONNECT`,
`VM_TEMPLATE`, and `VM_POOL`), so change both together.

## Tests

```sh
tests/run.sh
```

Runs `tests/test_*.sh` against `vm-new`/`vm-dispose`/`vm-ip`/`vm-list` with a stubbed
`virsh`/`qemu-img`/`cloud-localds`/`virt-install`/`ssh-keygen`
(`tests/fixtures/bin/`, put first on `PATH`) — no libvirt, KVM, or network
needed, and the real `qemu:///system` connection and `~/.ssh/known_hosts` are
never touched. Each stub logs its argv to `$STUB_LOG` so tests can assert
exactly what a script passed it (e.g. that a domain name goes through
`--domain` rather than positionally, where virsh would parse a flag-like name
as its own option instead of a domain).

```sh
tests/run-in-vm.sh
```

Runs the same suite inside a throwaway dev VM instead, for extra assurance
before trusting a change to the stubs themselves — the guest has no real
virsh/qemu-img to fall through to and no `~/.ssh/known_hosts` of its own to
lose. Slower (a couple of minutes, for VM boot) than `tests/run.sh`
(under a second), which stays the one to run while iterating.
