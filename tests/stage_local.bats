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
