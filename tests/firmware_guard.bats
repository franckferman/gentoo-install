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
