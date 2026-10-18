# Portage (profile, make.conf, sets)

> Everything the target's `/etc/portage` must say before a single package is
> built: the profile that matches your init system and flavour, a `make.conf`
> computed for this machine, the ebuild tree, and the package set to install.
> This mirrors `steps/60_portage.sh` and the files under `data/`.

## What the installer does

`step_60_portage` runs entirely **inside the chroot** (chapter 07). It declares
the `gentoo` repository, syncs the ebuild tree, selects the Portage profile that
matches your `--flavour`, `--init` and `--arch` from `data/profiles.tsv`, writes
a managed block in `make.conf` (with a `MAKEOPTS` computed from this machine's
cores *and* memory), creates the three per-package directories under
`/etc/portage`, resolves a package set from `data/packages/sets.tsv` and the
`.list` files it names, writes that set, and emerges it.

The end state is a configured Portage: a profile symlink, a validated
`make.conf`, a synced tree, and a base set of packages installed. Nothing here
builds for a CPU you did not name, accepts a license you did not accept, or
installs a desktop you did not ask for.

Every command below runs inside the chroot, so each block is marked `# chroot`.

## Concepts

**The profile is the distribution's opinion.** A Gentoo profile
(`default/linux/amd64/23.0` and its variants) sets a baseline of USE flags,
masks, and defaults. It has to agree with the stage3 you unpacked: an OpenRC
stage wants an OpenRC profile, a systemd stage a systemd profile.
`data/profiles.tsv` maps each `(flavour, init, arch)` triple to the exact name
`eselect profile set` takes. Two rows carry a USE delta the profile genuinely
leaves undone: an OpenRC desktop needs `elogind` for seat management, and a
systemd desktop needs `-elogind` so it does not collide with the `logind` that
systemd already provides.

**The profile is proven before it is set.** `eselect profile set` on a name the
tree does not carry says only "invalid profile", unhelpfully, three steps into an
install. So the installer checks that the profile *directory* exists in the
synced tree first, and falls back through the older names in the `fallbacks`
column (the 17.x profiles still live in pre-2023 snapshots) before giving up with
a message that names every candidate it tried.

**`make.conf` is a delta, not a replacement.** USE in `make.conf` adds to what
the profile already decided; it does not restate it. The installer writes a
*marked block* in `make.conf`, so a re-run replaces only its own region and
leaves anything you added outside the markers alone. It then hands the file to
`emerge --info`, which parses `make.conf`, the profile and every repository
before printing a line, and rolls the file back if Portage refuses it. One
unbalanced quote there would make every later `emerge` fail with a parse error
that names no file at all.

**Why `MAKEOPTS` is computed, not copied.** `-j` equal to the core count is the
advice everyone repeats, and it is how a 32-core machine with 8 GiB of RAM gets
a compiler killed by the OOM killer halfway through linking the kernel, with no
error worth reading. A parallel link job wants roughly 2 GiB (rust, llvm and
webkit all do), so the memory budget and the core count are both ceilings and
the smaller one wins. Swap counts toward the memory budget.

**Two ways to get the tree.** `emerge-webrsync` fetches one signed daily
snapshot over HTTPS and checks its GPG signature; it is faster on a fresh
install and crosses an HTTP proxy. `emerge --sync` speaks rsync to a mirror and
gives the tree as of an hour ago, but rsync's port 873 is routinely dropped by
firewalls and hotel networks. The installer defaults to `webrsync`.

## Do it by hand

You are inside the chroot, with name resolution working (chapter 07).

### 1. Declare the repository and sync the tree

```bash
# chroot
mkdir -p /etc/portage/repos.conf
cp /usr/share/portage/config/repos.conf /etc/portage/repos.conf/gentoo.conf
emerge-webrsync        # the signed HTTPS snapshot; or: emerge --sync
```

Copying the stage3's `repos.conf` into `/etc/portage` makes the declaration
yours; the copy under `/usr/share` would be overwritten by the next Portage
upgrade. The installer skips the sync if the tree is younger than 24 hours.

### 2. Select the profile

List what the synced tree actually offers, then set the one that matches your
init and flavour. For the default OpenRC base system:

```bash
# chroot
eselect profile list
eselect profile set default/linux/amd64/23.0
```

For base + systemd it is `default/linux/amd64/23.0/systemd`; for an OpenRC
desktop, `default/linux/amd64/23.0/desktop`; and so on down `data/profiles.tsv`.
The DE-specific profiles (`.../desktop/plasma`, `.../desktop/gnome`) are a choice
the table does not make for you; name one by hand if you want it. Confirm what
`make.profile` now points at:

```bash
# chroot
eselect profile show
```

### 3. Compute MAKEOPTS

Take the smaller of your core count and your memory budget:

```bash
# chroot
nproc                                                      # cores, e.g. 8
awk '/MemTotal|SwapTotal/{s+=$2} END{print int(s/1024/2048)}' /proc/meminfo
#   (RAM+swap in MiB) / 2048 MiB-per-job, e.g. 7
```

With 8 cores and a budget of 7 jobs, memory is the ceiling, so `MAKEOPTS="-j7"`.
With 8 cores and a 32-job budget, cores win and it is `-j8`. The installer shows
this arithmetic so a number you disagree with is at least one you can see.

### 4. Write make.conf

Edit `/etc/portage/make.conf` and set the baseline. These are the installer's
defaults; adjust them with intent:

```bash
# chroot - /etc/portage/make.conf
COMMON_FLAGS="-O2 -pipe"
CFLAGS="${COMMON_FLAGS}"
CXXFLAGS="${COMMON_FLAGS}"
FCFLAGS="${COMMON_FLAGS}"
FFLAGS="${COMMON_FLAGS}"
MAKEOPTS="-j7"                       # from step 3
USE=""                               # a delta on top of the profile
ACCEPT_LICENSE="-* @FREE"            # free software only; grant the rest per package
GRUB_PLATFORMS="efi-64"              # "pc" on a BIOS machine
PORTAGE_TMPDIR="/var/tmp"            # inside the target, where a 20 GiB build has room
EMERGE_DEFAULT_OPTS="--verbose --with-bdeps=y --complete-graph=y --nospinner"
```

Re-assign `CFLAGS` and friends to `${COMMON_FLAGS}` *here*, below your
`COMMON_FLAGS`. A stage3's own `make.conf` sets `CFLAGS="${COMMON_FLAGS}"`
*above* where you are editing, so a `COMMON_FLAGS` set lower down would never
reach them. `VIDEO_CARDS` is left to the profile unless you know your card
(for example `VIDEO_CARDS="amdgpu radeonsi"`). This chapter sets a working
baseline; for the full tour of each knob (`-march=native`, `FEATURES`,
`CPU_FLAGS_X86`, license policy), see the sibling Post-Install Handbook's
*Tuning make.conf* chapter.

**Warning:** Validate before you rely on it. One unbalanced quote breaks every later
`emerge`:

```bash
# chroot
emerge --info >/dev/null && echo "make.conf parses"
```

The installer does exactly this and restores its backup if `emerge --info`
refuses the file.

### 5. Create the per-package directories

Keep these as *directories* of drop-in files, one subject per file, so two
changes never collide in a diff:

```bash
# chroot
mkdir -p /etc/portage/package.use \
         /etc/portage/package.accept_keywords \
         /etc/portage/package.license
```

`package.license` is where you lift the global `ACCEPT_LICENSE="-* @FREE"` for
one package at a time. `linux-firmware`, for instance, needs the
`@BINARY-REDISTRIBUTABLE` group; the installer reads that grant out of the
`# LICENCE: needs ...` comment beside the atom in the package list, so the grant
and its reason live in one place:

```bash
# chroot - /etc/portage/package.license/10-gentoo-install
sys-kernel/linux-firmware @BINARY-REDISTRIBUTABLE
```

### 6. Choose and install the package set

The sets form a chain, each level adding to the one before and removing nothing:

```
base ──▶ minimal ──▶ server ──▶ desktop
```

`data/packages/sets.tsv` is the inheritance table and each `<set>.list` holds
the atoms. `base` is Portage tooling and a hardware inventory
(`gentoolkit`, `portage-utils`, `git`, `pciutils`, `usbutils`). `minimal` adds
what makes a bootable, repairable machine (`sudo`, `vim`, `dhcpcd`,
`linux-firmware`, ...). `server` adds unattended-machine needs (`chrony`,
`nftables`, `logrotate`, `smartmontools`, ...). `desktop` adds a graphical floor
(`xorg-server`, `pipewire`, `networkmanager`, fonts) but deliberately **no**
desktop environment, because GNOME or Plasma is a choice with its own profile.

Two init overlays sit on top of whichever level you pick, because the init
system is what decides who provides cron and the system log. `init-openrc` adds
`syslog-ng` and `cronie`; `init-systemd` is deliberately empty, because
`systemd-journald` and systemd timers already cover both.

Resolve a set by concatenating its chain root-first, then install it:

```bash
# chroot - the "minimal" set for an OpenRC system, by hand
emerge --noreplace \
  app-portage/gentoolkit app-portage/portage-utils dev-vcs/git \
  sys-apps/pciutils sys-apps/usbutils \
  app-admin/sudo app-editors/vim app-portage/cpuid2cpuflags net-misc/dhcpcd \
  sys-fs/dosfstools sys-process/htop sys-kernel/linux-firmware \
  app-admin/syslog-ng sys-process/cronie          # the init-openrc overlay
```

`--noreplace` is what makes a re-run cheap: a package already installed is left
alone rather than rebuilt to the same version. The installer instead writes the
resolved list to `/etc/portage/sets/gentoo-install` and runs
`emerge --noreplace @gentoo-install`, which also registers the set so a later
`emerge --update --deep --newuse @world` keeps these packages too. The set to
install defaults to `minimal`; it follows your `--flavour` or `--disk-layout`
only when one of those names a known set and you set it explicitly.

## Verify

```bash
# chroot
eselect profile show                               # the profile you set
emerge --info | grep -E '^(MAKEOPTS|CFLAGS|ACCEPT_LICENSE)='   # effective values
emerge --noreplace --pretend @world >/dev/null && echo "set resolves"
cat /var/lib/portage/world                         # packages now tracked
```

`emerge --info` prints the configuration *after* Portage merges `make.conf`, the
profile and your `package.use`, so it is the authoritative check that your
`MAKEOPTS` and license policy are what you intended.

## Pitfalls and rollback

- **"invalid profile" / none of the candidates exist.** The tree is older or
  newer than the table expects. List what it really offers with
  `eselect profile list` and set one by hand.
- **`make.conf` rejected.** A quoting or syntax error. `emerge --info` names the
  reason; the installer restores its backup. Fix the quote and re-validate.
- **`emerge-webrsync` fails on the signature.** A clock more than a day out makes
  the snapshot's signature look invalid. Fix the time, or fall back to
  `emerge --sync` (`portage_sync = rsync`).
- **`emerge --sync` hangs or fails.** Port 873 is filtered. Use
  `emerge-webrsync` (`portage_sync = webrsync`), which needs only HTTPS.
- **The set stops on a blocked or masked package.** That package names itself.
  Resolve it with `emerge --ask <atom>`, or write the set now and build it later
  (`portage_emerge_set = no`, then `emerge --noreplace @gentoo-install`).
- **Rollback.** `make.conf` is backed up before every write; restore the backup
  to undo the file. Removing `/etc/portage/sets/gentoo-install` and the
  `10-gentoo-install` drop-ins reverts the configuration; it does not uninstall
  packages already merged (`emerge --deselect`/`--depclean` do that). The
  installer leaves `@world` unrebuilt by default (`portage_update_world = no`),
  so the stage3's packages keep the USE flags they shipped with until you run
  `emerge --update --deep --newuse @world` yourself.

## Reference

- **Step:** `60` - `steps/60_portage.sh`
- **Uses:** `data/profiles.tsv`, `data/packages/sets.tsv`,
  `data/packages/*.list`, `data/video-cards.tsv`; `lib/chroot.sh` to run inside
  the target
- **Flags/settings:** `--flavour`, `--init`, `--arch` (choose profile and set);
  `portage_profile`, `portage_sync` (`webrsync`/`rsync`/`none`),
  `portage_makeopts`, `portage_common_flags`, `portage_use`,
  `portage_accept_license`, `portage_video_cards`, `portage_packages`,
  `portage_emerge_set`, `portage_update_world`
- **Writes:** `make.profile` symlink; `/etc/portage/make.conf` (managed block,
  backed up); `/etc/portage/repos.conf/gentoo.conf`; the synced tree;
  `/etc/portage/package.use|package.accept_keywords|package.license/10-gentoo-install`;
  `/etc/portage/sets/gentoo-install`; state-journal entries `portage.profile`,
  `portage.makeopts`, `portage.set`, `portage.packages`, `portage.sync`

---
[← Previous: Entering the chroot](07-chroot.md) · [Handbook index](README.md) · [Next: Kernel, initramfs & cmdline →](09-kernel-initramfs.md)
