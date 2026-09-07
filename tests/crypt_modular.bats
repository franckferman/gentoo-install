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

@test "no function invoked inside a command substitution can install a trap" {
  # This one cost a night, and it is a class rather than a case.
  #
  # crypt_secret_file() used to print a path, so every caller ran it as
  # "$(crypt_secret_file ...)" — a subshell. It called crypt_arm_secret_trap(),
  # which holds `trap ... EXIT`. A trap installed inside a subshell fires when
  # that subshell ends, and this one calls cleanup(), which unmounts every
  # tracked mount. Creating a secret file therefore unmounted the machine being
  # installed, and the next line failed with "No such file or directory" about a
  # path that had existed a line earlier, while the same command run by hand
  # worked.
  #
  # The first version of this test looked for a literal `trap` inside the
  # substituted function and passed with the defect deliberately put back — the
  # armer was one call away. The check is transitive now, and it was watched
  # failing before it was kept.
  local offenders
  offenders="$(awk -f "${GI_ROOT}/tests/no-trap-in-substitution.awk" $(gi_shell_files))"
  if [[ -n "$offenders" ]]; then
    printf 'a trap can be armed from inside a command substitution:\n%s\n' "$offenders" >&2
    return 1
  fi
}

# --------------------------------------------------------------------------- #
#  Secrets, and who is left holding them                                      #
# --------------------------------------------------------------------------- #
@test "a secret file is registered where the trap can actually see it" {
  # The same subshell, one consequence further on, and this one was live.
  #
  # crypt_secret_file() registered every file it made in _GI_CRYPT_SECRETS and
  # handed it to track_temp — but it printed the path, so every call site was
  # a command substitution and both registrations died with that subshell. The
  # array crypt_wipe_secrets() read was empty at every exit: nothing was ever
  # wiped, and a file holding the LUKS passphrase in clear stayed on the tmpfs
  # for the length of the run and past the end of it.
  #
  # It fills a caller-named variable now, which is the same shape
  # crypt_read_passphrase() already had. This test is the property, not the
  # shape: make one, wipe, and look.
  gi_bash '
    DRY_RUN=no
    crypt_secret_file path demo || exit 1
    [[ -f "$path" ]] || exit 1
    (( ${#_GI_CRYPT_SECRETS[@]} == 1 )) || exit 2
    crypt_wipe_secrets
    if [[ -e "$path" ]]; then rm -f "$path"; exit 3; fi
  '
  [ "$status" -eq 0 ]
}

@test "a slot proved twice is still one way in" {
  # The count is a safety gate — luks-tpm refuses to finish under two — so it
  # has to count credentials and not proofs. Step 75 proves the recovery slot
  # again before it may write the TPM one, and that must not be enough on its
  # own to satisfy the rule.
  gi_bash '
    crypt_forget_ways_in
    crypt_record_way_in 0 "recovery"
    crypt_record_way_in 0 "recovery, proved again by the seal"
    crypt_ways_in_count
  '
  [ "$status" -eq 0 ]
  [ "$output" = "1" ]
}

# --------------------------------------------------------------------------- #
#  luks-tpm: what runs where                                                  #
# --------------------------------------------------------------------------- #
@test "luks-tpm asks the live medium for the chip and for nothing else" {
  # It used to refuse without clevis, jose and tpm2-tools on the medium that is
  # running — and install-amd64-minimal.iso, the one the Gentoo handbook tells
  # everyone to boot, has none of them and cannot install them. A run on that
  # ISO stopped at step 30 with a message that said the target needed them.
  # The sealing moved into the target, where step 70 installs clevis anyway;
  # the only thing asked here is the chip, because that cannot be installed.
  gi_bash '
    config_init_defaults
    CFG[crypt]=luks-tpm
    CFG[crypt_recovery]=yes
    source "${GI_ROOT}/variants/crypt/luks-tpm.sh"
    crypt_require_device() { CRYPT_DEVICE=/dev/sdz; return 0; }
    crypt_tpm_present() { return 0; }
    crypt_already_provisioned() { return 1; }
    have() { [[ "$1" != clevis && "$1" != jose && "$1" != tpm2_createprimary ]]; }
    crypt_variant_check
  '
  [ "$status" -eq 0 ]
}

@test "luks-tpm still refuses a machine with no TPM, before anything is destroyed" {
  gi_bash '
    config_init_defaults
    CFG[crypt]=luks-tpm
    CFG[crypt_recovery]=yes
    source "${GI_ROOT}/variants/crypt/luks-tpm.sh"
    crypt_require_device() { CRYPT_DEVICE=/dev/sdz; return 0; }
    crypt_tpm_present() { return 1; }
    crypt_already_provisioned() { return 1; }
    crypt_variant_check
  '
  [ "$status" -ne 0 ]
  [[ "$stderr" == *"no TPM 2.0 device"* ]]
}

@test "the binding is in the seal hook and nowhere near apply()" {
  # Order matters more than presence here: apply() runs in step 30, on the live
  # medium, where clevis does not exist. A binding that crept back into it
  # would fail on the standard install medium and nowhere else — the worst
  # kind of regression, because every developer machine has clevis.
  gi_bash '
    source "${GI_ROOT}/variants/crypt/luks-tpm.sh"
    declare -F crypt_variant_seal >/dev/null || exit 1
    declare -f crypt_variant_apply | grep -q clevis_bind && exit 2
    declare -f crypt_variant_seal | grep -q clevis_bind || exit 3
    exit 0
  '
  [ "$status" -eq 0 ]
}

@test "a variant with nothing to seal makes step 75 succeed and say so" {
  gi_bash 'config_init_defaults; set_explicit crypt luks-passphrase; step_75_seal'
  [ "$status" -eq 0 ]
  [[ "$stderr" == *"nothing to seal"* ]]
}

@test "crypt = none reaches step 75 and finds no container" {
  gi_bash 'config_init_defaults; set_explicit crypt none; step_75_seal'
  [ "$status" -eq 0 ]
  [[ "$stderr" == *"no container to seal"* ]]
}

# --------------------------------------------------------------------------- #
#  What a missing package may and may not cost                                #
# --------------------------------------------------------------------------- #
@test "a sealing helper that will not merge does not cost the kernel" {
  # app-crypt/clevis is not in the official Gentoo repository. emerge answered
  # "there are no ebuilds to satisfy app-crypt/clevis", step 70 returned
  # non-zero, and the run lost the kernel, the bootloader and the final
  # verification with it — leaving a machine that could not boot because an
  # optional helper was unavailable, for a container that opened perfectly well
  # with its recovery passphrase.
  gi_bash '
    config_init_defaults
    target_crypt() { printf "tpm\n"; }
    kernel_pkg_installed() { return 1; }
    kernel_write_package_use() { return 0; }
    kernel_write_dracut_conf() { printf "REWROTE %s\n" "$1"; }
    kernel_emerge() { shift; case "$*" in *clevis*) return 1 ;; esac; return 0; }
    kernel_ensure_crypt_packages /mnt/gentoo
  '
  [ "$status" -eq 0 ]
  [[ "$stderr" == *"guru"* || "$stderr" == *"GURU"* ]]
  # And the initramfs configuration is written again afterwards, because the
  # first one was written before anything was installed and still names the
  # modules clevis would have provided. dracut fails the whole initramfs over a
  # module it cannot find, and that initramfs is built inside the emerge of the
  # kernel — so the list has to stop asking.
  [[ "$output" == *"REWROTE /mnt/gentoo"* ]]
}

@test "but cryptsetup and dracut still do" {
  # Those two are how the machine opens its container at all. Without them
  # there is no reason to build a kernel, and the step says so by failing.
  gi_bash '
    config_init_defaults
    target_crypt() { printf "tpm\n"; }
    kernel_pkg_installed() { return 1; }
    kernel_write_package_use() { return 0; }
    kernel_write_dracut_conf() { return 0; }
    kernel_emerge() { shift; case "$*" in *cryptsetup*) return 1 ;; esac; return 0; }
    kernel_ensure_crypt_packages /mnt/gentoo
  '
  [ "$status" -ne 0 ]
}

@test "luks-tpm says the overlay is needed before the disk is erased" {
  gi_bash '
    config_init_defaults
    CFG[crypt_recovery]=yes
    source "${GI_ROOT}/variants/crypt/luks-tpm.sh"
    crypt_require_device() { CRYPT_DEVICE=/dev/sdz; return 0; }
    crypt_tpm_present() { return 0; }
    crypt_already_provisioned() { return 1; }
    crypt_variant_check
  '
  [ "$status" -eq 0 ]
  [[ "$stderr" == *"not in the official Gentoo repository"* ]]
  [[ "$stderr" == *"guru"* ]]
}

@test "the dracut module list stops asking for what is not in the target" {
  # The list is written before the packages exist, so it names what the
  # configuration wants. If it still names them when dracut looks — and dracut
  # looks from inside the emerge of the kernel — the kernel does not install:
  #
  #   dist-kernel_install_kernel: die "Kernel install failed"
  #
  # A missing clevis therefore has to be dropped from the list, not just
  # tolerated in the emerge. A missing crypt is a different matter: without it
  # the machine cannot open its container at all, and an initramfs built that
  # way is a machine that does not start.
  local root
  root="$(gi_tmp)/prune"
  mkdir -p "${root}/usr/lib/dracut/modules.d/90crypt" \
    "${root}/usr/lib/dracut/modules.d/90dm" "${root}/usr/lib/dracut/modules.d/90lvm"

  local kept
  kept="$(gi_capture 'kernel_dracut_prune_modules "$1" "crypt dm lvm clevis clevis-pin-tpm2"' "$root" 2>/dev/null)"
  [ "$kept" = "crypt dm lvm" ]

  # Nothing is pruned before dracut itself is installed: "not there yet" is
  # not "not coming", and that is the first write of the run.
  local empty
  empty="$(gi_tmp)/empty"
  mkdir -p "$empty"
  kept="$(gi_capture 'kernel_dracut_prune_modules "$1" "crypt dm clevis"' "$empty" 2>/dev/null)"
  [ "$kept" = "crypt dm clevis" ]
}

@test "a missing crypt module is refused, because that machine would not start" {
  local root
  root="$(gi_tmp)/nocrypt"
  mkdir -p "${root}/usr/lib/dracut/modules.d/90lvm"
  gi_bash 'kernel_dracut_prune_modules "$1" "crypt lvm"' "$root"
  [ "$status" -ne 0 ]
  [[ "$stderr" == *"cannot start"* ]]
}

@test "an LVM root gets the lvm binary, not just device-mapper" {
  # sys-fs/lvm2 without USE=lvm installs device-mapper and no lvm binary, and
  # cryptsetup pulls it in exactly that way — so the package is present, looks
  # right, and dracut says:
  #
  #   dracut[E]: Module 'lvm' cannot be installed.
  #
  # which fails the initramfs, which fails the kernel's install phase, which
  # leaves a partitioned disk with no kernel on it. Every LVM install with the
  # distribution kernel hit this.
  gi_bash '
    config_init_defaults
    target_topology() { printf "lvm\n"; }
    kernel_pkg_installed() { return 1; }
    kernel_write_package_use() { printf "USE %s\n" "$*"; }
    kernel_emerge() { shift; printf "EMERGE %s\n" "$*"; }
    kernel_ensure_lvm_tools /mnt/gentoo
  '
  [ "$status" -eq 0 ]
  [[ "$output" == *"sys-fs/lvm2 lvm"* ]]
  [[ "$output" == *"EMERGE sys-fs/lvm2"* ]]
}

@test "an lvm2 already installed without the flag is rebuilt with it" {
  # --noreplace on a package that is already there is a no-op, which is the
  # right default everywhere else and wrong here: the package is present
  # precisely because something else pulled it in without the flag.
  gi_bash '
    config_init_defaults
    target_topology() { printf "lvm\n"; }
    kernel_pkg_installed() { return 0; }
    kernel_write_package_use() { return 0; }
    kernel_in_target() { shift; printf "RAN %s\n" "$*"; }
    kernel_ensure_lvm_tools /mnt/gentoo
  '
  [ "$status" -eq 0 ]
  [[ "$output" == *"--changed-use"* ]]
  [[ "$output" == *"sys-fs/lvm2"* ]]
}

@test "a plain layout is not given lvm tools it will never use" {
  gi_bash '
    config_init_defaults
    target_topology() { printf "plain\n"; }
    kernel_write_package_use() { printf "USE %s\n" "$*"; }
    kernel_emerge() { printf "EMERGE %s\n" "$*"; }
    kernel_ensure_lvm_tools /mnt/gentoo
  '
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "the seal resolves the container before it uses it" {
  # local dev="$CRYPT_DEVICE" on the line above crypt_require_device reads the
  # variable that call is there to fill. Inside one run step 30 had already set
  # it, so nothing showed; step 75 on its own asked for "the recovery
  # passphrase for " and refused it against "slot 0 of ".
  gi_bash '
    config_init_defaults
    source "${GI_ROOT}/variants/crypt/luks-tpm.sh"
    CRYPT_DEVICE=""
    crypt_require_device() { CRYPT_DEVICE=/dev/sdz; return 0; }
    _lt_seal_requires() { return 0; }
    crypt_clevis_slot() { return 1; }
    _lt_seal_key() { printf "asked for %s\n" "$1" >&2; return 1; }
    crypt_variant_seal
  '
  [ "$status" -ne 0 ]
  [[ "$stderr" == *"asked for /dev/sdz"* ]]
}

@test "clevis is asked for the flag that exists, and rebuilt when it changes" {
  # The only clevis ebuild Gentoo has is app-crypt/clevis in GURU, and its
  # flags are: dracut pkcs11 test tpm1 udisks. The installer asked for tpm2 —
  # a flag nobody has, ignored in silence — while dracut, the one that installs
  # the initramfs modules, was never requested. The sealing then succeeds and
  # is proved, and the machine still asks for its passphrase at every boot.
  #
  # And the emerge has to be --changed-use: the package is usually already
  # installed by then, and --noreplace would leave it exactly as it is.
  gi_bash '
    config_init_defaults
    target_crypt() { printf "tpm\n"; }
    target_topology() { printf "plain\n"; }
    kernel_pkg_installed() { return 0; }
    kernel_write_package_use() { printf "USE %s\n" "$*"; }
    kernel_write_dracut_conf() { return 0; }
    kernel_in_target() { shift; printf "RAN %s\n" "$*"; }
    kernel_ensure_crypt_packages /mnt/gentoo
  '
  [ "$status" -eq 0 ]
  [[ "$output" == *"app-crypt/clevis dracut"* ]]
  [[ "$output" != *"app-crypt/clevis tpm2"* ]]
  [[ "$output" == *"--changed-use"* ]]
  [[ "$output" == *"app-crypt/clevis"* ]]
}

@test "an initramfs that predates its modules is named as such" {
  # The image on disk can be older than the packages the configuration asks
  # for, and nothing in the configuration says so — only the image can. It
  # happened here: clevis arrived on a later run, the module list was right,
  # and the initramfs was the one built before it existed. The machine had a
  # sealed TPM keyslot it could not use.
  local root
  root="$(gi_tmp)/initrd"
  mkdir -p "${root}/usr/lib/dracut/modules.d/90crypt" \
    "${root}/usr/lib/dracut/modules.d/90dm" "${root}/boot"
  : >"${root}/boot/initramfs-test.img"

  gi_capture '
    chroot() { shift 2; printf "crypt\n"; }
    kernel_dracut_modules() { printf "crypt dm\n"; }
    kernel_initramfs_missing_modules "$1" /boot/initramfs-test.img
  ' "$root" >"${root}/out" 2>/dev/null
  [ "$(cat "${root}/out")" = "dm" ]

  # And says nothing when the image carries everything asked of it.
  gi_capture '
    chroot() { shift 2; printf "crypt\ndm\n"; }
    kernel_dracut_modules() { printf "crypt dm\n"; }
    kernel_initramfs_missing_modules "$1" /boot/initramfs-test.img
  ' "$root" >"${root}/out2" 2>/dev/null
  [ ! -s "${root}/out2" ]
}

# --------------------------------------------------------------------------- #
#  A console that takes the screen away                                       #
# --------------------------------------------------------------------------- #
@test "a command line naming only a serial console is called out" {
  # The kernel prints to every console= it is given and makes the last one
  # /dev/console. Name ttyS0 and nothing else and the framebuffer goes quiet —
  # including the initramfs asking for the LUKS passphrase, which is the one
  # message a person has to see.
  #
  # This project's own testing notes recommended console=ttyS0,115200 to make a
  # boot drivable. An install took the advice, the machine booted correctly and
  # said nothing on either console, and it was read as a hung image for most of
  # an afternoon.
  gi_bash 'kernel_warn_console_takeover "root=/dev/sda2 ro console=ttyS0,115200"'
  [ "$status" -eq 0 ]
  [[ "$stderr" == *"none of them is the screen"* ]]
  [[ "$stderr" == *"console=tty0 console=ttyS0"* ]]
}

@test "naming the screen as well says nothing" {
  gi_bash 'kernel_warn_console_takeover "root=/dev/sda2 ro console=tty0 console=ttyS0,115200"'
  [ "$status" -eq 0 ]
  [ -z "$stderr" ]
}

@test "no console= at all says nothing either" {
  gi_bash 'kernel_warn_console_takeover "root=/dev/sda2 ro rd.luks.uuid=luks-1234"'
  [ "$status" -eq 0 ]
  [ -z "$stderr" ]
}

@test "tty0 and ttyS0 are told apart" {
  # `tty` as a pattern matches both, which is how the first version of this
  # check looked at console=ttyS0 and saw a screen.
  gi_bash 'kernel_warn_console_takeover "ro console=ttyS0"'
  [ "$status" -eq 0 ]
  [[ "$stderr" == *"none of them is the screen"* ]]
  gi_bash 'kernel_warn_console_takeover "ro console=tty1"'
  [ "$status" -eq 0 ]
  [ -z "$stderr" ]
}

@test "the command line display asks that question" {
  gi_bash '
    config_init_defaults
    kernel_cmdline() { printf "root=/dev/sda2 ro console=ttyS0,115200\n"; }
    show_kernel_cmdline
  '
  [ "$status" -eq 0 ]
  [[ "$stderr" == *"none of them is the screen"* ]]
}

@test "a resume claims no TPM slot the journal does not know about" {
  # apply() asserted crypt_tpm_slot on the already-provisioned path. On a
  # machine where step 75 never succeeded — no TPM in the target, clevis
  # absent, a sealing the chip refused — a --resume then wrote into the
  # journal that the TPM opens this container.
  gi_bash 'source "${GI_ROOT}/variants/crypt/luks-tpm.sh"
    config_init_defaults >/dev/null 2>&1
    CRYPT_DEVICE=/dev/sdz2; _LT_PROVISIONED=yes
    CFG[crypt_primary_slot]=1; CFG[crypt_tpm_slot]=2
    state_get() { [[ "$1" == crypt.slots ]] && printf "1:recovery-passphrase\n"; }
    crypt_variant_apply >/dev/null 2>&1
    printf "%s\n" "$CRYPT_RECORD"'
  [ "$output" = "1:recovery-passphrase" ]
}

@test "and keeps the slot clevis really took, not the configured one" {
  # clevis picks the first free slot when the one asked for is busy, which the
  # sealing code says while reading the real slot back. A resume replaced that
  # true record with crypt_tpm_slot.
  gi_bash 'source "${GI_ROOT}/variants/crypt/luks-tpm.sh"
    config_init_defaults >/dev/null 2>&1
    CRYPT_DEVICE=/dev/sdz2; _LT_PROVISIONED=yes
    CFG[crypt_primary_slot]=1; CFG[crypt_tpm_slot]=2
    state_get() { [[ "$1" == crypt.slots ]] && printf "1:recovery-passphrase 3:tpm2\n"; }
    crypt_variant_apply >/dev/null 2>&1
    printf "%s\n" "$CRYPT_RECORD"'
  [ "$output" = "1:recovery-passphrase 3:tpm2" ]
}

@test "the recorded TPM slot is read, never guessed" {
  gi_bash 'source "${GI_ROOT}/variants/crypt/luks-tpm.sh"
    state_get() { [[ "$1" == crypt.slots ]] && printf "%s\n" "$SLOTS"; }
    SLOTS=""                                 ; printf "[%s]" "$(_lt_recorded_tpm_slot)"
    SLOTS="1:recovery-passphrase"            ; printf "[%s]" "$(_lt_recorded_tpm_slot)"
    SLOTS="1:recovery-passphrase 7:tpm2"     ; printf "[%s]\n" "$(_lt_recorded_tpm_slot)"'
  [ "$output" = "[][][7]" ]
}

@test "a key placed where the target can read it says when that is not RAM" {
  # crypt_secure_tmpdir asks which of /run, /dev/shm and /tmp is in RAM and
  # says out loud when none is. The one directory it never sees is the copy
  # the sealing side reads: that has to sit at a path both sides agree on, so
  # it is placed by name rather than chosen — and never asked about. Measured
  # with /run unbound: the key landed on ext4 in the clear and nothing was said.
  local dir
  dir="$(gi_tmp)/persistent"
  mkdir -p "$dir"
  gi_bash 'have() { [[ "$1" == "findmnt" ]]; }
    findmnt() { printf "ext4\n"; }
    crypt_warn_if_persistent "$1"' "$dir"
  [ "$status" -eq 0 ]
  [[ "$stderr" == *"is ext4, not RAM"* ]]
  [[ "$stderr" == *"removed is not erased"* ]]
  [[ "$stderr" == *"--steps 50,75"* ]]
}

@test "and says nothing when it is" {
  local dir
  dir="$(gi_tmp)/ram"
  mkdir -p "$dir"
  gi_bash 'have() { [[ "$1" == "findmnt" ]]; }
    findmnt() { printf "tmpfs\n"; }
    crypt_warn_if_persistent "$1"' "$dir"
  [ "$status" -eq 0 ]
  [ -z "$stderr" ]
}

@test "the copy for the sealing side is asked about before it is written" {
  local body
  body="$(sed -n '/^crypt_key_for_target/,/^}/p' "${GI_ROOT}/lib/crypt.sh")"
  [[ "$body" == *"crypt_warn_if_persistent"* ]]
  # And still registered like every other secret, so the trap removes it.
  [[ "$body" == *"crypt_secret_file copy seal"* ]]
}
