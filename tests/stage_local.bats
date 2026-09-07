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

@test "the wget fallback tells a 404 from a 503 and from a broken network" {
  # wget's exit status separates them — 8 is "the server answered with an
  # error", 4 is a network failure — and the code inside that answer decides.
  # This used to grep wget's words for "404 ", which --quiet had silenced and
  # which a French locale writes with a non-breaking space; every 404 on a
  # wget-only machine came out transient and was retried, and the message
  # naming --arch, --init and --flavour was never printed.
  local case_ verdict
  # The two halves of the defect, and the cases that must keep working.
  # An empty message is what --quiet produced: the classification had nothing
  # to read and every 404 became transient. The second case carries the
  # non-breaking space a French wget puts after the number, which the pattern
  # looking for "404 " could not have matched even unsilenced.
  for case_ in "8||permanent" \
    "8|erreur 404\u00a0: Not Found|permanent" \
    "8|erreur 503 : SERVICE UNAVAILABLE|transient" \
    "4|unable to resolve host address|transient" \
    "0||ok"; do
    run --separate-stderr bash -c '
      source "$GI_ENTRY"
      config_init_defaults >/dev/null 2>&1
      DRY_RUN=no
      WGET_RC="$1"; WGET_MSG="$2"
      have() { [[ "$1" == "wget" ]]; }
      wget() { [[ -n "$WGET_MSG" ]] && printf "%s\n" "$WGET_MSG" >&2; return "$WGET_RC"; }
      rc=0; _stage_http_get url /dev/null no >/dev/null 2>&1 || rc=$?
      case $rc in
        0) printf "ok\n" ;;
        1) printf "transient\n" ;;
        2) printf "permanent\n" ;;
        3) printf "range\n" ;;
      esac' bash "${case_%%|*}" "$(printf '%b' "$(printf '%s' "$case_" | cut -d'|' -f2)")"
    verdict="${case_##*|}"
    [ "$output" = "$verdict" ] || {
      printf 'wget exit %s said %s, expected %s\n' "${case_%%|*}" "$output" "$verdict" >&2
      return 1
    }
  done
}

@test "the wget fallback asks for the line that carries the code" {
  # --quiet silences the very evidence the classification depends on.
  local body
  body="$(sed -n '/^_stage_http_get/,/^}/p' "${GI_ROOT}/lib/stage.sh")"
  [[ "$body" == *"wget --no-verbose"* ]]
  [[ "$body" != *"wget --quiet"* ]]
}

# --------------------------------------------------------------------------- #
#  What checked it, kept                                                      #
# --------------------------------------------------------------------------- #
# The catalogue path journals stage.verified and step 95 prints it back on the
# closing screen. This path said "nothing verified this archive" once, hours
# earlier, and then had nothing to show — so the recap of a --stage-file
# install was silent about the archive it had installed and silent about what,
# if anything, had checked it. A --resume never saw the warning at all.

@test "an archive nobody checked is recorded as checked by nothing" {
  gi_bash '
    tmp="${BATS_TEST_TMPDIR}/a.tar"; : >"$tmp"
    CFG[stage_signature]=""; CFG[stage_checksum]=""
    stage_local_verify "$tmp" >/dev/null 2>&1
    printf "%s\n" "$STAGE_LOCAL_VERIFIED"
  '
  [ "$status" -eq 0 ]
  [ "$output" = "nothing" ]
}

@test "a checksum that matches is recorded as the sha256 it was" {
  gi_bash '
    tmp="${BATS_TEST_TMPDIR}/a.tar"; printf "payload" >"$tmp"
    CFG[stage_signature]=""
    CFG[stage_checksum]="$(sha256sum -- "$tmp" | cut -d" " -f1)"
    stage_local_verify "$tmp" >/dev/null 2>&1 || { echo "verify refused"; exit 1; }
    printf "%s\n" "$STAGE_LOCAL_VERIFIED"
  '
  [ "$status" -eq 0 ]
  [ "$output" = "sha256" ]
}

@test "a signature and a checksum are both recorded, in one value" {
  # stage_verify_detached is stubbed because this test is about the record, not
  # about gpg; the signature path itself is exercised by the catalogue suite.
  gi_bash '
    tmp="${BATS_TEST_TMPDIR}/a.tar"; printf "payload" >"$tmp"
    printf "sig" >"${tmp}.asc"
    CFG[stage_signature]=""
    CFG[stage_checksum]="$(sha256sum -- "$tmp" | cut -d" " -f1)"
    stage_verify_detached() { return 0; }
    stage_local_verify "$tmp" >/dev/null 2>&1 || { echo "verify refused"; exit 1; }
    printf "%s\n" "$STAGE_LOCAL_VERIFIED"
  '
  [ "$status" -eq 0 ]
  [ "$output" = "pgp-signature+sha256" ]
}

@test "the local path journals what checked the archive, like the catalogue one" {
  run --separate-stderr bash -c 'source "$GI_ENTRY"
    config_init_defaults
    dir="${BATS_TEST_TMPDIR}/j"; rm -rf -- "$dir"; mkdir -p -- "$dir"
    CFG[state_dir]="$dir"; STATE_DIR="$dir"; DRY_RUN="no"
    state_init >/dev/null 2>&1
    CFG[stage_file]="${BATS_TEST_TMPDIR}/mine.tar.xz"; : >"${CFG[stage_file]}"
    stage_local_check_file() { return 0; }
    stage_local_verify()     { STAGE_LOCAL_VERIFIED="nothing"; return 0; }
    stage_unpack()           { return 0; }
    stage_show_result()      { return 0; }
    _step_40_local /mnt/gentoo file >/dev/null
    printf "verified=%s\n" "$(state_get stage.verified)"
    printf "tarball=%s\n"  "$(state_get stage.tarball)"
  '
  [ "$status" -eq 0 ]
  [[ "$output" == *"verified=nothing"* ]] || {
    printf 'the recap has to be able to say that nothing checked it: %s\n' "$output" >&2
    return 1
  }
  [[ "$output" == *"tarball=mine.tar.xz"* ]]
}
