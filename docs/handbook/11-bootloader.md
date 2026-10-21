# Bootloader (GRUB / EFI stub / systemd-boot / UKI)

> Make the kernel of step 70 reachable at power-on, four different ways, and
> verify each one before returning. Mirrors `steps/80_boot.sh` and
> `variants/boot/*`, driven by `--bootloader`.

## What the installer does

`step_80_boot` (in `steps/80_boot.sh`) installs one of four bootloaders and
checks its own work: the EFI file exists, the generated configuration parses,
the boot entry is in NVRAM (or the removable fallback is on the ESP). It sources
`steps/70_kernel.sh` so the command line and kernel image it uses are exactly
the ones the initramfs was built for; two implementations of that would be one
too many.

It first resolves the firmware mode (`uefi` or `bios`, auto-detected from
`/sys/firmware/efi`) and refuses the three UEFI-only variants on a BIOS run. Then
it dispatches to a variant under `variants/boot/`. The end state is a disk a
firmware will start: a loader (or the kernel itself) on the EFI system partition
or in the MBR, pointed at by an NVRAM entry or the removable-media path, with the
kernel command line delivered by whichever channel the variant uses. The
installer runs its commands with `chroot /mnt/gentoo ...`; by hand you are inside
the chroot, so the blocks are `# chroot`.

## Concepts

- **Which one, and why.** **GRUB** is the default because it boots everything:
  UEFI and legacy BIOS, an encrypted `/boot`, a root on LVM, a disk that also
  carries Windows, and it has an editable menu for the first reboot. **EFI
  stub** removes the loader entirely: the kernel is itself an EFI binary the
  firmware launches, with nothing in between to misconfigure and nothing to fall
  back to. **systemd-boot** is a small UEFI loader whose menu is a directory of
  plain-text entry files. **UKI** (unified kernel image) packs kernel,
  initramfs, and command line into one signed EFI binary that boots from the
  fallback path with *no NVRAM entry at all*, which is the shape that survives a
  cleared NVRAM and the shape Secure Boot wants.
- **The command line must match.** Every variant hands the kernel the same line
  step 70 composed (recorded as `kernel.cmdline`). Where it lives differs: GRUB
  puts it in `GRUB_CMDLINE_LINUX`, the EFI stub in the NVRAM load options or
  `CONFIG_CMDLINE`, systemd-boot in the entry's `options`, the UKI compiled into
  the image.
- **NVRAM is firmware state, not a file.** It is global to the machine and
  outlives the install. Writing an entry for a disk this machine did not boot
  from, while running on an installed system, can overwrite that machine's own
  entry with a pointer to a disk the firmware will not find at the next power-on.
  The installer guards every NVRAM write with `disk_may_write_firmware_state`
  and falls back to `\EFI\BOOT\BOOTX64.EFI` when the write is unsafe.
- **Secure Boot is optional throughout.** If `--secureboot-keyfile` and
  `--secureboot-cert` are both given, every EFI binary is signed with `sbsign`
  and the signature is verified against the certificate; otherwise binaries are
  installed unsigned and the installer says so.

## Do it by hand

### GRUB (`--bootloader grub`, the default)

```bash
# chroot
# USE flag selects the platform grub-install needs:
echo 'sys-boot/grub grub_platforms_efi-64' >> /etc/portage/package.use/70-gentoo-install-kernel
emerge --verbose sys-boot/grub sys-boot/efibootmgr   # efibootmgr: UEFI only

# Put our command line in GRUB_CMDLINE_LINUX. grub-mkconfig writes its own
# root= from grub-probe first and appends ours after, so ours wins (it is last).
cat >> /etc/default/grub <<'EOF'
GRUB_DISTRIBUTOR="Gentoo"
GRUB_TIMEOUT=5
GRUB_CMDLINE_LINUX="root=/dev/mapper/gentoo ro rd.luks.uuid=luks-<UUID>"
EOF
```

If `/boot` lives *inside* the LUKS container, GRUB has to open it itself: add
`GRUB_ENABLE_CRYPTODISK=y` and `GRUB_PRELOAD_MODULES="cryptodisk luks2"` (and
`lvm` for an LVM root). With `/boot` on the ESP or its own plain partition GRUB
never sees the encryption, so leave cryptodisk off (it only adds a second
passphrase prompt).

**Warning:** GRUB only learned to open an `argon2id` LUKS2 keyslot in 2.12 (late
2023), and this installer's default PBKDF is `argon2id` (chapter 05). An encrypted
`/boot` opened by an older GRUB fails to unlock with a cryptic error. The default
layout avoids this by keeping `/boot` on the unencrypted ESP; if you deliberately
put `/boot` inside LUKS, either run GRUB 2.12 or newer, or give GRUB a pbkdf2
keyslot of its own (`cryptsetup luksAddKey --pbkdf pbkdf2 "$DEV"`).

Then install and generate:

```bash
# chroot (UEFI)
grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=gentoo
# chroot (legacy BIOS): the whole disk, not a partition
grub-install --target=i386-pc /dev/sda

grub-mkconfig -o /boot/grub/grub.cfg
grub-script-check /boot/grub/grub.cfg          # the installer rolls back on failure
```

**Warning:** `grub-mkconfig` writes a shell script. If it does not parse, the machine
reaches a rescue prompt at power-on with no shell to fix it. Always run
`grub-script-check` before trusting it.

### EFI stub (`--bootloader efistub`, UEFI only)

No loader at all. The kernel must be built with `CONFIG_EFI_STUB=y` (the
dist-kernel ships it; the manual variant sets it when `bootloader=efistub`). The
command line travels in the NVRAM entry's load options by default
(`efistub_cmdline=efibootmgr`), where `efibootmgr -v` can show it and the
firmware menu can change it, or compiled in (`builtin`, `CONFIG_CMDLINE`).

```bash
# chroot
emerge --verbose sys-boot/efibootmgr
mkdir -p /boot/EFI/gentoo
cp /boot/vmlinuz-<version> /boot/EFI/gentoo/vmlinuz.efi
cp /boot/initramfs-<version>.img /boot/EFI/gentoo/initramfs.img
efibootmgr --create --disk /dev/sda --part 1 --label gentoo \
  --loader '\EFI\gentoo\vmlinuz.efi' \
  --unicode 'initrd=\EFI\gentoo\initramfs.img root=/dev/mapper/gentoo ro rd.luks.uuid=luks-<UUID>'
```

`initrd=` is a load option too, so the EFI stub reads it from the NVRAM entry and
nowhere else; it is required even when `CONFIG_CMDLINE` owns the rest of the
line. Confirm the file starts with the PE magic (`head -c 2 vmlinuz.efi` prints
`MZ`); a kernel without the stub is skipped silently by the firmware.

### systemd-boot (`--bootloader systemd-boot`, UEFI only)

`bootctl` comes from `sys-apps/systemd` on a systemd target, or from
`sys-apps/systemd-utils[boot,kernel-install]` on OpenRC (the `boot` flag builds
`bootctl` and the loader; the ebuild requires `kernel-install` alongside it).

```bash
# chroot (OpenRC)
echo 'sys-apps/systemd-utils boot kernel-install' >> /etc/portage/package.use/70-gentoo-install-kernel
emerge --verbose sys-apps/systemd-utils sys-boot/efibootmgr

bootctl --esp-path=/boot install               # writes the loader + removable copy

mkdir -p /boot/loader/entries
cat > /boot/loader/loader.conf <<'EOF'
default gentoo.conf
timeout 5
EOF
cat > /boot/loader/entries/gentoo.conf <<EOF
title      Gentoo Linux
version    <version>
linux      /vmlinuz-<version>
initrd     /initramfs-<version>.img
options    root=/dev/mapper/gentoo ro rd.luks.uuid=luks-<UUID>
EOF
bootctl --esp-path=/boot list                  # the loader's own reading of the entry
```

The `linux` and `initrd` paths are relative to the root of the ESP, which
systemd-boot reads directly. With the ESP at `/boot` (the default) the kernel
step 70 installed already sits at the ESP root, so the entry points straight at
it and nothing is copied, which is exactly what the installer does. If you mount
the ESP elsewhere, say `/efi`, copy the kernel and initramfs into a subdirectory
on it (`/efi/EFI/gentoo/`) and point `linux` and `initrd` there instead.

### UKI (`--bootloader uki`, UEFI only)

One signed binary, built by `dracut --uefi`, which wraps the kernel and
initramfs around systemd's EFI stub (`linuxx64.efi.stub`, from
`sys-apps/systemd[boot]` or `sys-apps/systemd-utils[boot,kernel-install]`).

```bash
# chroot
emerge --verbose sys-kernel/dracut sys-apps/systemd-utils   # or systemd[boot]
mkdir -p /boot/EFI/Linux
dracut --force --uefi --kver <version> \
  --uefi-stub /usr/lib/systemd/boot/efi/linuxx64.efi.stub \
  --kernel-cmdline 'root=/dev/mapper/gentoo ro rd.luks.uuid=luks-<UUID>' \
  /boot/EFI/Linux/gentoo-<version>.efi

# The reason to build a UKI: a copy at the fallback path needs no NVRAM entry.
mkdir -p /boot/EFI/BOOT
cp /boot/EFI/Linux/gentoo-<version>.efi /boot/EFI/BOOT/BOOTX64.EFI
```

Note: if step 70 already wrote your command line into
`/etc/dracut.conf.d/70-gentoo-install.conf`, dracut picks it up from there and
you must *not* also pass `--kernel-cmdline` with the same value, or the line ends
up in the image twice.

## Verify

```bash
# chroot
head -c 2 /boot/EFI/.../<binary>.efi           # 'MZ' = a PE binary the firmware can run
efibootmgr -v                                  # UEFI: the entry and its loader path
ls /boot/EFI/BOOT/BOOTX64.EFI                   # the removable fallback, if written
```

For GRUB also confirm `grep -c '^menuentry' /boot/grub/grub.cfg` is non-zero and
that your `root=` is the *last* one on the `linux` line. For a UKI, the proof is
that `/boot/EFI/BOOT/BOOTX64.EFI` is the same file as the image in `/boot/EFI/Linux`.
Step 95 re-runs all of these as its "Boot entry" check.

## Pitfalls and rollback

- **UEFI-only variant on a BIOS boot.** efistub, systemd-boot, and uki need an
  ESP. The installer refuses before touching anything; use `--bootloader grub`,
  or `--firmware uefi` if only the installer (not the target) booted legacy.
- **Warning:** **No entry and no fallback.** An install that writes neither leaves a disk
  that drops to the firmware menu or straight to PXE. When the NVRAM write is
  guarded off, the installer writes `\EFI\BOOT\BOOTX64.EFI` instead; by hand, do
  the same (`--boot-removable yes`, or copy the loader there).
- **Secure Boot refusal.** An unsigned binary on a machine with Secure Boot on
  is refused at power-on with no useful message. Sign with `--secureboot-keyfile`
  / `--secureboot-cert`, or disable Secure Boot in firmware setup. For GRUB,
  signing the binary is only half an answer (its modules and config stay
  unsigned); a UKI is the clean Secure Boot shape.
- **ESP not mounted where expected.** `grub-install` and `bootctl install` write
  into the ESP and will not create it; mount it at `--esp-mount` first.
- **Kernel update.** efistub and (until `installkernel` is wired) systemd-boot
  and uki do not refresh the ESP on a kernel update; rerun step 80 after one.
- **Resume.** The NVRAM label and the signing certificate/key path are recorded
  so a later run does not re-derive them from a default.

## Reference

- **Step:** `80` - `steps/80_boot.sh`
- **Uses:** `variants/boot/{grub,efistub,systemd-boot,uki}.sh`;
  `steps/70_kernel.sh` (for `kernel_cmdline`, `kernel_installed`); `lib/*.sh`
- **Flags/settings:** `--bootloader grub|efistub|systemd-boot|uki`,
  `--firmware uefi|bios` (auto-detected if unset), `--boot-label`, `--boot-timeout`,
  `--boot-removable yes|no`, `--efistub-cmdline efibootmgr|builtin`,
  `--secureboot-keyfile PATH`, `--secureboot-cert PATH`
- **Writes (by variant):** GRUB `/etc/default/grub`, `/boot/grub/grub.cfg`, the
  EFI binary under `<esp>/EFI/<label>/` or the MBR; efistub
  `<esp>/EFI/<label>/vmlinuz.efi` and `initramfs.img`; systemd-boot
  `<esp>/loader/loader.conf`, `<esp>/loader/entries/<label>.conf`, the loader
  under `<esp>/EFI/systemd/`; uki `<esp>/EFI/Linux/<label>-<version>.efi` and the
  fallback `<esp>/EFI/BOOT/BOOTX64.EFI`; an NVRAM entry where allowed; state
  `boot.variant`, `boot.firmware`, `boot.label`

---
[← Previous: TPM sealing](10-tpm-sealing.md) · [Handbook index](README.md) · [Next: System configuration →](12-system-config.md)
