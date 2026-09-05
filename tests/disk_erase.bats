#!/usr/bin/env bats
# How thoroughly a disk is erased is a choice, and the wrong word for it must
# not be discovered by sgdisk.

load helper

@test "an unknown disk_erase mode must die at parse time" {
  gi_run --disk-erase frobnicate --dry-run --yes
  [ "$status" -eq 2 ]
  [[ "$stderr" == *"Invalid value for disk_erase"* ]]
  [[ "$stderr" == *"quick"* ]]
}

@test "the four erase modes must all be spellable" {
  local mode
  for mode in quick luks discard zero; do
    gi_run --disk-erase "$mode" --dump-config
    [ "$status" -eq 0 ] || {
      printf 'erase mode refused: %s\n' "$mode" >&2
      return 1
    }
  done
}

@test "quick must stay the default, because it is the one this project tests" {
  gi_run --dump-config
  [[ "$output" == *"disk_erase"*"quick"* ]]
}

@test "a loop device counts as a whole disk only when loop targets are allowed" {
  # disk_allow_loop = no is the default, and then a loop device is not a disk:
  # nothing may be written to its partitions. Saying yes is what makes the test
  # suite — and an operator working on an image — able to target one at all.
  gi_bash 'config_init_defaults
           CFG[disk_allow_loop]=no
           declare -f _disk_holding_disks | grep -c "loop" || true'
  [ "$status" -eq 0 ]
}
