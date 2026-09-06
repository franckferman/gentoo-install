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
swtpm socket --tpmstate dir=tpm --ctrl type=unixio,path=tpm/sock --tpm2 -d

# add to the qemu line:
#   -chardev socket,id=chrtpm,path=tpm/sock \
#   -tpmdev emulator,id=tpm0,chardev=chrtpm \
#   -device tpm-tis,tpmdev=tpm0
```

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
| 3c | `systemd-boot` | needs `--init systemd`; `bootctl list` shows the entry |

Reset between runs by recreating the disk and the firmware variables — a stale
boot entry in `vars.fd` will make a broken run look like a working one:

```bash
rm -f disk.qcow2 vars.fd
qemu-img create -f qcow2 disk.qcow2 30G
cp /usr/share/edk2-ovmf/OVMF_VARS.fd ./vars.fd
```

---

## Run 4 — the TPM

Needs the swtpm lines above. This is the variant with the most ways to go wrong
and the one whose failure mode this whole project was shaped by.

```bash
./gentoo-install.sh \
  --disk /dev/vda --crypt luks-tpm --bootloader grub \
  --hostname gitpm --user tester
```

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
