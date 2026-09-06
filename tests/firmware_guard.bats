#!/usr/bin/env bats
# Firmware state: the NVRAM entry and the reboot.
#
# These two are the only things this installer does that outlive the run and are
# global to the machine, and they are the only two that have actually broken
# one. An install to a loop image, run on a working Gentoo laptop, wrote an
# NVRAM entry labelled 'gentoo' pointing at the loop device's ESP — displacing
# the entry that machine booted from — and then rebooted, because the run
# carried --yes and the reboot prompt accepted it. The next power-on found no
# bootable entry. Nothing was wiped and no data was lost, but recovering it took
# a live USB and a chroot.
#
# Both guards below exist so that the same two commands cannot combine that way
# again, on this machine or on anyone else's.

load helper

# --------------------------------------------------------------------------- #
#  disk_target_carries_this_system                                            #
# --------------------------------------------------------------------------- #
@test "a target that is not among the running system's disks is not this machine" {
  gi_bash 'disk_root_ancestors() { printf "nvme0n1p3\nnvme0n1\n"; }
           disk_target_carries_this_system /dev/loop0'
  [ "$status" -ne 0 ]
}

@test "the disk the running system sits on is recognised through LVM and LUKS" {
  # The ancestor walk is what makes this work: / is an LVM volume on a LUKS
  # container on a partition, and the answer has to come out as the whole disk.
  gi_bash 'disk_root_ancestors() { printf "vg0-root\nluks-19399017\nnvme0n1p3\nnvme0n1\n"; }
           disk_target_carries_this_system /dev/nvme0n1'
  [ "$status" -eq 0 ]
}

@test "an empty target is never this machine" {
  gi_bash 'disk_target_carries_this_system ""'
  [ "$status" -ne 0 ]
}

# --------------------------------------------------------------------------- #
#  disk_may_write_firmware_state                                              #
# --------------------------------------------------------------------------- #
@test "a live medium may always write firmware state" {
  # Installing from a live ISO onto a new disk and rebooting into it is the
  # normal path, and the guard must not stand in its way.
  gi_bash 'disk_on_live_medium() { return 0; }
           disk_root_ancestors() { printf "nvme0n1\n"; }
           disk_may_write_firmware_state /dev/sdb'
  [ "$status" -eq 0 ]
}

@test "an installed system may not write firmware state about another disk" {
  gi_bash 'disk_on_live_medium() { return 1; }
           disk_root_ancestors() { printf "nvme0n1p3\nnvme0n1\n"; }
           disk_may_write_firmware_state /dev/loop0'
  [ "$status" -ne 0 ]
}

@test "an installed system may write firmware state about its own disk" {
  gi_bash 'disk_on_live_medium() { return 1; }
           disk_root_ancestors() { printf "nvme0n1p3\nnvme0n1\n"; }
           disk_may_write_firmware_state /dev/nvme0n1'
  [ "$status" -eq 0 ]
}

# --------------------------------------------------------------------------- #
#  The reboot                                                                 #
# --------------------------------------------------------------------------- #
@test "--yes does not answer the reboot question" {
  # The whole incident in one test. --yes answered a prompt whose wrong answer
  # restarts the operator's machine; it must not, exactly as it does not answer
  # a typed proof (DESIGN.md §12).
  gi_bash '
    config_init_defaults
    ASSUME_YES=yes
    NON_INTERACTIVE=no
    disk_may_write_firmware_state() { return 0; }
    run_cmd() { printf "RAN %s\n" "$*"; }
    _fin_reboot
  '
  [ "$status" -eq 0 ]
  [[ "$output" != *"RAN reboot"* ]]
}

@test "--non-interactive does not answer the reboot question either" {
  gi_bash '
    config_init_defaults
    NON_INTERACTIVE=yes
    disk_may_write_firmware_state() { return 0; }
    run_cmd() { printf "RAN %s\n" "$*"; }
    _fin_reboot
  '
  [ "$status" -eq 0 ]
  [[ "$output" != *"RAN reboot"* ]]
}

@test "reboot = yes, set on purpose, does reboot" {
  # The guard removes an accident, not the feature.
  gi_bash '
    config_init_defaults
    CFG[reboot]=yes
    disk_may_write_firmware_state() { return 0; }
    run_cmd() { printf "RAN %s\n" "$*"; }
    _fin_reboot
  '
  [ "$status" -eq 0 ]
  [[ "$output" == *"RAN reboot"* ]]
}

@test "reboot = yes is still refused when the target is not this machine" {
  # An explicit answer to the second question does not answer the first one.
  gi_bash '
    config_init_defaults
    CFG[reboot]=yes
    disk_may_write_firmware_state() { return 1; }
    run_cmd() { printf "RAN %s\n" "$*"; }
    _fin_reboot
  '
  [ "$status" -eq 0 ]
  [[ "$output" != *"RAN reboot"* ]]
}

# --------------------------------------------------------------------------- #
#  The encryption ordering                                                    #
# --------------------------------------------------------------------------- #
@test "step 20 hands over to step 30 when a container is still to be made" {
  # An encrypted install needs the container before any filesystem: the LUKS
  # header lives in the partition, and a filesystem written there first is one
  # the header overwrites. Before this handover existed, an encrypted run
  # formatted the partition, step 30 failed on a state key nothing wrote, and
  # the run carried on to install an unencrypted system onto a disk whose
  # operator had asked for encryption.
  gi_bash 'config_init_defaults
           CFG[crypt]=luks-passphrase
           CFG[crypt_name]=nosuchmapper-for-a-test
           _step20_awaiting_container "$(printf "meta\tlvm\tno\t0\t-\t-\n")"'
  [ "$status" -eq 0 ]
}

@test "step 20 finishes on its own when nothing asked for encryption" {
  gi_bash 'config_init_defaults
           CFG[crypt]=none
           _step20_awaiting_container "$(printf "meta\tlvm\tno\t0\t-\t-\n")"'
  [ "$status" -ne 0 ]
}

@test "the plan hands the root filesystem to the mapper, not the partition" {
  # The rewrite is the whole point of the handover: after step 30 opens the
  # container, mkfs must land inside it. Everything else in the plan is left
  # alone — the ESP is outside the container and stays where it is.
  local out
  out="$(gi_capture 'disk_plan_retarget_crypt "$1" /dev/mapper/gentoo' "$(
    printf 'meta\tlvm\tno\t0\t-\t-\nesp\tESP\t/boot\t1024\tvfat\t/dev/sda1\npart\troot\t/\t20000\text4\t/dev/sda2\n'
  )")"
  [[ "$out" == *"/dev/mapper/gentoo"* ]]
  [[ "$out" == *"/dev/sda1"* ]]
  [[ "$out" != *"/dev/sda2"* ]]
}

@test "an LVM plan is left alone, because disk_pv_device already prefers the mapper" {
  local out
  out="$(gi_capture 'disk_plan_retarget_crypt "$1" /dev/mapper/gentoo' "$(
    printf 'meta\tlvm\tyes\t0\t-\t-\npart\tsystem\t-\t20000\tlvm\t/dev/sda2\n'
  )")"
  [[ "$out" == *"/dev/sda2"* ]]
  [[ "$out" != *"mapper"* ]]
}

# --------------------------------------------------------------------------- #
#  Secure Boot                                                                #
# --------------------------------------------------------------------------- #
@test "signing needs both halves of the pair, and says which one is missing" {
  # secureboot_keyfile was read by the code and declared by nothing until this
  # was found by sweeping the settings, so this path had never run at all. Half
  # a pair is a mistake worth stopping for: the alternative is an unsigned
  # binary on a machine whose operator believes it is signed.
  local dir
  dir="$(gi_tmp)"
  : >"${dir}/key"
  : >"${dir}/cert"

  gi_bash 'config_init_defaults; CFG[secureboot_keyfile]="$1"; boot_secureboot_ready' "${dir}/key"
  [ "$status" -ne 0 ]

  gi_bash 'config_init_defaults; CFG[secureboot_cert]="$1"; boot_secureboot_ready' "${dir}/cert"
  [ "$status" -ne 0 ]

  # sbsign is the third thing it insists on, and the test container has no
  # signing tools; the question here is the pairing, so only that is stubbed.
  gi_bash 'config_init_defaults
           have() { [[ "$1" == sbsign ]] || command -v "$1" >/dev/null 2>&1; }
           CFG[secureboot_keyfile]="$1"; CFG[secureboot_cert]="$2"
           boot_secureboot_ready' "${dir}/key" "${dir}/cert"
  [ "$status" -eq 0 ]
}

@test "the unified image is signed before it is copied to the fallback path" {
  # Order, not decoration. A firmware with Secure Boot on starts
  # EFI/BOOT/BOOTX64.EFI and refuses it unsigned — so copying first and signing
  # after would leave the one file that actually boots without a signature.
  # Verified on a real image as well: sbverify --cert says "Signature
  # verification OK" for both the image and its copy.
  local sign copy
  sign="$(grep -n 'boot_install_efi' "${GI_ROOT}/variants/boot/uki.sh" | head -n1 | cut -d: -f1)"
  copy="$(grep -n 'boot_uki_write_fallback "\$root"' "${GI_ROOT}/variants/boot/uki.sh" \
    | tail -n1 | cut -d: -f1)"
  [ -n "$sign" ]
  [ -n "$copy" ]
  [ "$sign" -lt "$copy" ]
}
