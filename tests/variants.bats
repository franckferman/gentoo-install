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
