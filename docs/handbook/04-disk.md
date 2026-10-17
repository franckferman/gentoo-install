# Partitioning & formatting the disk

> Lay a GPT table down on the target, make an EFI System Partition and the
> volumes your layout asks for, format them, and mount the tree under
> `/mnt/gentoo`. This mirrors `steps/20_disk.sh` (`--disk`, `--disk-layout`).

**Warning:** **This is the one step in the whole install that cannot be undone.** Every
other phase writes into a tree you can wipe and redo; this phase erases a block
device. Once `sgdisk` writes a fresh table and `mkfs` runs, whatever was on the
disk is gone, and no `--rollback`, `--resume` or backup in this installer brings
it back. Read the whole chapter before you type a device name. Confirm, by hand
and out loud, that the device you are about to erase is the one you mean.

## What the installer does

`step_20_disk` (in `steps/20_disk.sh`, driving `lib/disk.sh` and one file under
`variants/layout/`) takes a chosen disk from whatever it holds now to a
partitioned, formatted tree mounted under `/mnt/gentoo`. In order it:

1. validates the disk settings (layout, filesystem, LVM mode, ESP size), in
   milliseconds, before a sector is read;
2. prints an inventory of every disk on the machine;
3. resolves the target (an explicit `--disk`, or one internal disk offered for
   confirmation, or a menu), and refuses it if it is not a whole disk, is
   removable, is mounted, or carries the running system;
4. computes a **plan**, a table of real sizes, and prints it;
5. asks three separate gates (below) before touching anything;
6. releases holders, wipes signatures and both GPT headers, writes a new GPT;
7. creates the partitions with `sgdisk`;
8. if the layout uses LVM, builds the volume group and logical volumes;
9. formats every volume and mounts the tree;
10. verifies the result and records the plan as facts for later steps.

When encryption is requested, step 20 **stops after partitioning** and hands
over: the LUKS header has to exist before any filesystem does, so step 30 opens
the container and creates the filesystems inside it (see
[Encryption](05-encryption.md)).

## Concepts

**GPT and the ESP.** The installer writes a GUID Partition Table, which keeps a
primary header at the start of the disk and a backup at the very end. The first
partition is always an **EFI System Partition** (ESP): a small FAT32 partition,
type code `EF00`, that UEFI firmware can read without any driver, where the
bootloader and (in this installer's default) the kernels live. The ESP defaults
to 1024 MiB (`disk_esp_size`) and is mounted at `/boot` (`disk_esp_mount`). A
512 MiB ESP is the number everyone copies and the first thing to fill up once
you keep more than three or four kernel generations; 1 GiB holds a dozen.

**A layout is a proportion, not a table of gigabytes.** `root:50` is a number
that works on the machine it was written for and ruins the plan on a 64 GiB
laptop. So a layout declares percentages with soft minima and maxima, and
`disk_plan` turns them into a table of real sizes that you read *before*
anything is written. Floors are enforced: a root volume never drops below 3 GiB,
and the installer warns when the filesystem that will build packages
(`/var/tmp/portage`, so `/var` when split off, otherwise `/`) is under 6 GiB,
because `sys-kernel/linux-firmware` alone unpacks 2.5 GiB.

**The four layout variants** (`--disk-layout`, files under `variants/layout/`):

| Variant | LVM | Volumes it declares |
|---------|-----|---------------------|
| `minimal` | no | `root:/` takes the rest. One root filesystem, no LVM, no swap volume. |
| `desktop` (default) | yes | `swap` (auto), `root:/` (25%, 8-80 GiB), `var:/var` (12%, 6-80 GiB), `home:/home` takes the rest. |
| `server` | yes | `swap` (auto), `root:/` (20%, 6-40 GiB), `var:/var` (35%, 8-400 GiB), `varlog:/var/log` (10%, 1-30 GiB), `home:/home` (15%, 2-200 GiB). The percentages add to 80; the remaining fifth is kept free in the volume group for `lvextend` and snapshots. |
| `custom` | yes unless `disk_lvm=no` | the volumes you name in `disk_volumes` (one line, records separated by `;`) or `disk_volumes_file` (one record per line). |

A record reads `name:mountpoint:size:filesystem`, where `size` is `rest`, `auto`
(swap only), `N%`, `N%/min/max`, or an absolute size like `8G`, and the
filesystem is a name or `@fs@` for whatever `--filesystem` says.

**Swap** (`disk_swap`, default `auto`) is sized from RAM, clamped to the 2-8 GiB
band, capped at a tenth of the disk, and dropped entirely on a disk under 4 GiB.

**Filesystems** (`--filesystem`, default `ext4`): `ext4` (the boring answer every
rescue disk repairs), `xfs`, `btrfs`, or `f2fs`. The ESP is always `vfat`.

**Three gates, not one gate three times.** `wipe_disk` is a tri-state you can
answer up front (`yes`/`no`/`ask`). The typed confirmation is a *proof* and no
flag lifts it: not `--yes`, not `--force`. And `_disk_assert_target()` is a check
the code runs on itself before every `sgdisk`, `wipefs` and `mkfs`, so a computed
path that is wrong stops in the code rather than on your disk.

## Do it by hand

Everything here runs on the **live medium** as root. The target tree ends up
under `/mnt/gentoo`.

### 1. See what disks the machine has

```bash
# live
lsblk -o NAME,SIZE,TYPE,TRAN,MODEL,MOUNTPOINTS
```

The installer prints the same inventory and refuses a disk that is removable
(USB transport), mounted, or carrying the running system. Pick a **whole disk**
(`nvme0n1`, `sda`), never a partition (`sda1`). **Warning:** Identify it by size, model,
and serial, not by letter: `sdb` is not a stable name.

```bash
# live - confirm the identity before you commit to it
DISK=/dev/nvme0n1
lsblk -f "$DISK"                       # what is on it now, about to be lost
sgdisk -p "$DISK" 2>/dev/null || true  # the current table, if any
```

### 2. Release anything holding the disk

`sgdisk` fails on a busy device and can leave the disk half-erased, so free the
stack from the top down: unmount, swap off, deactivate any volume group, close
any LUKS or device-mapper node.

```bash
# live
for mp in $(lsblk -lno MOUNTPOINT "$DISK" | grep -v '^$' | sort -r); do
  umount -R "$mp" || umount -l "$mp"
done
swapoff -a
# deactivate a volume group that lives on this disk, close any mapper:
vgchange -an <vg-on-this-disk> 2>/dev/null || true
cryptsetup close <mapper> 2>/dev/null || true
```

### 3. **Warning:** The point of no return: wipe signatures and write a fresh GPT

**Warning:** **Everything below destroys data on `$DISK`.** This is where you treat the
installer's typed proof as a habit: before each command, say the device path out
loud and check it against the model and serial from step 1. The installer makes
you type the exact path (`confirm_typed`) precisely because there is no reflex
answer to "type `/dev/nvme0n1`"; do the same deliberation by hand.

```bash
# live
# clear filesystem/RAID signatures on every partition, then on the disk itself
for part in $(lsblk -lnpo NAME,TYPE "$DISK" | awk '$2=="part"{print $1}'); do
  wipefs -a "$part"
done
wipefs -a "$DISK"
# zap both GPT headers (primary and the backup at the end of the disk), then
# write a clean, empty GPT. Zapping only the front leaves the stale backup
# header, which is what makes a "fresh" disk come back with yesterday's table.
sgdisk --zap-all "$DISK"
sgdisk --clear "$DISK"
partprobe "$DISK"; udevadm settle --timeout=15
```

The installer also offers heavier erase modes (`disk_erase`): `luks` destroys a
LUKS header first (crypto-erase, instant on a once-encrypted disk), `discard`
asks the drive to forget every block, `zero` overwrites the whole device. The
default is `quick`, which is the `wipefs`/`sgdisk` pass above.

### 4. Create the partitions

`sgdisk` picks aligned starts itself, so there is no sector arithmetic to get
wrong, and `0:0` for the last partition means "to the end of the disk". The ESP
is partition 1; the GPT type codes are the ones the installer uses:

- `EF00` EFI System Partition
- `8E00` Linux LVM
- `8304` root (`/`), `8302` `/home` (discoverable-partitions codes, so a
  systemd-boot system can mount them without an `fstab` entry)
- `8200` swap, `8300` any other Linux filesystem

**Minimal (no LVM):** ESP plus one root partition that takes the rest.

```bash
# live
sgdisk -n 1:0:+1024M -t 1:EF00 -c 1:"EFI System" "$DISK"
sgdisk -n 2:0:0      -t 2:8304 -c 2:"root"       "$DISK"
partprobe "$DISK"; udevadm settle --timeout=15
```

**Desktop/server (LVM):** ESP plus one big LVM partition; the volumes live inside
the group, not in the partition table.

```bash
# live
sgdisk -n 1:0:+1024M -t 1:EF00 -c 1:"EFI System" "$DISK"
sgdisk -n 2:0:0      -t 2:8E00 -c 2:"Linux LVM"  "$DISK"
partprobe "$DISK"; udevadm settle --timeout=15
```

Partition device names follow the kernel's rule: a disk name ending in a digit
takes a `p` (`nvme0n1p1`), otherwise not (`sda1`).

> If you are encrypting, **stop here and go to [Encryption](05-encryption.md).**
> The LUKS container goes on partition 2 (the root partition, or the LVM
> partition), and the filesystems are made *inside* the opened container. A
> filesystem written before the LUKS header is a filesystem the header
> overwrites.

### 5. (LVM only) Build the group and the volumes

```bash
# live
pvcreate -ff -y /dev/nvme0n1p2
vgcreate vg0 /dev/nvme0n1p2
# sized volumes with -L, the one taking the rest with -l 100%FREE last:
lvcreate --yes -L 4096m -n swap vg0
lvcreate --yes -L 20480m -n root vg0
lvcreate --yes -L 15360m -n var  vg0
lvcreate --yes -l 100%FREE -n home vg0
vgchange -ay vg0
```

The installer computes each `-L` size from the plan; the rest volume is always
created last with `100%FREE` so the rounding of every extent above it lands
inside it instead of failing the last `lvcreate`.

### 6. Format every volume

The ESP is `vfat`; the data volumes get your `--filesystem`. These are the exact
`mkfs` invocations the installer runs:

```bash
# live
mkfs.vfat -F 32 -n EFI /dev/nvme0n1p1
# ext4: -m 1 on everything except / (the 5% root reserve only helps on /);
#       a repo-bearing /var or / gets a denser inode table (-N) when needed
mkfs.ext4 -q -F -L root            /dev/vg0/root
mkfs.ext4 -q -F -m 1 -L var        /dev/vg0/var
mkfs.ext4 -q -F -m 1 -L home       /dev/vg0/home
mkswap -L swap /dev/vg0/swap
# xfs:   mkfs.xfs   -q -f -L LABEL DEV
# btrfs: mkfs.btrfs -q -f -L LABEL DEV
# f2fs:  mkfs.f2fs  -q -f -l LABEL DEV
```

### 7. Mount the tree under `/mnt/gentoo`

Mount shallowest first, so `/var` exists before `/var/log` is mounted on it.

```bash
# live
mount /dev/vg0/root /mnt/gentoo
mkdir -p /mnt/gentoo/boot /mnt/gentoo/var /mnt/gentoo/home
mount /dev/nvme0n1p1 /mnt/gentoo/boot     # the ESP, at disk_esp_mount
mount /dev/vg0/var  /mnt/gentoo/var
mount /dev/vg0/home /mnt/gentoo/home
swapon /dev/vg0/swap
```

## Verify

```bash
# live
lsblk -f "$DISK"                       # one vfat ESP, your filesystems, right labels
findmnt -R /mnt/gentoo                 # the whole tree, each from the right device
swapon --show                          # swap active, if your layout has it
```

The installer's `disk_verify` checks each volume one by one: the device exists,
the mountpoint is mounted, it is mounted **from the device the plan names** (not
some other disk), and the filesystem on it is the one the plan expects. Confirm
the same by eye: `/mnt/gentoo` from `root`, `/mnt/gentoo/boot` from the ESP, and
so on. A `/var` mounted from the wrong disk would pass a naive "something is
mounted here" check and then eat the stage3.

## Pitfalls and rollback

- **Wrong disk.** There is no rollback. The installer's typed proof exists to
  stop exactly this; by hand, your only guard is re-reading the device path
  against model and serial before step 3. Nothing after step 20 can run without
  it, and nothing can undo it.
- **Disk too small / layout does not fit.** `disk_plan` refuses before the wipe
  with the sizes it computed. Use `--disk-layout minimal`, a smaller ESP, or a
  bigger disk. By hand, add up your volumes against the disk first.
- **`/var` or `/` under 6 GiB.** The build fills `/var/tmp/portage` and dies with
  ENOSPC minutes into an `emerge`. Give the build filesystem room, or use
  `--disk-layout minimal`.
- **Volume group name collision.** `disk_vg` defaults to `vg0`, a very common
  name. The installer refuses a `vg0` that lives on *another* disk before it
  wipes anything, because deactivating it later would reach into the running
  system. By hand, name your group something unlikely (`gi-vg0`) if `vg0` is
  taken.
- **Disk comes back with the old table.** You zapped only the front header.
  `sgdisk --zap-all` clears the backup header at the end of the disk too.
- **Rollback and resume.** The state journal records step 20 as done, so
  `--resume` skips it and `--restart` (or `--steps 20 --restart`) forgets it and
  runs again. Re-running is itself destructive: it re-wipes. The installer's
  idempotence check (`_step20_already_provisioned`) will *skip* the wipe if the
  exact planned tree is already partitioned, formatted, and mounted, so a clean
  resume does not erase a disk twice. There is no "undo the wipe" because there
  cannot be one.

## Reference

- **Step:** `20` - `steps/20_disk.sh`
- **Uses:** `lib/disk.sh`; one of `variants/layout/minimal.sh`,
  `variants/layout/desktop.sh`, `variants/layout/server.sh`,
  `variants/layout/custom.sh`
- **Flags/settings:** `--disk`, `--disk-layout minimal|server|desktop|custom`,
  `--filesystem ext4|xfs|btrfs|f2fs`, `--lvm auto|yes|no`, `--list-disks`;
  settings `disk_esp_size`, `disk_esp_mount`, `disk_swap`, `disk_vg`,
  `disk_erase quick|luks|discard|zero`, `disk_allow_removable|mounted|system`,
  `wipe_disk ask|yes|no`, and for `custom` `disk_volumes` / `disk_volumes_file`
- **Writes:** a GPT table, an ESP and the layout's volumes on the target disk;
  filesystems; the tree mounted under `/mnt/gentoo`; the state facts
  `disk.device`, `disk.layout`, `disk.lvm`, `disk.vg_name`, `disk.mountpoint`,
  `disk.root_device`, `disk.root_uuid`, `disk.esp_device`, `disk.esp_uuid`,
  `disk.esp_mount`, `disk.root_fstype`, `disk.boot_device`, `disk.root_lv`,
  `disk.crypt_device`; and the plan table at `disk-plan.tsv` in the state
  directory

---
[← Previous: Pre-flight checks](03-preflight.md) · [Handbook index](README.md) · [Next: Encryption (LUKS, GPG, TPM) →](05-encryption.md)
