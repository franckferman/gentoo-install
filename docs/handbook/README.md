# The Gentoo Install Handbook

A step-by-step, *do-it-by-hand* companion to [`gentoo-install.sh`](../../gentoo-install.sh).

`gentoo-install` is a modular installer that takes a blank disk to a booting, optionally
**encrypted** Gentoo system: pre-flight checks, partitioning, LUKS (passphrase, GPG
keyfile, or **TPM-sealed**), the verified stage3, chroot, Portage, kernel + initramfs,
TPM sealing, bootloader, system configuration, and a final handover. This handbook
teaches you to perform each of those phases **manually**, so you understand the whole
install, not just the automation.

> **This complements the official
> [Gentoo Handbook](https://wiki.gentoo.org/wiki/Handbook:Main_Page), it does not
> replace it.** Where they overlap (the classic base install), we follow the official
> steps and add what the installer adds: disk encryption, the stage3 trust chain, TPM
> sealing, resume/rollback. When your system is installed and boots, continue with the
> sibling [Post-Install Handbook](https://github.com/franckferman/gentoo-post-install/tree/stable/docs/handbook).

## How to use this

- Read top to bottom for a full manual install, or jump to the phase you want to learn.
- Each step chapter ends with a **Reference** box: the `steps/NN_*.sh` it mirrors, the
  `lib/` and `variants/` it uses, the `--flags` that drive it, and what it writes, so
  you can compare your manual result against the installer.
- Preview first: `./gentoo-install.sh --dry-run` prints every action and needs no root.

## Conventions

- `# live` = root on the live install medium; `# chroot` = inside the target chroot;
  `$` = an unprivileged shell. Each block says which one it is.
- The target root is mounted at `/mnt/gentoo` until you chroot into it.
- **OpenRC and systemd** are both covered where they differ.
- A bold **Warning:** marker flags destructive or lock-out steps (disk wipe, LUKS
  format, bootloader). The installer guards the disk step with a typed proof; respect
  the same caution by hand.

## Chapters

| # | Chapter | Installer phase |
|---|---------|-----------------|
| 00 | [Overview & philosophy](00-overview.md) | the pipeline, config, state |
| 01 | [Configuration & the CLI](01-configuration-cli.md) | settings, profiles, precedence |
| 02 | [State, resume & rollback](02-state-resume-rollback.md) | the state journal |
| 03 | [Pre-flight checks](03-preflight.md) | `steps/10_preflight.sh` |
| 04 | [Partitioning & formatting the disk](04-disk.md) | `steps/20_disk.sh` |
| 05 | [Encryption (LUKS, GPG, TPM)](05-encryption.md) | `steps/30_crypt.sh` |
| 06 | [The stage3 (fetch, verify, unpack)](06-stage3.md) | `steps/40_stage.sh` |
| 07 | [Entering the chroot](07-chroot.md) | `steps/50_chroot.sh` |
| 08 | [Portage (profile, make.conf, sets)](08-portage.md) | `steps/60_portage.sh` |
| 09 | [Kernel, initramfs & cmdline](09-kernel-initramfs.md) | `steps/70_kernel.sh` |
| 10 | [TPM sealing](10-tpm-sealing.md) | `steps/75_seal.sh` |
| 11 | [Bootloader (GRUB / EFI stub / systemd-boot / UKI)](11-bootloader.md) | `steps/80_boot.sh` |
| 12 | [System configuration](12-system-config.md) | `steps/90_system.sh` |
| 13 | [Finalize & handover](13-finalize.md) | `steps/95_finalize.sh` |
| 99 | [Appendix: data, profiles, tests, troubleshooting](99-appendix.md) | `data/`, `tests/` |

## Contributing

New chapters follow [`TEMPLATE.md`](TEMPLATE.md) and mirror the matching
`steps/NN_*.sh` phase (and its `lib/`/`variants/`) exactly. Keep manual steps in sync
with the installer when it changes.
