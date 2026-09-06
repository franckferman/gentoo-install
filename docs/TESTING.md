# Testing this installer on a virtual machine

**Run 1 has been made and passed** (2026-09-05): an image taken from an empty
GPT to a login prompt, then booted under QEMU with OVMF. What it proved, and
what it did not, is in the README's Status section. Runs 2 to 5 — the encrypted
ones, the other bootloaders, a stage of your own — have not.

---

## Before you start: do not run this against a machine you are using

Two things this installer does are not confined to the target tree. They reach
the firmware of the machine the installer is running on, and they outlive the
run:

- **the NVRAM boot entry**, written by `efibootmgr` in step 80;
- **the reboot** offered by step 95.

Both are correct from a live medium. Both are dangerous from a working system.
Run on a booted Gentoo laptop against a loop image, they replaced that laptop's
own `gentoo` entry with a pointer to the loop device's ESP, and then rebooted
it. The disk was untouched and no data was lost, and it still cost a live USB, a
`grub-install` and an `efibootmgr` to get the machine back.

Since then the installer refuses both unless it is running from a live medium or
reinstalling the very disk it booted from, and `--yes` no longer answers the
reboot question — only `--reboot yes` does. Those guards are in
`lib/disk.sh:disk_may_write_firmware_state` and they are covered by
`tests/firmware_guard.bats`. **They are a safety net, not a licence:** test in a
VM, which is what this page is for.

It is written to be run, not read. Every command here was checked on the machine
this project was written on; where something is specific to that machine, it
says so.

---

## Why a VM and not a spare disk

A spare disk tests one path. A VM tests a matrix, reverts in a second, and
cannot destroy anything that matters if a guard fails. The whole point of this
exercise is to find out whether the guards hold, so run it where being wrong is
free.

---

## What the host needs

| | |
|---|---|
| `qemu-system-x86_64` | the VM |
| `/dev/kvm` | acceleration; without it a kernel build takes hours instead of tens of minutes |
| OVMF firmware | UEFI. On Gentoo: `/usr/share/edk2-ovmf/OVMF_CODE.fd` |
| a Gentoo minimal ISO | <https://www.gentoo.org/downloads/> — the *admin* ISO carries `cryptsetup` and `lvm2` |
| 30 GB of disk, 4 GB of RAM | the kernel is what needs the room |

Check them:

```bash
command -v qemu-system-x86_64
[ -c /dev/kvm ] && echo "kvm ok"
ls /usr/share/edk2-ovmf/OVMF_CODE.fd
```

If `/dev/kvm` is not readable, add yourself to the `kvm` group and log in again.

---

## Setting the VM up

```bash
mkdir -p ~/vm/gentoo-install && cd ~/vm/gentoo-install

# A writable copy of the firmware variables: OVMF_CODE.fd stays read-only,
# OVMF_VARS.fd is where the boot entries this installer creates will land.
cp /usr/share/edk2-ovmf/OVMF_VARS.fd ./vars.fd

qemu-img create -f qcow2 disk.qcow2 30G
```

The ISO goes in the same directory. Then:

```bash
qemu-system-x86_64 \
  -enable-kvm -m 4096 -smp 4 -cpu host \
  -machine q35 \
  -drive if=pflash,format=raw,readonly=on,file=/usr/share/edk2-ovmf/OVMF_CODE.fd \
  -drive if=pflash,format=raw,file=vars.fd \
  -drive file=disk.qcow2,if=virtio,format=qcow2 \
  -cdrom install-amd64-minimal.iso \
  -boot menu=on \
  -netdev user,id=n0,hostfwd=tcp::2222-:22 -device virtio-net,netdev=n0 \
  -display gtk
```

`hostfwd` gives you `ssh -p 2222 root@localhost` once the live image has sshd
running, which is far more comfortable than typing in a VM window.

**For the TPM variant only**, add a software TPM. It needs `swtpm` on the host:

```bash
mkdir -p tpm
swtpm socket --tpm2 --tpmstate dir=tpm \
  --ctrl type=unixio,path=tpm/sock --flags startup-clear &

# add to the qemu line:
#   -chardev socket,id=chrtpm,path=tpm/sock \
#   -tpmdev emulator,id=tpm0,chardev=chrtpm \
#   -device tpm-tis,tpmdev=tpm0
```

`--flags startup-clear` is not decoration: it makes swtpm start the TPM itself
rather than wait for firmware to send `TPM2_Startup`. Without it the guest can
find the device and get nothing out of it. Check from inside the guest, not
from the QEMU monitor — the monitor reports the device QEMU created, which says
nothing about whether the guest's kernel bound a driver to it:

```bash
ls -l /dev/tpm0 /dev/tpmrm0
cat /sys/class/tpm/tpm0/tpm_version_major    # 2
```

`swtpm_setup` is not needed for this and may fail on some hosts ("Error getting
next filename"); `swtpm socket` creates the state it needs on its own.

---

## Headless: a serial console instead of a window

`-display gtk` needs a screen and a keyboard. To drive a run from a script — or
from an ssh session — boot the ISO's kernel directly and put the console on a
socket. The ISO's own GRUB is graphical, and its menu cannot be driven blind:
`screendump` returns a framebuffer, not text.

```bash
# once: take the kernel and the initramfs out of the ISO
sudo mount -o ro,loop install-amd64-minimal.iso /mnt/iso
cp /mnt/iso/boot/gentoo ./kernel && cp /mnt/iso/boot/gentoo.igz ./initrd
blkid -o value -s LABEL install-amd64-minimal.iso   # e.g. Gentoo-amd64-20260830
sudo umount /mnt/iso
```

```bash
# then, instead of -boot menu=on -display gtk:
  -kernel ./kernel -initrd ./initrd \
  -append "dokeymap nodhcp root=live:CDLABEL=<the label> rd.live.dir=/ \
           rd.live.squashimg=image.squashfs cdroot console=ttyS0,115200" \
  -serial unix:./serial.sock,server=on,wait=off \
  -display none
```

The ISO still goes in as `-cdrom`: the kernel above is only the entry point,
and the live system is read from the same disc. `socat UNIX-CONNECT:serial.sock
-` then gives a shell, `dhcpcd eth0` gives it network (the `nodhcp` above keeps
the boot from waiting for one), and the installer's prompts — the typed disk
proof, the passwords — are answered by writing lines to it.

---

## Getting the installer into the VM

From the live image, once it has network:

```bash
# on the host
cd ~/projects && tar czf /tmp/gi.tar.gz gentoo-install
scp -P 2222 /tmp/gi.tar.gz root@localhost:/root/

# in the VM
tar xzf /root/gi.tar.gz -C /root && cd /root/gentoo-install
```

---

## Run 1 — the simplest path that can possibly work

Prove the chain end to end before varying anything. No encryption, GRUB,
distribution kernel: the fewest moving parts.

```bash
./gentoo-install.sh --list-disks          # expect: vda, 30 GiB, virtio
./gentoo-install.sh --dry-run \
  --disk /dev/vda --disk-layout minimal --crypt none \
  --bootloader grub --kernel dist-kernel \
  --hostname gitest --user tester
```

Read the plan. Then drop `--dry-run` and let it run. It will ask you to type
`/dev/vda` before it erases anything — that confirmation is not lifted by
`--force`, and typing anything else must cancel.

**Then reboot into the installed system.** That is the test. Everything before
it is preparation.

What to check once it boots:

```bash
lsblk -f                  # the layout that was asked for
findmnt --verify          # fstab agrees with reality
id tester                 # the account, its groups
sudo -v                   # privilege escalation works
uname -r                  # the kernel that was installed
```

If it does not boot, the machine is still there: boot the ISO again, and the
tools under `tools/` are what they are for.

---

## Run 2 — encryption with a passphrase

The one most people will use.

**Passed, 6 September 2026**, on a plain layout (no LVM): the container built,
the kernel and GRUB installed, all five of step 95's checks clear, and then —
booted from its own disk with no ISO attached — this, which is the whole point
of the run:

```
[    0.699718] dracut: dracut-111
[    1.151886] dracut: luksOpen /dev/vdb2 luks-198ed542-0dbb-43cc-b9bf-a204491ce76e
Enter passphrase for /dev/vdb2:
```

Two things that run also settled, neither of them about encryption:

- **Pre-flight was advisory.** It refused the disk — `16 GiB, minimum 20`, and
  `--force does not lift these` — and the run erased it anyway, because the
  runner accumulates failures. It stops there now.
- **Typing the passphrase from outside still does not work.** QEMU's
  `sendkey` reaches the framebuffer and the characters appear under the prompt,
  and dracut's reader does not take them. Install with
  `kernel_cmdline_extra = "console=ttyS0,115200"` if you want the whole boot on
  a serial line, or type it at the window.

```bash
./gentoo-install.sh \
  --disk /dev/vda --disk-layout server --crypt luks-passphrase \
  --bootloader grub --kernel dist-kernel \
  --hostname gicrypt --user tester
```

Two things to watch that Run 1 could not show:

- the installer says which keymap the console is on before asking for the
  passphrase. Type one whose characters sit in the same place on a US keyboard,
  or the machine will ask for something you cannot type at the next boot.
- **type the passphrase yourself, at the VM window.** Driving that prompt from
  outside does not work, and the ways it fails are worth knowing before you
  spend an evening on them. QEMU's `sendkey` delivers the characters — they
  echo — and dracut's reader never sees the line end. A serial console does not
  help either: with `console=tty0 console=ttyS0` the prompt is printed on the
  last console and read from the first, and with `console=ttyS0` alone the
  prompt arrives on the socket and input written to it is still not consumed,
  though the dracut debug shell on that same socket answers `echo` perfectly.
  What can be checked from outside is that the passphrase is the right one:

  ```bash
  printf '%s' 'the-passphrase' \
    | sudo cryptsetup luksOpen --test-passphrase --key-file - /dev/loopXp2
  ```

  A passphrase given through `crypt_pass_file` is stored without the newline a
  prompt would not send, so the file and the keyboard agree — that command is
  what proves it.
- **the boot must stop and ask for the passphrase.** If it boots straight
  through, the initramfs is opening the container some other way and that is a
  finding, not a success.

Then, from the running system:

```bash
./tools/luks-check.sh report --device /dev/vda2
./tools/luks-header.sh backup --out /root
./tools/luks-header.sh verify /root/*.img
```

---

## Run 3 — the bootloaders

Same encryption, three boot paths. This is where the matrix earns its keep.

| Run | `--bootloader` | Watch for |
|---|---|---|
| 3a | `grub` | already covered by Run 2 |
| 3b | `efistub` | `efibootmgr -v` in the installed system names the kernel and carries the command line |
| 3c | `systemd-boot` | `bootctl list` shows the entry. Does **not** need `--init systemd`: bootctl comes from `sys-apps/systemd-utils` |
| 3d | `uki` | one signed binary at `\EFI\BOOT\BOOTX64.EFI`, started with no entry at all |

**`systemd-boot` and `uki` pass.** Both were booted on an encrypted disk, through
to the passphrase prompt.

**`efistub` cannot be proved from a machine that is not the target**, and it is
worth saying why rather than leaving it open. An efistub install has no
configuration file: the NVRAM entry *is* the configuration — it carries the
kernel command line and the `initrd=`. So it needs an entry to be written, and
this installer refuses to write one unless it is running from a live medium or
reinstalling the very disk it booted from (`lib/disk.sh`,
`disk_may_write_firmware_state`). Testing it therefore takes one of:

- a run from a live medium, where writing the entry is legitimate; or
- `boot_removable = yes` **and** a kernel with its command line compiled in
  (`kernel_embed_cmdline`), since the fallback path is launched with no load
  options — which means building a kernel rather than using the distribution's.

The `uki` bootloader exists partly because of this. It carries the command line
and the initramfs inside the binary, so it needs neither an entry nor a rebuilt
kernel, and it is the variant to reach for when the NVRAM cannot be trusted.

Reset between runs by recreating the disk and the firmware variables — a stale
boot entry in `vars.fd` will make a broken run look like a working one:

```bash
rm -f disk.qcow2 vars.fd
qemu-img create -f qcow2 disk.qcow2 30G
cp /usr/share/edk2-ovmf/OVMF_VARS.fd ./vars.fd
```

---

## Run 3b — the unified kernel image, and a firmware that knows nothing

Run on 6 September 2026, on purpose, against the failure this project was
shaped by: a UEFI firmware whose NVRAM has never heard of this disk.

```bash
./gentoo-install.sh --disk /dev/vdb --crypt luks-passphrase \
  --disk-layout minimal --bootloader uki --boot-removable yes \
  --kernel-cmdline-extra "console=ttyS0,115200" --hostname giuki --user tester
```

**The install passed completely** — eleven steps, none failed, the first run in
this project's life to do that — and step 95 said:

```
3/ 5  [PASS] Boot entry     unified kernel image at the fallback path
```

**The fallback is what a blank NVRAM picks**, which is the whole claim of this
variant, and the contrast with the day before is exact. Same pristine
`OVMF_VARS`, a GRUB install:

```
BdsDxe: failed to load Boot0001 "UEFI Misc Device" … Not Found
>>Start PXE over IPv4.
```

and the UKI install:

```
BdsDxe: loading  Boot0001 "UEFI Misc Device" from PciRoot(0x0)/Pci(0x3,0x0)
BdsDxe: starting Boot0001 "UEFI Misc Device" from PciRoot(0x0)/Pci(0x3,0x0)
```

**And then it hangs, and that is not explained.** The firmware starts the image
and nothing follows: no kernel output on the framebuffer, none on `ttyS0`
despite `console=ttyS0,115200` being in the baked-in command line, and the
guest idle at a few percent of one core. What has been ruled out:

- the artefact — `EFI/BOOT/BOOTX64.EFI` and `EFI/Linux/gentoo-*.efi` are byte
  for byte identical, 45,239,808 bytes, on an ESP that is 14% full;
- its shape — the PE carries the ten sections a systemd-stub image should,
  with sane addresses:

```
.sdmagic  va=0x00020000 vsz=       40
.cmdline  va=0x00023000 vsz=      239
.linux    va=0x00025000 vsz= 22608880
.initrd   va=0x015b5000 vsz= 22514210
```

- the firmware build — `OVMF_CODE_4M.qcow2` and `OVMF_CODE.fd` behave the same;
- memory — 4 GiB and 8 GiB behave the same.

What has not been tried: booting the same machine's plain `vmlinuz` and
`initramfs` with `-kernel`/`-initrd` to see whether the pair works outside the
UKI, and building the image with `ukify` instead of `dracut --uefi`
(`sys-apps/systemd-utils[ukify]`, which this install did not enable). Either
would say whether the fault is in the image or in the stack around it.

---

## Run 4 — the TPM

Needs the swtpm lines above and the headless section: the installer has to run
**inside** the VM, because sealing binds a key to the TPM of the machine being
installed.

**Read this before running it.** `app-crypt/clevis` is not in the official
Gentoo repository. That was found here, by running this: `emerge` answered
"there are no ebuilds to satisfy app-crypt/clevis". The GURU overlay carries
it, and the sealing needs it in the target:

```bash
# inside the target, or before --steps 50,75
eselect repository enable guru && emaint sync -r guru
emerge --ask app-crypt/clevis
```

Without it the run is still worth doing and still ends with an encrypted
machine — the container built, the recovery passphrase proved, the kernel and
the bootloader installed. What you are checking then is that step 75 refuses
clearly and that nothing else is damaged by its refusal, which is a real
property: an earlier version failed step 70 over the same missing package and
lost the kernel with it.

This is the variant with the most ways to go wrong and the one whose failure
mode this whole project was shaped by.

```bash
./gentoo-install.sh \
  --disk /dev/vda --crypt luks-tpm --bootloader grub \
  --hostname gitpm --user tester
```

**Passed, 6 September 2026**, and the sequence that got there is worth keeping
because no single run does it: the installer in the guest, `--steps 20,30,40,50,60`
first, then GURU and its keyword line written into the target, then
`--steps 50,70,75,80,95`. Between phases the target has to be mounted again —
the installer releases what it mounted when it exits, and only step 20 mounts
the tree — so `tools/luks-open.sh` is what puts it back:

```bash
GI_PASSPHRASE=... ./tools/luks-open.sh open --device /dev/vda2 \
    --target /mnt/gentoo --luks-pass --force
```

What the run produced, read from the machine itself after booting from its own
disk with no ISO attached:

```console
gitpm ~ # clevis luks list -d /dev/vda2
2: tpm2 '{"hash":"sha256","key":"ecc","pcr_bank":"sha256","pcr_ids":"0,2,3,6"}'
```

It reached `gitpm login:` without asking for anything, having checked root,
`/dev/vda1`, `/home` and `/var` on the way, and root logs in.

- the recovery passphrase is not optional here and the installer refuses
  `crypt_recovery = no`. Note what you type: it is the way back in.
- **first boot must unlock without asking.**
- then, deliberately break it and check the recovery path holds:

```bash
# in the VM, change a PCR by changing the firmware: add or remove a device,
# or simply run this and reboot
./tools/tpm-pcr.sh snapshot --tag before
# ... reboot with -device virtio-rng-pci added to the qemu line ...
./tools/tpm-pcr.sh compare --since before
```

The machine should now ask for the recovery passphrase, `tpm-pcr.sh compare`
should name the PCR that moved, and `tools/tpm-reseal.sh` should put it back —
and should refuse to claim success unless the TPM actually releases the key.

---

## Run 5 — a stage of your own

```bash
# on the host, or in the VM
wget <a stage3 url>
./gentoo-install.sh --disk /dev/vda --stage-file ./stage3-*.tar.xz \
  --stage-checksum "$(sha256sum stage3-*.tar.xz | cut -d' ' -f1)"
```

Watch that the catalogue is skipped entirely and the checksum is checked.
Then run it again without `--stage-checksum` and watch it say, loudly, that
nothing verified the archive.

**Both halves pass** (2026-09-06). Two things the first run showed that this
page did not promise:

- a `.asc` sitting beside the archive is found and used without being named, so
  an archive downloaded from a mirror with its signature is verified by
  signature *and* by checksum, not by checksum alone;
- with neither a signature nor a checksum the run does not stop. It says
  `nothing verified this archive`, names both ways to fix it, and unpacks —
  *"because that is what was asked"*. That is the right call for a flag whose
  whole purpose is to install something the catalogue does not know about, and
  it is worth knowing before you rely on it.

---

## What a run has to produce to count

A run counts when **all** of these hold:

- [ ] the machine boots from its own disk, unaided
- [ ] `findmnt --verify` is silent
- [ ] the encrypted variants ask for what they should ask for, and only that
- [ ] the account created can log in and escalate
- [ ] `emerge --info` runs without complaint
- [ ] running the installer again with `--resume` says everything is already
      done rather than doing it twice

Write down which runs passed and which did not, and **change the Status section
of the README to say exactly that**. "Tested on a VM" without naming the paths
tested is the kind of claim this project exists not to make.

---

## When something fails

That is the point of the exercise. The useful reflex:

1. `./gentoo-install.sh --resume` — the state journal knows what completed.
2. `/var/log/gentoo-install.log` on the target.
3. The tools under `tools/` work from the live image against the installed
   disk: `luks-check.sh report`, `luks-open.sh open`, `rescue-chroot.sh enter`.
4. If a guard refused something it should have allowed, that is a bug worth more
   than the install. Write it down before working around it.
