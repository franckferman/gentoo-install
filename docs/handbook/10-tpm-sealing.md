# TPM sealing

> Bind a LUKS2 keyslot to the TPM with clevis, so the machine unlocks itself
> while the firmware is unchanged and falls back to the recovery passphrase when
> it is not. Mirrors `steps/75_seal.sh` and the second half of
> `variants/crypt/luks-tpm.sh` (`--crypt luks-tpm`).

## What the installer does

`step_75_seal` (in `steps/75_seal.sh`) finishes what the encryption variant
still owes the target, from inside the target. Today only one variant owes
anything: `luks-tpm`. [Chapter 05](05-encryption.md) covered the first half,
run in step 30, which creates the LUKS2 container, proves a recovery passphrase
opens it, and opens it. This chapter is the second half: sealing a *second*
keyslot to the TPM.

The step reads the variant from the **state journal** (not from the live
settings, which a bare `--steps 75` run would read as the default
`luks-passphrase`), loads it, and if the variant defines a `crypt_variant_seal`
hook it attaches the chroot, confirms a TPM device is visible inside the target,
and runs the sealing there. A variant with nothing to seal says so and the step
succeeds. The end state: a new keyslot on the LUKS header carrying a
clevis `tpm2` token, proved by making the chip release the key and testing it
against that slot, and `crypt.slots` in the journal recording both ways in.

## Concepts

- **What "sealing" means here.** clevis's `tpm2` pin draws a **brand new random
  key**, writes it into a new LUKS keyslot, and seals that key to the TPM under
  a PCR policy. The TPM stores the sealed blob (as a clevis token in the LUKS2
  header) and will release the key only when the named PCRs hold the values they
  held at sealing time.
- **Two slots, two secrets.** The key file handed to `clevis luks bind -k` is
  used only to prove the right to write a new slot; it is *not* the thing that
  gets sealed, and it is not copied. So slot 0 (the recovery passphrase) and the
  TPM slot hold two different secrets, protected two different ways. Removing the
  TPM slot never touches the passphrase, and resealing never removes it.
- **What the measurement gates.** The default PCR policy is `0,2,3,6` on the
  `sha256` bank (the named policy `firmware`):
  - **PCR 0** the firmware itself. A BIOS update changes it, and that is the one
    event that breaks sealing on real fleets.
  - **PCR 2, 3** option ROMs and their configuration (a card added or removed).
  - **PCR 6** platform events.
  - **PCR 4 is deliberately out:** it measures the boot binary, rewritten at
    every kernel build, so binding it would break the automatic unlock after
    every update.
  - **PCR 7 is out too,** which is a known hole: Secure Boot can be switched off
    without these registers noticing. Add it (`--crypt-pcrs
    firmware+secureboot`) if your threat model needs it, and reseal when you
    touch Secure Boot keys.
  Some consumer firmware leaves PCR 2, 3, and 6 at the empty value, in which case
  sealing against them binds nothing; the installer measures this on the machine
  and warns.
- **Why inside the target, after the kernel exists.** The
  `install-amd64-minimal.iso` the Gentoo Handbook tells everyone to boot ships
  no clevis, no jose, and no tpm2-tools, and cannot install them (it carries no
  ebuild repository). Step 70 already installs clevis into the *target* because
  the initramfs needs it to unlock at boot. So the sealing runs there, with the
  very binaries that will release the key at every boot afterwards. That makes
  the proof stronger: the version that seals is the version that unseals. And it
  is safe to do from a chroot because PCRs `0,2,3,6` measure the firmware, not
  the running operating system, so the value sealed from inside the chroot is the
  value the installed system finds at boot.
- **The recovery passphrase is not optional.** `crypt_recovery=no` is refused
  for this variant. A machine sealed with no second keyslot is one firmware
  update away from a rebuild.

## Do it by hand

You are inside the chroot ([chapter 07](07-chroot.md)), the container from
chapter 05 is open, and `/dev` is bound in so the TPM device node is visible.

### 1. Get clevis and the TPM stack into the target

clevis is in the GURU overlay, keyworded `~amd64`:

```bash
# chroot
eselect repository enable guru && emaint sync -r guru
echo '*/*::guru ~amd64' >> /etc/portage/package.accept_keywords/guru
emerge --ask app-crypt/clevis app-crypt/tpm2-tools app-crypt/jose
```

`app-crypt/clevis` must carry the `dracut` USE flag so step 70's initramfs got
its `clevis` and `clevis-pin-tpm2` modules; `clevis-encrypt-tpm2` shells out to
`tpm2_createprimary`, `tpm2_create`, `tpm2_load`, and `tpm2_unseal` from
`app-crypt/tpm2-tools`; `jose` builds the JWE. Confirm the chip is visible:

```bash
# chroot
ls -l /dev/tpmrm0 /dev/tpm0        # at least one must be a character device
```

### 2. Bind a keyslot to the TPM

clevis needs a key that already opens the container (slot 0, the recovery
passphrase) to prove it may write a new slot. The installer keeps the key file
from step 30 on a tmpfs; by hand you supply the passphrase. Then:

```bash
# chroot
DEV=/dev/nvme0n1p2        # the raw LUKS partition
clevis luks bind -s 2 -d "$DEV" tpm2 '{"pcr_bank":"sha256","pcr_ids":"0,2,3,6"}'
```

`-s 2` is `crypt_tpm_slot` (the default). clevis prompts for an existing
passphrase, draws its own new key for slot 2, and seals it under the policy.
clevis takes the first free slot if the one you asked for is busy, so read back
which it actually used:

```bash
# chroot
clevis luks list -d "$DEV"          # shows e.g.  2: tpm2 '{"pcr_ids":"0,2,3,6",...}'
```

### 3. Prove the TPM honours the binding

**Warning:** A token in `clevis luks list` proves only that a token exists; it reads
identically whether the TPM honours it or refuses it. Do not hand the machine
over as self-unlocking until you have made the chip actually release the key and
checked that key against the slot:

```bash
# chroot
clevis luks pass -d "$DEV" -s 2 > /run/released.key   # TPM releases the sealed key
cryptsetup --test-passphrase open --key-file /run/released.key \
  --key-slot 2 "$DEV" && echo "TPM slot verified"
shred -u /run/released.key
```

If `clevis luks pass` fails or the key opens nothing, the binding exists but the
sealing does not work: the machine will ask for the recovery passphrase at every
boot. Slot 0 was proved in step 30, so it still boots; fix the TPM and reseal.

## How unlocking works at boot

The initramfs carries the `clevis` and `clevis-pin-tpm2` dracut modules (step
70). On an encrypted root with a `tpm2` token, the clevis hook in early boot
asks the TPM to unseal the key. If the current PCRs match the policy, the TPM
releases it, the container opens, and no passphrase is asked for. If they do not
match (a BIOS update moved PCR 0, the firmware setup changed, the disk moved to
another machine), the unseal fails and the initramfs falls through to the
recovery passphrase prompt on slot 0. Nothing is lost; the machine boots either
way, and the binding can be made again afterwards.

## Verify

```bash
# chroot
clevis luks list -d "$DEV"                       # a tpm2 token on slot 2
cryptsetup luksDump "$DEV" | grep -A1 'Keyslots'  # slot 0 and slot 2 both in use
lsinitrd /boot/initramfs-<version>.img --mod | grep -E 'clevis'
```

The last command confirms the initramfs can reach the TPM at all: without the
`clevis` and `clevis-pin-tpm2` modules the sealing works, is proved, and the
machine still asks for the passphrase at every boot. Step 95 re-reads the
initramfs and checks for both modules.

## Pitfalls and rollback

- **clevis absent.** Step 70 could not emerge it (GURU not enabled, or the merge
  failed), so the module is missing from the initramfs and step 75 refuses to
  seal. The install is not stranded: the container opens with the recovery
  passphrase, proved in step 30. Enable the overlay, emerge clevis, then
  `./gentoo-install.sh --steps 50,75`.
- **No TPM device inside the target.** `/dev` was not bound in, or the chip is
  disabled in firmware setup. clevis fails with an opaque tpm2 TCTI error; the
  installer checks for `/dev/tpmrm0` or `/dev/tpm0` first and says so plainly.
- **Sealing against empty PCRs.** On firmware that never measured option ROMs,
  PCR 2/3/6 hold the empty-register value and add nothing to the policy. The
  installer warns; `./tools/tpm-pcr.sh show` says the same register by register.
- **Removing a binding.** `clevis luks unbind -d "$DEV" -s 2` drops the TPM slot
  and leaves slot 0 untouched. To re-exercise an existing sealing use the
  `tools/tpm-reseal` tool rather than binding a second slot beside the first.
- **Resume / restart.** Only a successful seal writes the `tpm2` entry into
  `crypt.slots`, so a `--resume` never claims a TPM slot that was never sealed.

## Reference

- **Step:** `75` - `steps/75_seal.sh`
- **Uses:** `variants/crypt/luks-tpm.sh` (`crypt_variant_seal`); the TPM/clevis
  helpers in `lib/crypt.sh` (`crypt_clevis_bind`, `crypt_clevis_verify_seal`,
  `crypt_pcr_policy`, `crypt_tpm_present`, `crypt_key_for_target`); `lib/chroot.sh`
- **Flags/settings:** `--crypt luks-tpm`, `--crypt-recovery yes` (required),
  `--crypt-pcrs firmware|secureboot|firmware+secureboot|strict|<list>`,
  `--crypt-pcr-bank sha256`, `--crypt-tpm-slot 2`, `--crypt-primary-slot 0`
- **Writes:** a new LUKS2 keyslot and a clevis `tpm2` token on the container
  header (not a file in the tree); state `crypt.slots`

---
[← Previous: Kernel, initramfs & cmdline](09-kernel-initramfs.md) · [Handbook index](README.md) · [Next: Bootloader (GRUB / EFI stub / systemd-boot / UKI) →](11-bootloader.md)
