#!/usr/bin/env bats
# The three variants nothing had ever run: kernel/genkernel, kernel/manual and
# the removable path of boot/efistub.
#
# They read clean — the vocabularies they compare against (crypt_family's
# "keyfile", target_topology's "lvm") are the right ones, the dracut config is
# written before the variant builds, and the impossible combinations are
# refused with the reason. None of that was exercised, and none of it was under
# a test: reading a refusal is not the same as watching it fire.

load helper

_plan() {
  # Run boot_efistub_check_plan under a given configuration.
  run --separate-stderr bash -c '
    source "$GI_ENTRY"
    config_init_defaults >/dev/null 2>&1
    parse_args "$@" >/dev/null 2>&1
    source "${GI_ROOT}/variants/boot/efistub.sh"
    boot_efistub_check_plan /mnt/nowhere' bash "$@"
}

@test "efistub on the removable path has nowhere to put the command line" {
  _plan --dry-run --bootloader efistub --boot-removable yes --crypt none
  [ "$status" -ne 0 ]
  [[ "$stderr" == *"nowhere to put the kernel command line"* ]]
  [[ "$stderr" == *"launched with no load options at all"* ]]
  [[ "$stderr" == *"efistub_cmdline = builtin"* ]]
  [[ "$stderr" == *"boot_removable = no"* ]]
}

@test "and no way to hand it an initramfs either" {
  # The one the machine actually needs: a compiled-in command line solves the
  # first problem and not this one. initrd= is a load option too.
  _plan --dry-run --bootloader efistub --boot-removable yes \
    --efistub-cmdline builtin --crypt luks-passphrase
  [ "$status" -ne 0 ]
  [[ "$stderr" == *"cannot hand the kernel an initramfs either"* ]]
  [[ "$stderr" == *"crypt = passphrase"* ]]
  [[ "$stderr" == *"bootloader = grub"* ]]
}

@test "an LVM root is refused on the removable path for the same reason" {
  _plan --dry-run --bootloader efistub --boot-removable yes \
    --efistub-cmdline builtin --crypt none --disk-lvm yes
  [ "$status" -ne 0 ]
  [[ "$stderr" == *"cannot hand the kernel an initramfs either"* ]]
  [[ "$stderr" == *"topology = lvm"* ]]
}

@test "a plain unencrypted root is the one thing the removable path can boot" {
  _plan --dry-run --bootloader efistub --boot-removable yes \
    --efistub-cmdline builtin --crypt none --disk-lvm no
  [ "$status" -eq 0 ]
  [[ "$stderr" == *"the kernel reaches its root on its own"* ]]
  [[ "$stderr" == *"never loaded"* ]]
}

@test "genkernel refuses the TPM variant and names the two that work" {
  # clevis and clevis-pin-tpm2 are dracut modules; genkernel builds its own
  # initramfs and has no idea what they are. Discovering that at the first
  # reboot is discovering it from a LiveUSB.
  gi_bash 'config_init_defaults >/dev/null 2>&1
    CFG[crypt]=luks-tpm
    source "${GI_ROOT}/variants/kernel/genkernel.sh"
    kernel_genkernel_build /mnt/nowhere'
  [ "$status" -ne 0 ]
  [[ "$stderr" == *"cannot be built with genkernel"* ]]
  [[ "$stderr" == *"kernel = dist-kernel"* ]]
  [[ "$stderr" == *"kernel = manual"* ]]
}

@test "genkernel is given the flags the layout and the encryption ask for" {
  # --luks or the initramfs has no cryptsetup in it at all; --gpg for the
  # wrapped key file; --lvm for a root on LVM. The words it compares against
  # are crypt_family's and target_topology's, and getting either vocabulary
  # wrong has cost this project a whole install twice.
  gi_capture 'config_init_defaults >/dev/null 2>&1
    CFG[crypt]=luks-keyfile-gpg; CFG[disk_lvm]=yes
    source "${GI_ROOT}/variants/kernel/genkernel.sh"
    kernel_genkernel_args' >"${BATS_TEST_TMPDIR}/args"
  grep -qx -- '--luks' "${BATS_TEST_TMPDIR}/args"
  grep -qx -- '--gpg' "${BATS_TEST_TMPDIR}/args"
  grep -qx -- '--lvm' "${BATS_TEST_TMPDIR}/args"

  gi_capture 'config_init_defaults >/dev/null 2>&1
    CFG[crypt]=none; CFG[disk_lvm]=no
    source "${GI_ROOT}/variants/kernel/genkernel.sh"
    kernel_genkernel_args' >"${BATS_TEST_TMPDIR}/plain"
  ! grep -qxE -- '--luks|--gpg|--lvm' "${BATS_TEST_TMPDIR}/plain"
}

@test "the manual kernel refuses to invent a configuration" {
  local dir
  dir="$(gi_tmp)/src"
  mkdir -p "$dir"
  gi_bash 'config_init_defaults >/dev/null 2>&1
    CFG[kernel_config]=""
    source "${GI_ROOT}/variants/kernel/manual.sh"
    kernel_manual_place_config "$1" ""' "$dir"
  [ "$status" -ne 0 ]
  [[ "$stderr" == *"does not invent one"* ]]
  [[ "$stderr" == *"kernel_config = running"* ]]
  [[ "$stderr" == *"kernel_config = defconfig"* ]]
}

@test "the manual kernel insists on the options the rest of the install needs" {
  gi_capture 'config_init_defaults >/dev/null 2>&1
    CFG[crypt]=luks-passphrase; CFG[disk_lvm]=no; CFG[bootloader]=efistub
    source "${GI_ROOT}/variants/kernel/manual.sh"
    kernel_manual_required_options' >"${BATS_TEST_TMPDIR}/opts"
  grep -qx 'CONFIG_DM_CRYPT=y' "${BATS_TEST_TMPDIR}/opts"
  grep -qx 'CONFIG_EFI_STUB=y' "${BATS_TEST_TMPDIR}/opts"

  gi_capture 'config_init_defaults >/dev/null 2>&1
    CFG[crypt]=none; CFG[disk_lvm]=no; CFG[bootloader]=grub
    source "${GI_ROOT}/variants/kernel/manual.sh"
    kernel_manual_required_options' >"${BATS_TEST_TMPDIR}/opts2"
  ! grep -qx 'CONFIG_DM_CRYPT=y' "${BATS_TEST_TMPDIR}/opts2"
  ! grep -qx 'CONFIG_EFI_STUB=y' "${BATS_TEST_TMPDIR}/opts2"
}

@test "the grub.cfg checker is looked for in the target before this machine" {
  # grub-script-check belongs to sys-boot/grub, which step 80 has just
  # installed in the target. It was asked of the host — `have` reads the
  # installer's own PATH — and a live medium need not carry grub at all, so the
  # one check standing between a grub.cfg that does not parse and a rescue
  # prompt was skipped with a warning. It never showed up on this bench because
  # this bench is a Gentoo box with grub on it.
  run --separate-stderr bash -c '
    source "$GI_ENTRY"
    source "${GI_ROOT}/variants/boot/grub.sh"
    chroot() { [[ "$2" == "grub-script-check" ]] && return 0; return 1; }
    boot_grub_script_checker /mnt/target /mnt/target/boot/grub/grub.cfg'
  [ "$status" -eq 0 ]
  [[ "$output" == *"chroot"* ]]
  [[ "$output" == *"/mnt/target"* ]]
  [[ "$output" == *"/boot/grub/grub.cfg"* ]]
}

@test "the host's checker is the fallback, not the first answer" {
  run --separate-stderr bash -c '
    source "$GI_ENTRY"
    source "${GI_ROOT}/variants/boot/grub.sh"
    chroot() { return 1; }
    have() { [[ "$1" == "grub-script-check" ]]; }
    boot_grub_script_checker /mnt/target /mnt/target/boot/grub/grub.cfg'
  [ "$status" -eq 0 ]
  [[ "$output" != *"chroot"* ]]
  [[ "$output" == *"grub-script-check"* ]]
  [[ "$output" == *"/mnt/target/boot/grub/grub.cfg"* ]]
}

@test "no checker anywhere yields nothing, so the caller can say so" {
  run --separate-stderr bash -c '
    source "$GI_ENTRY"
    source "${GI_ROOT}/variants/boot/grub.sh"
    chroot() { return 1; }
    have() { return 1; }
    boot_grub_script_checker /mnt/target /mnt/target/boot/grub/grub.cfg'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "installing to / does not chroot to /" {
  run --separate-stderr bash -c '
    source "$GI_ENTRY"
    source "${GI_ROOT}/variants/boot/grub.sh"
    chroot() { return 0; }
    have() { [[ "$1" == "grub-script-check" ]]; }
    boot_grub_script_checker / /boot/grub/grub.cfg'
  [ "$status" -eq 0 ]
  [[ "$output" != *"chroot"* ]]
}

@test "the grub verifier asks the same question the writer asks" {
  # It had the same defect three lines away: `have grub-script-check` on the
  # host, so a live medium without grub verified nothing and said nothing.
  local body
  body="$(sed -n '/^boot_grub_verify/,/^}/p' "${GI_ROOT}/variants/boot/grub.sh")"
  [[ "$body" == *"boot_grub_script_checker"* ]]
  [[ "$body" != *"have grub-script-check"* ]]
  [[ "$body" == *"has not been established"* ]]
}

@test "signing in place strips what is already there first" {
  # sbsign appends; it does not replace. Signing an image in place — what
  # happens when the ESP is at /boot and the kernel is already where the
  # loader reads it — left one more signature per run of step 80. Measured on
  # a real PE binary: four runs, four signatures. And after rotating the key
  # pair the image still verified against the retired certificate.
  local dir
  dir="$(gi_tmp)"
  printf 'image\n' >"${dir}/k.efi"
  run --separate-stderr bash -c '
    source "$GI_ENTRY"
    config_init_defaults >/dev/null 2>&1
    DRY_RUN=no
    CFG[secureboot_keyfile]="$1/k"; CFG[secureboot_cert]="$1/c"
    : >"$1/k"; : >"$1/c"
    boot_strip_signatures() { printf "stripped %s\n" "$1" >"$1.stripped"; }
    sbsign() { return 0; }
    show_signature() { :; }
    boot_install_efi "$1/k.efi" "$1/k.efi"' bash "$dir"
  [ "$status" -eq 0 ]
  [ -f "${dir}/k.efi.stripped" ]
  grep -q "stripped ${dir}/k.efi" "${dir}/k.efi.stripped"
}

@test "a fresh destination has nothing to strip" {
  local dir
  dir="$(gi_tmp)"
  printf 'image\n' >"${dir}/src.efi"
  run --separate-stderr bash -c '
    source "$GI_ENTRY"
    config_init_defaults >/dev/null 2>&1
    DRY_RUN=no
    CFG[secureboot_keyfile]="$1/k"; CFG[secureboot_cert]="$1/c"
    : >"$1/k"; : >"$1/c"
    boot_strip_signatures() { printf "x\n" >"$1.stripped"; }
    sbsign() { return 0; }
    show_signature() { :; }
    boot_install_efi "$1/src.efi" "$1/dest.efi"' bash "$dir"
  [ "$status" -eq 0 ]
  [ ! -e "${dir}/dest.efi.stripped" ]
  [ ! -e "${dir}/src.efi.stripped" ]
}

@test "the signature strip is bounded" {
  # An unbounded loop over an external tool's exit code is one bug away from
  # never ending, and this one runs as root against the ESP.
  local dir
  dir="$(gi_tmp)"
  printf 'x\n' >"${dir}/img"
  run --separate-stderr timeout 20 bash -c '
    source "$GI_ENTRY"
    have() { [[ "$1" == "sbattach" ]]; }
    sbattach() { printf "call\n" >>"'"${dir}"'/calls"; return 0; }
    boot_strip_signatures "$1/img"' bash "$dir"
  [ "$status" -eq 0 ]
  [ "$(wc -l <"${dir}/calls")" -le 16 ]
  [ "$(wc -l <"${dir}/calls")" -gt 1 ]
}
