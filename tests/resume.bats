#!/usr/bin/env bats
# Coming back to a target another process left behind.
#
# The installer mounts the target in step 20 and releases everything it mounted
# when the run ends. So the second invocation — a --resume after an
# interruption, a --steps 70,80 to finish a job, the very sequence step 95
# prints when it fails — used to arrive at an empty /mnt/gentoo and mount
# /proc and /dev over nothing. The way back was tools/luks-open.sh, a rescue
# tool, for the ordinary case of picking up where the last run stopped.
#
# Step 50 reattaches now, from the plan step 20 wrote down. These tests are
# about what it does and, more importantly, what it refuses to do.

load helper

plan_fixture() {
  # A plan as step 20 writes it: meta rows, then the volumes.
  printf 'meta\tmountpoint\t/mnt/gentoo\t0\t-\t-\n'
  printf 'meta\tdevice\t/dev/vdz\t0\t-\t-\n'
  printf 'meta\tlvm\tyes\t0\t-\t-\n'
  printf 'meta\tvg\tvg0\t0\t-\t-\n'
}

@test "no recorded plan means there is nothing to reattach" {
  # --root pointing at a tree somebody else prepared is a supported way to use
  # this installer, and it has no plan of ours anywhere.
  gi_bash '
    config_init_defaults
    CFG[state_dir]="$1"
    STATE_DIR="$1"
    _step50_reattach
  ' "$(gi_tmp)/noplan"
  [ "$status" -eq 0 ]
}

@test "a target that is already mounted is left exactly as it is" {
  gi_bash '
    config_init_defaults
    CFG[state_dir]="$1"; STATE_DIR="$1"
    disk_saved_plan() { printf "meta\tmountpoint\t/mnt/gentoo\t0\t-\t-\n"; }
    disk_target_is_mounted() { return 0; }
    disk_mount_tree() { printf "MOUNTED\n"; }
    _step50_reattach
  ' "$(gi_tmp)"
  [ "$status" -eq 0 ]
  [[ "$output" != *"MOUNTED"* ]]
}

@test "a plan describing this machine's own disk is refused, not mounted" {
  # A plan left in the state directory from another install would otherwise
  # activate a volume group and mount a running system's filesystems under
  # /mnt/gentoo.
  #
  # The stub here is disk_root_ancestors, which is what the predicate actually
  # reads, and not the predicate itself. That distinction is the test: the first
  # version of this guard called disk_may_write_firmware_state — which answers
  # "may I write an NVRAM entry for this disk", and answers yes for the disk you
  # booted from — and a test that stubbed the predicate agreed with the mistake
  # and passed.
  gi_bash '
    config_init_defaults
    disk_saved_plan() { printf "meta\tmountpoint\t/mnt/gentoo\t0\t-\t-\nmeta\tdevice\t/dev/nvme0n1\t0\t-\t-\n"; }
    disk_target_is_mounted() { return 1; }
    disk_root_ancestors() { printf "nvme0n1p3\nnvme0n1\n"; }
    disk_mount_tree() { printf "MOUNTED\n"; }
    _step50_reattach
  '
  [ "$status" -ne 0 ]
  [[ "$output" != *"MOUNTED"* ]]
  [[ "$stderr" == *"this machine's own disk"* ]]
}

@test "a plan describing another disk entirely is mounted, not refused" {
  # The other half, and the one the wrong predicate broke: installing to a
  # second disk from a running system is ordinary, and its tree is exactly what
  # a resume has to mount.
  gi_bash '
    config_init_defaults
    set_explicit crypt none
    disk_saved_plan() { printf "meta\tmountpoint\t/mnt/gentoo\t0\t-\t-\nmeta\tdevice\t/dev/sdb\t0\t-\t-\n"; }
    disk_target_is_mounted() { return 1; }
    disk_root_ancestors() { printf "nvme0n1p3\nnvme0n1\n"; }
    disk_activate_volume_group() { return 0; }
    disk_mount_tree() { printf "MOUNTED\n"; }
    _step50_reattach
  '
  [ "$status" -eq 0 ]
  [[ "$output" == *"MOUNTED"* ]]
}

@test "an encrypted target is opened before its group is activated or mounted" {
  # Order is the whole content of this one: the volume group lives inside the
  # container, and the tree lives inside the group.
  gi_bash '
    config_init_defaults
    set_explicit crypt luks-passphrase
    CFG[crypt_name]=gentoo
    CFG[crypt_device]=/dev/vdz2
    disk_saved_plan() { printf "meta\tmountpoint\t/mnt/gentoo\t0\t-\t-\nmeta\tdevice\t/dev/vdz\t0\t-\t-\n"; }
    disk_target_is_mounted() { return 1; }
    disk_may_write_firmware_state() { return 0; }
    crypt_is_open() { return 1; }
    crypt_open_for_resume() { printf "OPEN %s %s\n" "$1" "$2"; }
    disk_activate_volume_group() { printf "VG\n"; }
    disk_mount_tree() { printf "MOUNT\n"; }
    _step50_reattach
  '
  [ "$status" -eq 0 ]
  [[ "$output" == *"OPEN /dev/vdz2 gentoo"* ]]
  local order
  order="$(printf '%s\n' "$output" | grep -nE 'OPEN|VG|MOUNT' | cut -d: -f2 | tr -d ' ' | paste -sd,)"
  [[ "$order" == OPEN*,VG,MOUNT ]]
}

@test "an unencrypted target is mounted without asking for anything" {
  gi_bash '
    config_init_defaults
    set_explicit crypt none
    disk_saved_plan() { printf "meta\tmountpoint\t/mnt/gentoo\t0\t-\t-\nmeta\tdevice\t/dev/vdz\t0\t-\t-\n"; }
    disk_target_is_mounted() { return 1; }
    disk_may_write_firmware_state() { return 0; }
    crypt_open_for_resume() { printf "OPEN\n"; }
    disk_activate_volume_group() { return 0; }
    disk_mount_tree() { printf "MOUNT\n"; }
    _step50_reattach
  '
  [ "$status" -eq 0 ]
  [[ "$output" != *"OPEN"* ]]
  [[ "$output" == *"MOUNT"* ]]
}

@test "an encrypted plan with no recorded container says so instead of guessing" {
  gi_bash '
    config_init_defaults
    set_explicit crypt luks-passphrase
    CFG[crypt_device]=""
    disk_saved_plan() { printf "meta\tmountpoint\t/mnt/gentoo\t0\t-\t-\nmeta\tdevice\t/dev/vdz\t0\t-\t-\n"; }
    disk_target_is_mounted() { return 1; }
    disk_may_write_firmware_state() { return 0; }
    crypt_is_open() { return 1; }
    state_get() { return 1; }
    disk_mount_tree() { printf "MOUNTED\n"; }
    _step50_reattach
  '
  [ "$status" -ne 0 ]
  [[ "$output" != *"MOUNTED"* ]]
  [[ "$stderr" == *"no container is recorded"* ]]
}

@test "the saved plan is read from the state directory the run was given" {
  local dir
  dir="$(gi_tmp)/withplan"
  mkdir -p "$dir"
  printf 'meta\tmountpoint\t/mnt/gentoo\t0\t-\t-\n' >"${dir}/disk-plan.tsv"
  gi_bash '
    config_init_defaults
    CFG[state_dir]="$1"
    disk_saved_plan | head -n 1
  ' "$dir"
  [ "$status" -eq 0 ]
  [[ "$output" == *"/mnt/gentoo"* ]]
}

@test "step 50 reattaches before it prepares anything" {
  # The wiring, tested on purpose: disabling the call left every test above
  # green, because they all exercise the function directly. A reattachment
  # nothing calls is a reattachment that does not happen.
  gi_bash '
    config_init_defaults
    _step50_reattach() { printf "REATTACHED\n"; return 1; }
    chroot_prepare() { printf "PREPARED\n"; return 0; }
    step_50_chroot
  '
  [ "$status" -ne 0 ]
  [[ "$output" == *"REATTACHED"* ]]
  [[ "$output" != *"PREPARED"* ]]
}
