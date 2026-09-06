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

# --------------------------------------------------------------------------- #
#  A journal that a reboot forgets                                            #
# --------------------------------------------------------------------------- #
@test "a state journal in RAM is named as such, before the install starts" {
  # The default is /var/lib/gentoo-install, and on the medium this installer is
  # designed for — a live ISO — that is a tmpfs. Which steps completed, and the
  # disk plan step 20 writes beside them, then live in RAM: interrupt the run,
  # reboot the medium, and --resume has nothing to resume from. Said once, at
  # the start, rather than discovered after three hours of compiling.
  gi_bash 'DRY_RUN=no; STATE_DIR=/dev/shm; state_warn_if_volatile'
  [ "$status" -eq 0 ]
  [[ "$stderr" == *"state journal is on a tmpfs"* ]]
  [[ "$stderr" == *"--state-dir"* ]]
}

@test "a journal on a real filesystem says nothing at all" {
  gi_bash 'DRY_RUN=no; STATE_DIR="$1"; state_warn_if_volatile' "$(gi_tmp)"
  [ "$status" -eq 0 ]
  [ -z "$stderr" ]
}

@test "state_init says it, so nobody has to remember to ask" {
  local dir
  dir="$(gi_tmp)/volatile"
  gi_bash '
    DRY_RUN=no
    state_warn_if_volatile() { printf "WARNED\n"; }
    state_init "$1"
  ' "$dir"
  [ "$status" -eq 0 ]
  [[ "$output" == *"WARNED"* ]]
}

@test "an overlay is followed to the layer that takes the writes" {
  # The Gentoo ISO mounts its root as
  #   overlay LiveOS_rootfs lowerdir=/run/rootfsbase,upperdir=/run/overlayfs
  # so the journal's directory answers "overlay", and the first version of this
  # check had no opinion about that — it said nothing on precisely the medium it
  # was written for, while /run is a tmpfs and the journal was in RAM.
  gi_bash '
    DRY_RUN=no
    STATE_DIR=/var/lib/gentoo-install
    have() { [[ "$1" == findmnt ]] || command -v "$1" >/dev/null 2>&1; }
    findmnt() {
      case "$*" in
        *FSTYPE*/tmp/upper*) printf "tmpfs\n" ;;
        *OPTIONS*)           printf "rw,lowerdir=/l,upperdir=/tmp/upper,workdir=/w\n" ;;
        *FSTYPE*)            printf "overlay\n" ;;
      esac
    }
    mkdir -p /tmp/upper
    state_filesystem
  '
  [ "$status" -eq 0 ]
  [ "$output" = "tmpfs" ]
}

@test "an overlay whose upper layer is on a disk is left alone" {
  gi_bash '
    DRY_RUN=no
    STATE_DIR=/var/lib/gentoo-install
    have() { [[ "$1" == findmnt ]] || command -v "$1" >/dev/null 2>&1; }
    findmnt() {
      case "$*" in
        *FSTYPE*/tmp/persistent*) printf "ext4\n" ;;
        *OPTIONS*)                printf "rw,lowerdir=/l,upperdir=/tmp/persistent,workdir=/w\n" ;;
        *FSTYPE*)                 printf "overlay\n" ;;
      esac
    }
    mkdir -p /tmp/persistent
    state_filesystem
  '
  [ "$status" -eq 0 ]
  [ "$output" = "ext4" ]
}

# --------------------------------------------------------------------------- #
#  The fstab and the plan, which have to agree                                #
# --------------------------------------------------------------------------- #
@test "an fstab missing a mountpoint the plan describes is called out" {
  # A target reattached by hand had its ESP mounted at /boot/efi while the plan
  # said /boot. Step 90 wrote /boot/efi into the fstab, step 80 asked
  # grub-install for /boot, and grub answered "/boot doesn't look like an EFI
  # partition" — a message about the ESP, produced by a disagreement two steps
  # earlier and never mentioned by either of them.
  gi_bash '
    config_init_defaults
    disk_saved_plan() {
      printf "esp\tesp\t/boot\t1024\tvfat\t/dev/vda1\n"
      printf "lv\troot\t/\t8192\text4\t/dev/vg0/root\n"
    }
    _sys_fstab_check_against_plan "$(printf "UUID=x / ext4 defaults 0 1\nUUID=y /boot/efi vfat defaults 0 2\n")"
  '
  [ "$status" -eq 0 ]
  [[ "$stderr" == *"does not carry every mountpoint"* ]]
  [[ "$stderr" == *"/boot"* ]]
}

@test "an fstab that carries the plan says nothing" {
  gi_bash '
    config_init_defaults
    disk_saved_plan() {
      printf "esp\tesp\t/boot\t1024\tvfat\t/dev/vda1\n"
      printf "lv\troot\t/\t8192\text4\t/dev/vg0/root\n"
      printf "lv\tswap\tswap\t2048\tswap\t/dev/vg0/swap\n"
    }
    _sys_fstab_check_against_plan "$(printf "UUID=x / ext4 defaults 0 1\nUUID=y /boot vfat defaults 0 2\n")"
  '
  [ "$status" -eq 0 ]
  [ -z "$stderr" ]
}

@test "no plan at all means nothing to disagree with" {
  gi_bash '
    config_init_defaults
    disk_saved_plan() { return 1; }
    _sys_fstab_check_against_plan "$(printf "UUID=x / ext4 defaults 0 1\n")"
  '
  [ "$status" -eq 0 ]
  [ -z "$stderr" ]
}

@test "step 90 runs that comparison, including in a dry run" {
  # The wiring, on purpose: removing the call left every test above green.
  # And a dry run is exactly when an operator wants to hear it — before the
  # fstab is written, not after the bootloader has been installed elsewhere.
  gi_bash '
    config_init_defaults
    DRY_RUN=yes
    _sys_fstab_render() { printf "UUID=x / ext4 defaults 0 1\n"; }
    _sys_fstab_check_against_plan() { printf "COMPARED\n"; }
    _sys_fstab /mnt/gentoo
  '
  [ "$status" -eq 0 ]
  [[ "$output" == *"COMPARED"* ]]
}

@test "the way back into the target is one that survives the run ending" {
  # Step 95 used to print "./gentoo-install.sh --steps 50   # then: chroot …",
  # and that cannot work: the run releases everything it mounted when it ends,
  # so the invocation mounts the target, says how to enter it, and unmounts it
  # on the way out. Step 50 reattaches for the steps that follow it in the same
  # run — not for an operator arriving afterwards. The rescue tools are what
  # stay mounted.
  local hint
  hint="$(sed -n '/to go back in without rebooting/,/^}/p' "${GI_ROOT}/steps/95_finalize.sh")"
  [[ "$hint" == *"luks-open.sh"* ]]
  [[ "$hint" == *"rescue-chroot.sh"* ]]
  [[ "$hint" != *"--steps 50   # then"* ]]
}
