#!/usr/bin/env bats
# The cipher and the key derivation are choices, and the wrong one must be
# refused before step 20 wipes a disk for it.

load helper

@test "an unknown crypt_pbkdf must die at parse time, not in step 30" {
  gi_run --crypt luks-passphrase --crypt-pbkdf scrypt --dry-run --yes
  [ "$status" -eq 2 ]
  [[ "$stderr" == *"Invalid value for crypt_pbkdf"* ]]
  [[ "$stderr" == *"argon2id"* ]]
}

@test "pbkdf2 with a memory parameter must be refused, cryptsetup rejects the pair" {
  gi_run --crypt luks-passphrase --crypt-pbkdf pbkdf2 \
    --crypt-pbkdf-memory 64 --dry-run --yes
  [ "$status" -ne 0 ]
  [[ "$stderr" == *"takes no crypt_pbkdf_memory"* ]]
}

@test "crypt_format_args must not pass --pbkdf-memory when the pbkdf is pbkdf2" {
  gi_bash 'config_init_defaults
           CFG[crypt_pbkdf]=pbkdf2; CFG[crypt_pbkdf_memory]=64
           crypt_format_args | tr "\n" " "'
  [ "$status" -eq 0 ]
  [[ "$output" != *"--pbkdf-memory"* ]]
}

@test "crypt_format_args must pass --pbkdf-memory for argon2, which takes one" {
  gi_bash 'config_init_defaults
           CFG[crypt_pbkdf]=argon2id; CFG[crypt_pbkdf_memory]=64
           crypt_format_args | tr "\n" " "'
  [ "$status" -eq 0 ]
  [[ "$output" == *"--pbkdf-memory 64"* ]]
}

@test "the crypt choice reads the same in both vocabularies" {
  # Two spellings name the same choice: the setting and the journal say
  # luks-passphrase, because step 30's catalogue is the directory
  # variants/crypt; the kernel command line, the dracut module list and the
  # package list say passphrase. Step 70 compared the long one against the short
  # one and fell to its default arm, so "Unknown crypt variant: luks-passphrase"
  # stopped every encrypted install before an initramfs could exist. Step 95 had
  # been normalising all along, in a copy of its own — which is why nothing
  # noticed.
  local pair
  for pair in "luks-passphrase:passphrase" "luks-tpm:tpm" \
    "luks-keyfile-gpg:keyfile" "none:none" ":none" \
    "passphrase:passphrase" "tpm:tpm" "keyfile:keyfile"; do
    run --separate-stderr bash -c 'source "$GI_ENTRY"; crypt_family "$1"' bash "${pair%%:*}"
    [ "$status" -eq 0 ]
    [ "$output" = "${pair##*:}" ] || {
      printf 'crypt_family %s gave %s, expected %s\n' "${pair%%:*}" "$output" "${pair##*:}" >&2
      return 1
    }
  done
}

@test "step 70 asks the normaliser, not the raw setting" {
  # The regression this file exists to prevent: target_crypt() must hand the
  # short spelling to everything downstream of it.
  gi_bash 'config_init_defaults; CFG[crypt]=luks-tpm; set_explicit crypt luks-tpm; target_crypt'
  [ "$status" -eq 0 ]
  [ "$output" = "tpm" ]
}

@test "dracut is not asked for the lvm module when there is no LVM" {
  # This one stopped run 2 dead. The list was "crypt dm lvm" for any encrypted
  # install, on the reasoning that lvm "costs a few kilobytes" — but on a plain
  # LUKS root sys-fs/lvm2 is not installed, so dracut answered "Module 'lvm'
  # cannot be installed", failed to generate the initramfs, and took
  # sys-kernel/gentoo-kernel-bin down with it. The default layout with the
  # default encryption is exactly that combination.
  gi_capture 'target_crypt() { printf "passphrase\n"; }
              target_topology() { printf "plain\n"; }
              target_fact() { printf "\n"; }
              target_init() { printf "openrc\n"; }
              kernel_dracut_modules' | grep -qx "crypt dm"
}

@test "dracut is asked for lvm exactly once when LUKS and LVM are stacked" {
  # Both arms contribute dm; the operator should not read "crypt dm dm lvm".
  gi_capture 'target_crypt() { printf "passphrase\n"; }
              target_topology() { printf "lvm\n"; }
              target_fact() { printf "\n"; }
              target_init() { printf "openrc\n"; }
              kernel_dracut_modules' | grep -qx "crypt dm lvm"
}

@test "an unencrypted LVM root still gets dm and lvm" {
  gi_capture 'target_crypt() { printf "none\n"; }
              target_topology() { printf "lvm\n"; }
              target_fact() { printf "\n"; }
              target_init() { printf "openrc\n"; }
              kernel_dracut_modules' | grep -qx "dm lvm"
}

@test "a package is not installed just because a sibling shares its name prefix" {
  # sys-boot/grub-themes-gentoo made sys-boot/grub look installed, so the emerge
  # was skipped and step 80 died on "chroot: cannot execute grub-install" — with
  # the line above it saying grub was already there. A Gentoo package directory
  # is name-version and a version starts with a digit; that is the whole test.
  local root
  root="$(gi_tmp)/fakeroot"
  mkdir -p "${root}/var/db/pkg/sys-boot/grub-themes-gentoo-1.0-r2"
  mkdir -p "${root}/var/db/pkg/sys-kernel/linux-firmware-20260101"

  gi_bash 'kernel_pkg_installed "$1" sys-boot/grub' "$root"
  [ "$status" -ne 0 ]

  gi_bash 'kernel_pkg_installed "$1" sys-kernel/linux' "$root"
  [ "$status" -ne 0 ]

  # The ones that really are there must still answer yes.
  gi_bash 'kernel_pkg_installed "$1" sys-boot/grub-themes-gentoo' "$root"
  [ "$status" -eq 0 ]

  mkdir -p "${root}/var/db/pkg/sys-boot/grub-2.12-r6"
  gi_bash 'kernel_pkg_installed "$1" sys-boot/grub' "$root"
  [ "$status" -eq 0 ]
}

@test "the wrapped key file is never written outside the target tree" {
  # _kg_key_path returned /boot/efi/luks-key.gpg with no prefix, and install(1)
  # was handed that. An install run from a live medium therefore wrote the
  # target's key file onto the live medium's own EFI partition; run on a working
  # machine, onto that machine's. It happened here — a wrapped key for a
  # throwaway loop image landed in this laptop's /boot/efi, beside its
  # bootloader — and the file had to be taken back off by hand.
  gi_bash 'config_init_defaults
           source "${GI_ROOT}/variants/crypt/luks-keyfile-gpg.sh"
           CFG[root]=/mnt/gentoo
           CFG[crypt_key_dir]=/boot/efi
           CFG[crypt_key_name]=luks-key.gpg
           _kg_key_host_path'
  [ "$status" -eq 0 ]
  [ "$output" = "/mnt/gentoo/boot/efi/luks-key.gpg" ]
}

@test "installing the key file refuses a destination outside the target" {
  # The same mistake by another route — a crypt_key_dir that escapes — is
  # refused rather than written.
  local dir
  dir="$(gi_tmp)"
  printf 'envelope\n' >"${dir}/src"
  gi_bash 'config_init_defaults
           source "${GI_ROOT}/variants/crypt/luks-keyfile-gpg.sh"
           CFG[root]=/mnt/gentoo
           _kg_install_key "$1" /boot/efi/luks-key.gpg' "${dir}/src"
  [ "$status" -ne 0 ]
  [[ "$stderr" == *"outside the target"* ]]
}
