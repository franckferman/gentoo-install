# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

The version is declared in `gentoo-install.sh` and nowhere else. `./gentoo-install.sh --version`
is the authority; nothing in this file, in the README or in a badge restates it.

## [Unreleased]

### Added

- **musl reaches step 60.** The profile is selected, `make.conf` is written and
  accepted by `emerge --info`, and `package.use`, `package.accept_keywords`,
  `package.license` and the `@gentoo-install` set are all written on a musl
  tree: `default/linux/amd64/23.0/musl`, `MAKEOPTS="-j16"`, 14 packages. Two
  steps, none failed.

- **A `musl` stage has been installed.** Never done before: the flavour was
  offered, the tables named it, and nothing had ever unpacked one. Steps 20 to
  50 on an encrypted disk, four steps and none failed — the signed pointer, the
  detached `.asc` and the signed sha256 all check out for
  `stage3-amd64-musl-openrc`, and the tree that lands is a real musl one
  (`ld-musl-x86_64.so.1`, `CHOST="x86_64-pc-linux-musl"`, no `libc.so.6`). The
  `default/linux/amd64/23.0/musl` profile is selected against a real Portage
  tree, with the development-profile warning the table asks for.

- **`cpu_governor`, `performance` by default.** An install is one long compile
  and a live medium boots on whatever governor its image shipped with, which
  is the right default for a laptop reading a web page and the wrong one for
  four hours of gcc. What it changes belongs to the machine running the
  installer, so it is announced, recorded in the journal, and put back three
  ways: step 95, the exit trap, and the journal on the next run if the machine
  lost power in between. A governor this machine's cpufreq driver does not
  offer is refused at the prompt, from `scaling_available_governors` rather
  than a table — `intel_pstate` has two and `acpi-cpufreq` has five. `keep`
  opts out.

- **PCR policies have names.** There is not one policy: `crypt_pcrs` now takes
  `firmware` (`0,2,3,6`, the default), `secureboot` (`7`),
  `firmware+secureboot` and `strict` (`0-7`), as well as a raw list. The name
  becomes its numbers once, at parse time, so the plan, the seal, the journal
  and a later reseal all read the same thing.

- **The installer says when a policy binds nothing.** Registers 2, 3 and 6 are
  empty on a good deal of consumer firmware — the value of a register extended
  with `EV_SEPARATOR` and nothing else — so the default policy rests on PCR 0
  alone. `tools/tpm-pcr.sh` reported that; the installer sealed against them
  without a word. It measures them now and says which ones bind nothing.

### Fixed

- **Step 60 asks whether the chroot is usable, not whether `/bin/true` runs
  in it.** The precondition ran `/bin/true` inside the target and took that as
  proof that "step 50 mounts the pseudo-filesystems this step needs".
  `/bin/true` needs none of them. On a target with no `/proc`, no `/sys` and no
  `/dev`, the check passed, the step wrote `make.conf`, `emerge --info` failed
  with *"Failed to validate a sane '/dev'"*, and the step reported the file as
  rejected — *"one unbalanced quote is enough"* — then restored the backup. The
  operator was left with a reverted `make.conf` and a wrong explanation.
  `chroot_pseudo_ready()` probes `/proc`, `/sys`, `/dev` and `/dev/fd` and
  names the ones that are missing, before anything is written.

- **A `make.conf` refusal quotes Portage instead of guessing.** When
  `emerge --info` says why, its own last lines are shown.

- **A system can be installed in more than one language, and given a DNS
  domain and an SSH key.** All three were read by step 90 through a candidate
  list in which no name was declared, so `--locales`, `--domain` and
  `--ssh-key` all came back "Unknown option" and the lookups always answered
  empty. The ssh one cost the most: with `ssh_key` unreachable, the branch that
  turns password authentication off could never be taken, and the warning that
  fires instead named `ssh_key = /path/to/id_ed25519.pub` as the remedy — a
  setting nothing declared. Same shape as `secureboot_keyfile`, `user_shell`
  and `user_groups` before them.

- **The last locale of a list is no longer dropped.** `tr` leaves no newline
  after the final field and a bare `read` reports EOF for it, so
  `locales = "fr_FR.UTF-8,ja_JP.EUC-JP"` generated the first and silently lost
  the second. The guard against this is written twice elsewhere in the
  repository with the same comment; it was missed in the one list nothing
  could reach.

- **Twenty-two alias spellings that no configuration file could use are gone.**
  `_sys_cfg` and `_portage_cfg` take a fallback and then every name a step is
  willing to answer to — `tz`, `host`, `use`, `makeopts`, `sudo_tool`,
  `video_cards`, `device` and fifteen more. None was declared, so none could
  ever arrive; they were lookups that could only ever miss. One name for one
  thing, as with `disk_root`, `chroot_dir` and `target_root` before them. The
  hygiene test that keeps every read key declared now scans these lists too,
  which is how they were found.

- **A musl target is no longer given locale work it cannot do.** musl has no
  locale system: there is no `locale-gen`, there never will be one, and
  `/etc/locale.gen` is a file nothing on such a system reads. Step 90 wrote it
  anyway, warned that the locales "were listed, not built", and handed the
  operator `chroot ... locale-gen && eselect locale set en_US.UTF-8` to run by
  hand — a command that cannot succeed there. A to-do nobody can do reads as
  unfinished work on a machine that is finished. `LANG` is still written to
  `/etc/env.d/02locale`, because programs read it for their own messages and
  for the character set they assume. The C library is read off the tree and
  not off `flavour`: `--stage-file` brings archives the catalogue never named.

- **The governor is one command, not one per CPU.** `run_cmd` in a loop put
  sixteen identical lines in the plan on the machine this was written on, and
  a hundred and twenty-eight on a two-socket server. `tee` takes every file at
  once.

- **The crypt settings are judged before step 20 erases anything.**
  `crypt_validate_config` describes itself as "ten milliseconds, before a
  single sector is touched" and was called from step 30 alone, so
  `--crypt-pcrs bogus` was accepted at the prompt and refused after the disk
  was gone. It runs at parse time; step 30 still calls it, so the step stays
  drivable on its own.

- **`bios-maint.sh` asks clevis two different questions again.** "Which slot
  does the TPM own" and "did anything but a typed passphrase open this
  machine" are not the same question, and one function answered both. A tang
  binding is not what a firmware flash invalidates, so it is not what gets
  taken away and put back; but it opens the machine with nobody typing
  anything, so it voids the proof `verify-boot` exists to make — the test
  reboot that this whole sequence is built around. `prepare` and `rebind` keep
  the tpm2 pin; `verify-boot` and `status` see every binding.

- **`bios-maint.sh status` says when the state file belongs to another
  machine.** Every command that acts already refuses on it. `status` is the
  one that does not act, and it printed the recorded container and the current
  one on adjacent lines without a word, then gave the next step of a sequence
  started somewhere else. It is the command an operator runs to find out where
  they are, which makes it the worst place to leave that comparison to the
  reader.

- **No tool writes its error log through a symlink any local user can plant.**
  All nine kept stderr in a fixed name under `/tmp`, cleared it with
  `: >"$ERR_LOG"` and chmod'd it — as root, on a path in a world-writable
  directory. A symlink left there beforehand made that arbitrary file
  truncation and an arbitrary mode change: the same shape as the incident
  `tests/mode_guard.bats` exists for, in the ten scripts that tell the
  operator to run them under `sudo`. Proved and then re-run against the fix:
  the planted target keeps its 32 bytes and its mode. `init_err_log` unlinks
  whatever is at the path — `rm` never follows a symlink — and creates the
  file with `O_EXCL`, falling back to an unpredictable name if the race is
  lost rather than writing through what was put back.

- **`tpm-pcr.sh snapshot --dir` no longer demands root.** The subcommand asked
  for it unconditionally, while `do_snapshot` four lines further down answers
  the unprivileged case itself — "Not writable: ... Point `--dir` at a
  directory this account can write" — a sentence the root check made
  unreachable, advertising a flag it prevented anyone from using. Root is
  still required for `/var/lib/gentoo-install`. A snapshot taken from an
  ordinary shell now says which fields it could not read: the registers are
  world-readable, the DMI serial and the event log are not.

- **`luks-addkey.sh` refuses every clevis-owned keyslot, not the first one.**
  clevis is built to hold several pins at once — a tpm2 pin for the machine
  that unlocks itself, a tang pin for the one that asks the network — and the
  guard read `clevis luks list | head -n 1`. With two bindings,
  `remove --slot <the second>` killed the keyslot and left its token behind
  pointing at a slot that no longer exists: exactly what the refusal printed
  for the first binding says it prevents. `--from tpm` now asks each binding in
  turn instead of only the first, so a tang-first machine is no longer told the
  TPM refused when the TPM was never asked.

- **`tpm-reseal.sh` and `bios-maint.sh` name the pin they mean.** Both took the
  first binding as "the one clevis owns". A BIOS flash breaks a tpm2 sealing
  and does nothing to a tang one, so on a tang-first machine both tools worked
  on a slot that has nothing to do with the TPM — one of them resealing it.
  They select the `tpm2` line, and report nothing to adopt when there is none.

- **A generated passphrase is refused on the ESP wherever it is.** The check
  was `/boot/efi` anywhere in the path — the layout the tooling grew up on —
  while gentoo-install mounts the ESP at `/boot`. On a machine it had
  installed, `--gen --pass-out /boot/pw` wrote the passphrase onto the
  partition the firmware reads before anything is decrypted, and reported it
  as "mode 600": vfat has no modes, and the `chmod` had changed nothing. The
  mountpoint comes from the journal, the filesystem type answers for layouts
  no list names, and the success line now states the mode the file actually
  has.

- **Two more names for the target root, removed.** `disk_root` went last
  cycle; `chroot_dir` and `target_root` were declared beside it and did the
  same job worse. Measured across the seven resolvers rather than read:
  `--root` moved all seven, `--chroot-dir` moved exactly one — the chroot,
  away from the disk the run had just mounted and the stage it had just
  unpacked — and `--target-root` moved none while being accepted without a
  word. A flag that is taken and ignored is worse than one that does not
  exist, so both are now refused by name. The tests that were pointing step 90
  at a throwaway tree through `chroot_dir` use `root`, which is what the step
  already documented for the purpose.

- **One name for the directory the whole run builds in.** Step 20 mounted the
  target on `disk_root`; steps 40 to 95 read `root`. Both defaulted to
  `/mnt/gentoo`, so the split showed only once one of them was set: `--root
  /mnt/x` moved the unpacking, the chroot, the kernel and the bootloader while
  step 20 went on mounting the target disk on `/mnt/gentoo`. Found by running
  `--steps 20,30,40 --root /mnt/gi5`, where step 40 answered "the target root
  does not exist — step 20 partitions and step 50 mounts; run them first" one
  screen under a step 20 that had just succeeded.

- **The guard against unpacking onto the installer's own disk no longer has a
  way past it.** `_stage_assert_target_mounted` was written after 1.3 GB of
  stage3 landed on the wrong disk, and it only bit when the recorded mountpoint
  was the very path about to be written — so two roots that disagreed, the
  exact case above, walked straight past the check that exists for them.
  Nothing was mounted on that root either. It now refuses whenever the disk
  plan recorded a mountpoint and the root being unpacked into is not mounted,
  and it names the path the plan actually used.

- **"Is there a terminal?" is now asked of the kernel, not of the permission
  bits.** `[[ -r /dev/tty ]]` reads the mode of the device node, 0666
  everywhere, so it is true for a process with no controlling terminal — a run
  under `sudo` from a pipe, a cron job, a container, a CI job — and the read
  that follows dies on the redirect. Eight guards asked it that way and each
  then reported the wrong reason: the typed disk confirmation printed a raw
  shell error and said "Nothing typed; nothing done" instead of naming what it
  needed, and the passphrase prompt returned in silence rather than naming the
  two unattended routes. Every refusal was safe; the sentence that tells the
  operator what to do about it was what got lost.

- **`efistub` has been booted**, which was the last of the four bootloaders with
  nothing behind it. It needs an NVRAM entry, because for that variant the entry
  *is* the configuration, and the installer writes one when it runs from a live
  medium — the case the guard permits. Eleven steps, none failed, and the
  firmware started the kernel with no bootloader in between. Three lists in the
  README that still named three bootloaders now name four, including one that
  claimed to quote the installer's own refusal.

- **`luks-check.sh` looks for the ESP where this installer mounts it.** It tested
  `/boot/efi`, hardcoded — the layout of the machine this tooling grew up on —
  while gentoo-install's own layouts mount the ESP at `/boot`. On a machine it
  had installed, the first tool an operator reaches for said "the ESP is not
  mounted, cannot look for the key" about a filesystem that was mounted all
  along, one directory away. The mountpoint and the key's path both come from
  the journal now, with the old convention kept for the machine whose `/var`
  will not mount.

- **Nine tools ask the install journal for the container before searching for
  it.** The journal is a fact about the machine in front of them; the volume
  group enumeration underneath is a search. It is checked and not trusted — a
  disk is `/dev/vda2` to the machine that was installed and can be `/dev/sdb2`
  to the rescue medium looking at it, so a recorded name that no longer carries
  a LUKS header is worth less than the search. A test requires every tool with a
  `resolve_device()` to make that call, and it checks the call rather than the
  definition, because an earlier version of it stayed green with the helper
  present and unused.

- **`key-backup.sh` reads what the installer recorded before guessing.** Its two
  candidate paths are a convention; the install journal is a fact about the
  machine in front of it. Composing that fact takes both entries and neither is
  enough alone: `crypt.keyfile` is the path the initramfs is told, relative to
  the root of the filesystem carrying it, and `disk.esp_mount` is where that
  filesystem is mounted — so a key recorded as `/efi/luks-key.gpg` with an ESP
  at `/boot` is `/boot/efi/luks-key.gpg` to anything walking the installed tree.
  The candidates remain, for the machine whose journal is gone, and the "looked
  in" message names the recorded path too.

- **A command line that names only a serial console is called out.** The kernel
  prints to every `console=` it is given and makes the last one `/dev/console`,
  so naming only `ttyS0` takes the framebuffer away — and this project's own
  testing notes recommended exactly that to make a boot drivable. An install
  took the advice, booted correctly, printed nowhere anybody was looking, and
  was read as a hung image for most of an afternoon. Step 70 says so now, and
  names the fix: `console=tty0 console=ttyS0,115200`. Which console the
  passphrase prompt lands on is decided by the order — `/dev/console` is the
  last one named — and that is written down in `docs/TESTING.md` along with the
  harness mistake that hid it: QEMU discards a socket serial port's output until
  a client connects.
- **The removable fallback is proved.** A `uki` install with `boot_removable =
  yes`, booted against a pristine NVRAM, is started by the firmware from
  `\EFI\BOOT\BOOTX64.EFI` — where the same firmware, with a GRUB install and
  the same empty NVRAM, fell through to PXE the day before. That is the failure
  this project was shaped by, removed rather than guarded against. The image
  that run produced then hangs after the firmware starts it, which is written up
  in `docs/TESTING.md` with what has been ruled out and what has not been tried,
  and said beside the earlier claim that a `uki` image booted. The hang was the
  console redirection above: with `console=tty0` the same image reaches
  `Enter passphrase for /dev/vda2:`.

- **A machine this installer signed could not be reflashed by this project's own
  tool.** `tools/bios-update.sh` has to sign `fwupdx64.efi` with the same pair
  the kernel was signed with, and it had two sources for that pair — a
  conventional `/etc/efikeys`, and a configuration file belonging to another
  tool. Neither is written by gentoo-install, so a machine installed and signed
  here reached "No Secure Boot signing pair found" after being asked about two
  files it never creates. The install journal is consulted first now, because it
  is the one file on that disk this project wrote.
- **Step 80 recorded the certificate and not the key.** Half a pair, which is
  exactly what `boot_secureboot_ready()` refuses to work with — and it went
  unnoticed because the state journal refuses a name ending in `_key` outright,
  so `boot.secureboot_cert` on its own looked complete. The path is journalled
  under `boot.secureboot_keyfile`, never the key itself, the same rule
  `crypt.keyfile` follows.

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
