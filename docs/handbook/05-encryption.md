# Encryption (LUKS, GPG, TPM)

> Put a LUKS2 container on the partition step 20 left, by one of four variants:
> `none`, a passphrase, a GPG-wrapped key file on the ESP, or a key sealed to the
> TPM. Then open it and build the filesystems inside. Mirrors
> `steps/30_crypt.sh` (`--crypt`).

**Warning:** **Formatting a LUKS container is irreversible.** `cryptsetup luksFormat`
writes a new header with a new master key; every keyslot a device held before is
gone, and with the old master key gone, every byte the old container protected
becomes unreadable noise. If you point this step at a device that already holds
data you want, you lose it. The installer makes you type the device path before
it reformats an existing header, and no flag lifts that proof. Treat it the same
way by hand.

## What the installer does

`step_30_crypt` (in `steps/30_crypt.sh`, driving `lib/crypt.sh` and one file
under `variants/crypt/`) sets up encryption. The step itself knows nothing about
LUKS, GPG or TPMs; it validates, loads the chosen variant, prints the plan,
confirms, applies, finishes the provisioning step 20 handed over, and then
refuses to declare the machine finished until the variant has **proved**, by
exercising them, that there is more than one way back into the container. In
order:

1. `crypt_validate_config` checks the settings (variant, slots, PBKDF, PCRs);
2. loads the variant and checks its tools are present here;
3. `crypt_variant_check` resolves the device (from `--crypt-device` or the
   `disk.crypt_device` step 20 recorded) and inspects any existing header;
4. prints the plan and asks a reversible confirmation (the variant's own
   `apply()` asks the **typed proof** before it destroys anything);
5. `crypt_variant_apply` creates the container and its keyslots, and opens it as
   `/dev/mapper/<crypt_name>` (default `gentoo`);
6. `_step30_finish_provisioning` runs the half of step 20 that could not happen
   before the container existed: the volume group, the filesystems, the mounts,
   all **inside the mapper** (see [the disk chapter](04-disk.md));
7. for the keyfile variant, `crypt_variant_deploy` installs the wrapped key on
   the ESP;
8. `crypt_variant_verify` exercises every credential and requires that enough
   independent ways in were proved;
9. records what was done (never the secret) in the state journal.

`none` is a variant like the others: it runs, it prints that the disk will be
readable by whoever holds it, and it does nothing. A step that vanishes when a
feature is off leaves you guessing whether it was skipped or forgotten.

## Concepts

**What LUKS is.** LUKS (Linux Unified Key Setup) puts a header at the front of a
partition. The data on the rest of the partition is encrypted with a single
random **master key**. The header holds that master key several times over, once
per **keyslot**, each copy wrapped under a different credential (a passphrase, a
key file). You never type or hold the master key; you supply a credential, LUKS
uses it to unwrap the master key from one slot, and the unlocked device appears
as `/dev/mapper/<name>`. Because every slot wraps the *same* master key,
adding or removing a slot is cheap and never re-encrypts the disk, and losing one
credential while another slot still works is an inconvenience, not a wiped disk.

**The cipher.** The installer formats LUKS2 with `aes-xts-plain64`, a 512-bit
key, `sha512`, and the `argon2id` PBKDF. These are the cryptsetup LUKS2 defaults
except the hash, and they are the values the project has run on real machines.
XTS uses two AES keys, so a 512-bit key size means **AES-256** (two 256-bit
keys), not AES-512. `argon2id` is memory-hard, which is what makes an offline
guessing attack expensive.

**The keyslot convention.** Slot 0 is always a credential a human can produce,
and nothing automatic ever writes to it, so removing an automatic unlock can
never remove the last way in. Slot 1 is the recovery credential. Slot 2 is the
TPM's. Each variant states its own use below.

**The proof doctrine.** Nothing here assumes a credential works; it exercises it.
Every test goes through `cryptsetup open --test-passphrase
--disable-external-tokens`, which activates nothing (safe on a live container)
and, crucially, stops a LUKS2 token plugin from answering in place of the
material under test. Without `--disable-external-tokens`, a machine whose TPM
still answers validates *any* key you hand it, so a dead credential reads as a
live one, which is exactly the state a machine is in just before a BIOS update
kills its sealing. The step will not finish until the variant has proved two
independent ways in (one, for a passphrase container with recovery turned off).

**Secrets never come from a flag.** `argv` is world-readable through `ps` and
shell history is forever, so a passphrase reaches the installer only by: an
environment variable (`GI_CRYPT_PASSPHRASE`, `GI_CRYPT_RECOVERY`), the first line
of a file (`crypt_pass_file`, `crypt_recovery_pass_file`, kept mode 600), or the
terminal, not echoed. Material is written to a mode-600 file on a tmpfs and wiped
on every exit path, including Ctrl-C.

## Do it by hand

Everything here runs on the **live medium** as root, after step 20 has
partitioned the disk. The container device is the partition step 20 set aside:
the root partition for a plain layout, or the LVM partition for an LVM layout
(the installer records it as `disk.crypt_device`). The examples use
`/dev/nvme0n1p2` and open it as `/dev/mapper/gentoo`.

### Variant `none`

Nothing to do. **Warning:** Understand what you are choosing: anyone who takes the disk out
of the machine reads everything on it. No passphrase, no key, no TPM stands in
the way, so a stolen laptop is a data breach rather than an inconvenience. If you
want this, skip to [the stage3 chapter](06-stage3.md); step 20 already formatted
and mounted the tree.

### Variant `luks-passphrase` (the default)

LUKS2 with a passphrase typed at every boot. It needs no hardware. Two keyslots:
slot 0 is the everyday boot passphrase, slot 1 a recovery passphrase, so a
mistyped-and-forgotten credential is survivable. `crypt_recovery = no` drops the
second slot (and the installer says so at that moment).

```bash
# live
DEV=/dev/nvme0n1p2
# 1. format: create the header and write the boot passphrase into slot 0.
#    cryptsetup prompts for it; --batch-mode skips only the "are you sure" y/N,
#    not the passphrase itself.
cryptsetup luksFormat --type luks2 --batch-mode \
  --cipher aes-xts-plain64 --key-size 512 --hash sha512 --pbkdf argon2id \
  --key-slot 0 "$DEV"
# 2. add the recovery passphrase in slot 1 (it must differ from slot 0):
cryptsetup luksAddKey --new-key-slot 1 "$DEV"
# 3. open the container -> /dev/mapper/gentoo
cryptsetup open --disable-external-tokens "$DEV" gentoo
```

**Warning:** The passphrase you type here is the one the installed machine will ask for at
every boot, possibly on a different keymap. Type one whose characters sit in the
same place on both keyboards, or you will set a passphrase you cannot reproduce.
The installer prints the live console's keymap for this reason.

**Prove both slots before you trust them** (this is what `crypt_variant_verify`
does, and it is the part no flag skips):

```bash
# live
cryptsetup open --test-passphrase --disable-external-tokens --key-slot 0 "$DEV"
cryptsetup open --test-passphrase --disable-external-tokens --key-slot 1 "$DEV"
```

### Variant `luks-keyfile-gpg`

LUKS2 opened by a long random key that never exists in the clear on disk. The key
is drawn, piped straight into a symmetric GPG envelope, and the envelope is what
lands on the (unencrypted FAT) ESP. **Two secrets:** the passphrase that opens
the file, and the file that opens the disk. Slot 0 holds the key file's key; slot
1 holds an independent recovery passphrase. At boot the initramfs unwraps the key
file and asks for its passphrase.

```bash
# live
DEV=/dev/nvme0n1p2
# 1. draw 4096 random bytes, base64, one line, and wrap them with a passphrase.
#    The key goes from the random source into gpg and no further; nothing in the
#    clear touches the disk. Do this on a tmpfs (e.g. under /run).
umask 077
openssl rand -base64 4096 | tr -d '\n' \
  | gpg --quiet --batch --yes --pinentry-mode loopback \
        --symmetric --cipher-algo aes256 --armor \
        -o /run/luks-key.gpg
# 2. unwrap it once to a tmpfs file and format slot 0 with those exact bytes:
gpg --quiet --batch --pinentry-mode loopback --decrypt /run/luks-key.gpg \
  > /run/luks-key.raw
cryptsetup luksFormat --type luks2 --batch-mode \
  --cipher aes-xts-plain64 --key-size 512 --hash sha512 --pbkdf argon2id \
  --key-slot 0 --key-file /run/luks-key.raw "$DEV"
# 3. recovery passphrase in slot 1 (independent of the key file):
cryptsetup luksAddKey --new-key-slot 1 --key-file /run/luks-key.raw "$DEV"
# 4. open, then (after the ESP is mounted) install the envelope onto it:
cryptsetup open --disable-external-tokens --key-file /run/luks-key.raw "$DEV" gentoo
# ... build and mount the filesystems inside /dev/mapper/gentoo ...
install -m 0600 /run/luks-key.gpg /mnt/gentoo/boot/efi/luks-key.gpg
```

**Warning:** The envelope on the ESP is the **only copy** of what opens slot 0. It is
readable by anyone, and that is by design: without the passphrase it is inert.
But if that disk dies, the key dies with it, so copy the envelope off the machine
before the machine leaves your hands. FAT keeps no permission bits, so the `0600`
is a courtesy, not protection; the passphrase is what protects the file.

Prove the key file as deployed (not the tmpfs copy) and the recovery passphrase:

```bash
# live
gpg --quiet --batch --pinentry-mode loopback \
  --decrypt /mnt/gentoo/boot/efi/luks-key.gpg > /run/esp-key.raw
cryptsetup open --test-passphrase --disable-external-tokens \
  --key-slot 0 --key-file /run/esp-key.raw "$DEV"
cryptsetup open --test-passphrase --disable-external-tokens --key-slot 1 "$DEV"
shred -u /run/luks-key.raw /run/esp-key.raw   # material does not outlive the step
```

### Variant `luks-tpm`

LUKS2 sealed to the TPM with clevis: the machine unlocks itself as long as the
firmware measures the same as it did on the day of the sealing. This variant runs
in **two halves**, and the second one lives in [TPM sealing](10-tpm-sealing.md).

- **Step 30 (here):** create the container, put the recovery passphrase in slot 0,
  prove it, and open the container. A recovery passphrase is mandatory
  (`crypt_recovery = no` is refused): the TPM is the only thing releasing the key,
  and it stops doing so on a BIOS update, a firmware setting change, or a moved
  disk, none of which is a fault and all of which are ordinary. Nothing here needs
  anything the Gentoo minimal ISO lacks; just `cryptsetup`, plus a TPM 2.0 device
  (`/dev/tpmrm0`, `/dev/tpm0`, or `/sys/class/tpm/tpm0`).
- **Step 75 (chapter 10):** seal a second key into slot 2 with `clevis luks bind`,
  from inside the target, because clevis (`app-crypt/clevis`, from the GURU
  overlay) and the tpm2 helpers are not on the live medium. The version that seals
  is then the version that unseals at boot.

```bash
# live
DEV=/dev/nvme0n1p2
# slot 0: the recovery passphrase, the human way in, never touched by clevis
cryptsetup luksFormat --type luks2 --batch-mode \
  --cipher aes-xts-plain64 --key-size 512 --hash sha512 --pbkdf argon2id \
  --key-slot 0 "$DEV"
cryptsetup open --test-passphrase --disable-external-tokens --key-slot 0 "$DEV"
cryptsetup open --disable-external-tokens "$DEV" gentoo
```

The TPM slot holds a key **clevis draws for itself and seals**; it is not a copy
of the passphrase, so the two slots hold two different secrets protected in two
different ways. The sealing binds PCRs `0,2,3,6` by default (the firmware and its
option ROMs, not the running system): register 0 is the firmware itself, which a
BIOS update changes; 2 and 3 are option ROMs and their configuration; 6 is
platform events. Register 4 is deliberately left out because it measures the boot
binary, rewritten at every kernel build, and 7 (Secure Boot state) is out because
Secure Boot can be switched off without the TPM noticing. Named policies exist:
`firmware` (`0,2,3,6`), `secureboot` (`7`), `firmware+secureboot`, and `strict`
(`0-7`).

**Warning:** The TPM releasing the key today is not a promise about tomorrow. After a BIOS
update the sealing stops matching, the machine asks for the recovery passphrase,
and you reseal afterwards. That is why the recovery slot is the condition for this
variant to exist, not an option on it. Finish the TPM binding in
[chapter 10](10-tpm-sealing.md).

### After opening: build the filesystems inside the container

For every encrypted variant, the filesystems go **inside** `/dev/mapper/gentoo`,
never on the raw partition. For a plain layout that means `mkfs` on the mapper;
for an LVM layout, `pvcreate`/`vgcreate`/`lvcreate` on the mapper, then `mkfs` on
the logical volumes. Follow [the disk chapter's steps 5-7](04-disk.md) using
`/dev/mapper/gentoo` in place of the raw partition.

## Verify

```bash
# live
cryptsetup status gentoo               # active, cipher aes-xts-plain64, the right device
cryptsetup luksDump "$DEV"             # LUKS2, the keyslots you created (0, 1, and/or 2)
ls -l /dev/mapper/gentoo               # the open container the filesystems sit on
```

Confirm the slots you expect are present and that a `--test-passphrase` against
each one succeeds. The installer counts **independent, just-exercised** ways in
and refuses to finish with fewer than it promised: two for every variant except a
passphrase container with `crypt_recovery = no`, which has one and warns loudly.

## Pitfalls and rollback

- **One credential only.** With `crypt_recovery = no`, a single secret stands
  between the machine and its data; forget it, mistype it at creation, or lose the
  note, and there is no reset. Keep the recovery slot.
- **Passphrase kept beside the key file.** For `luks-keyfile-gpg`, the installer
  refuses a `crypt_pass_file` that sits in `crypt_key_dir`: the envelope and the
  passphrase that opens it would travel together, which is the same as shipping
  neither. Keep them apart, ideally the passphrase on a tmpfs.
- **Key file the initramfs cannot reach.** The key must sit on the ESP (the one
  unencrypted filesystem available before anything is unlocked), or on a device
  you name with `crypt_keyfile_uuid`. A key on the encrypted root cannot open the
  root that holds it.
- **TPM "works" but is never exercised.** A `clevis luks list` token reads
  identically whether the TPM honours it or refuses it. Only making the chip
  release the key and testing the result (what `crypt_clevis_verify_seal` does)
  proves it. Never hand over a machine as self-unlocking on the strength of a
  token alone.
- **Reformatting an existing header.** **Warning:** It destroys every keyslot and makes the
  old data unreadable. The installer shows the existing header and asks you to
  type the device path (`crypt_wipe_luks = ask`); `--force` does not lift it.
- **Rollback and resume.** There is no "un-format" for a LUKS container, just as
  there is no undo for the disk wipe. A `--resume` reopens the container by asking
  for a passphrase (`crypt_open_for_resume`), which is why every variant
  guarantees a human-producible slot; `--restart` forgets the journal and, with
  `crypt_wipe_luks = yes`, reformats. The journal records *what* was done
  (`crypt.variant`, `crypt.uuid`, `crypt.slots`, and for the keyfile variant the
  key's path and UUID), never the secret itself.

## Reference

- **Step:** `30` - `steps/30_crypt.sh`
- **Uses:** `lib/crypt.sh`; one of `variants/crypt/none.sh`,
  `variants/crypt/luks-passphrase.sh`, `variants/crypt/luks-keyfile-gpg.sh`,
  `variants/crypt/luks-tpm.sh` (whose `seal()` half runs in step 75)
- **Flags/settings:** `--crypt none|luks-passphrase|luks-keyfile-gpg|luks-tpm`;
  settings `crypt_recovery`, `crypt_name`, `crypt_cipher`, `crypt_key_size`,
  `crypt_hash`, `crypt_pbkdf`, `crypt_wipe_luks ask|yes|no`,
  `crypt_primary_slot`/`crypt_recovery_slot`/`crypt_tpm_slot`, `crypt_pass_file`,
  `crypt_recovery_pass_file`, `crypt_key_dir`, `crypt_key_name`, `crypt_pcrs`,
  `crypt_pcr_bank`; environment `GI_CRYPT_PASSPHRASE`, `GI_CRYPT_RECOVERY`
- **Writes:** a LUKS2 header on `disk.crypt_device`; the open mapper
  `/dev/mapper/<crypt_name>`; for `luks-keyfile-gpg`, the wrapped key file on the
  ESP (`crypt_key_dir`/`crypt_key_name`); the state facts `crypt.variant`,
  `crypt.device`, `crypt.uuid`, `crypt.name`, `crypt.slots`, and (keyfile)
  `crypt.keyfile`, `crypt.keyfile_uuid`

---
[← Previous: Partitioning & formatting the disk](04-disk.md) · [Handbook index](README.md) · [Next: The stage3 (fetch, verify, unpack) →](06-stage3.md)
