# Pre-flight checks

> Eleven checks that change nothing and refuse to start the install on a bad
> footing. This mirrors `steps/10_preflight.sh` (step 10).

## What the installer does

`step_10_preflight()` runs eleven checks, in order: `root`, `firmware`, `arch`,
`tools`, `network`, `dns`, `clock`, `disk`, `memory`, `tpm`, `keyring`. Each ends
in one of four verdicts (PASS, WARN, FAIL, SKIP), then prints why it says so and
the exact command that fixes it, so you never have to leave the screen to make
the next run pass.

No single check aborts the run. An operator preparing an install wants the whole
list in one pass, not one refusal per attempt, so the checks all run and the
aggregate at the bottom decides: any **FAIL** stops the run, and a **WARN** asks
for confirmation. This is the one step whose failure halts the pipeline (it
decides whether anything may be written at all), and the only thing it writes is
a few keys in the [state journal](02-state-resume-rollback.md). It also sets the
`firmware` default from what it detects.

## Concepts

### Four verdicts, two of them with teeth

- **PASS**: fine, move on.
- **WARN**: usable but worth a look; the aggregate asks you to confirm.
- **FAIL**: blocking; the run stops.
- **SKIP**: not applicable to this configuration (for example the TPM check when
  you asked for no TPM binding).

### A FAIL is a proof, a WARN is a confirmation

This is the line the whole safety model rests on. `--force` and `--yes` lift
*confirmations*: given either, the aggregate accepts the warnings without asking.
Nothing lifts a FAIL, because a FAIL is a proof that failed, not a question. The
installer learned this the hard way: a run once refused a 16 GiB disk as too
small and then erased it anyway, so pre-flight was made the one halting step and
its FAILs were made unliftable.

### Why check now

Every FAIL guards against a failure that would otherwise surface *after* the
disk is already partitioned, where it is expensive and confusing. A wrong-arch
stage3 fails the chroot with "Exec format error" in step 50; a clock in the past
makes every signature look BAD in step 40 and sends you hunting a mirror
compromise that is not there. Pre-flight pulls those failures forward to the one
moment nothing has been touched yet.

### What the eleven checks guard against

| # | Check | Guards against |
|---|-------|----------------|
| 1 | root | running the destructive steps without uid 0 (SKIP under `--dry-run`) |
| 2 | firmware | choosing a UEFI-only bootloader on a BIOS boot, or vice versa; sets the `firmware` fact |
| 3 | arch | a stage3 whose binaries this CPU cannot run |
| 4 | tools | a missing `mkfs`, partitioner, `cryptsetup`, or `gpg` discovered mid-install |
| 5 | network | the mirror being unreachable before step 40 fetches anything |
| 6 | dns | a reachable network with no resolver (told apart from network on purpose) |
| 7 | clock | skew that breaks GPG and TLS and masquerades as a bad signature |
| 8 | disk | a missing, mounted, or too-small target disk |
| 9 | memory | an OOM-killed kernel link; also computes a safe `-jN` |
| 10 | tpm | a requested TPM binding with no usable TPM 2.0 (SKIP if none requested) |
| 11 | keyring | a missing Gentoo release keyring when signature verification is on |

## Do it by hand

Run these on the live medium before a manual install. They change nothing, so
there is no harm in running them all.

```bash
# live
id -u                                   # 1. root: must print 0

# 2. firmware: UEFI if this directory exists, else BIOS
ls /sys/firmware/efi >/dev/null 2>&1 && echo UEFI || echo BIOS
cat /sys/firmware/efi/fw_platform_size  # 64 (good) or 32 (needs i386-efi GRUB)
mount | grep efivarfs                    # efibootmgr needs efivarfs mounted

uname -m                                # 3. arch: x86_64 for an amd64 target
```

Then the tools. The installer needs these always: `lsblk blkid wipefs findmnt
mount umount tar chroot awk date df`, plus one partitioner (`sgdisk`, `sfdisk`,
or `parted`), plus the `mkfs` for your filesystem. On UEFI add `mkfs.fat` and
`efibootmgr`; add `cryptsetup` if you are encrypting and `gpg` if you verify
signatures (both on by default).

```bash
# live
for t in lsblk blkid wipefs findmnt mount umount tar chroot awk date df \
         sgdisk mkfs.ext4 mkfs.fat efibootmgr cryptsetup gpg; do
  command -v "$t" >/dev/null || echo "missing: $t"
done
```

On the official Gentoo install medium every one of these is already present; a
missing one usually means a rescue image that is not it. Install what is missing
with `emerge --ask --oneshot <package>`.

```bash
# live
# 5/6. network and DNS: reach the mirror, and resolve its name
curl -sSI --max-time 8 https://distfiles.gentoo.org >/dev/null && echo "mirror ok"
getent ahosts distfiles.gentoo.org | head -n1   # must print an address
ip route show default                            # must show a default route

# 7. clock: within an hour of real time (compare against the mirror's Date:)
date -u
curl -sSI https://distfiles.gentoo.org | grep -i '^date:'
```

More than an hour of skew breaks signature and certificate checks. Fix it with
`chronyd -q 'server pool.ntp.org iburst'` or `hwclock --hctosys`, then write it
back with `hwclock --systohc`.

```bash
# live
# 8. disk: a real block device, not mounted, at least 20 GiB
lsblk -dn -o NAME,SIZE,TYPE,MODEL
blockdev --getsize64 /dev/nvme0n1       # bytes; >= ~21.5e9 for the 20 GiB floor
findmnt --source /dev/nvme0n1           # must print nothing (not mounted)

# 9. memory: RAM + swap; the kernel link wants headroom
awk '/MemTotal|SwapTotal/{print}' /proc/meminfo
```

The installer wants at least 2048 MiB of RAM plus swap (below that the kernel
link is OOM-killed) and is comfortable from 4096 MiB. It budgets one parallel
compile job per 2048 MiB, capped at the CPU count, and that number becomes the
`MAKEOPTS="-jN"` step 60 writes. If swap is zero, add some on the target:

```bash
# live
fallocate -l 8G /mnt/gentoo/swapfile && chmod 600 /mnt/gentoo/swapfile
mkswap /mnt/gentoo/swapfile && swapon /mnt/gentoo/swapfile
```

TPM and keyring apply only to certain configurations:

```bash
# live
# 10. tpm: only if you chose --crypt luks-tpm
ls /sys/class/tpm/tpm0                       # the device must exist
cat /sys/class/tpm/tpm0/tpm_version_major    # must be 2
ls -l /dev/tpmrm0                            # the kernel resource manager

# 11. keyring: the Gentoo release keys, when verifying signatures (the default)
gpg --show-keys /usr/share/openpgp-keys/gentoo-release.asc
```

If the keyring file is absent, install it from a package rather than downloading
it from the same mirror it is meant to police: `emerge --ask --oneshot
app-crypt/openpgp-keys-gentoo-release`.

## Verify

Let the installer run its own pass. Without root you can still review it under
`--dry-run` (the `root` check then reports SKIP):

```bash
$ ./gentoo-install.sh --steps 10 --dry-run
# live
./gentoo-install.sh --steps 10
```

A clean run ends with `pre-flight: 11 checks, all clear`. Warnings end with
`passed with N warning(s)` and the aggregate asks to continue; blocking findings
end with `Pre-flight failed: N blocking` and name each one. The verdict is also
recorded in the journal as `preflight.result` (pass/warn/fail), so
[`--resume`](02-state-resume-rollback.md) and `--json` can read it back.

## Pitfalls and rollback

- **A FAIL cannot be forced.** `--force` lifts the warnings' question only. Fix
  the cause (every finding prints the command) and re-run `--steps 10`.
- **BIOS vs UEFI is a firmware setting, not a later choice.** A system installed
  in BIOS/CSM mode does not become a UEFI one afterwards. If you meant UEFI, turn
  CSM off and boot the medium again before step 20.
- **efivarfs not mounted** is only a WARN, but if you ignore it `efibootmgr`
  writes no boot entry and the finished install looks like a failed one at
  reboot. Mount it: `mount -t efivarfs efivarfs /sys/firmware/efi/efivars`.
- **A wrong clock reads as a bad signature.** If step 40 later complains about
  signatures, suspect the clock first.
- **Rollback:** there is nothing to roll back. Pre-flight writes only the journal
  and changes nothing on disk. Because it is the halting step, a FAIL stops the
  run before step 20, so nothing the later steps would have written was written.

## Reference

- **Step:** `10` - `steps/10_preflight.sh`
- **Uses:** `lib/core.sh` (`have`, output, thresholds), `lib/config.sh` (the
  settings it reads), `lib/state.sh` (recording the verdict), `lib/ui.sh`
  (`confirm` for the WARN aggregate)
- **Flags/settings:** `--force` and `--yes` (accept warnings), `--dry-run` (SKIPs
  the root check); reads `disk`, `disk_filesystem`, `firmware`, `crypt`,
  `verify_signatures`, `mirror`, `arch`
- **Writes:** the state journal only, `preflight.result`, `preflight.checks`,
  `preflight.firmware`, `preflight.failed`, `preflight.warned`; sets the
  `firmware` default from detection

---
[← Previous: State, resume & rollback](02-state-resume-rollback.md) · [Handbook index](README.md) · [Next: Partitioning & formatting the disk →](04-disk.md)
