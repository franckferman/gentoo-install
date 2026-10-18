# Entering the chroot

> Turn the unpacked stage3 under `/mnt/gentoo` into something commands can run
> in: copy in name resolution, mount the pseudo-filesystems and the EFI system
> partition, then `chroot` into it. This mirrors `steps/50_chroot.sh` and
> `lib/chroot.sh`. This chapter is the exact moment the install crosses from the
> live medium into the target, so every command below says which side it runs
> on.

## What the installer does

`step_50_chroot` calls `chroot_prepare`, which, in order: resolves and sanity-
checks the target root; mounts `/proc`, `/sys`, `/dev` (with `/dev/pts` and
`/dev/shm`) and `/run` inside it, using the recursive-bind and `make-rslave`
pattern; mounts the EFI system partition on `/boot/efi`; and copies the live
medium's `/etc/resolv.conf` into the target so Portage has a working network.
It then proves a command really executes inside by running `/bin/true` there,
and prints how to open an interactive shell yourself.

The end state is a target you can run commands in. The installer keeps the
mounts up: steps 60 through 90 all run inside them, and step 95 releases them.
`core.sh`'s exit trap releases them too, so an interrupted run never leaves the
target half-mounted.

Up to now every command ran on the **live medium** against `/mnt/gentoo`. After
the `chroot` call, commands run **inside the target**. This chapter uses
`# live` for the former and `# chroot` for the latter, and the two are not
interchangeable.

## Concepts

**What a chroot is.** `chroot /mnt/gentoo /bin/bash` runs a shell whose idea of
`/` is `/mnt/gentoo`. From inside, `/bin/bash`, `/usr`, `/etc` and every path
are the *target's* files, not the live medium's. You are building the new system
with its own userland: its compiler, its Portage, its `eselect`. What you are
**not** changing is the running kernel. The live kernel keeps running the whole
time; the chroot only swaps the filesystem view.

**Why the pseudo-filesystems.** Because the kernel is still the live one, the
target needs windows onto it, and onto the devices and runtime state the running
system maintains. Each mount answers a concrete need:

- **`/proc`** is the kernel's process and system interface. Portage refuses to
  build without a sane `/proc` and `/dev`; `emerge` reads `/proc/self/mounts`.
- **`/sys`** is sysfs, the device and bus tree. Kernel installs, `udev` and
  bootloader tools read it.
- **`/dev`** is the device nodes. Without it the chroot has no `/dev/null`,
  `/dev/urandom` or disk nodes, and almost nothing works.
- **`/dev/pts`** is the pseudo-terminal devices. Without it the chroot cannot
  open a terminal.
- **`/dev/shm`** is POSIX shared memory. Without a tmpfs here, every build that
  uses shared memory breaks.
- **`/run`** is volatile runtime state. Tools expect it to exist and match the
  host's.

**Why recursive bind plus `make-rslave`.** `/sys` and `/dev` are not single
filesystems; they have other filesystems mounted under them, so a recursive bind
(`--rbind`) carries the children in too. `--make-rslave` then marks the copy a
*slave*: mount events still flow from host to chroot, but a mount you make later
inside the chroot does **not** propagate back out to the host. Skip it and a
`umount -R` on the way out can reach back and take the host's own `/dev` with it.
`/run` is bound plainly and made a slave for the same reason.

**Why the EFI system partition is mounted now.** On a UEFI machine the
bootloader (step 80, chapter 11) writes into `/boot/efi`. If that is just an
empty directory inside the chroot, those writes land on the root filesystem
instead, the firmware never sees them, and the machine does not boot, with no
error to explain it. Mounting the real ESP there now is what makes the later
bootloader step reach the firmware partition. A BIOS machine has no ESP and this
is simply skipped.

**Why `resolv.conf` is copied with `cat`, not `cp`.** Inside the chroot,
`emerge` needs DNS. On a systemd live medium `/etc/resolv.conf` is a symlink into
`/run/systemd/resolve`; copying the *symlink* would give the chroot a dangling
link and a name-resolution failure nobody connects back to this step. Copying the
*contents* avoids that.

## Do it by hand

The target is mounted at `/mnt/gentoo` with the stage3 unpacked (chapter 06).

### 1. Copy in name resolution (live)

```bash
# live
cat /etc/resolv.conf > /mnt/gentoo/etc/resolv.conf
```

Using `cat` (reading the contents) rather than `cp -L`/`cp` of a possible
symlink is deliberate, as above.

### 2. Mount the pseudo-filesystems (live)

In the order the Gentoo Handbook gives, which is also the reverse order they
must be unmounted in:

```bash
# live
mount -t proc  /proc  /mnt/gentoo/proc
mount --rbind  /sys   /mnt/gentoo/sys
mount --make-rslave   /mnt/gentoo/sys
mount --rbind  /dev   /mnt/gentoo/dev
mount --make-rslave   /mnt/gentoo/dev
mount --bind   /run   /mnt/gentoo/run
mount --make-slave    /mnt/gentoo/run
```

`/dev/pts` and `/dev/shm` normally arrive with the recursive bind of `/dev`, so
you usually do not mount them again. If a stage3 unpacked over a tmpfs `/dev`
leaves them missing, add them explicitly, with the same options the installer
uses:

```bash
# live  (only if /dev/pts or /dev/shm did not come across)
mount -t devpts -o gid=5,mode=620            devpts /mnt/gentoo/dev/pts
mount -t tmpfs  -o nosuid,nodev,noexec,mode=1777 tmpfs  /mnt/gentoo/dev/shm
```

### 3. Mount the EFI system partition (live)

Find the ESP for the target's disk (the FAT32 partition with the EFI type GUID),
then mount it on `/boot/efi` inside the target. Assume it is `/dev/sda1` here:

```bash
# live
blkid /dev/sda1                              # TYPE should be "vfat"
mkdir -p /mnt/gentoo/boot/efi
mount -t vfat /dev/sda1 /mnt/gentoo/boot/efi
```

**Warning:** Mount the *right* partition. Mounting a non-vfat partition on `/boot/efi`
hides the real ESP and loses the bootloader. The installer checks the filesystem
type with `blkid` and refuses anything that is not `vfat`; do the same by hand.
(A systemd-boot layout may mount the ESP on `/boot` instead; use that mountpoint
if that is your layout.)

### 4. Enter the chroot (live → chroot)

**Warning:** This is the crossing. Everything after it writes to the **target**, not the
live medium.

```bash
# live
chroot /mnt/gentoo /bin/bash
# chroot
source /etc/profile
export PS1="(chroot) ${PS1}"
```

`source /etc/profile` loads the target's `PATH` and environment; the `PS1`
change gives you a visible `(chroot)` marker so you always know which side you
are on. The installer does the equivalent non-interactively: before each command
it runs, it sources `/etc/profile` with output silenced and sets a clean `PATH`,
then executes your command directly with no shell re-quoting. For an interactive
look-around it opens `chroot /mnt/gentoo /bin/bash --rcfile ... -i` with a red
`(chroot)` prompt.

### 5. Prove a command actually runs inside

```bash
# chroot
/bin/true && echo "the chroot runs commands"
cat /etc/gentoo-release
```

The installer runs `/bin/true` inside precisely here. It is one fork now versus
discovering three hours into a kernel build that nothing ever ran. A 32-bit or
foreign-architecture stage3 on a 64-bit host mounts fine but runs nothing;
catching it here is the point.

## Verify

```bash
# chroot
test -r /proc/self/mounts && echo proc ok
test -d /sys/class        && echo sys ok
test -c /dev/null         && echo dev ok
test -e /dev/fd/0         && echo "/dev/fd ok"        # bash process substitution
findmnt /boot/efi         # on a UEFI machine: the ESP, type vfat
getent hosts gentoo.org   # name resolution works
```

The last four matter for real work. `emerge` uses bash process substitution, so
a missing `/dev/fd` stops it before it reads anything; a working `/boot/efi`
mount is the difference between a booting and a non-booting machine; and DNS is
what lets Portage sync and fetch. From another live terminal you can reach the
same chroot with `chroot /mnt/gentoo /bin/bash -l`.

## Pitfalls and rollback

- **"Refusing to treat / as a chroot target."** The installer resolves the path
  with `readlink -f` first, so `/`, `//`, `/mnt/..` and other spellings of the
  root are all caught. Every mount and unmount would otherwise land on the
  running system. Point it at `/mnt/gentoo`.
- **Mounted but nothing runs.** Usually an architecture mismatch between the
  stage3 and the host. Re-check the variant you unpacked (chapter 06).
- **`emerge` fails on a sane `/dev` or on process substitution.** A
  pseudo-filesystem did not mount. Re-run the mount block; the installer probes
  `/proc`, `/sys`, `/dev` and `/dev/fd` by name and tells you which is missing.
- **Unmounting on the way out.** Release deepest-first, the reverse of the mount
  order, and let the recursive unmount handle the children:
  ```bash
  # live   (after exiting the chroot shell)
  umount -R /mnt/gentoo/boot/efi
  umount -R /mnt/gentoo/dev /mnt/gentoo/run /mnt/gentoo/sys /mnt/gentoo/proc
  ```
  The installer tracks exactly the mounts *this run* created and unmounts only
  those, deepest first, falling back to a lazy `umount -Rl` when one is busy. A
  mount that was already there when it arrived is adopted and left untouched. If
  a mount will not release, `fuser -vm /mnt/gentoo` names what still holds it.
- **Resuming later.** When you come back for another step (`--resume`, or
  `--steps 70,80`), the target is no longer mounted, because the previous run
  released everything it mounted. The installer re-mounts the tree from the disk
  plan step 20 recorded, reopening a LUKS container if one was used, before it
  re-enters. By hand, re-mount the root and re-run this chapter's steps first.
- **Rollback.** Nothing here is written to the target except `/etc/resolv.conf`.
  Unmounting (above) fully undoes the step.

## Reference

- **Step:** `50` - `steps/50_chroot.sh`
- **Uses:** `lib/chroot.sh` (mounts, entry, cleanup), plus `lib/disk.sh` and
  `lib/crypt.sh` for re-mounting a target a previous run left behind
- **Flags/settings:** `root` (the target, default `/mnt/gentoo`); `esp_device`
  and the ESP mountpoint (default `/boot/efi`); honours `GI_TARGET`,
  `GI_ESP_DEVICE`, `GI_ESP_MOUNTPOINT` for testing
- **Writes:** mounts under `root` (`/proc`, `/sys`, `/dev`, `/dev/pts`,
  `/dev/shm`, `/run`, the ESP); `<root>/etc/resolv.conf`; state-journal entries
  `chroot.target`, `chroot.mounts`, `chroot.esp`

---
[← Previous: The stage3 (fetch, verify, unpack)](06-stage3.md) · [Handbook index](README.md) · [Next: Portage (profile, make.conf, sets) →](08-portage.md)
