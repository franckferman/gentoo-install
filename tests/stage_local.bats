#!/usr/bin/env bats
# A stage of one's own: the path that skips the catalogue entirely.

load helper

@test "stage_file and stage_url together must be refused, not silently ranked" {
  gi_run --steps 40 --dry-run --yes --stage-file /tmp/a.tar --stage-url http://x/b.tar
  [ "$status" -ne 0 ]
  [[ "$stderr" == *"both name a stage"* ]]
}

@test "a stage_file that is not there must be named, not discovered mid-install" {
  gi_run --steps 40 --dry-run --yes --stage-file /nonexistent/stage.tar
  [ "$status" -ne 0 ]
  [[ "$stderr" == *"No such stage archive"* ]]
}

@test "an invalid sha256 must die at the check, before tar is asked to open anything" {
  gi_run --steps 40 --dry-run --yes --stage-file /tmp/a.tar --stage-checksum not-hex
  [ "$status" -ne 0 ]
}

@test "the four stage-of-your-own settings must be spellable in a .conf" {
  local key
  for key in stage_file stage_url stage_signature stage_checksum; do
    printf '%s = x\n' "$key" >"${BATS_TEST_TMPDIR}/one.conf"
    gi_run --config "${BATS_TEST_TMPDIR}/one.conf" --dump-config
    [[ "$stderr" != *"Unknown setting"* ]] || {
      printf 'setting declared but unreachable from a .conf: %s\n' "$key" >&2
      return 1
    }
  done
}

@test "unpacking refuses a target the disk plan says should be mounted but is not" {
  # The runner accumulates failures instead of stopping (DESIGN.md §4), so a
  # failed step 20 leaves step 40 pointed at an unmounted directory. Found by
  # running it: 1.3 GB of stage3 landed on the installer's own disk, then went
  # invisible when the next run mounted the real filesystem over it.
  local dir
  dir="$(gi_tmp)"
  mkdir -p "${dir}/state" "${dir}/target"
  printf 'disk.mountpoint=%s\n' "${dir}/target" >"${dir}/state/state"
  chmod 600 "${dir}/state/state"

  gi_bash 'STATE_DIR="$1"; STATE_FILE="$1/state"; stage_unpack /nonexistent.tar "$2"' \
    "${dir}/state" "${dir}/target"
  [ "$status" -ne 0 ]
  [[ "$stderr" == *"nothing is mounted on"* ]]
}

@test "unpacking into a plain --root with no disk plan stays allowed" {
  # The guard must not break installing into a directory on purpose: it only
  # bites when step 20 recorded that very path as a mountpoint.
  local dir
  dir="$(gi_tmp)"
  mkdir -p "${dir}/state" "${dir}/target"
  : >"${dir}/state/state"

  gi_bash 'STATE_DIR="$1"; STATE_FILE="$1/state"; _stage_assert_target_mounted "$2"' \
    "${dir}/state" "${dir}/target"
  [ "$status" -eq 0 ]
}

@test "the disk plan mounts where the rest of the run builds" {
  # Two settings named the same directory — disk_root for step 20, root for
  # steps 40 to 95 — and agreed only until one of them was set.
  gi_bash 'CFG[root]=/mnt/elsewhere; disk_mount_root'
  [ "$status" -eq 0 ]
  [ "$output" = "/mnt/elsewhere" ]
}

@test "no disk_root setting survives beside root" {
  gi_bash 'config_init_defaults >/dev/null 2>&1; printf "%s\n" "${CFG[disk_root]+set}"'
  [ -z "$output" ]
}

@test "the stage refuses a root the disk plan did not mount" {
  # The guard exists because 1.3 GB of stage3 once landed on the installer's
  # own disk. It used to bite only when the planned mountpoint was the very
  # path about to be written, so two roots that disagreed walked past it —
  # and nothing is mounted on that root either.
  local dir
  dir="$(gi_tmp)"
  mkdir -p "${dir}/state" "${dir}/notmounted"
  printf 'disk.mountpoint=/mnt/gentoo\n' >"${dir}/state/journal"
  gi_bash 'STATE_FILE="$1/state/journal"; _stage_assert_target_mounted "$1/notmounted"' "$dir"
  [ "$status" -ne 0 ]
  [[ "$stderr" == *"mounted the target on /mnt/gentoo"* ]]
  [[ "$stderr" == *"not on the target"* ]]
}

@test "a plain directory with no disk plan is still unpacked into" {
  local dir
  dir="$(gi_tmp)"
  mkdir -p "${dir}/state" "${dir}/plain"
  : >"${dir}/state/journal"
  gi_bash 'STATE_FILE="$1/state/journal"; _stage_assert_target_mounted "$1/plain"' "$dir"
  [ "$status" -eq 0 ]
}
