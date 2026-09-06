# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

The version is declared in `gentoo-install.sh` and nowhere else. `./gentoo-install.sh --version`
is the authority; nothing in this file, in the README or in a badge restates it.

## [Unreleased]

### Fixed

- **The way back into a finished target is one that survives the run ending.**
  Step 95 printed `./gentoo-install.sh --steps 50   # then: chroot …`, which
  cannot work: the run releases everything it mounted when it ends, so that
  invocation mounts the target, explains how to enter it, and unmounts it on the
  way out. It names `tools/luks-open.sh` and `tools/rescue-chroot.sh` now.

- **A failed pre-flight stops the run.** The runner accumulates failures, which
  is right for almost every step and wrong for the one whose checks decide
  whether anything may be written at all. A real run showed it: pre-flight
  refused a 16 GiB disk — `minimum 20`, and `--force does not lift these: they
  are proofs, not confirmations` — and the run went on to erase that disk and
  install onto it. `STEP_HALTS` names the steps whose failure ends the run, in
  a table rather than an `if` on a number, and the report says how many steps
  were not run and that nothing they would have written was written.

- **A reseal reproduces the policy in force.** `tools/tpm-reseal.sh` read the
  binding it was about to replace, printed it on screen, and then resealed with
  its own default — `pcr_ids 0,2,3,6`. A machine installed with another set of
  registers, or with an RSA key rather than ECC, came back from a reseal bound
  to something its operator never chose, with the old configuration displayed
  two lines above the new one. The stored configuration is reused verbatim now
  unless `--pcrs` says otherwise.

- **Two files are compared with whatever the medium carries.** `backup_file()`
  used `cmp` to avoid stacking a second identical backup, and `cmp` comes from
  diffutils, which the Gentoo minimal ISO does not have. So every file written
  during an install on that ISO printed `cmp: command not found` and then took
  a backup it did not need — a failed comparison reads as "different". It falls
  back to a checksum now, and when nothing can tell it says "different", because
  one backup too many is a wasted copy and one too few is a lost original.

- **The generated fstab is compared with the disk plan.** Step 90 writes the
  fstab from the kernel's mount table and step 80 installs the bootloader
  against the plan, and nothing checked that the two agree. A target whose ESP
  was mounted at `/boot/efi` while the plan said `/boot` produced an fstab
  naming the first and a `grub-install` asking for the second, which answered
  `/boot doesn't look like an EFI partition` — a message about the ESP, caused
  by a disagreement two steps earlier that neither step mentioned. Every
  mountpoint the plan describes is now looked for in the fstab, and the ones
  that are missing are named, in a dry run as well.

- **A state journal that a reboot forgets now says so.** The default is
  `/var/lib/gentoo-install`, and on the medium this installer is designed for —
  a live ISO — that is RAM: the Gentoo ISO mounts its root as an overlay whose
  upper layer is `/run/overlayfs`, on tmpfs. So which steps completed, and the
  disk plan step 20 writes beside them, are lost by rebooting the medium, and
  `--resume` starts from the beginning. It is said once, at startup, with
  `--state-dir` named as the way out. The check follows an overlay to the layer
  that receives the writes, because the first version did not and therefore said
  nothing on exactly the medium it was written for.

- **The installer could not get back to its own target.** Only step 20 mounted
  the tree, and every run releases what it mounted when it ends — so the second
  invocation, which is what `--resume` is, arrived at an empty `/mnt/gentoo` and
  mounted `/proc` and `/dev` over nothing. The way back in was
  `tools/luks-open.sh`, a rescue tool, for the ordinary case of picking up where
  the last run stopped. Step 50 reattaches now, from the plan step 20 recorded:
  it opens the container (asking for a passphrase, once), activates the volume
  group and mounts the tree the plan describes. A plan naming the disk this
  machine booted from is refused rather than mounted — the same guard the
  September incident bought, on this door too.
- **`make format` no longer leaves root-owned files** in the contributor's own
  checkout. The formatter runs in a container, and a container writing as root
  made two files in this repository unwritable by their author. Only the image
  that writes gets the caller's id: the linters and the test suite are left
  alone, because bats has to be root inside its own container to exercise the
  tools' root checks.

- **clevis was asked for a USE flag that does not exist, and not for the one
  that matters.** `app-crypt/clevis` in GURU has `IUSE="dracut pkcs11 test tpm1
  udisks"`; the installer wrote `tpm2`, which nobody has and portage ignores in
  silence, and never wrote `dracut`. Without it the package installs its
  binaries and no initramfs module, so the sealing succeeded, was proved, and
  the machine still asked for its passphrase at every boot. The optional
  packages are also emerged with `--changed-use` now: they are usually already
  installed by the time the flag is written, and `--noreplace` would leave them
  exactly as they are.
- **An initramfs older than its modules is rebuilt rather than kept.** Step 70
  returned early when the kernel package was installed and `/boot` held an
  image, so a package installed on a later run — clevis, here — never reached
  the initramfs. The image is asked what it carries, with `lsinitrd` run inside
  the target where dracut lives, and the deployment is re-run when it is behind.

- **An LVM root never got the `lvm` binary, so no LVM install could boot.**
  `sys-fs/lvm2` installs device-mapper and nothing more unless it is built with
  `USE=lvm`, and it arrives as a dependency of cryptsetup — present, correct
  looking, and missing the one file dracut's `lvm` module checks for. dracut
  then says `Module 'lvm' cannot be installed`, the initramfs fails, the
  kernel's own install phase fails with it, and step 70 ends with a partitioned
  disk, a stage3 and no kernel. Step 70 now writes the flag and rebuilds the
  package with `--changed-use` when it is already there without it.
- **A dracut module that is not in the target is no longer asked for.** The
  module list is written before the packages exist, so it names what the
  configuration wants; when dracut then cannot find one it fails the whole
  initramfs, and that initramfs is built inside the emerge of the kernel. So a
  missing `clevis` did not cost the automatic unlock, it cost the kernel. The
  list is written again once the packages are in place, without the modules
  that are genuinely absent, saying for each one what the machine loses — and
  still refusing when what is missing is `crypt`, `dm` or `lvm`, because that
  machine would not start at all.
- **`app-crypt/clevis` is unstable-keyworded in GURU**, so enabling the overlay
  is not enough on a stable target. Every message that names the overlay now
  names the keyword line too.

- **Nine of the ten tools looked for a volume group named `vg1`.** That is the
  group the machine this tooling grew up on happened to have; `gentoo-install`
  creates `vg0`. So every "detected from the volume group" path found nothing on
  the machines this project installs, and `luks-open.sh close` was worse — it
  deactivated no group, could not close the container it had opened, and
  reported an item still held. None of them names a group now: they ask LVM
  which group sits inside the container, and say so when more than one does.
- **`luks-open.sh` mounted a list of volume names instead of the machine's own
  layout.** `root`, `home`, `apps`, `usr`, `var`, `portage`, `log`, `opt`, and
  the ESP at `/boot/efi` — again the layout of one machine. A system installed
  by this project keeps its ESP at `/boot`, so a rescue mounted it in the wrong
  place and any volume named otherwise was silently missed. It reads the
  target's `/etc/fstab` now, in both the LVM and the plain case. When that file
  names nothing usable — a stage3 ships one whose every line is a comment — it
  falls back to the volume names and says that is what it is doing.
- **A GPG-wrapped key file was written where the initramfs would not look.**
  `crypt_key_dir` is a path in the installed system (`/boot/efi`), while
  `rd.luks.key=<path>:UUID=<esp>` names a path relative to the root of the ESP.
  With the default layout the ESP is mounted at `/boot`, so the key landed at
  `/efi/luks-key.gpg` as the initramfs sees it and the journal recorded the
  constant `/luks-key.gpg`. The machine still booted, asking for the recovery
  passphrase, so nothing looked broken — while the one file the variant exists
  to place was never read. The recorded path is now computed from where the
  file is actually written, and a `crypt_key_dir` that is not on the ESP is
  refused rather than written to.
- **The keyfile variant tested its directory on the wrong filesystem.**
  `crypt_variant_check` tested `/boot/efi` against the running system rather
  than against the target, which passes on a machine that has one and refuses
  on the Gentoo minimal ISO, which does not.

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
