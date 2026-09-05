#!/usr/bin/env bats
#
# gentoo-install — the resume journal and the precedence of target_fact
# ----------------------------------------------------------------------------
# A Gentoo install compiles a kernel, so an interruption three hours in must not
# start over. What --resume then reads has to be believed over the plan: the
# machine is the fact, the configuration is only an intention. Everything here
# writes inside $BATS_TMPDIR and nowhere else.
#

bats_require_minimum_version 1.5.0

load helper

# --------------------------------------------------------------------------- #
#  target_fact: explicit  >  journal  >  declared default  >  fallback         #
# --------------------------------------------------------------------------- #
@test "a default must lose to the state journal, or --resume answers about a machine that does not exist" {
  # config_init_defaults gives crypt the non-empty default luks-passphrase. If
  # that beat the journal, a --resume run with no configuration file would
  # answer "luks-passphrase" about a disk step 30 encrypted with a TPM key three
  # hours ago, and every later check would verify an install that is not there.
  gi_bash '
    config_init_defaults
    state_attach "$1"; state_init "$1"
    state_set crypt luks-tpm
    target_fact crypt crypt none
  ' "$(gi_tmp)/journal"

  [ "$status" -eq 0 ]
  [ "$output" = "luks-tpm" ]
}

@test "an explicit setting must beat the state journal, because that is the operator talking" {
  gi_bash '
    config_init_defaults
    state_attach "$1"; state_init "$1"
    state_set crypt luks-tpm
    set_explicit crypt luks-keyfile-gpg
    target_fact crypt crypt none
  ' "$(gi_tmp)/journal"

  [ "$status" -eq 0 ]
  [ "$output" = "luks-keyfile-gpg" ]
}

@test "the declared default is used only once the journal has been asked and has nothing" {
  gi_bash '
    config_init_defaults
    state_attach "$1"; state_init "$1"
    target_fact crypt crypt none
  ' "$(gi_tmp)/journal"

  [ "$status" -eq 0 ]
  [ "$output" = "luks-passphrase" ]
}

@test "the fallback is reached last, when neither the journal nor a default has anything" {
  # crypt_keyfile is declared with an empty default on purpose, exactly so that
  # target_fact falls through to the journal and then to the caller's fallback.
  gi_bash '
    config_init_defaults
    state_attach "$1"; state_init "$1"
    target_fact crypt_keyfile crypt.keyfile cryptroot
  ' "$(gi_tmp)/journal"

  [ "$status" -eq 0 ]
  [ "$output" = "cryptroot" ]
}

@test "target_fact must put its answer on stdout and nothing else with it" {
  # It is read through $( ). A stray diagnostic on stdout would become part of
  # the device name, the volume group or the kernel command line.
  gi_bash '
    config_init_defaults
    state_attach "$1"; state_init "$1"
    state_set crypt luks-tpm
    target_fact crypt crypt none
  ' "$(gi_tmp)/journal"

  [ "$status" -eq 0 ]
  [ "$stderr" = "" ]
}

# --------------------------------------------------------------------------- #
#  The journal itself                                                         #
# --------------------------------------------------------------------------- #
@test "the journal records what was done and must refuse to record with what" {
  # DESIGN.md §9. state_set checks the key itself rather than trusting every
  # caller to remember, so one forgetful call site cannot leak a passphrase into
  # a file that outlives the install.
  local key
  for key in crypt_passphrase root_password luks_key api_token client_secret; do
    gi_bash '
      state_attach "$1"; state_init "$1"
      state_set "$2" nevermind
    ' "$(gi_tmp)/journal" "$key"

    [ "$status" -ne 0 ] || {
      printf 'state_set accepted the secret-looking key %s\n' "$key" >&2
      return 1
    }
    [[ "$stderr" == *"never with what"* ]]
  done
}

@test "a step the journal marks done must be reported done, so --resume can skip it" {
  local dir
  dir="$(gi_tmp)/resume"
  mkdir -p -- "$dir"
  printf 'step.10=done 2026-01-01T00:00:00Z\n' >"${dir}/state"

  run --separate-stderr "$GI_ENTRY" \
    --log-file "$(gi_tmp)/install.log" --state-dir "$dir" \
    --resume --steps 10 --json
  [ "$status" -eq 0 ]
  [[ "$output" == *'"number": 10'* ]]
  [[ "$output" == *'"done": true'* ]]
}

@test "--resume and --restart contradict each other and must be refused, not silently ranked" {
  gi_run --resume --restart --dry-run
  [ "$status" -eq 2 ]
  [[ "$stderr" == *"contradict"* ]]
}
