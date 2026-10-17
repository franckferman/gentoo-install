# Overview & philosophy

> What `gentoo-install` is, the pipeline it runs, how it is configured and resumed,
> and the safety model, so the rest of the handbook makes sense.

## What this installer is

`gentoo-install.sh` takes a blank disk to a booting Gentoo system. It is **modular**:
a thin orchestrator runs an ordered pipeline of numbered **steps**, each a file under
`steps/`, each backed by small libraries under `lib/` and interchangeable strategies
under `variants/`. You can run the whole thing, or a subset, or preview it, and you can
stop and resume. This handbook teaches you to do each step by hand.

## The pipeline

The install is a fixed sequence of phases. Each has its own chapter.

| Step | Phase | What it does |
|------|-------|--------------|
| 10 | Pre-flight | Eleven checks that change nothing; refuse to start on a bad footing. |
| 20 | Disk | Partition and format the target. The one irreversible step. |
| 30 | Encryption | LUKS, via a chosen variant: passphrase, GPG keyfile, or TPM-sealed (or none). |
| 40 | Stage3 | Fetch, cryptographically verify, and unpack the stage3 tarball. |
| 50 | Chroot | Mount the pseudo-filesystems and enter the target. |
| 60 | Portage | Profile, `make.conf`, the ebuild tree, and package sets. |
| 70 | Kernel | A kernel (dist-kernel, genkernel, or manual), its initramfs, and the boot cmdline. |
| 75 | Sealing | Finish what the encryption variant owes the target, from inside it (e.g. TPM enrol). |
| 80 | Bootloader | Make the kernel reachable at power-on: GRUB, EFI stub, systemd-boot, or a UKI. |
| 90 | System | Timezone, locale, keymap, hostname, `fstab`, root password, accounts, sudo. |
| 95 | Finalize | Five last checks, a recap, and the handover. Builds nothing. |

The whole thing targets a root mounted at `/mnt/gentoo` until step 50, then continues
inside the chroot.

## Variants: one step, several strategies

Several steps delegate the "how" to a `variants/` file, so the step stays small and the
choice is explicit:

- **`variants/crypt/`** - `luks-passphrase`, `luks-keyfile-gpg`, `luks-tpm`, `none`.
- **`variants/layout/`** - `minimal`, `desktop`, `server`, `custom` disk layouts.
- **`variants/kernel/`** - `dist-kernel`, `genkernel`, `manual`.
- **`variants/boot/`** - `grub`, `efistub`, `systemd-boot`, `uki`.

You pick them with flags (`--crypt luks-tpm`, `--disk-layout server`, `--bootloader
efistub`), and each has its own section in the relevant chapter.

## How it is configured

Settings come from four places, and **later always beats earlier**:

```
built-in default  <  profile  <  configuration file  <  explicit flag
```

- A **profile** (`--profile minimal|default|desktop|server|hardened`) sets a bundle of
  defaults.
- A **config file** (`--config FILE`, `key = value` lines) overrides the profile.
- An **explicit flag** (`--<setting> VALUE`) overrides everything. Every setting is also
  a flag; `--dump-config` prints the authoritative set with each value's origin.

See [Configuration & the CLI](01-configuration-cli.md).

## Safety model

- **`--dry-run`** prints every action and changes nothing, and needs no privileges. It
  is the first thing to run.
- **`--yes` / `--force`** lift *confirmations*, but never the **typed proofs**: the
  destructive disk step makes you type an exact phrase, and no flag can skip that. By
  hand, treat the disk and LUKS-format steps with the same deliberateness.
- **State journal + `--resume` / `--restart`:** each completed step is recorded, so an
  interrupted install can continue where it stopped, or be cleared and restarted. See
  [State, resume & rollback](02-state-resume-rollback.md).
- **`--on-conflict`** decides what happens to a target file that already differs:
  `overwrite`, `skip`, `prompt`, or `backup`.

## Where this sits

This handbook covers the **install**. It complements, and does not replace, the
official [Gentoo Handbook](https://wiki.gentoo.org/wiki/Handbook:Main_Page); where they
overlap we follow it and add what this installer adds (encryption, the stage3 trust
chain, TPM sealing, resume). Once the machine boots, continue with the sibling
[Post-Install Handbook](https://github.com/franckferman/gentoo-post-install/tree/stable/docs/handbook)
for tuning, hardening, and desktop setup.

---
[Handbook index](README.md) · [Next: Configuration & the CLI →](01-configuration-cli.md)
