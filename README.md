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
  — apt, npm, GitHub/Copilot, VS Code, Anthropic, etc. Add a domain there and
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

### Copied credentials

`vm-new` can copy a Claude Code OAuth session and a GitHub PAT into a new VM
(see [Daily use](#daily-use)) so it comes up already authenticated. Both are
real exceptions to "no shared filesystem" above — deliberately, since the
project the VM exists to run needs *some* credential to reach Claude and
GitHub, and the alternative (typing a login/token into a VM by hand every
time) doesn't change the exposure, just the convenience. Mitigations:

- the GitHub PAT is meant to be a fine-grained token scoped to one repo, not
  your full account — a compromised VM can only affect what that repo's PAT
  permission grants, not every repo you can touch
- the seed ISO carrying both secrets is `chmod 600` right after it's built,
  though libvirt's storage driver may re-chown/re-mode it once attached
  (observed `0644 libvirt-qemu:libvirt-qemu` on this host) — worth verifying
  on a new host rather than assuming it holds
- once copied in, both are as exposed as anything else `vm-dispose` deletes
  with the VM: if a project turns out to need a fully untrusted VM, skip
  `--repo`/rely on no host `~/.claude` creds and authenticate by hand instead

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
pkexec ansible-playbook -i "$PWD/inventory.ini" "$PWD/site.yml" --tags system -e dev_vms_user=$USER
ansible-playbook site.yml --tags user
```

(`pkexec` doesn't reliably preserve the calling shell's working directory, so
`site.yml` and `inventory.ini` are passed as absolute paths here — expanded
by your shell before `pkexec` runs, from wherever you've cloned this repo.)

Re-run the same command(s) any time you pull changes to this repo (e.g. a
new domain in `allowed_domains.txt`, or an updated `vm-new` script) — the
playbook is idempotent, so it only touches what actually changed, and
restarts squid itself if the allowlist did.

## Daily use

```sh
vm-new myproject              # create a VM (options: --mem MB --vcpus N --disk SIZE)
vm-new ai --copy-repos ~/repos  # ...and copy every repo under ~/repos into it
ssh myproject                 # or connect VSCode via Remote-SSH to host "myproject"
vm-keys myproject             # print the VM's own SSH/GPG public keys, to add on GitHub
vm-copy-repos myproject ~/repos  # copy repos into an existing VM (skips ones already there)
vm-list                         # show every dev VM, its state, and its IP if running
vm-ip myproject               # refresh the SSH config entry if the DHCP lease changed
vm-dispose myproject          # destroy the VM and delete its disk
```

`vm-new` boots a copy-on-write overlay of a shared Debian template image, so
creation costs seconds and only the delta in disk. Node.js is installed by
cloud-init on first boot (`VM_NODE_MAJOR` env var overrides the version,
default 22), followed by `npm install -g @anthropic-ai/claude-code`.

Project runtimes come from [asdf](https://asdf-vm.com): cloud-init installs it
and the `nodejs` and `php` plugins, then sets the newest Node.js 24 and PHP 8.5
as the `dev` user's defaults in `~/.tool-versions` (override with
`VM_ASDF_NODEJS` / `VM_ASDF_PHP`, which take version prefixes; `VM_ASDF_VERSION`
pins asdf itself). A project's own `.tool-versions` takes precedence. PHP is
compiled from source, so first boot takes several minutes longer; follow it
with `ssh myproject cloud-init status --wait`. VMs created before this need the
same setup done by hand; the steps are the asdf parts of `vm-new`'s cloud-init.

`vm-new` also automates the rest of the setup that used to be manual:

- **VS Code extension**: once the VM has an IP, `vm-new` runs
  `code --remote ssh-remote+<name> --install-extension anthropic.claude-code`
  itself, so the extension is already installed by the time you connect. This
  needs the `code` CLI on your host `PATH` (VS Code: *Shell Command: Install
  'code' command in PATH*, once). If `code` isn't found, or the VM's sshd
  isn't up yet, it just prints a one-line command to run by hand.
- **Claude Code login**: if `~/.claude/.credentials.json` exists on the host,
  `vm-new` copies it into the VM (`/home/dev/.claude/.credentials.json`), so
  Claude Code is already logged in under your Claude.ai plan — no separate,
  metered API billing, since it's using your normal subscription session
  rather than an API key. **Tradeoff**: that session token now lives inside a
  VM whose whole point is to contain code that might be hostile, so treat it
  as within that VM's blast radius (same as the GitHub PAT below). If the
  file isn't present, `vm-new` says so and you run `claude` inside the VM to
  log in manually, same as before.
- **Cloning the project**: `vm-new myproject --repo <url>` clones the repo on
  first boot via `gh repo clone`, authenticated with a **fine-grained GitHub
  PAT scoped to just that repo** (not your full GitHub access) — mirroring
  the dedicated-keypair pattern already used for the dev-vm SSH key. Create
  one at github.com → Settings → Developer settings → Fine-grained tokens →
  repository access: only that repo → permission: Contents (read-only, or
  read/write if you want to `git push` from inside the VM), then save it
  where `vm-new` looks by default:
  ```sh
  mkdir -p ~/.config/dev-vms/tokens && chmod 700 ~/.config/dev-vms/tokens
  echo YOUR_TOKEN > ~/.config/dev-vms/tokens/myproject.token
  chmod 600 ~/.config/dev-vms/tokens/myproject.token
  vm-new myproject --repo git@github.com:you/myproject.git
  ```
  (or pass `--github-token-file` to use a different path). Without `--repo`,
  clone manually inside the VM over HTTPS or a read-only deploy key, same as
  before.
- **Git identity and keys**: on first boot every VM generates its own
  ed25519 SSH key and, if your host has `git config --global user.name` and
  `user.email`, a GPG signing key (`Name (vm-name) <email>`, expiring after
  one year), and sets git up to commit as you and sign commits and tags. The
  private keys never exist on the host. Run `vm-keys <name>` to print the
  public halves and add them at GitHub → Settings → SSH and GPG keys; delete
  them there to cut the VM off. They have **no passphrase** on purpose: the AI
  uses them unattended, and an unlocked agent is as usable to it as an
  unencrypted key, so the passphrase wouldn't keep it out. What keeps the VM
  out of production is GitHub-side: protect the branches that deploy
  (required PR review, no force-push), since the key can push anywhere your
  account can. Outbound SSH (port 22) is allowed by the egress filter, so the
  usual `git@github.com:` remotes work.
- **Copying existing repos** (optional): `vm-new <name> --copy-repos ~/repos`,
  or `vm-copy-repos <name> ~/repos` for a VM that already exists, puts every
  git repo up to three levels under that directory at the same relative path
  under `/home/dev/repos`. Copied: all local branches (including unpushed
  ones), tags, remote-tracking refs and remote URLs; the branch or commit
  you have checked out; worktrees; uncommitted changes to tracked files; and
  `.env`/`.env.*` files (treated as dev settings). **Not** copied: any other
  untracked or ignored file (keys, DB dumps, `auth.json`, `node_modules`, ...),
  directories that aren't git repos, and submodule contents (run
  `git submodule update --init` in the VM). Secrets that are *committed* to a
  repo still come along with its history. Repos already in the VM are
  skipped, so re-running it only adds new ones; host git hooks never run.

Push to a branch from inside the VM; fetch and review on the host.

## Layout

- `site.yml` — entry point; add future roles (packages, dotfiles, …) here
- `roles/dev-vms/` — virtualization packages, libvirt network, template image
  download, and the `vm-new`/`vm-dispose`/`vm-ip`/`vm-list`/`vm-keys`/
  `vm-copy-repos` scripts
- `tests/` — test suite for those scripts (see below)

Paths (template dir, VM pool dir, SSH key) are defined in
`roles/dev-vms/defaults/main.yml`; the scripts in `roles/dev-vms/files/`
default to the same paths (overridable per-invocation via `VM_CONNECT`,
`VM_TEMPLATE`, and `VM_POOL`), so change both together.

## Tests

```sh
tests/run.sh
```

Runs `tests/test_*.sh` against `vm-new`/`vm-dispose`/`vm-ip`/`vm-list`/`vm-copy-repos` with a stubbed
`virsh`/`qemu-img`/`cloud-localds`/`virt-install`/`ssh-keygen`/`ssh`
(`tests/fixtures/bin/`, put first on `PATH`; the fake `ssh` runs the "remote"
command locally when `STUB_SSH_EXEC=1`, which is how `vm-copy-repos`' git
pushes are tested against a sandbox directory) — no libvirt, KVM, or network
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

```sh
tests/run-integration-in-vm.sh
```

Real, unstubbed integration test: provisions the actual dev-vms role (real
libvirt/KVM, real squid+nwfilter) inside a *nested* throwaway VM
(`vm-new --nested`, needing host CPU/kernel support for nested
virtualization), then runs the real `vm-new`/`vm-dispose` against it —
booting and disposing an actual inner VM, not stub argument shapes. The
template image is seeded from the host's own cached copy (with a checksum
computed from that same copy) rather than downloaded again, since the real
download redirects to whichever Debian mirror it picks, which the squid
allowlist can't practically enumerate in advance. Slow (10+ minutes: nested
boot, full package install, an actual inner VM boot) and heavier (two levels
of VM) — for validating real libvirt/virsh behavior before trusting a change
to `vm-new`/`vm-dispose`/`vm-ip` themselves, not for routine iteration.
