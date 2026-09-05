<div align="center">

# gentoo-install

**A modular Gentoo installer in bash: ten numbered steps, a signed stage3, encryption that proves there is more than one way back in, and a plan you can read before anything is written.**

[![Gentoo](https://img.shields.io/badge/Gentoo-amd64-54487A?style=flat-square&logo=gentoo&logoColor=white)](https://www.gentoo.org)
[![Shell](https://img.shields.io/badge/shell-bash-4EAA25?style=flat-square&logo=gnubash&logoColor=white)](gentoo-install.sh)
[![License](https://img.shields.io/badge/license-AGPL--3.0-blue?style=flat-square)](LICENSE)
[![CI](https://img.shields.io/github/actions/workflow/status/franckferman/gentoo-install/ci.yml?style=flat-square&label=CI)](.github/workflows/ci.yml)

</div>

Run from a Gentoo live medium. The step number is the public API: it appears in
`--steps`, in this document and in your own notes, and it does not change.
Nothing is touched until the plan has been printed and, for the one destructive
step, until the device path has been typed out by hand.

---

## Status

**Not yet proven end to end on real hardware.** Every module has been exercised
on its own — loop devices, throwaway targets, a chroot that is not this
machine's — and the full ten-step sequence has only ever been run under
`--dry-run`. No machine has been installed by this script from an empty disk to
a first boot.

Treat it accordingly: read the plan, run `--dry-run` first, and do not point
version `0.1.0` at a disk holding anything you would miss. The design contract
it is written against is [`docs/DESIGN.md`](docs/DESIGN.md), and what is done
and not done is in [`CHANGELOG.md`](CHANGELOG.md).

---

## Table of contents

The table of contents is the table of the steps, in the order they run.

- [Requirements](#requirements)
- [Quick start](#quick-start)
- [How it works](#how-it-works)
- **The install**
  - [10 preflight](#10-preflight) — privileges, tools, network, disk inventory
  - [20 disk](#20-disk) — partition and format the target disks (DESTRUCTIVE)
  - [30 crypt](#30-crypt) — LUKS containers and keyfiles
  - [40 stage](#40-stage) — fetch, verify and unpack the stage3 tarball
  - [50 chroot](#50-chroot) — mount the pseudo-filesystems and enter the chroot
  - [60 portage](#60-portage) — make.conf, repositories, profile, USE flags
  - [70 kernel](#70-kernel) — kernel sources, configuration and build
  - [80 boot](#80-boot) — bootloader install and entries
  - [90 system](#90-system) — fstab, locale, timezone, network, users, packages
  - [95 finalize](#95-finalize) — verify, unmount, report what to do next
- **Reference**
  - [The four choices](#the-four-choices)
  - [Stage3 variants](#stage3-variants)
  - [Package sets](#package-sets)
  - [Configuration](#configuration)
  - [Verifying the stage3](#verifying-the-stage3)
  - [Safety](#safety)
  - [Rescue tools](#rescue-tools)
  - [Repository layout](#repository-layout)
  - [Contributing](#contributing)
  - [Licence](#licence)

---

## Requirements

- An **amd64** machine. `data/stages.tsv` covers no other architecture yet, and
  `--arch` refuses anything else at parse time rather than 404-ing later.
- A **Gentoo live medium** (the official minimal install CD or admin CD). Every
  tool step 10 checks for is already on it: `lsblk`, `blkid`, `wipefs`,
  `findmnt`, `mount`, `umount`, `tar`, `chroot`, `awk`, `date`, `df`, one of
  `sgdisk` / `sfdisk` / `parted`, one of `curl` / `wget`, the `mkfs` for the
  chosen filesystem, plus `mkfs.fat` and `efibootmgr` on UEFI, `cryptsetup`
  when encryption is on, and `gpg` while signature verification is on.
- **bash 4** or newer. The step registry and the settings table are associative
  arrays.
- **root**, from step 20 onwards. `--dry-run` deliberately needs none, so the
  plan can be reviewed before you decide to `sudo`.
- The **Gentoo release keyring**, `app-crypt/openpgp-keys-gentoo-release`. It
  ships on the live medium. Step 40 refuses to run without it rather than
  fetching a stage3 it cannot check.

---

## Quick start

```bash
# On the live medium
git clone https://github.com/franckferman/gentoo-install
cd gentoo-install

# What would happen on this machine, changing nothing. No root needed.
./gentoo-install.sh --dry-run

# The ten steps, their numbers, and what each one does
./gentoo-install.sh --list-steps

# Every setting this version knows, its value, and where the value came from
./gentoo-install.sh --dump-config

# The same plan as JSON, for a script or a diff
./gentoo-install.sh --json

# A headless server: no 32-bit ABI, LVM with /var and /var/log split off
sudo ./gentoo-install.sh --profile server --disk-layout server

# A desktop on systemd, unlocked by the TPM, booted by systemd-boot
sudo ./gentoo-install.sh --profile desktop --crypt luks-tpm --bootloader systemd-boot

# A file of settings, and only the disk and stage steps
sudo ./gentoo-install.sh --config machine.conf --steps 20,40

# Pick up where an interrupted run stopped
sudo ./gentoo-install.sh --resume
```

---

## How it works

Ten steps run in order. Each is one file under `steps/`, each returns a code,
and the runner accumulates failures instead of stopping at the first one — a
run that announces success after a failed step tells you nothing. The final
summary names what failed and how to resume:

```
[x] 2 of 10 step(s) failed in 41s:
[x]        70 step_70_kernel
[x]        80 step_80_boot
[x]        fix the cause, then: ./gentoo-install.sh --resume
```

`--steps 20,40-60,95` selects; `--skip-steps 30` removes. A bare number has to
name a real step — `--steps 99` is a mistake worth stopping for — while a range
is a span and simply selects whatever exists inside it. Both are resolved at
parse time, in milliseconds, never in the middle of an `emerge`.

Everything a step prints goes to **stderr**, one glyph per level:
`[*]` doing, `[+]` done, `[!]` warning, `[x]` failure, `[=]` already done.
Standard output carries only values and `--json`, so `./gentoo-install.sh --json > plan.json`
is a clean file. Colour follows `-t 2` and `NO_COLOR`, so `| tee install.log`
keeps it.

A state journal under `/var/lib/gentoo-install` records which steps completed —
what was done, never with what: no passphrase and no key ever reaches it.
`--resume` skips what it marks done, `--restart` clears it. That matters on a
distribution that compiles its own kernel: an interrupted install must not
start over.

---

## 10 preflight

Eleven read-only checks, each ending in `PASS`, `WARN`, `FAIL` or `SKIP`
followed by why and by the exact command that fixes it: privileges, firmware,
architecture, tools, network, DNS, clock, disks, memory, TPM, keyring.

No check aborts on its own — you want the whole list in one pass, not one
refusal per attempt. The aggregate decides: a `FAIL` stops, a `WARN` asks, and
`--force` answers only the question a `WARN` asks. Nothing lifts a `FAIL`,
because a `FAIL` is a proof that failed.

The firmware check is the one that decides what comes later: no
`/sys/firmware/efi` means the machine booted in BIOS/CSM mode, which takes
systemd-boot and the EFI stub off the table and makes GRUB the only answer.

## 20 disk

The only step that cannot be undone, so it is the one that says the most before
it acts. It validates the settings, inventories the disks, picks the target,
refuses it if it is removable, in use, or carrying the running system, computes
the layout as a table of real sizes and prints it, prints the disk's identity
and everything currently on it — and only then asks for the device path to be
typed out.

A layout is a **proportion, not a table of gigabytes**: `root:50` works on the
machine it was written for and destroys the plan on a 64 GiB laptop. Layouts
declare percentages with soft minima and maxima, and the plan turns them into
real sizes you read before confirming. See [Safety](#safety) for the refusals
and the typed confirmation.

## 30 crypt

Loads one of the variants under `variants/crypt/` and runs it. The step itself
knows nothing about LUKS, TPMs or GPG: it validates, plans, confirms, applies,
and then refuses to declare the machine finished until the variant has proved,
by exercising them, that there is more than one way back into the container.

`none` is a variant like the others and says out loud that the disk will be
readable by whoever ends up holding it. A step that vanishes when a feature is
off leaves you guessing whether it was skipped or forgotten.

## 40 stage

Walks the trust chain from one end to the other: pick the variant, prove the
signed pointer, prove the tarball, unpack it. See
[Verifying the stage3](#verifying-the-stage3) — it is the part of this project
that is worth reading before the rest.

The tarball is cached under `/var/cache/gentoo-install`, outside the target
root so unpacking cannot swallow it.

## 50 chroot

Turns the unpacked stage3 into something commands can run in: `/proc`, `/sys`,
`/dev` (with `pts` and `shm`), `/run` and the EFI system partition mounted,
`/etc/resolv.conf` copied in, and a proof that a command really does execute
inside before any later step assumes it.

The mounts stay up: steps 60 to 90 run inside them and step 95 releases them.
The `EXIT` trap releases them too, so an interrupted run does not leave the
target half-mounted.

## 60 portage

Everything `/etc/portage` has to say before a single package is built: the
profile matching the init system and the flavour, a `make.conf` whose
`MAKEOPTS` is computed from this machine's cores *and* its memory, the ebuild
tree, the three per-package directories, and the package set described by
[`data/packages/sets.tsv`](data/packages/sets.tsv).

The profile is never set on trust: the directory is looked up in the synced
tree first, so a profile that is not there produces a sentence naming every
candidate tried, instead of eselect's "invalid profile" three steps into an
install. And `make.conf` is written, handed to `emerge --info`, and rolled back
when Portage refuses it — one unbalanced quote there makes every later emerge
fail with a parse error.

## 70 kernel

Three ways to get a kernel behind one step: `dist-kernel`, `genkernel`,
`manual`. What the step itself owns is the part that decides whether an
encrypted machine comes back up — the dracut module list and the kernel command
line, both composed from what steps 20 and 30 recorded rather than hardcoded.

genkernel does not use dracut: its initramfs reads `crypt_root=`, `root_key=`
and `dolvm` where dracut reads `rd.luks.uuid=` and `rd.luks.key=`. The step
composes the right dialect rather than assuming one.

## 80 boot

Makes the kernel of step 70 reachable at power-on, with `grub`, `efistub` or
`systemd-boot`. Each verifies its own work before returning: the EFI file
exists, `grub-script-check` accepts the generated configuration, the boot entry
is in NVRAM, the loader entry points at files that are actually there. A
bootloader written and not verified is a problem discovered at the next
power-on, in front of a firmware menu, with no shell.

The command line and the kernel image come from step 70. Two implementations of
that would be one too many.

## 90 system

Timezone, locales, console keymap, hostname, `/etc/hosts`, `fstab`, root
password, one user with its groups, sudo or doas, a network service matching
the init system, an optional hardened sshd, and the services those choices
imply.

Every mount in `fstab` is named by **UUID**, never `/dev/sdX`, because the
kernel is free to renumber disks between boots. `fstab` is written, handed to
`findmnt --verify`, and rolled back if findmnt objects: it is the one file here
with a checker good enough to catch a machine that will not boot.

## 95 finalize

The only step that builds nothing. It asks whether what the previous steps
built will come back up, says what is left to do by hand, releases exactly what
this install mounted, and stops.

The check that pays for the file is the initramfs one, and it is asked of the
**image itself** — `lsinitrd` when there is one, the cpio archive when there is
not — never of the configuration that was meant to produce it. An image without
the modules the encryption variant needs is a machine that stops at a dracut
prompt with no root and no explanation.

The reboot is a tri-state (`ask` | `yes` | `no`) and defaults to `ask`. Nothing
here reboots on its own.

---

## The four choices

| Axis | Setting | Values | Default |
|---|---|---|---|
| Encryption | `crypt` | `none` · `luks-passphrase` · `luks-tpm` · `luks-keyfile-gpg` | `luks-passphrase` |
| Bootloader | `bootloader` | `grub` · `efistub` · `systemd-boot` | `grub` |
| Kernel | `kernel` | `dist-kernel` · `genkernel` · `manual` | `dist-kernel` |
| Disk layout | `disk_layout` | `minimal` · `server` · `desktop` · `custom` | `desktop` |

**Encryption** — `luks-passphrase` is the default because it is safe by default
and depends on no hardware: no TPM, no key file, no second partition to keep in
sync. If the machine boots, the passphrase opens it. It writes two keyslots,
not one: the everyday passphrase in slot 0 and a recovery passphrase in slot 1,
so a mistyped-and-forgotten credential is an annoyance and not a wiped disk.
`luks-tpm` seals to the TPM with clevis and always keeps a recovery slot,
because a TPM that stops releasing the key after a firmware update is a
documented incident and not a hypothesis. `luks-keyfile-gpg` draws a long
random key, pipes it straight into a GPG envelope, and puts the envelope on the
ESP: two secrets, the passphrase that opens the file and the file that opens
the disk. `none` says out loud what it means.

**Bootloader** — `grub` is the default because it is the one that boots
everything: UEFI and legacy BIOS, an encrypted `/boot`, a root on LVM, a disk
that also carries Windows, and it has a menu you can edit from the keyboard
when something is wrong. `efistub` puts nothing between the firmware and the
kernel, and gives up the menu and the fallback entry in exchange.
`systemd-boot` is a directory of five-line entries, repairable from any machine
that can mount FAT; it is UEFI-only by construction and refuses a BIOS run
before touching anything.

**Kernel** — `dist-kernel` is what a first Gentoo install should get: Portage
installs a kernel like anything else, and `emerge -uDN @world` keeps it up to
date. `genkernel` compiles here and builds its own initramfs. `manual` fetches
sources and compiles a `.config` you supply — it refuses to invent one, because
a kernel built from a guess is a machine that boots to a blinking cursor.

**Disk layout** — `minimal` is one root filesystem and no LVM. `server` puts
`/var` and `/var/log` on their own volumes so a runaway log does not take sshd
with it, and leaves a fifth of the group unallocated. `desktop` gives `/home`
what is left. `custom` reads the records you write in `disk_volumes` or
`disk_volumes_file`, in the same format the three built-in layouts print, so a
plan can be started from `--disk-layout desktop`, read off the table, and
adjusted.

---

## Stage3 variants

Nineteen published amd64 variants, listed once in
[`data/stages.tsv`](data/stages.tsv). They are a composition of two axes —
`init` × `flavour` — and the names compose:

| flavour | openrc | systemd | libc | constraints |
|---|---|---|---|---|
| `base` | ✔ | ✔ | glibc | — |
| `desktop` | ✔ | ✔ | glibc | — |
| `nomultilib` | ✔ | ✔ | glibc | no-multilib |
| `hardened` | ✔ | ✔ | glibc | hardened-toolchain |
| `hardened-selinux` | ✔ | ✔ | glibc | hardened-toolchain, selinux |
| `musl` | ✔ | ✔ | musl | no-multilib |
| `musl-hardened` | ✔ | ✔ | musl | no-multilib, hardened-toolchain |
| `llvm` | ✔ | ✔ | glibc | libcxx-abi |
| `musl-llvm` | ✔ | ✔ | musl | no-multilib, libcxx-abi, experimental |
| `splitusr` | ✔ | — | glibc | openrc-only, split-usr |

Nine flavours × two init systems, plus `splitusr` for OpenRC only: nineteen.
`libc` and the stage id are derived from the row, not set by hand.

`splitusr` is **the exception the selector knows about**. Upstream publishes no
systemd counterpart, so the combination is refused at parse time — before the
disks are touched — instead of 404-ing halfway through an install:

```console
$ ./gentoo-install.sh --flavour splitusr --init systemd --dry-run
[x] No amd64 stage3 is published for flavour 'splitusr' with init 'systemd'
[x]        flavour 'splitusr' exists only for: openrc
[x]        example:  --flavour splitusr --init openrc
```

`./gentoo-install.sh --list-flavours` prints the flavours for the current
`--arch`.

---

## Package sets

The inheritance table is data, not a comment in a script, because the question
a reader actually asks is "what does `desktop` add over `server`" and the
answer must be readable without opening any code. It lives in
[`data/packages/sets.tsv`](data/packages/sets.tsv):

```
base ──▶ minimal ──▶ server ──▶ desktop
```

Each level **adds** to the one before it and removes nothing. Resolving a set
means walking the `inherits` column up to the root and concatenating the
`.list` files from the root down.

| Set | Inherits | Adds | Total | What it adds |
|---|---|---|---|---|
| [`base`](data/packages/base.list) | — | 5 | 5 | Portage tooling and hardware inventory: `gentoolkit`, `portage-utils`, `git`, `pciutils`, `usbutils` |
| [`minimal`](data/packages/minimal.list) | `base` | 7 | 12 | A machine that boots and can repair itself: `sudo`, `vim`, `cpuid2cpuflags`, `dhcpcd`, `dosfstools`, `htop`, `linux-firmware` |
| [`server`](data/packages/server.list) | `minimal` | 7 | 19 | Headless and always on: `logrotate`, `tmux`, `nftables`, `chrony`, `dmidecode`, `smartmontools`, `lsof` |
| [`desktop`](data/packages/desktop.list) | `server` | 9 | 28 | A graphical session: `xorg-server`, `xrandr`, `xterm`, `xdg-utils`, `pipewire`, `wireplumber`, `networkmanager`, `dejavu`, `noto` |

Two overlays sit outside that chain and are applied on top of whichever level
was chosen, according to `--init`:

| Overlay | Adds | Why |
|---|---|---|
| [`init-openrc`](data/packages/init-openrc.list) | 2 | `syslog-ng` and `cronie` — the two services systemd provides itself |
| [`init-systemd`](data/packages/init-systemd.list) | 0 | Deliberately empty. journald is the log and timers are the cron; adding the OpenRC pair would give the machine two of each with the logs split between them |

`@system` is not repeated in any of these files: they are the delta, and a list
that restates `@system` is a list nobody trusts to be one. No desktop
environment is listed either — GNOME, Plasma and Xfce are a choice with a
Portage profile attached (see [`data/profiles.tsv`](data/profiles.tsv)), and an
installer that picks one promotes its author's taste to a default.

**Which set gets installed**: whichever of `--flavour` or `--disk-layout` you
set **explicitly** and which names a set in the table — so `--flavour desktop`
and `--disk-layout server` each select their namesake. With neither given
explicitly, the answer is `minimal`. Both carry a default of their own, and a
plain run must not quietly install a desktop.

---

## Configuration

There are three ways to set anything, and they are the same surface:

```bash
# 1. a configuration file: key = value, one per line, # comments a whole line
printf 'bootloader = efistub\ncrypt = luks-tpm\n' > machine.conf
./gentoo-install.sh --config machine.conf --dry-run

# 2. a flag — every declared setting is one, spelled with dashes
./gentoo-install.sh --bootloader efistub --crypt luks-tpm --dry-run

# 3. the setting under its own name, which is what --dump-config prints
./gentoo-install.sh --dump-config | grep -E '^(bootloader|crypt) '
```

**Precedence, always in this order:**

```
built-in default  <  profile  <  configuration file  <  explicit flag
```

The profile applies *after* parsing, with a "set unless the operator already
asked" primitive written once and used for every setting — so it can never
overwrite an intention, and not merely for the handful somebody remembered.

**Every declared setting is also a flag.** There is no hand-maintained list of
them in `--help`, because a hand-maintained list drifts; `--dump-config` prints
the authoritative set, with each value and where it came from:

```console
$ ./gentoo-install.sh --dump-config | head -5
arch                     = amd64                        # default
assume_yes               = no                           # default
boot_device              =                              # default
boot_disk                =                              # default
boot_label               =                              # default
```

A key that is not in that list is refused — in a `.conf` on the line that
spells it, and on the command line as an unknown option. A value outside its
enumeration is refused too, once every source has been merged, before a single
step runs:

```console
$ ./gentoo-install.sh --config bad.conf
[*] configuration read from bad.conf
[x] Invalid value for bootloader: frobnicate
[x]        one of: grub, efistub, systemd-boot
[x]        example:  bootloader = grub
```

### The target root

The directory the stage3 is unpacked into and the system is built under is the
`root` setting, default `/mnt/gentoo` — the same name in a `.conf` (`root = /mnt/gentoo`)
and on the command line (`--root /mnt/gentoo`), like every other declared
setting. It is not `--target`, `--prefix` or `--destdir`; those do not exist.
The separate `disk_root` setting is where step 20 mounts the tree it has just
made.

### Meta-profiles

`--profile` sets a coherent group of defaults, and nothing more. It picks the
stage3 to fetch; it does not choose your disk layout or your bootloader.

| `--profile` | flavour | init | also |
|---|---|---|---|
| `minimal` | `base` | `openrc` | — |
| `default` | `base` | `openrc` | — |
| `desktop` | `desktop` | `systemd` | — |
| `server` | `nomultilib` | `openrc` | — |
| `hardened` | `hardened` | `openrc` | `on_conflict = prompt` |

### Writing to files

Every generated block is fenced, so a rerun replaces its own work and nothing
else:

```
# >>> gentoo-install: portage make.conf >>>
...
# <<< gentoo-install: portage make.conf <<<
```

`--on-conflict` decides what happens to a file that already differs:
`overwrite`, `skip`, `prompt`, or `backup` (the default). Where a file has a
checker — `emerge --info`, `findmnt --verify`, `grub-script-check` — it is
written, validated, and rolled back if the checker objects.

---

## Verifying the stage3

This is the part that separates the project from a script that pipes `wget`
into `tar`. **A mirror is a stranger.**

1. **The pointer is signed, and its signature is checked first.**
   `latest-stage3-amd64-<variant>.txt` names which timestamped tarball is
   current and how many bytes it has. That file is clearsigned by the Gentoo
   release key. The path and the byte count are read out of **what gpg wrote**,
   never out of the file on disk — text appended outside the signature is
   therefore unparseable rather than trusted.
2. **The tarball's own detached signature is checked.** The `.asc` beside the
   tarball is a signature over the tarball's bytes. This is the strong
   guarantee, and gpg's *status output* is what decides, never its exit code
   alone: gpg exits 0 for a good signature and for other things too.
3. **The signed checksum is cross-checked**, and **the announced byte count is
   compared** against the file on disk.

Why the `.sha256` alone would prove nothing: **the same mirror serves the
tarball and its checksum**. A mirror that substitutes one can substitute the
other, and the pair will agree perfectly. A checksum without a signature proves
only that a mirror is self-consistent with itself. The signature is what a
stranger cannot forge, which is why the chain starts and ends with one and the
checksum is a cross-check, never a substitute.

The keyring is `app-crypt/openpgp-keys-gentoo-release`, looked for at
`/usr/share/openpgp-keys/gentoo-release.asc` and three other usual paths, or
wherever `keyring` points. It is imported into a **disposable** GNUPGHOME that
is destroyed with the run, so nothing is added to your own keyring. Fetching
the keys from anywhere but a trusted medium is itself a trust problem, and step
40 refuses to run without them rather than pretending otherwise.

`verify_signatures = no` exists and turns the chain off. It warns, in full,
every time — a compromised mirror then picks your stage3.

---

## Safety

**Three refusals, three switches.** Each lifts one refusal and one only, because
a single blanket flag is how an operator lifts three guards meaning to lift one:

| The installer refuses | Because | What lifts it |
|---|---|---|
| The disk carrying the running system | It is the machine you are working from | `disk_allow_system = yes` |
| A disk with mounted filesystems | Something is using it right now | `disk_allow_mounted = yes` |
| A removable disk | A USB stick is not an install target | `disk_allow_removable = yes` |
| Loop devices, absent from the inventory | They are images, not disks | `disk_allow_loop = yes` |

**`--force` lifts confirmations. It does not lift proofs.** Nor does `--yes`.

**The confirmation for the erase is a typed device path**, never `y`:

```
[!] Every byte on /dev/nvme0n1 will be overwritten. There is no undo.
[!] This erases /dev/nvme0n1 completely.
Type /dev/nvme0n1 to confirm:
```

There is no reflex answer to that, which is the entire point. `--yes` and
`--force` do not lift it and will not; a non-interactive run reaches it and
stops, saying so. Behind it, every destructive command checks the device it was
handed against the confirmed target before running, so a mistake in the code
stops there rather than on a disk.

**Anything whose wrong answer destroys something is a tri-state**, not a
boolean, and defaults to `ask`: `wipe_disk`, `wipe_foreign`, `crypt_wipe_luks`,
`reboot`. A boolean cannot express "ask me".

**`--dry-run` shows the plan and changes nothing**, and needs no privileges by
design, so you can read what a run would do before deciding to `sudo` it. Every
destructive command in the project goes through one helper, so dry-run coverage
is complete by construction rather than by remembering.

**Nothing is erased before another way in has been shown to work.** Step 30
does not report success until the encryption variant has *exercised* the
credentials it created — not merely observed that a keyslot or a TPM token
exists.

---

## Rescue tools

Ten standalone scripts under [`tools/`](tools), for a machine that is **already
installed and no longer boots**. They are not part of the install; they are
what you reach for at 2 a.m. with a live USB.

**Each one is self-contained by design.** None sources a library, none reads
`lib/`, and each carries its own output helpers and exit codes. The duplication
is deliberate and is the whole point: a LUKS rescue tool that cannot be copied
alone onto a USB stick is useless in exactly the situation it exists for. Only
the output shape is shared with the installer — `[*] [+] [!] [x] [=]`, colour
on `-t 2`, the same exit codes. Every one answers `--help` and exits 0.

| Tool | What it is for |
|---|---|
| [`luks-check.sh`](tools/luks-check.sh) | Read-only report on a LUKS container: keyslots, clevis tokens, TPM policy, and whether a passphrase or key file still opens it. Opens nothing, writes nothing — the first thing to run on a machine that will not boot |
| [`luks-open.sh`](tools/luks-open.sh) | Unlocks the container from a live medium, activates the volume group and mounts the tree in the order the layout requires. `close` undoes only what it opened |
| [`rescue-chroot.sh`](tools/rescue-chroot.sh) | Binds `/dev`, `/sys`, `/proc` and `/run` into a tree `luks-open.sh` has mounted and chroots in. On the way out it names the processes still holding the tree — gpg-agent, usually |
| [`luks-addkey.sh`](tools/luks-addkey.sh) | Adds a passphrase to a free keyslot, and removes one only after another has been proved to open the container here and now. Slot 0 is never removed |
| [`luks-header.sh`](tools/luks-header.sh) | Backs up, verifies, diffs and restores the LUKS2 header — the one thing no secret replaces. `restore` rewrites every keyslot at once and is the most destructive command in this repository |
| [`key-backup.sh`](tools/key-backup.sh) | Takes the GPG-wrapped LUKS key off the machine, after decrypting it and testing it against a real keyslot. Copying a file that no longer works is not a backup |
| [`tpm-pcr.sh`](tools/tpm-pcr.sh) | Reads the TPM PCRs, says which moved since a snapshot, and whether the clevis policy is even sealed on them. Never writes to the TPM |
| [`tpm-reseal.sh`](tools/tpm-reseal.sh) | Redoes the clevis binding after a firmware change, then asks the TPM to release what it just sealed and tests it against the keyslot. A token that exists is not a token that works |
| [`bios-update.sh`](tools/bios-update.sh) | Proves a BIOS flash can be survived — nine checks and an attestation `flash` refuses to run without — then signs `fwupdx64.efi` and flashes |
| [`bios-maint.sh`](tools/bios-maint.sh) | Walks a firmware update through the other tools in the one order that works, across reboots, refusing to continue when the previous step was not proved |

A typical rescue is three commands:

```bash
./luks-check.sh          # what state is this container in
./luks-open.sh           # unlock and mount under /mnt/rescue
./rescue-chroot.sh       # work inside the system
```

---

## Repository layout

```
gentoo-install.sh      the entry point, the step registry, and the only
                       place VERSION is declared
lib/                   core, config, state, ui, disk, crypt, stage, chroot
steps/                 one file per step: 10_preflight.sh … 95_finalize.sh
variants/crypt/        none, luks-passphrase, luks-tpm, luks-keyfile-gpg
variants/boot/         grub, efistub, systemd-boot
variants/kernel/       dist-kernel, genkernel, manual
variants/layout/       minimal, server, desktop, custom
tools/                 the ten standalone rescue scripts
data/stages.tsv        the 19 published stage3 variants
data/profiles.tsv      Portage profiles per init and flavour
data/video-cards.tsv   VIDEO_CARDS, from what lspci reports
data/packages/         sets.tsv, the inheritance table, and the .list files
docs/DESIGN.md         the design contract every file follows
tests/                 bats, run in CI
```

---

## Contributing

[`CONTRIBUTING.md`](CONTRIBUTING.md) has the short version:
`make lint test`, and read [`docs/DESIGN.md`](docs/DESIGN.md) first — it is a
contract, not advice. One rule above the others: **a guard rail is not removed
without saying what it prevented.**

## Licence

[AGPL-3.0](LICENSE).
