# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

The version is declared in `gentoo-install.sh` and nowhere else. `./gentoo-install.sh --version`
is the authority; nothing in this file, in the README or in a badge restates it.

## [Unreleased]

Nothing yet.

## [0.1.0] — unreleased

First shape of the project. **Not published, and not yet proven end to end on
real hardware**: every module has been exercised on its own, and the full
ten-step sequence has only ever run under `--dry-run`.

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
