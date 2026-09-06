# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

The version is declared in `gentoo-install.sh` and nowhere else. `./gentoo-install.sh --version`
is the authority; nothing in this file, in the README or in a badge restates it.

## [Unreleased]

### Fixed

- **The TPM sealing left the live medium.** `crypt = luks-tpm` refused at step
  30 unless the running medium carried clevis, jose and tpm2-tools, and
  `install-amd64-minimal.iso` — the medium the Gentoo handbook tells everyone to
  boot — carries none of them and cannot install them: it has no ebuild
  repository. The refusal even blamed the target. The binding now happens in the
  new step 75, inside the target: step 30 ends with one proved way in and says
  so, step 75 adds the second and proves it by making the chip release the key.
  `--steps 50,75` seals a machine that is already installed, and
  `--skip-steps 75` installs now and seals later.
- **`app-crypt/clevis` is not in the official Gentoo repository**, which the
  same run discovered — and a missing optional package no longer costs the
  kernel. Step 70's `emerge` of the sealing helpers failed, the step failed with
  it, and the run lost the kernel, the bootloader and the final verification:
  an unbootable machine, because a helper was unavailable, for a container that
  opened perfectly well with its recovery passphrase. Step 70 now separates what
  the machine needs to open its container from what seals a slot afterwards, and
  every message that mentions clevis names the GURU overlay it lives in.
- **No secret file was ever wiped.** `crypt_secret_file()` registered every file
  it made for the trap and for `cleanup()` — but it printed the path, so every
  call site was a command substitution and both registrations died with that
  subshell. The array `crypt_wipe_secrets()` read was empty at every exit: a
  file holding the LUKS passphrase in clear survived the run. It fills a
  caller-named variable now, the same shape `crypt_read_passphrase()` already
  had, and a test creates one and looks for it after the wipe.
- **A slot proved twice counted as two ways in.** The count is the gate that
  stops `luks-tpm` finishing with the TPM as the only credential, so it has to
  count credentials rather than proofs.

- **A dry run of an encrypted install always failed.** The state journal is how
  one step tells the next what it did — step 20 records `disk.crypt_device`,
  step 30 reads it — and a dry run wrote nothing, so step 30 stopped with "No
  device to encrypt" and every step behind it fell over the same way. The plan
  an operator asked to see ended in five failures caused by asking. A dry run
  now keeps its writes in memory and reads find them; nothing reaches the
  filesystem, and `--dry-run is complete by construction` becomes true for the
  steps that talk to each other.

- **A Gentoo `/var` ran out of inodes, not bytes.** The default desktop layout
  on a 24 GiB disk gives `/var` 3 GiB, mke2fs sizes the inode table by bytes —
  one per 16 KiB, so 196,608 of them — and the ebuild repository is 160,000
  files holding 120 MiB. `emerge --sync` stopped partway through with "No space
  left on device" while `df` reported 2.7 GiB free. A filesystem that will hold
  the repository is now made with inodes for it, and only when mke2fs would not
  have made enough on its own.
- **Then it ran out of bytes.** `sys-kernel/linux-firmware` unpacks 2.5 GiB into
  `/var/tmp/portage`, which is where every package is built. The desktop
  layout's floor for `/var` is 6 GiB rather than 3, and the plan now says, before
  the typed confirmation, when the filesystem that will hold `/var/tmp/portage`
  is too small to build in — naming the number, and refusing nothing.

- **The installer no longer rewrites the firmware state of the machine it runs
  on.** Step 80 wrote an `efibootmgr` entry, and step 95 offered a reboot, with
  nothing checking whether the target was the disk this machine booted from. Run
  against a disk image on a working laptop, the two combined: the entry replaced
  that laptop's own, pointing at an ESP that vanished with the loop device, and
  the reboot followed. `lib/disk.sh:disk_may_write_firmware_state` now gates
  both, and `--yes` no longer answers the reboot question — only `--reboot yes`
  does, because a reboot is irreversible in the way a typed proof is
  (`DESIGN.md` §12).
- **A loader is left where a firmware with no NVRAM entry will look for it.**
  When the entry cannot be written, the loader is copied to
  `\EFI\BOOT\BOOTX64.EFI`. Without it the first image this project produced had
  a working GRUB, a valid `grub.cfg` and a correct `fstab`, and dropped straight
  to PXE.
- **`chmod` no longer follows a caller-named path onto a device node.**
  `--log-file /dev/null`, run as root, reached `chmod 0600 /dev/null` and left
  the machine without a writable `/dev/null`; every shell that redirects to it
  then dies before running its command. `_core_plain_file()` guards every such
  `chmod`, and `state_init()` only tightens a directory it created — `--state-dir
  /tmp` as root would otherwise have stripped the sticky bit off `/tmp`.
- **Eight settings and state-journal keys were read under names nothing wrote.**
  Found by running the installer rather than reading it: `--device` was accepted
  and ignored (`disk` was the real name); `secureboot_keyfile` was read and never
  declared, so Secure Boot signing could not be switched on at all; step 20 wrote
  `disk.root`/`disk.vg`/`disk.esp` while steps 70 and 80 read
  `disk.root_device`/`disk.vg_name`/`disk.esp_device`; `chroot_target()` read
  `CFG[target]`, a setting that does not exist, so `--root` never reached step 50;
  and step 30 journalled `crypt.name` while step 70 read `crypt.luks_name` —
  which meant an encrypted install created `/dev/mapper/gentoo` and told the
  kernel `root=/dev/mapper/cryptroot`.
- **`target_layout()` answered the wrong question.** Ten call sites compared it
  against `lvm` and `plain`, but it returned the partitioning profile
  (`minimal`, `server`, …), so `kernel_cmdline()` refused with "Unknown disk
  layout" for every layout the installer offers. `target_topology()` now derives
  the storage shape from `disk.lvm`.
- **fstab was generated from a mis-split `findmnt`.** `--raw` separates columns
  with a space, not a tab; read with `IFS=$'\t'` the whole line landed in the
  target field, the `/boot` line failed and the root line was dropped in
  silence. Pseudo-filesystems are excluded from both the generator and the
  finalize check.
- **Unpacking a stage refuses a target the disk plan says should be mounted and
  is not** — 1.3 GB of stage3 had landed on the installer's own filesystem after
  step 20 failed and the run carried on.

### Added

- **Step 75, `seal`** — what the encryption variant still owes the target, done
  inside the target. It is a number of its own rather than a few lines at the
  end of step 70 because the number is the public API: `--skip-steps 75`
  installs now and seals later, `--steps 50,75` seals a machine that is already
  installed. A variant with nothing to seal says so and the step succeeds.
- `tests/firmware_guard.bats`, `tests/mode_guard.bats`, and two hygiene tests
  that fail when a setting or a state-journal key is read under a name nothing
  declares or writes. Every one of them exists because of a defect above.
- CI runs `make lint` and `make test` rather than keeping its own file list; the
  copy had drifted to a quarter of the project.

### Not done yet

- A UKI variant (`ukify`/`dracut --uefi`, `sbctl` signing, a fallback at
  `\EFI\BOOT\BOOTX64.EFI`). It would remove this class of boot failure rather
  than guard against it.

## [0.1.0] — unreleased

First shape of the project. The ten-step sequence has been run through once
end to end, producing a disk image that booted to a login prompt under QEMU with
OVMF; the encrypted variants, the other bootloaders and the LVM layouts have not
been carried through to a boot. The README's Status section says exactly what
was and was not covered.

### Added

- **Entry point and step registry.** Ten numbered steps — 10 preflight,
  20 disk, 30 crypt, 40 stage, 50 chroot, 60 portage, 70 kernel, 80 boot,
  90 system, 95 finalize. The number is the public API. Steps are sourced at
  startup and the registry is checked before the plan is printed, so a step
  the registry names but no file defines is a launch error rather than a
  surprise two hours into an install.
- **Selection and reporting.** `--steps 20,40-60,95` and `--skip-steps`,
  resolved at parse time against the registry. The runner accumulates failures
  instead of stopping at the first, names them in the summary, and exits
  non-zero.
- **Configuration surface.** One settings table, with the precedence
  *built-in default < profile < configuration file < explicit flag* implemented
  once and applied to every setting. Every declared setting is also a flag and
  also a `.conf` key. `--dump-config` prints each value and where it came from;
  `--json` prints the plan; secrets are masked in both.
- **Enumeration checking**, covering 21 settings, run once after every source
  has been merged. An invalid value is refused in milliseconds with the valid
  ones listed, instead of failing inside step 80.
- **Stage3 catalogue**, `data/stages.tsv`: the 19 published amd64 variants as a
  composition of `init` × `flavour`. Impossible combinations — `splitusr` with
  `systemd` — are refused at parse time rather than 404-ing after the disks
  have been wiped.
- **Stage3 trust chain**: the clearsigned `latest-*.txt` pointer verified
  first and its payload read from what gpg wrote, then the tarball's detached
  `.asc`, then the signed checksum, then the announced byte count. A disposable
  GNUPGHOME, so the operator's own keyring is untouched.
- **Encryption variants**: `none`, `luks-passphrase`, `luks-tpm`,
  `luks-keyfile-gpg`. Each proves, by exercising them, that more than one way
  back into the container exists before the step reports success.
- **Bootloader variants**: `grub`, `efistub`, `systemd-boot`, each verifying
  its own work — the EFI file, `grub-script-check`, the NVRAM entry, the loader
  entry's targets.
- **Kernel variants**: `dist-kernel`, `genkernel`, `manual`, with the command
  line and the dracut or genkernel module list composed from what steps 20 and
  30 recorded.
- **Disk layouts**: `minimal`, `server`, `desktop`, `custom`, declared as
  proportions with soft minima and maxima and rendered into a table of real
  sizes before anything is written.
- **Disk safety**: separate refusals for the system disk, a mounted disk and a
  removable disk, each with its own override; a typed device path as the erase
  confirmation, which neither `--yes` nor `--force` lifts; and a target
  assertion re-checked before every destructive command.
- **Package sets** as data: `data/packages/sets.tsv` and the `.list` files it
  names, inheriting cumulatively `base → minimal → server → desktop`, with
  `init-openrc` and `init-systemd` overlaid according to the init system.
- **State journal** under `/var/lib/gentoo-install`, recording what was done
  and never with what. `--resume` skips completed steps, `--restart` clears it.
- **`--dry-run`**, needing no privileges, with every destructive command routed
  through a single helper so the coverage is complete by construction.
- **Ten standalone rescue tools** under `tools/`: `luks-check`, `luks-open`,
  `rescue-chroot`, `luks-addkey`, `luks-header`, `key-backup`, `tpm-pcr`,
  `tpm-reseal`, `bios-update`, `bios-maint`. Each sources no library and can be
  copied alone onto a USB stick.
- **Repository furniture**: `LICENSE` (AGPL-3.0), `Makefile`, `.shellcheckrc`,
  `.editorconfig`, `.github/workflows/ci.yml`, `docs/DESIGN.md`.

### Known limitations

- No end-to-end install has been performed on real hardware.
- `amd64` is the only architecture in `data/stages.tsv`; `--arch` refuses the
  rest.
- The `tests/` directory carries no bats suite yet, so `make test` reports that
  there is nothing to run.
- `make lint` requires `shellcheck` and `shfmt` on the `PATH` and fails on a
  machine without them; `CONTRIBUTING.md` gives the container commands used in
  the meantime.

[Unreleased]: https://github.com/franckferman/gentoo-install/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/franckferman/gentoo-install/releases/tag/v0.1.0
