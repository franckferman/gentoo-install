# Appendix: data, profiles, tests & troubleshooting

> The cross-cutting pieces that are not a single step: the data tables that drive the
> installer, the profile/variant matrix, how the project tests itself, and what to do
> when an install goes wrong.

## The `data/` tables

The installer keeps its knowledge in plain tables under `data/`, so adding a stage3
flavour or a package set is a data edit, not a code change:

- `data/stages.tsv` - the stage3 flavours per architecture and init system.
- `data/profiles.tsv` - the Portage profile each (init, flavour, profile) maps to.
- `data/video-cards.tsv` - `VIDEO_CARDS` hints by vendor.
- `data/packages/*.list` - the package sets: `base`, `minimal`, `desktop`, `server`,
  and the init-specific `init-openrc` / `init-systemd` lists.
- `data/packages/sets.tsv` - which lists each profile pulls in.

Reading these tells you exactly what a `--profile` will install, without running
anything. `--dump-config` resolves them against your flags.

## The variant matrix

Four steps delegate their "how" to a `variants/` file. Pick one per axis:

| Axis | Flag | Variants |
|------|------|----------|
| Disk layout | `--disk-layout` | `minimal`, `desktop`, `server`, `custom` |
| Encryption | `--crypt` | `none`, `luks-passphrase`, `luks-keyfile-gpg`, `luks-tpm` |
| Kernel | `--kernel` | `dist-kernel`, `genkernel`, `manual` |
| Bootloader | `--bootloader` | `grub`, `efistub`, `systemd-boot`, `uki` |

Each variant is a small, readable script; when in doubt about what a choice does, read
its file. The relevant chapter (05 encryption, 09 kernel, 11 bootloader) walks each one.

## Profiles

`--profile minimal | default | desktop | server | hardened` sets a bundle of defaults
(layout, package sets, and more). A profile loses to a config file, which loses to an
explicit flag. `--dump-config` prints the resolved settings and where each came from.

## How the installer tests itself

The project has a real test gate (see `docs/TESTING.md` and the `Makefile`):

- **`bats` suites** under `tests/` (for example `disk_erase.bats`, `crypt_modular.bats`,
  `resume.bats`, `rollback.bats`, `mode_guard.bats`, `cli.bats`) exercise the logic with
  the destructive parts mocked, so nothing touches real hardware.
- **shellcheck** (`.shellcheckrc`) keeps the bash clean.
- **CI** (`.github/workflows/ci.yml`) runs them on every change.

By hand, the equivalent discipline is: always `--dry-run` first, and on a throwaway VM
before real hardware.

## Troubleshooting

- **It will not boot after install (encrypted root).** The usual cause is the initramfs
  or the kernel command line, not the disk. Boot the live medium, unlock and mount the
  target, chroot in (chapter 07), and re-check chapters 09 (initramfs/cmdline) and 11
  (bootloader).
- **An install stopped partway.** Re-run with `--resume` to continue from the state
  journal, or `--restart` to clear it and start over. See chapter 02.
- **A file on the target already differs.** `--on-conflict overwrite|skip|prompt|backup`
  decides what happens; `backup` keeps the old one.
- **The stage3 verification failed.** Do not bypass it. Re-fetch the signed pointer and
  tarball and re-verify (chapter 06); a failure here means a corrupt or tampered
  download, which is exactly what the check exists to catch.
- **TPM unlock stopped working after a firmware or boot change.** Sealing is bound to
  platform measurements (PCRs); a changed measurement is meant to refuse. Unlock with
  your fallback (passphrase/recovery) and re-enrol (chapter 10).
- **Read the plan without risk.** `--dry-run`, `--dump-config`, `--list-steps`,
  `--list-disks`, and `--list-flavours` all report and change nothing.

## References

- [Gentoo Handbook](https://wiki.gentoo.org/wiki/Handbook:Main_Page) - the authoritative base install.
- [Gentoo Wiki: Full disk encryption](https://wiki.gentoo.org/wiki/Full_Disk_Encryption_From_Scratch) and [dm-crypt](https://wiki.gentoo.org/wiki/Dm-crypt).
- `docs/DESIGN.md` - the installer's design contract.
- `docs/TESTING.md` - the test strategy.
- The sibling [Post-Install Handbook](https://github.com/franckferman/gentoo-post-install/tree/stable/docs/handbook) - what to do once it boots.
- `./gentoo-install.sh --help` - the authoritative, current flag list.

---
[← Previous: Finalize & handover](13-finalize.md) · [Handbook index](README.md)
