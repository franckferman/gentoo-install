#!/usr/bin/env bats
#
# gentoo-install — the plan handed to the steps that come after the disk
# ----------------------------------------------------------------------------
# Two steps build the tree: step 20 alone when nothing is encrypted, step 20
# then step 30 when something is. Whichever built it has to say what it built,
# and the facts are read off the devices at the moment they are said.
#
# That moment is the whole of it. On an encrypted run step 20 stops after
# partitioning, so its moment is before any filesystem exists — measured on a
# loop image, blkid on a partitioned, unformatted ESP prints nothing and the
# same partition after mkfs.vfat prints a UUID. Step 30 creates the
# filesystems and used to rewrite only the plan file, so disk.esp_uuid stayed
# unset for good, crypt.keyfile_uuid with it, and step 70 wrote
# rd.luks.key=<path> with no device after it: dracut then looks for the key
# inside the initramfs, where crypt = luks-keyfile-gpg has not put it.
#

bats_require_minimum_version 1.5.0

load helper

# A journal and a state directory this test owns, and the settings the
# recorder reads. Prefixed to the snippets below.
gi_journal_setup() {
  cat <<'EOF'
  dir="${BATS_TEST_TMPDIR}/journal"; rm -rf -- "$dir"; mkdir -p -- "$dir"
  CFG[state_dir]="$dir"; STATE_DIR="$dir"; DRY_RUN="no"
  CFG[disk_esp_mount]="/boot"; CFG[disk_filesystem]="ext4"
  CFG[crypt]="luks-keyfile-gpg"; CFG[crypt_name]="gentoo"
  state_init >/dev/null 2>&1
EOF
}

# A plain (non-LVM) encrypted layout, as step 20 leaves it and as step 30
# retargets it. The devices deliberately do not exist: a UUID that cannot be
# read is the case under test.
gi_plain_plan() {
  cat <<'EOF'
  raw_plan="$(printf '%s\n' \
    "meta	device	/dev/sdz	0	-	-" \
    "meta	layout	plain	0	-	-" \
    "meta	lvm	no	0	-	-" \
    "meta	vg	-	0	-	-" \
    "meta	mountpoint	/mnt/gentoo	0	-	-" \
    "esp	esp	/boot	512	vfat	/dev/sdz1" \
    "part	root	/	4096	ext4	/dev/sdz2")"
  mapped_plan="$(disk_plan_retarget_crypt "$raw_plan" /dev/mapper/gentoo)"
EOF
}

# --------------------------------------------------------------------------- #
#  The seam: step 30 owes the journal what it owes the plan file              #
# --------------------------------------------------------------------------- #
@test "step 30 records the plan it provisioned, and does not just write the file" {
  # Read out of the sourced shell rather than out of the file, so a function
  # that was renamed or deleted fails here instead of matching a stale line.
  gi_bash '
    body="$(declare -f _step30_finish_provisioning)"
    [[ "$body" == *disk_record_plan_facts* ]] || { echo "no disk_record_plan_facts"; exit 1; }
    [[ "$body" != *write_file* ]] || { echo "still writes the plan file by hand"; exit 1; }
  '
  [ "$status" -eq 0 ] || {
    printf 'step 30 finishes the provisioning step 20 could not: %s\n' "$output" >&2
    printf 'writing the plan file alone leaves the journal describing devices\n' >&2
    printf 'that had no filesystem on them yet.\n' >&2
    return 1
  }
}

@test "step 20 hands the same recorder the plan, on all three of its exits" {
  gi_bash '
    body="$(declare -f step_20_disk)"
    n="$(grep -c "disk_record_plan_facts" <<<"$body")"
    [[ "$n" -eq 3 ]] || { echo "called ${n} times, not 3"; exit 1; }
  '
  [ "$status" -eq 0 ] || {
    printf 'step 20 leaves by three doors — already provisioned, handed to step 30,\n' >&2
    printf 'and finished — and each has to journal what it built: %s\n' "$output" >&2
    return 1
  }
}

# --------------------------------------------------------------------------- #
#  The facts follow the plan they are given                                   #
# --------------------------------------------------------------------------- #
@test "the recorded root device is the one the plan names, mapper or partition" {
  run --separate-stderr bash -c 'source "$GI_ENTRY"
'"$(gi_journal_setup)"'
'"$(gi_plain_plan)"'
    disk_record_plan_facts "$raw_plan" >/dev/null
    printf "raw=%s\n" "$(state_get disk.root_device)"
    disk_record_plan_facts "$mapped_plan" >/dev/null
    printf "mapped=%s\n" "$(state_get disk.root_device)"
  '
  [ "$status" -eq 0 ]
  [[ "$output" == *"raw=/dev/sdz2"* ]] || {
    printf 'before the container exists, / is the partition: %s\n' "$output" >&2
    return 1
  }
  [[ "$output" == *"mapped=/dev/mapper/gentoo"* ]] || {
    printf 'once the container is open, / is the mapper, and step 90 writes an\n' >&2
    printf 'fstab from what is mounted there: %s\n' "$output" >&2
    return 1
  }
}

@test "the device to encrypt is never the mapper of the container it is inside" {
  # The second pass runs on a plan that names the mapper where the partition
  # used to be. Recording that would hand the next --resume /dev/mapper/gentoo
  # as the container to open, and the container to open is what lies under it.
  run --separate-stderr bash -c 'source "$GI_ENTRY"
'"$(gi_journal_setup)"'
'"$(gi_plain_plan)"'
    disk_record_plan_facts "$raw_plan" >/dev/null
    printf "first=%s\n" "$(state_get disk.crypt_device)"
    disk_record_plan_facts "$mapped_plan" >/dev/null
    printf "second=%s\n" "$(state_get disk.crypt_device)"
  '
  [ "$status" -eq 0 ]
  [[ "$output" == *"first=/dev/sdz2"* && "$output" == *"second=/dev/sdz2"* ]] || {
    printf 'the partition under the container must survive the second pass: %s\n' "$output" >&2
    return 1
  }
}

@test "a UUID that could not be read is left unwritten, not written empty" {
  # Step 20 records before the filesystems exist. Writing an empty value there
  # would leave step 30 nothing to fill in, and a later reader cannot tell an
  # empty value from a value that means empty.
  run --separate-stderr bash -c 'source "$GI_ENTRY"
'"$(gi_journal_setup)"'
'"$(gi_plain_plan)"'
    disk_record_plan_facts "$raw_plan" >/dev/null
    if state_get disk.esp_uuid >/dev/null 2>&1; then echo "written anyway"; exit 1; fi
    state_set disk.esp_uuid 38CE-7632
    disk_record_plan_facts "$raw_plan" >/dev/null
    printf "kept=%s\n" "$(state_get disk.esp_uuid)"
  '
  [ "$status" -eq 0 ] || {
    printf 'an unreadable UUID must leave the key absent: %s\n' "$output" >&2
    return 1
  }
  [[ "$output" == *"kept=38CE-7632"* ]] || {
    printf 'a second pass must not blank a UUID an earlier one read: %s\n' "$output" >&2
    return 1
  }
}

# --------------------------------------------------------------------------- #
#  What it is all for                                                         #
# --------------------------------------------------------------------------- #
@test "the ESP UUID in the journal is what puts the key's device on the cmdline" {
  # crypt = luks-keyfile-gpg exists to unlock without anyone typing anything.
  # rd.luks.key=<path> with no device after it makes dracut read <path> from
  # inside the initramfs, so the machine falls back to the recovery passphrase
  # and the file the variant deployed is never opened.
  local snippet='
    dir="${BATS_TEST_TMPDIR}/j$1"; rm -rf -- "$dir"; mkdir -p -- "$dir"
    CFG[state_dir]="$dir"; STATE_DIR="$dir"; DRY_RUN="no"
    CFG[crypt]="luks-keyfile-gpg"; CFG[crypt_name]="gentoo"
    CFG[disk_esp_mount]="/boot"; CFG[crypt_key_dir]="/boot/efi"
    CFG[bootloader]="grub"; CFG[kernel_initramfs]="dracut"
    state_init >/dev/null 2>&1
    state_set disk.layout plain
    state_set disk.esp_mount /boot
    state_set disk.root_fstype ext4
    [[ -z "$2" ]] || state_set disk.esp_uuid "$2"
    crypt_state_record luks-keyfile-gpg /dev/sdz2 >/dev/null 2>&1
    state_set crypt.uuid 1d3f0f4a-0f5a-4c7e-9a2b-2f9d3c5e7a11
    kernel_cmdline
  '
  gi_bash "$snippet" without ""
  [ "$status" -eq 0 ]
  [[ "$output" == *"rd.luks.key=/efi/luks-key.gpg"* ]]
  [[ "$output" != *"rd.luks.key=/efi/luks-key.gpg:UUID="* ]] || {
    printf 'no ESP UUID was recorded, so no device can be named\n' >&2
    return 1
  }

  gi_bash "$snippet" with 38CE-7632
  [ "$status" -eq 0 ]
  [[ "$output" == *"rd.luks.key=/efi/luks-key.gpg:UUID=38CE-7632"* ]] || {
    printf 'with the ESP UUID recorded, dracut must be told which filesystem\n' >&2
    printf 'carries the key: %s\n' "$output" >&2
    return 1
  }
}
