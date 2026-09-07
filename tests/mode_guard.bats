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

@test "a block with no closing marker is refused, not swallowed to end of file" {
  # The replacement is an awk that starts printing at the open marker and
  # swallows lines until the close marker. With no close marker it swallows to
  # end of file: a make.conf whose closing line an etc-update merge or a hand
  # edit had removed came back four lines shorter — USE, ACCEPT_LICENSE,
  # VIDEO_CARDS and GRUB_PLATFORMS gone — and the run said "block written".
  local dir f
  dir="$(gi_tmp)"
  f="${dir}/make.conf"
  {
    printf 'COMMON_FLAGS="-O2 -pipe"\n'
    printf '# >>> gentoo-install: portage make.conf >>>\n'
    printf 'MAKEOPTS="-j4"\n'
    printf 'USE="elogind"\n'
    printf 'VIDEO_CARDS="intel"\n'
  } >"$f"

  gi_bash 'DRY_RUN=no; ON_CONFLICT=overwrite
    write_block "$1" "portage make.conf" <<< "MAKEOPTS=\"-j16\""' "$f"
  [ "$status" -ne 0 ]
  [[ "$stderr" == *"not whole"* ]]
  [[ "$stderr" == *"nothing says where the block ends"* ]]
  grep -q 'USE="elogind"' "$f"
  grep -q 'VIDEO_CARDS="intel"' "$f"
  [ "$(wc -l <"$f")" -eq 5 ]
}

@test "an orphan closing marker and a doubled block are refused too" {
  local dir f
  dir="$(gi_tmp)"
  f="${dir}/orphan"
  printf 'A=1\n# <<< gentoo-install: t <<<\nB=2\n' >"$f"
  gi_bash 'DRY_RUN=no; write_block "$1" "t" <<< "x"' "$f"
  [ "$status" -ne 0 ]
  [[ "$stderr" == *"left over from an"* ]]

  f="${dir}/doubled"
  printf '# >>> gentoo-install: t >>>\nx\n# <<< gentoo-install: t <<<\n' >"$f"
  printf '# >>> gentoo-install: t >>>\ny\n# <<< gentoo-install: t <<<\n' >>"$f"
  gi_bash 'DRY_RUN=no; write_block "$1" "t" <<< "z"' "$f"
  [ "$status" -ne 0 ]
  [[ "$stderr" == *"only one can be this run's"* ]]
}

@test "a whole block is still replaced, and what surrounds it survives" {
  local dir f
  dir="$(gi_tmp)"
  f="${dir}/whole"
  printf 'BEFORE=1\n# >>> gentoo-install: t >>>\nold\n# <<< gentoo-install: t <<<\nAFTER=2\n' >"$f"
  gi_bash 'DRY_RUN=no; ON_CONFLICT=overwrite; write_block "$1" "t" <<< "new"' "$f"
  [ "$status" -eq 0 ]
  grep -q '^BEFORE=1$' "$f"
  grep -q '^AFTER=2$' "$f"
  grep -q '^new$' "$f"
  ! grep -q '^old$' "$f"
}

@test "a file with no markers at all still gets its block appended" {
  local dir f
  dir="$(gi_tmp)"
  f="${dir}/fresh"
  printf 'A=1\n' >"$f"
  gi_bash 'DRY_RUN=no; write_block "$1" "t" <<< "x"' "$f"
  [ "$status" -eq 0 ]
  grep -q '^A=1$' "$f"
  grep -qxF '# >>> gentoo-install: t >>>' "$f"
  grep -qxF '# <<< gentoo-install: t <<<' "$f"
}
