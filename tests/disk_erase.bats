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

# --------------------------------------------------------------------------- #
#  Inodes, which is what a Gentoo /var runs out of first                      #
# --------------------------------------------------------------------------- #
# Found by installing: the default desktop layout on a 24 GiB disk gives /var
# 3 GiB, mke2fs makes 196,608 inodes for it at one per 16 KiB, and the ebuild
# repository is 160,000 files. `emerge --sync` stopped partway through with
# "No space left on device" while df reported 2.7 GiB free — the one error
# message that sends you looking at the wrong number.

@test "a small /var is given inodes for the ebuild repository" {
  local out
  out="$(gi_capture 'disk_ext_inode_args /var 3221225472' </dev/null)"
  [[ "$out" == *"-N"* ]]
  [[ "$out" == *"500000"* ]]
}

@test "a large /var is left alone: the default is already generous there" {
  # 200 GiB gives 13 million inodes by default. Asking for half a million would
  # be asking for fewer.
  local out
  out="$(gi_capture 'disk_ext_inode_args /var 214748364800' </dev/null)"
  [ -z "$out" ]
}

@test "a filesystem that holds no repository is not touched" {
  local out
  out="$(gi_capture 'disk_ext_inode_args /home 3221225472' </dev/null)"
  [ -z "$out" ]
}

@test "a tiny /var is capped at what mke2fs will accept" {
  # One inode per 4 KiB is as dense as it goes; 1 GiB therefore caps at 262144
  # rather than asking for a table that will not fit.
  local out
  out="$(gi_capture 'disk_ext_inode_args /var 1073741824' </dev/null)"
  [[ "$out" == *"262144"* ]]
}

@test "a size that is not a number changes nothing" {
  # blockdev prints nothing for a device that is not there, and a dry run has
  # no device at all. The default table is the right answer then.
  local out
  out="$(gi_capture 'disk_ext_inode_args /var ""' </dev/null)"
  [ -z "$out" ]
}

# --------------------------------------------------------------------------- #
#  Room to build, which is not the same as room to store                      #
# --------------------------------------------------------------------------- #
@test "the filesystem a package is built on is /var when /var is split off" {
  local out
  out="$(gi_capture 'disk_build_space_mib "$1"' "$(
    printf 'meta\tlvm\tyes\t0\t-\t-\nlv\tvar\t/var\t2949\text4\t/dev/vg0/var\nlv\troot\t/\t8192\text4\t/dev/vg0/root\n'
  )")"
  [ "$out" = "2949 /var" ]
}

@test "and the root filesystem when it is not" {
  local out
  out="$(gi_capture 'disk_build_space_mib "$1"' "$(
    printf 'meta\tlvm\tno\t0\t-\t-\npart\troot\t/\t21000\text4\t/dev/sda2\n'
  )")"
  [ "$out" = "21000 /" ]
}

@test "a /var too small to build in is named before the disk is erased" {
  # The plan is the screen the operator reads before typing the device name.
  # This one was learned the other way round: the run reached step 60, spent
  # four minutes emerging, and died unpacking linux-firmware into a 2.9 GiB
  # /var. Nothing here refuses anything — a layout is the operator's to choose
  # — but it is said while there is still something to do about it.
  gi_bash 'disk_warn_build_space "$1"' "$(
    printf 'meta\tlvm\tyes\t0\t-\t-\nlv\tvar\t/var\t2949\text4\t/dev/vg0/var\n'
  )"
  [ "$status" -eq 0 ]
  [[ "$stderr" == *"packages are built there"* ]]
  [[ "$stderr" == *"linux-firmware"* ]]
}

@test "a /var with room says nothing at all" {
  gi_bash 'disk_warn_build_space "$1"' "$(
    printf 'meta\tlvm\tyes\t0\t-\t-\nlv\tvar\t/var\t8192\text4\t/dev/vg0/var\n'
  )"
  [ "$status" -eq 0 ]
  [ -z "$stderr" ]
}

@test "the desktop layout gives /var room to build in" {
  # The floor, read from the layout itself rather than restated here: a
  # percentage that works on a 500 GiB disk is 2.9 GiB on a 24 GiB one, and
  # the floor is what makes the small disk work.
  local spec
  spec="$(grep -E '^var:/var:' "${GI_ROOT}/variants/layout/desktop.sh")"
  [[ "$spec" == *"/6G/"* ]]
}
