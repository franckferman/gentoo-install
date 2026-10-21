# Kernel, initramfs & cmdline

> A kernel (one of three ways), an initramfs that can open an encrypted root,
> and the command line that ties the two together. Mirrors `steps/70_kernel.sh`
> and `variants/kernel/*`, driven by `--kernel`.

## What the installer does

`step_70_kernel` (in `steps/70_kernel.sh`) puts a bootable kernel in the
target's `/boot`, and, for anything but an unencrypted root on a plain
partition, an initramfs beside it. It delegates the "how" to one of three
variants under `variants/kernel/` (`dist-kernel`, `genkernel`, `manual`), but
the two things that decide whether an encrypted machine comes back up it keeps
for itself: the **dracut module list** and the **kernel command line**. Both are
composed from what steps 20 and 30 recorded, never hardcoded, so the eight
combinations of crypt variant and disk layout each get the line they need.

The end state: `/boot/vmlinuz-<version>` and (almost always)
`/boot/initramfs-<version>.img`, a `/etc/dracut.conf.d/70-gentoo-install.conf`
that tells dracut what to build, and the composed command line recorded in the
state journal as `kernel.cmdline` for step 80 to hand to the bootloader. The
installer runs every command with `chroot /mnt/gentoo ...`; by hand you are
already inside the chroot from [chapter 07](07-chroot.md), so the blocks below
are marked `# chroot`.

## Concepts

- **Three kernels.** `dist-kernel` (the default) installs a kernel the way
  Portage installs anything: `sys-kernel/gentoo-kernel-bin` is prebuilt and
  signed by Gentoo (minutes, not hours), and `sys-kernel/gentoo-kernel` is the
  same configuration compiled from source. `genkernel` compiles the kernel here
  and builds *its own* initramfs. `manual` takes your sources and your
  `.config`.
- **The initramfs is what opens the container.** A LUKS root, or a root on LVM,
  cannot be mounted by the bare kernel: it needs a small early userspace
  (the initramfs) carrying `cryptsetup`, `dmsetup`, and friends. Get its module
  list wrong and the machine stops at a dracut prompt with no root and no
  message that names the missing piece. This is the single most common way an
  encrypted Gentoo install fails to boot.
- **Two initramfs dialects.** dracut and genkernel do not share a parameter
  name for unlocking a container. dracut reads `rd.luks.uuid=`; genkernel's own
  initramfs reads `crypt_root=`. A line written for one is silently ignored by
  the other, so the command line is composed in the dialect of whichever tool
  will read it (`kernel.initramfs_generator`, defaulting to `genkernel` for the
  genkernel variant and `dracut` otherwise).
- **The command line is derived, not fixed.** It names where root is, which
  container to open, and how. The installer builds it from the crypt variant,
  the topology (`plain` or `lvm`), and the generator.

## Do it by hand

### 1. Write the dracut configuration first

dracut's configuration has to be in place *before* the kernel is emerged,
because `sys-kernel/installkernel` runs dracut from inside that emerge. A
configuration written afterwards arrives one initramfs too late.

```bash
# chroot
mkdir -p /etc/dracut.conf.d
cat > /etc/dracut.conf.d/70-gentoo-install.conf <<'EOF'
hostonly="yes"
hostonly_cmdline="no"
kernel_cmdline="root=/dev/mapper/gentoo ro rd.luks.uuid=luks-<LUKS-UUID>"
add_dracutmodules+=" crypt dm "
omit_dracutmodules+=" systemd plymouth "
EOF
```

The two lines that matter most: `hostonly_cmdline="no"` stops dracut baking the
*live medium's* command line into the target's image, and `kernel_cmdline=` is
the line composed in the next step. The module list and the command line above
are examples; compute yours below.

**Module list.** Start empty, then:

- encrypted (`crypt` is `passphrase`, `tpm`, or `keyfile`): add `crypt dm`
- root on LVM: add `dm lvm`
- `crypt=tpm`: add `clevis clevis-pin-tpm2` (see [chapter 10](10-tpm-sealing.md))
- `crypt=keyfile`: add `crypt-gpg`

Omit `plymouth` always (a splash screen draws over the passphrase prompt), and
omit `systemd` unless the target init is systemd.

### 2. Compose the kernel command line

Build it piece by piece. The `root=` token depends on topology, crypt, and
generator:

| Topology / crypt | generator | `root=` |
|---|---|---|
| plain, `crypt=none` | any | `root=UUID=<root-fs-uuid>` (or `root=<device>`) |
| plain, encrypted | dracut | `root=/dev/mapper/<crypt_name>` (default `gentoo`) |
| plain, encrypted | genkernel | `root=/dev/mapper/root` |
| lvm | any | `root=/dev/mapper/<vg>-<lv>` |

**Warning:** In `/dev/mapper`, a hyphen in a volume-group or logical-volume name is
**doubled**: a group `vg-crypt` appears as `vg--crypt`. A `root=` that spells it
once boots to a dracut prompt and still looks right in the log.

Then append, in order:

- `rootfstype=<fstype>` if the root filesystem type is known
- `ro` always (the initramfs mounts read-only; init remounts rw)
- LVM: `dolvm` for genkernel, or `rd.lvm.vg=<vg>` for dracut
- unlock token for `passphrase`/`tpm`/`keyfile`:
  - dracut: `rd.luks.uuid=luks-<LUKS-UUID>` (the `luks-` prefix is what dracut
    itself prints; it strips it before comparing, so the bare UUID works too)
  - genkernel: `crypt_root=UUID=<LUKS-UUID>`
- `keyfile` only, the key's location:
  - dracut: `rd.luks.key=<path>:UUID=<device-uuid>`
  - genkernel: `root_key=<path> root_keydev=UUID=<device-uuid>`
- anything in `kernel_cmdline_extra`

The LUKS UUID is `cryptsetup luksUUID <device>`; the root filesystem UUID is
`blkid -s UUID -o value <device>`.

**Warning:** If you set `console=` to a serial port only (for example
`console=ttyS0,115200`), the kernel hands the framebuffer to the serial line and
the initramfs asks for the LUKS passphrase where nobody is looking. Name the
screen too: `console=tty0 console=ttyS0,115200`, screen last.

### 3a. Distribution kernel (`--kernel dist-kernel`, the default)

```bash
# chroot
# installkernel runs dracut; without the dracut USE flag the kernel lands in
# /boot with no initramfs beside it.
echo 'sys-kernel/installkernel dracut' >> /etc/portage/package.use/70-gentoo-install-kernel
emerge --verbose sys-kernel/installkernel

# The packages the initramfs needs to open the container (idempotent):
emerge --verbose sys-fs/cryptsetup sys-kernel/dracut      # add app-crypt/gnupg for keyfile
# On an LVM root, lvm2 must carry USE=lvm or dracut's lvm module has no binary:
#   echo 'sys-fs/lvm2 lvm' >> /etc/portage/package.use/70-gentoo-install-kernel

emerge --verbose sys-kernel/gentoo-kernel-bin             # or gentoo-kernel for source
emerge --verbose sys-kernel/linux-firmware                # wifi/GPU on real hardware
```

Merging `gentoo-kernel-bin` deploys `/boot` from its postinstall hook and runs
dracut against the configuration from step 1. On a systemd target you also need
`sys-apps/systemd[cryptsetup]`, because its initramfs starts
`systemd-cryptsetup@.service` rather than calling `cryptsetup`:

```bash
# chroot (systemd target only)
echo 'sys-apps/systemd cryptsetup' >> /etc/portage/package.use/70-gentoo-install-kernel
emerge --verbose --changed-use sys-apps/systemd
dracut --force --kver <version>      # rebuild so the new module is in the image
```

### 3b. genkernel (`--kernel genkernel`)

```bash
# chroot
emerge --verbose sys-kernel/genkernel sys-kernel/gentoo-sources
emerge --verbose sys-fs/cryptsetup            # genkernel's --luks needs it present
eselect kernel set 1                          # point /usr/src/linux at the sources
genkernel --bootdir=/boot --no-mountboot --makeopts=-j$(nproc) --luks all
```

Add `--lvm` for an LVM root, `--gpg` for the GPG keyfile variant, and
`--kernel-config=<file>` to start from a configuration you trust. genkernel
cannot do `crypt=tpm`: clevis is a dracut module and genkernel builds its own
initramfs, so the installer refuses that combination here.

### 3c. manual (`--kernel manual`)

```bash
# chroot
emerge --verbose sys-kernel/gentoo-sources
emerge --verbose sys-fs/cryptsetup sys-kernel/dracut
eselect kernel set 1                          # /usr/src/linux -> the sources

cd /usr/src/linux
zcat /proc/config.gz > .config                # or cp your own .config here
```

For an encrypted or LVM root the configuration must carry at least
`CONFIG_BLK_DEV_INITRD=y`, `CONFIG_MD=y`, `CONFIG_BLK_DEV_DM=y`,
`CONFIG_DM_CRYPT=y`, and the crypto the LUKS header uses (`CONFIG_CRYPTO_AES`,
`CONFIG_CRYPTO_XTS`, `CONFIG_CRYPTO_SHA512` for the default `sha512` header hash,
`CONFIG_CRYPTO_USER_API_SKCIPHER`). For `crypt=tpm` add `CONFIG_TCG_TPM`,
`CONFIG_TCG_CRB`, and `CONFIG_CRYPTO_SHA256` for the TPM's sha256 PCR bank; for `bootloader=efistub` add `CONFIG_EFI=y`,
`CONFIG_EFI_STUB=y`. Set them with the tree's own tool so dependencies resolve:

```bash
# chroot (in /usr/src/linux)
scripts/config --enable CONFIG_DM_CRYPT --enable CONFIG_BLK_DEV_DM
make olddefconfig                             # re-resolve; do not sed .config
make -j$(nproc) && make modules_install && make install
dracut --force --kver "$(make -s kernelrelease)"
```

## Verify

```bash
# chroot
ls -l /boot/vmlinuz-* /boot/initramfs-*.img    # a real kernel is megabytes
lsinitrd /boot/initramfs-<version>.img --mod    # must list: crypt, dm, (lvm/clevis/...)
```

`lsinitrd ... --mod` is the authority: it asks the image what it carries rather
than trusting the configuration. For an encrypted root the list must include
`crypt`. On a systemd target it must also include `systemd-cryptsetup` (which
dracut adds only when `/usr/lib/systemd/systemd-cryptsetup` exists, that is, when
`sys-apps/systemd[cryptsetup]` is installed). Step 95 asks this same question
again before it lets you reboot.

## Pitfalls and rollback

- **Missing crypt module.** The emerge for the module's package failed (classic
  with `app-crypt/clevis`, which lives in the GURU overlay, not the official
  tree). The kernel still installed but the initramfs cannot open the container.
  Rebuild once the package is present: `dracut --force --add 'crypt dm' --kver
  <version>`.
- **Stale initramfs.** The image on disk predates a package it is built out of
  (for example `systemd[cryptsetup]` or clevis arrived on a later run). The
  symptom is a correct configuration and a wrong image. Rebuild:
  `emerge --config sys-kernel/gentoo-kernel-bin` (dist-kernel) or
  `dracut --force --kver <version>`.
- **Wrong `root=`.** A doubled-hyphen slip, or the genkernel dialect written
  for a dracut initramfs, drops you at a dracut prompt. **Warning:** This is only
  recoverable from a live medium and a chroot, so check the composed line before
  rebooting.
- **Resume.** The kernel facts (`kernel.variant`, `kernel.build`,
  `kernel.initramfs_generator`) are recorded so a `--resume` hours later
  rebuilds the same kernel the disk already carries. `--restart` clears them.

## Reference

- **Step:** `70` - `steps/70_kernel.sh`
- **Uses:** `variants/kernel/{dist-kernel,genkernel,manual}.sh`;
  `lib/core.sh`, `lib/config.sh`, `lib/state.sh`
- **Flags/settings:** `--kernel dist-kernel|genkernel|manual`,
  `--kernel-build binary|source`, `--initramfs dracut|genkernel`,
  `--kernel-config PATH|defconfig|running`, `--kernel-source-dir PATH`,
  `--kernel-firmware yes|no`, `--kernel-embed-cmdline`, `--kernel-menuconfig`,
  `--dracut-modules-extra`, `--kernel-cmdline-extra`
- **Writes:** `/etc/portage/package.use/70-gentoo-install-kernel`,
  `/etc/dracut.conf.d/70-gentoo-install.conf`, `/boot/vmlinuz-<version>`,
  `/boot/initramfs-<version>.img`; state `kernel.version`, `kernel.image`,
  `kernel.initramfs`, `kernel.cmdline`, `kernel.variant`, `kernel.build`,
  `kernel.initramfs_generator`

---
[← Previous: Portage (profile, make.conf, sets)](08-portage.md) · [Handbook index](README.md) · [Next: TPM sealing →](10-tpm-sealing.md)
