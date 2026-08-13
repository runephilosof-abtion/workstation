# Workstation

Reproducible, Ansible-managed setup for this machine. The first role, `dev-vms`,
provides Qubes-style per-project development VMs on KVM/libvirt so coding
agents (Claude Code etc.) run behind a hardware virtualization boundary instead
of a shared-kernel container.

## Threat model

An agent inside a project VM may run arbitrary hostile code. Containment comes
from:

- a separate guest kernel (KVM), not Linux namespaces
- **no shared filesystem** — the repo is cloned *inside* the VM; work comes
  back to the host only through git, where you review the diff before merging
- a dedicated SSH keypair (`~/.ssh/dev-vm`) used only toward dev VMs

The host-side `git` never executes anything the VM wrote: hooks and config
changes arrive as reviewable diff, not as live files.

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
  download, and the `vm-new`/`vm-dispose`/`vm-ip` scripts

Paths (template dir, VM pool dir, SSH key) are defined in
`roles/dev-vms/defaults/main.yml`; the scripts in `roles/dev-vms/files/`
default to the same paths (overridable per-invocation via `VM_CONNECT`,
`VM_TEMPLATE`, and `VM_POOL`), so change both together.
