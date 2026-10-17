# System configuration

> Timezone, locales, keymap, hostname, `/etc/hosts`, `fstab`, the root password,
> groups and user accounts, and who may become root. Mirrors
> `steps/90_system.sh`.

## What the installer does

`step_90_system` (in `steps/90_system.sh`) configures the system being
installed, in twelve parts run in order: `timezone`, `locales`, `keymap`,
`hostname`, `fstab`, `root_password`, `groups`, `accounts`, `privilege`,
`root_lock`, `network`, `sshd`. Three rules hold throughout: every `fstab`
mount is named by UUID (a kernel may renumber disks between boots); `fstab` is
written, handed to `findmnt --verify`, and rolled back if it objects (a broken
`fstab` is a machine that does not boot); and root is never locked until another
account is shown to escalate *and* to be able to log in. The target is never
`/`: the step refuses to configure the machine running the installer.

Anything it cannot finish (a tool missing from the stage3, a password not
entered) becomes a recorded "to-do" that [chapter 13](13-finalize.md) reads back
rather than a silent gap. The installer runs commands with `chroot /mnt/gentoo`;
by hand you are inside the chroot, so the blocks are `# chroot`.

## Concepts

- **Two init systems, three files that differ.** The keymap, the hostname
  helper file, and how services are enabled differ between OpenRC and systemd;
  everything else is the same. Each part below marks where they diverge.
- **fstab is generated, not hand-copied.** The installer reads the kernel's own
  mount table (`findmnt`) rather than guessing, so it describes exactly what
  step 20 built and step 50 mounted. A filesystem mounted now but absent from
  `fstab` is one the installed system will not mount.
- **Accounts are a record format, checked before anything is created.** Each
  account is `name:groups:shell:privilege`; useradd refuses a whole account over
  one unknown group, so the installer validates the lot first and creates groups
  before accounts.
- **Privilege is per account and never a group rule.** The installer writes one
  explicit `sudo`/`doas` rule per account, deliberately *not* a
  `%wheel ALL=(ALL:ALL) ALL` line, because a group rule also hands root to an
  account that asked for `none` and happens to be in `wheel`.

## Do it by hand

### 1. Timezone

```bash
# chroot
ln -sfn ../usr/share/zoneinfo/Europe/Paris /etc/localtime
echo 'Europe/Paris' > /etc/timezone
```

A relative symlink, so it means the same thing inside and outside the chroot.
(`--timezone`)

### 2. Locales (OpenRC and systemd alike)

```bash
# chroot
cat >> /etc/locale.gen <<'EOF'
C.UTF-8 UTF-8
en_US.UTF-8 UTF-8
EOF
locale-gen
eselect locale set en_US.utf8        # note: utf8, the way `locale -a` spells it
env-update && . /etc/profile
```

`--locale` names the one that becomes `LANG`; `--locales` adds more. On **musl**
there is no locale system at all: no `locale-gen`, no `/etc/locale.gen` worth
writing, so the installer sets only `LANG` and `LC_COLLATE` in
`/etc/env.d/02locale`.

### 3. Console keymap

```bash
# chroot (systemd)
echo 'KEYMAP="us"' > /etc/vconsole.conf
# chroot (OpenRC)
echo 'keymap="us"' > /etc/conf.d/keymaps
```

(`--keymap`) **Warning:** If the keymap is wrong, a non-ASCII character in the root or LUKS
password may not type the way you expect at the console.

### 4. Hostname and /etc/hosts

```bash
# chroot
echo 'workstation' > /etc/hostname
# OpenRC before 0.45 reads this one instead; writing both is harmless:
echo 'hostname="workstation"' > /etc/conf.d/hostname   # OpenRC only
```

Add the project-owned line to `/etc/hosts` (leave the stage3's localhost lines):

```
127.0.0.1   localhost
::1         localhost
127.0.1.1   workstation.example.net workstation
```

(`--hostname`, `--domain`)

### 5. fstab

Generate it from what is mounted, by UUID. The ESP gets restrictive masks
because it holds the bootloader (and, on an encrypted machine, sometimes a key
file):

```
# /etc/fstab
UUID=<root-uuid>   /       ext4   defaults,noatime                          0 1
UUID=<esp-uuid>    /efi    vfat   defaults,noatime,fmask=0077,dmask=0077    0 2
UUID=<swap-uuid>   none    swap   sw                                        0 0
```

**Warning:** Before trusting it, verify: a broken `fstab` stops the machine in the
initramfs, and that is not recoverable from the installed system.

```bash
# chroot
findmnt --verify --tab-file /etc/fstab
```

### 6. Root password

```bash
# chroot
passwd root                          # or: printf 'root:PASS\n' | chpasswd
```

The installer reads the secret into `chpasswd`'s stdin only, never into argv (it
would show in `ps`) and never into the journal. A locked root (the stage3
default) is safe but unusable until you set a password or install a key.

### 7. Groups, then accounts

Create extra groups first (`--groups "docker;media:1500"`):

```bash
# chroot
groupadd docker
groupadd -g 1500 media
```

Then the accounts (`--accounts "alice:wheel,audio,video:/bin/bash:sudo"`, or
`--accounts-file`). The default groups are `wheel,audio,video,usb,portage`, the
default shell `/bin/bash`, the default privilege `sudo`:

```bash
# chroot
useradd -m -G wheel,audio,video,usb,portage -s /bin/bash alice
passwd alice
```

### 8. Privilege (sudo / doas)

The installer writes a drop-in, one rule per account, and validates it:

```bash
# chroot (sudo)
emerge --verbose app-admin/sudo
cat > /etc/sudoers.d/10-gentoo-install <<'EOF'
alice ALL=(ALL:ALL) ALL
EOF
chmod 0440 /etc/sudoers.d/10-gentoo-install
visudo -c -f /etc/sudoers.d/10-gentoo-install
```

For doas instead: `permit persist alice` in `/etc/doas.conf` (mode 0400),
checked with `doas -C /etc/doas.conf`. `sudo-nopasswd` / `doas-nopasswd` drop the
password check; the installer warns, because anything running as that account is
then root. (`--privilege`)

### 9. Lock root (optional)

**Warning:** `--root-lock yes` runs `passwd -l root`, and the installer refuses it unless
another account both escalates (sudo or doas) *and* can log in (a password or an
`authorized_keys` with a key in it). `--force` does **not** lift this: a locked
root with no way up is recoverable only from a live medium. By hand, confirm
your admin account works before:

```bash
# chroot
passwd -l root
```

### 10. Network

```bash
# chroot (OpenRC, the default there)
emerge --verbose net-misc/dhcpcd
rc-update add dhcpcd default
# chroot (systemd, the default there)
systemctl enable systemd-networkd systemd-resolved
ln -sfn ../run/systemd/resolve/stub-resolv.conf /etc/resolv.conf
```

(`--network dhcpcd|networkmanager|systemd-networkd|none`; `systemd-networkd`
needs `init=systemd`.) The installer writes a `20-wired.network` DHCP file for
systemd-networkd.

### 11. sshd (off by default)

sshd opens a port on every boot, so it is off unless asked (`--sshd`). When
enabled, supply a key (`--ssh-key`) and the installer installs it to the first
account's `authorized_keys` and turns password authentication off; without a
key it leaves passwords on and warns. It writes a hardening drop-in with an
`Include` line at the top of `sshd_config` (sshd takes the first value it sees,
so the include must come first):

```bash
# chroot
cat > /etc/ssh/sshd_config.d/10-gentoo-install.conf <<'EOF'
PermitRootLogin no
PasswordAuthentication no
KbdInteractiveAuthentication no
X11Forwarding no
MaxAuthTries 3
EOF
rc-update add sshd default            # OpenRC;  systemctl enable sshd on systemd
```

## Verify

```bash
# chroot
cat /etc/timezone /etc/hostname
locale                                # LANG set to your locale
findmnt --verify --tab-file /etc/fstab
awk -F: '$2 ~ /^\$/ {print $1}' /etc/shadow    # accounts with a usable password
id alice                              # groups and membership
```

A root or user account with a password hash starting with `$` (not `!`, `*`, or
empty) is a way in. Step 95's "A way in" check reads the same `/etc/shadow`.

## Pitfalls and rollback

- **fstab rejected.** `findmnt --verify` objected (a UUID that does not resolve,
  a missing field). The previous content is put back; nothing is left
  half-written. Fix the mounts, rerun step 90.
- **Tool missing from the stage3.** `chpasswd`, `useradd`, `locale-gen` absent
  means that part is deferred to a to-do rather than failing the install;
  chapter 13 lists them.
- **Account in an unknown group.** useradd would refuse the whole account, so
  the installer refuses up front. Create the group (`--groups`) or drop it from
  the account's list.
- **Locked root, no way up.** The one accident this step is written against. If
  it happened anyway, recover from a live medium: chroot in and
  `passwd -u root` or set up an admin account.
- **Rerun.** The sudoers/doas files are drop-ins, so rerunning replaces the
  installer's own file and leaves hand edits alone; an earlier sudo grant that
  no longer applies is emptied rather than left behind.

## Reference

- **Step:** `90` - `steps/90_system.sh`
- **Uses:** `lib/core.sh`, `lib/config.sh`, `lib/state.sh`, `lib/ui.sh`;
  `data/services.tsv` (extra services)
- **Flags/settings:** `--timezone`, `--locale`, `--locales`, `--keymap`,
  `--hostname`, `--domain`, `--root-lock yes|no`,
  `--groups`, `--accounts`, `--accounts-file`, `--user`, `--user-groups`,
  `--user-shell`, `--privilege sudo|sudo-nopasswd|doas|doas-nopasswd|none`,
  `--network`, `--sshd`, `--ssh-key`, `--init openrc|systemd`
- **Writes:** `/etc/localtime`, `/etc/timezone`, `/etc/locale.gen` (or
  `/etc/env.d/02locale` on musl), `/etc/vconsole.conf` or `/etc/conf.d/keymaps`,
  `/etc/hostname` (and `/etc/conf.d/hostname` on OpenRC), `/etc/hosts`,
  `/etc/fstab`, `/etc/shadow` (via chpasswd/passwd), `/etc/passwd`,
  `/etc/group`, `/etc/sudoers.d/10-gentoo-install` or `/etc/doas.conf`,
  network and sshd drop-ins; state `system.*` (including `system.todo.N`)

---
[← Previous: Bootloader (GRUB / EFI stub / systemd-boot / UKI)](11-bootloader.md) · [Handbook index](README.md) · [Next: Finalize & handover →](13-finalize.md)
