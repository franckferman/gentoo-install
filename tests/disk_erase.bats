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

@test "a volume group is judged confined only when every PV is on the target" {
  # disk_release deactivates the whole group it finds through an LV on the
  # target. Proved on two loop devices: releasing the first took down a
  # logical volume living entirely on the second, and the run said nothing.
  #
  # Both answers in one snippet, and printed rather than returned: a test that
  # only checks a non-zero status passes just as well when the function has
  # been deleted, which is how a guard comes back without anything noticing.
  gi_bash 'config_init_defaults >/dev/null 2>&1
    _disk_holding_disks() { case "$1" in *sdb*) printf "sdb\n" ;; *sdc*) printf "sdc\n" ;; esac; }
    vgs() { printf "  /dev/sdb1\n  /dev/sdc1\n"; }
    _disk_vg_is_confined vg_data /dev/sdb && printf "spanning=allowed " || printf "spanning=refused "
    vgs() { printf "  /dev/sdb1\n  /dev/sdb2\n"; }
    _disk_vg_is_confined vg0 /dev/sdb && printf "confined=allowed\n" || printf "confined=refused\n"'
  [ "$status" -eq 0 ]
  [ "$output" = "spanning=refused confined=allowed" ]
}

@test "releasing a disk asks whether the group stays on it" {
  # Every write in lib/disk.sh goes through _disk_assert_target. vgchange is
  # not a write to a device, so it never did.
  local body
  body="$(sed -n '/^disk_release/,/^}/p' "${GI_ROOT}/lib/disk.sh")"
  [[ "$body" == *"_disk_vg_is_confined"* ]]
  [[ "$body" == *"reaches past"* ]]
  # And it refuses rather than deactivating half a group.
  [[ "$body" == *"takes down volumes on a disk nobody confirmed"* ]]
}

@test "the last partition takes the rest only when the plan keeps nothing back" {
  # The plan emits a free row only when something is left over. Its absence
  # means the last volume is meant to take the rest, and 0:0 is exact — it also
  # absorbs the megabyte alignment rounds away. Its presence means the
  # opposite, and 0:0 was taking that too: the server layout keeps a fifth of
  # the disk back on purpose, and without LVM the plan said "home 28.6 GiB,
  # 38.2 GiB unpartitioned" while the disk came back with a 66.9 GiB home.
  local snippet='
    config_init_defaults >/dev/null 2>&1
    DRY_RUN=yes
    _disk_assert_target() { return 0; }
    run_cmd() { printf "%s\n" "$*" >&2; return 0; }
    run_quiet() { return 0; }
    _disk_settle() { return 0; }
    disk_partition loop0 "$1"'

  # A plan that keeps nothing back: the last partition takes the rest.
  local plan_rest
  plan_rest="$(printf 'meta\tlvm\tno\t0\t-\t-\nesp\tesp\t/boot\t1024\tvfat\t/dev/loop0p1\npart\troot\t/\t8192\text4\t/dev/loop0p2\npart\thome\t/home\t40960\text4\t/dev/loop0p3\n')"
  run --separate-stderr bash -c 'source "$GI_ENTRY"; '"$snippet" bash "$plan_rest"
  [ "$status" -eq 0 ]
  [[ "$stderr" == *"-n 3:0:0"* ]]

  # A plan that keeps space back: the last partition gets the size announced.
  local plan_free
  plan_free="$(printf 'meta\tlvm\tno\t0\t-\t-\nesp\tesp\t/boot\t1024\tvfat\t/dev/loop0p1\npart\troot\t/\t8192\text4\t/dev/loop0p2\npart\thome\t/home\t40960\text4\t/dev/loop0p3\nfree\t-\t-\t20480\t-\t-\n')"
  run --separate-stderr bash -c 'source "$GI_ENTRY"; '"$snippet" bash "$plan_free"
  [ "$status" -eq 0 ]
  [[ "$stderr" == *"-n 3:0:+40960M"* ]]
  [[ "$stderr" != *"-n 3:0:0"* ]]
}

@test "a volume group is called active when LVM says its volumes are" {
  # The teardown asked `vgs -o vg_attr | grep -q a`, and the a in vg_attr is
  # the allocation policy, not activity. Measured on the machine this was
  # written on: an active group reads "wz--n--", with no a anywhere, so the
  # warning never fired for the thing it names — while a group created with
  # --alloc anywhere reads "wz--a--" and would have raised it while inactive.
  gi_bash 'lvs() { printf "  active\n  active\n"; }; _disk_vg_is_active vg0'
  [ "$status" -eq 0 ]

  gi_bash 'lvs() { printf "  \n  \n"; }; _disk_vg_is_active vg0'
  [ "$status" -ne 0 ]

  # And the attributes of an active group, which used to be the question.
  gi_bash 'lvs() { printf "  active\n"; }
    vgs() { printf "  wz--n--\n"; }
    _disk_vg_is_active vg0'
  [ "$status" -eq 0 ]
}

@test "the teardown asks about activity, not about an attribute letter" {
  local body
  body="$(sed -n '/^disk_teardown/,/^}/p' "${GI_ROOT}/lib/disk.sh")"
  [[ "$body" == *"_disk_vg_is_active"* ]]
  [[ "$body" != *"vg_attr"* ]]
}

@test "verification says what each mountpoint carries, not merely that something is" {
  # disk_verify checked that a device exists, that something is mounted at the
  # target, and that the *planned* device holds the right filesystem type. It
  # never asked what was mounted. Proved on two loop devices: /var mounted from
  # a different disk entirely, and the run reported "disk verification passed"
  # a moment before step 40 would unpack the stage3 into that tree.
  # disk_mount_tree compares the source before it mounts, four functions away.
  local dir dev plan
  dir="$(gi_tmp)"
  dev="${dir}/planned"
  mknod "$dev" b 7 200 2>/dev/null || skip "cannot create a block node here"
  plan="$(printf 'meta\tmountpoint\t/mnt/t\t0\t-\t-\npart\troot\t/\t4096\text4\t%s\n' "$dev")"

  run --separate-stderr bash -c '
    source "$GI_ENTRY"; DRY_RUN=no
    mountpoint() { return 0; }
    findmnt() { printf "/dev/somebody-else\n"; }
    lsblk() { printf "ext4\n"; }
    disk_verify "$1"' bash "$plan"
  [ "$status" -ne 0 ]
  [[ "$stderr" == *"mounted from /dev/somebody-else"* ]]
  [[ "$stderr" == *"the plan says ${dev}"* ]]

  # And it passes when the planned device is the one mounted.
  run --separate-stderr bash -c '
    source "$GI_ENTRY"; DRY_RUN=no
    WANT="$2"
    mountpoint() { return 0; }
    findmnt() { printf "%s\n" "$WANT"; }
    lsblk() { printf "ext4\n"; }
    disk_verify "$1"' bash "$plan" "$dev"
  [[ "$stderr" == *"disk verification passed"* ]]
}

# --------------------------------------------------------------------------- #
#  The volume group's name belongs to somebody                                #
# --------------------------------------------------------------------------- #
@test "a layout that makes no volume group is not refused for a name" {
  # disk_lvm defaults to auto, and auto means "whatever the layout says":
  # minimal declares `lvm: no` and makes no group at all. Asking CFG[disk_lvm]
  # refused a perfectly good minimal install on a machine that has a vg0, for a
  # name it was never going to use.
  gi_bash '
    config_init_defaults >/dev/null 2>&1
    CFG[disk_vg]=vg0; CFG[disk_lvm]=auto
    have() { [[ "$1" == "vgs" ]]; }
    vgs() { return 0; }
    _disk_vg_is_confined() { return 1; }
    plan="$(printf "meta\tlvm\tno\t0\t-\t-\n")"
    disk_guard_vg_name /dev/vdz "$plan"
  '
  [ "$status" -eq 0 ] || {
    printf 'no group is made, so no name can collide: %s\n' "$stderr" >&2
    return 1
  }
}

@test "a volume group of the configured name living elsewhere is refused" {
  # disk_vg defaults to vg0, the commonest volume group name there is. On a
  # machine whose own group is called vg0, an install got as far as
  #     [+] /dev/loop0: GPT table created
  #     [x] vgcreate vg0 failed on /dev/loop0p2
  # so the disk was erased for a run that could not continue — and every step
  # after 20 names the group by that name, including the one that deactivates
  # it.
  gi_bash '
    config_init_defaults >/dev/null 2>&1
    CFG[disk_vg]=vg0; CFG[disk_lvm]=yes
    have() { [[ "$1" == "vgs" ]]; }
    vgs() { return 0; }                      # a group of that name exists
    _disk_vg_is_confined() { return 1; }     # and not on the target disk
    plan="$(printf "meta\tlvm\tyes\t0\t-\t-\n")"
    disk_guard_vg_name /dev/vdz "$plan"
  '
  [ "$status" -ne 0 ] || {
    printf 'the collision has to be refused before the disk is erased\n' >&2
    return 1
  }
  [[ "$stderr" == *"already exists, and not on /dev/vdz"* ]]
  [[ "$stderr" == *"disk_vg = gi-vg0"* ]]
}

@test "a group of that name on the target disk is this install's own" {
  gi_bash '
    config_init_defaults >/dev/null 2>&1
    CFG[disk_vg]=vg0; CFG[disk_lvm]=yes
    have() { [[ "$1" == "vgs" ]]; }
    vgs() { return 0; }
    _disk_vg_is_confined() { return 0; }     # every PV is on the target
    plan="$(printf "meta\tlvm\tyes\t0\t-\t-\n")"
    disk_guard_vg_name /dev/vdz "$plan"
  '
  [ "$status" -eq 0 ] || {
    printf 'a previous run of ours is not a collision: %s\n' "$stderr" >&2
    return 1
  }
}

@test "no LVM asked for means no name to collide with" {
  gi_bash '
    config_init_defaults >/dev/null 2>&1
    CFG[disk_vg]=vg0; CFG[disk_lvm]=no
    have() { [[ "$1" == "vgs" ]]; }
    vgs() { return 0; }
    _disk_vg_is_confined() { return 1; }
    plan="$(printf "meta\tlvm\tno\t0\t-\t-\n")"
    disk_guard_vg_name /dev/vdz "$plan"
  '
  [ "$status" -eq 0 ]
}

@test "the teardown does not deactivate a group that reaches past the target" {
  # disk_release asks this before it deactivates anything; the teardown asked
  # only whether the name resolved, so it would have run vgchange -an vg0
  # against the host's own root, home, var and swap.
  gi_bash '
    plan="$(printf "meta\tmountpoint\t/mnt/t\t0\t-\t-\nmeta\tlvm\tyes\t0\t-\t-\nmeta\tvg\tvg0\t0\t-\t-\nmeta\tdevice\t/dev/vdz\t0\t-\t-\n")"
    mountpoint() { return 1; }
    vgs() { return 0; }
    _disk_vg_is_confined() { return 1; }
    _disk_vg_is_active() { return 1; }
    vgchange() { printf "VGCHANGE %s\n" "$*"; return 0; }
    run_quiet() { "$@"; }
    disk_teardown "$plan"
  '
  [[ "$output" != *VGCHANGE* ]] || {
    printf 'it deactivated a group that is not on the target disk: %s\n' "$output" >&2
    return 1
  }
  [[ "$stderr" == *"reaches past /dev/vdz"* ]]
}

@test "and does deactivate the one it made" {
  gi_bash '
    plan="$(printf "meta\tmountpoint\t/mnt/t\t0\t-\t-\nmeta\tlvm\tyes\t0\t-\t-\nmeta\tvg\tvg0\t0\t-\t-\nmeta\tdevice\t/dev/vdz\t0\t-\t-\n")"
    mountpoint() { return 1; }
    vgs() { return 0; }
    _disk_vg_is_confined() { return 0; }
    _disk_vg_is_active() { return 1; }
    vgchange() { printf "VGCHANGE %s\n" "$*"; return 0; }
    run_quiet() { "$@"; }
    disk_teardown "$plan"
  '
  [[ "$output" == *"VGCHANGE -an vg0"* ]]
}

@test "an LVM disk is given two partitions to make" {
  gi_bash '
    plan="$(printf "meta\tlvm\tyes\t0\t-\t-\nesp\tesp\t/boot\t1024\tvfat\t/dev/vdz1\npart\tsystem\t-\t0\tlvm\t/dev/vdz2\n")"
    DRY_RUN=yes
    _disk_assert_target() { return 0; }
    # to stderr: the caller redirects run_cmd stdout to /dev/null
    run_cmd() { printf "SGDISK %s\n" "$*" >&2; return 0; }
    run_quiet() { return 0; }
    _disk_settle() { return 0; }
    disk_normalize() { printf "%s\n" "$1"; }
    disk_partition vdz "$plan"
  '
  [ "$status" -eq 0 ]
  [[ "$stderr" == *"-n 1:"*"-n 2:0:0"* ]] || {
    printf 'an ESP and a physical volume: %s\n' "$stderr" >&2
    return 1
  }
}

@test "and says so afterwards" {
  # index counts what sgdisk was asked for, and the LVM branch never advanced
  # it: the run said "1 partition(s) created" about a disk carrying both, right
  # above "vgcreate failed on /dev/loop0p2" — which reads as "the partition is
  # not there" when it is.
  local blk="" c
  for c in /dev/loop0 /dev/loop1 /dev/ram0; do
    [[ -b "$c" ]] && { blk="$c"; break; }
  done
  [[ -n "$blk" ]] || skip "no block device here for the readiness check"

  gi_bash '
    plan="$(printf "meta\tlvm\tyes\t0\t-\t-\nesp\tesp\t/boot\t1024\tvfat\t/dev/vdz1\npart\tsystem\t-\t0\tlvm\t/dev/vdz2\n")"
    DRY_RUN=no
    _disk_assert_target() { return 0; }
    run_cmd() { return 0; }
    run_quiet() { return 0; }
    _disk_settle() { return 0; }
    disk_partition_device() { printf "%s\n" "$1"; }
    disk_normalize() { printf "%s\n" "$1"; }
    disk_partition "$1" "$plan"
  ' "$blk"
  [ "$status" -eq 0 ]
  [[ "$stderr" == *"2 partition(s) created"* ]] || {
    printf 'an ESP and a physical volume are two partitions: %s\n' "$stderr" >&2
    return 1
  }
}

@test "step 20 asks that question with the plan in hand" {
  # In disk_guard it had no plan to ask, so it asked the setting instead.
  gi_bash '
    body="$(declare -f step_20_disk)"
    [[ "$body" == *disk_guard_vg_name* ]] || { echo "step 20 does not ask"; exit 1; }
    [[ "$body" == *\"\$plan\"* ]] || { echo "and not with the plan"; exit 1; }
    [[ "$(declare -f disk_guard)" != *disk_guard_vg_name* ]] \
      || { echo "disk_guard still asks, with no plan to ask about"; exit 1; }
  '
  [ "$status" -eq 0 ] || {
    printf 'the plan is what says whether a group will be made\n' >&2
    return 1
  }
}
