#!/usr/bin/env bats
# The mode guard: this installer runs as root, so every chmod on a path the
# caller named is a chance to change a node the whole machine shares.
#
# This suite exists because of a real incident. `--log-file /dev/null` under
# sudo reached `chmod 0600 /dev/null`, which succeeded. Every unprivileged
# process on the machine then lost the ability to write to /dev/null, and each
# shell that redirected to it died before running its command — the machine had
# no working shell until /dev/null was recreated by hand.

load helper

@test "_core_plain_file refuses a character device" {
  gi_bash '_core_plain_file /dev/null'
  [ "$status" -ne 0 ]
}

@test "_core_plain_file refuses a symlink, even to a regular file" {
  local dir
  dir="$(gi_tmp)"
  printf 'x\n' >"${dir}/real"
  ln -sf "${dir}/real" "${dir}/link"
  gi_bash '_core_plain_file "$1"' "${dir}/link"
  [ "$status" -ne 0 ]
}

@test "_core_plain_file refuses a directory" {
  gi_bash '_core_plain_file "$1"' "$(gi_tmp)"
  [ "$status" -ne 0 ]
}

@test "_core_plain_file accepts an ordinary file" {
  local dir
  dir="$(gi_tmp)"
  printf 'x\n' >"${dir}/plain"
  gi_bash '_core_plain_file "$1"' "${dir}/plain"
  [ "$status" -eq 0 ]
}

@test "core_open_log leaves the mode of a device node alone" {
  local before after
  before="$(stat -c '%a' /dev/null)"
  gi_bash 'core_open_log /dev/null'
  [ "$status" -eq 0 ]
  after="$(stat -c '%a' /dev/null)"
  [ "$before" = "$after" ]
}

@test "core_open_log still accepts /dev/null as a log destination" {
  # Silencing the log must keep working; the guard removes the chmod, not the
  # feature.
  gi_capture 'core_open_log /dev/null; printf "%s\n" "$LOG_FILE"' | grep -qx '/dev/null'
}

@test "core_open_log still tightens an ordinary log file" {
  local dir
  dir="$(gi_tmp)"
  gi_bash 'core_open_log "$1"' "${dir}/run.log"
  [ "$status" -eq 0 ]
  [ "$(stat -c '%a' "${dir}/run.log")" = "600" ]
}

@test "state_init does not re-mode a state directory it did not create" {
  # --state-dir names a path the caller chose. Handed an existing shared
  # directory, a root-run installer that chmod 0700'd it would lock every other
  # user out of it — the /tmp sticky bit is the case that matters.
  local dir
  dir="$(gi_tmp)/shared"
  mkdir -p "$dir"
  chmod 1777 "$dir"
  gi_bash 'DRY_RUN=no; state_init "$1"' "$dir"
  [ "$status" -eq 0 ]
  [ "$(stat -c '%a' "$dir")" = "1777" ]
}

@test "state_init still tightens a state directory it creates itself" {
  local dir
  dir="$(gi_tmp)/fresh"
  gi_bash 'DRY_RUN=no; state_init "$1"' "$dir"
  [ "$status" -eq 0 ]
  [ "$(stat -c '%a' "$dir")" = "700" ]
}

@test "the two caller-named paths keep their guards" {
  # The behavioural tests above are the real protection; this one names the two
  # places a future edit is most likely to undo, so the failure says why.
  grep -A3 'if ! { : >>"$path"; }' "${GI_ROOT}/lib/core.sh" >/dev/null
  grep -q '_core_plain_file "$path"' "${GI_ROOT}/lib/core.sh"
  grep -q 'dir_existed' "${GI_ROOT}/lib/state.sh"
  grep -q '_core_plain_file "$STATE_FILE"' "${GI_ROOT}/lib/state.sh"
}
