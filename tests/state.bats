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

# --------------------------------------------------------------------------- #
#  A dry run remembers what it would have written                             #
# --------------------------------------------------------------------------- #
# The journal is how one step tells the next what it did. With a dry run
# writing nothing and reading nothing, step 30 stopped at "No device to
# encrypt" — a message about the operator's disk, printed because of the
# operator's --dry-run — and steps 70, 75, 80 and 95 fell over behind it. The
# plan they asked to see ended in five failures none of which would happen.

@test "a dry run reads back what it said it would record" {
  gi_bash '
    DRY_RUN=yes
    STATE_DIR="$1"; STATE_FILE="${1}/state"
    state_set disk.crypt_device /dev/vda2
    state_get disk.crypt_device
  ' "$(gi_tmp)"
  [ "$status" -eq 0 ]
  [ "$output" = "/dev/vda2" ]
}

@test "a dry run writes nothing to the journal file" {
  local dir
  dir="$(gi_tmp)/dryjournal"
  mkdir -p "$dir"
  gi_bash '
    DRY_RUN=yes
    STATE_DIR="$1"; STATE_FILE="${1}/state"
    state_set disk.crypt_device /dev/vda2
  ' "$dir"
  [ "$status" -eq 0 ]
  [ ! -e "${dir}/state" ]
}

@test "a dry run over a real journal still reads the real values" {
  # --resume --dry-run has to show what the last real run left behind, not an
  # empty world.
  local dir
  dir="$(gi_tmp)/mixed"
  mkdir -p "$dir"
  printf 'disk.root_device=/dev/vg0/root\n' >"${dir}/state"
  gi_bash '
    DRY_RUN=yes
    STATE_DIR="$1"; STATE_FILE="${1}/state"
    state_set disk.crypt_device /dev/vda2
    printf "%s %s\n" "$(state_get disk.root_device)" "$(state_get disk.crypt_device)"
  ' "$dir"
  [ "$status" -eq 0 ]
  [ "$output" = "/dev/vg0/root /dev/vda2" ]
}

@test "a symlink where the journal belongs stops the run, and is not followed" {
  # The journal is created as root at a path --state-dir chose, and `: >` on a
  # symlink follows it. Proved on a dangling one: the file appeared at the
  # other end. _core_plain_file two lines down already refused to chmod a
  # symlink — it just did not refuse to create through one.
  local dir
  dir="$(gi_tmp)/sj"
  mkdir -p "${dir}/d"
  ln -sfn "${dir}/elsewhere" "${dir}/d/state"

  gi_bash 'DRY_RUN=no; state_init "$1/d"' "$dir"
  [ "$status" -ne 0 ]
  [[ "$stderr" == *"not a regular file"* ]]
  [[ "$stderr" == *"--state-dir"* ]]
  [ ! -e "${dir}/elsewhere" ]
}

@test "a symlink onto a real file leaves that file alone" {
  local dir
  dir="$(gi_tmp)/sj2"
  mkdir -p "${dir}/d"
  printf 'something that matters\n' >"${dir}/victim"
  ln -sfn "${dir}/victim" "${dir}/d/state"

  gi_bash 'DRY_RUN=no; state_init "$1/d"' "$dir"
  [ "$status" -ne 0 ]
  [ "$(cat "${dir}/victim")" = "something that matters" ]
}

@test "a directory where the journal belongs is refused too" {
  local dir
  dir="$(gi_tmp)/sj3"
  mkdir -p "${dir}/d/state"
  gi_bash 'DRY_RUN=no; state_init "$1/d"' "$dir"
  [ "$status" -ne 0 ]
  [[ "$stderr" == *"not a regular file"* ]]
}

@test "an ordinary journal is created and read back" {
  local dir
  dir="$(gi_tmp)/sj4"
  mkdir -p "${dir}/d"
  gi_bash 'DRY_RUN=no; state_init "$1/d"; state_set step.20 "done now"; state_get step.20' "$dir"
  [ "$status" -eq 0 ]
  [ "$output" = "done now" ]
  [ -f "${dir}/d/state" ]
  [ ! -L "${dir}/d/state" ]
}

# --------------------------------------------------------------------------- #
#  The to-do list belongs to the run that wrote it                            #
# --------------------------------------------------------------------------- #
# Step 90 records what an operator still has to do by hand, numbered from 1,
# and step 95 reads them back on the closing screen — which is the point: a
# --resume never saw the warnings as they went by. The numbering restarts at 1
# on every run, so the entries of the previous run had to be forgotten first.

@test "a rerun does not leave behind the to-dos it has just fixed" {
  run --separate-stderr bash -c 'source "$GI_ENTRY"
    d="${BATS_TEST_TMPDIR}/todo"; rm -rf -- "$d"; mkdir -p -- "$d"
    CFG[state_dir]="$d"; STATE_DIR="$d"; DRY_RUN=no
    state_init >/dev/null 2>&1

    _SYS_TODO_N=0
    _sys_todo "set the root password" >/dev/null 2>&1
    _sys_todo "create an account"     >/dev/null 2>&1
    _sys_todo "install an ssh key"    >/dev/null 2>&1

    # The operator fixes two of them and runs --steps 90 again.
    _SYS_TODO_N=0
    _sys_forget_todo
    _sys_todo "install an ssh key" >/dev/null 2>&1

    state_dump | grep "^system\.todo\."
  '
  [ "$status" -eq 0 ]
  [ "$output" = "system.todo.1=install an ssh key" ] || {
    printf 'the journal must hold the one thing that is left, and nothing else:\n%s\n' \
      "$output" >&2
    printf 'without the forget, .2 kept a finished item and .3 repeated .1.\n' >&2
    return 1
  }
}

@test "step 90 forgets the last run's to-dos before it records its own" {
  # Read out of the sourced shell, so a renamed or deleted function fails here
  # rather than matching a stale line in the file.
  gi_bash '
    body="$(declare -f step_90_system)"
    [[ "$body" == *_sys_forget_todo* ]] || { echo "no _sys_forget_todo"; exit 1; }
  '
  [ "$status" -eq 0 ] || {
    printf 'the numbering restarts at 1 every run; the old entries have to go\n' >&2
    printf 'first, or step 95 lists work that is already done: %s\n' "$output" >&2
    return 1
  }
}
