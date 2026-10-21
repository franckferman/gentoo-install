# Finalize & handover

> Five checks that build nothing, a recap of what was built, the things left to
> do by hand, a clean unmount, and a reboot that is never taken on the
> installer's own initiative. Mirrors `steps/95_finalize.sh`.

## What the installer does

`step_95_finalize` (in `steps/95_finalize.sh`) is the only step that builds
nothing. It asks whether what the previous steps built will actually come back
up, says what is left to do by hand, releases exactly what this install mounted,
and stops. It runs five checks in order, each producing a PASS, WARN, FAIL, or
SKIP verdict:

| Check | Question |
|---|---|
| `kernel` | Is there a real kernel image in `/boot` (not an empty or truncated file)? |
| `initramfs` | Does the image carry the modules this root cannot be reached without? |
| `bootentry` | Will the firmware actually pick something up (loader, config, NVRAM or fallback)? |
| `fstab` | Does every UUID in `fstab` resolve, with a `/` entry and nothing mounted that `fstab` omits? |
| `access` | Is there a way in after boot (a password or an ssh key)? |

A FAIL blocks the reboot. After the checks come a recap, the list of recorded
to-dos, a warning about secrets, and the next steps. Then the release, and only
then the reboot, if it was genuinely asked for.

## Concepts

- **It verifies, it does not fix.** Every FAIL carries the exact command that
  repairs it, because the alternative is diagnosing a dead machine from a live
  USB.
- **The initramfs check is the one that pays for the file.** It asks the image
  itself (`lsinitrd`, or the cpio archive when that is unreadable) which modules
  it carries, never the configuration that was *meant* to produce it. An image
  missing `crypt` on an encrypted root stops the machine at a dracut prompt with
  no root and no message that names the gap.
- **NVRAM is read as the machine's, not the disk's.** A boot entry lives in the
  firmware of the machine running the check. When the target is some other disk,
  that entry says nothing about whether the target boots, so the check discounts
  it (`disk_may_write_firmware_state`) and looks for the removable fallback
  instead.
- **The reboot is a tri-state and never automatic.** `--yes` and `--force` lift
  confirmations but not this: a reboot is irreversible the way a disk wipe is.
  Only `--reboot yes`, or a person answering at a terminal, takes it, and only
  when the reboot would actually enter the target.

## Do it by hand

The installer runs these checks with the target still mounted at `/mnt/gentoo`.
Run the checks from the live medium or inside the chroot (`# chroot`), unmount
from the live medium (`# live`), then reboot.

### 1. Re-run the five checks

```bash
# chroot: a kernel and an initramfs that can open the container
ls -l /boot/vmlinuz-* /boot/initramfs-*.img
lsinitrd /boot/initramfs-<version>.img --mod | grep -E 'crypt|dm|lvm|clevis'

# chroot: fstab resolves and has a root entry
findmnt --verify --tab-file /etc/fstab

# chroot: a way in after boot
awk -F: '$2 ~ /^\$/ {print $1}' /etc/shadow      # accounts with a usable password
```

For the boot entry, confirm the loader or kernel is on the ESP and something
points the firmware at it (`efibootmgr -v`, or
`ls /boot/EFI/BOOT/BOOTX64.EFI` for the removable fallback). These mirror
[chapter 11](11-bootloader.md)'s verification.

### 2. Read the recap, and write down the secrets

The installer prints what it built (stage, disk, layout, encryption, kernel,
initramfs, bootloader, hostname, locale, network, user, sshd) and every recorded
to-do. **Warning:** The screen you must not scroll past is the one about the LUKS
passphrase:

- Nothing recovers a lost LUKS passphrase: not this installer, not Gentoo, not
  the TPM. Write it down somewhere that is not this machine.
- With `crypt=tpm`, the TPM unlocks silently, so you will not be reminded the
  passphrase exists until a firmware update stops the sealing from matching and
  it becomes the only way in.
- With `crypt=keyfile`, the GPG-wrapped key sits on an unencrypted partition;
  copy it off the machine, because losing that partition loses the disk.

### 3. Unmount cleanly

Release the stack innermost first: the pseudo-filesystems, then the target tree,
then the LUKS container.

```bash
# live
umount -R /mnt/gentoo                  # recursive: deepest mount first
cryptsetup close gentoo                # the open LUKS mapping, once nothing stands on it
```

If `umount -R` reports the tree is busy, a shell or an open file is still in it
(`fuser -vm /mnt/gentoo`); a lazy `umount -Rl` detaches it and the reboot
finishes the job. The container closes with the machine anyway, so a container
that will not close is not a reason to stay.

### 4. Reboot

```bash
# live
reboot
```

**Warning:** Remove the install medium first, or the firmware may boot it again instead of
the disk you just built.

## Verify

The install is done when all five checks PASS (WARN is survivable, FAIL is not)
and the machine boots unassisted into:

- a login prompt (`crypt=none`),
- a LUKS passphrase prompt, then login (`crypt=passphrase` / `keyfile`), or
- a silent unlock, then login (`crypt=tpm`, while the firmware is unchanged).

After the first login, bring the system fully up to date, which also pulls the
first post-stage3 kernel if the dist-kernel variant has a newer one:

```bash
# on the booted machine
emerge --sync && emerge --ask --update --deep --newuse @world
```

Then continue with the sibling
[Post-Install Handbook](https://github.com/franckferman/gentoo-post-install/tree/stable/docs/handbook)
for tuning, hardening, GPU drivers, and a desktop stack.

## Pitfalls and rollback

- **A FAIL blocks the reboot.** This is deliberate: a machine that failed a
  proof is not one to reboot into. Fix the named cause, then re-run the step
  against the mounted target: `./gentoo-install.sh --steps 50,95`.
- **Going back in after the run ends.** The run releases everything it mounted
  when it finishes, so `--steps 50` on its own mounts, prepares, prints, and
  unmounts again, leaving nothing to chroot into. To reattach a finished target
  by hand, use the rescue tools:
  `./tools/luks-open.sh open --target /mnt/gentoo` then
  `./tools/rescue-chroot.sh enter --target /mnt/gentoo`.
- **"Not rebooting."** The installer skips the reboot when the target is not the
  disk this machine booted from (rebooting would restart the installer host, not
  enter the target) and when `--yes` was passed without `--reboot yes`. That is
  not a failure; reboot by hand when ready.
- **A busy mount.** `umount -R` failing leaves the encryption layer alone on
  purpose, because the tree above it is still held. Close the holders first.

## Reference

- **Step:** `95` - `steps/95_finalize.sh`
- **Uses:** `steps/70_kernel.sh` (`kernel_installed`); `lib/chroot.sh`
  (`chroot_cleanup`), `lib/disk.sh` (`disk_teardown`,
  `disk_may_write_firmware_state`); `lib/core.sh`, `lib/config.sh`,
  `lib/state.sh`, `lib/ui.sh`
- **Flags/settings:** `--reboot ask|yes|no`; honours `--yes` / `--force` only in
  that they do *not* answer the reboot; reads the state journal for the recap
- **Writes:** nothing on the target (it builds nothing). State
  `finalize.result`, `finalize.checks`, `finalize.failed`, `finalize.warned`.
  Releases the mounts this install made and restores the CPU governor step 40
  changed on the host

---
[← Previous: System configuration](12-system-config.md) · [Handbook index](README.md) · [Next: Appendix: data, profiles, tests, troubleshooting →](99-appendix.md)
