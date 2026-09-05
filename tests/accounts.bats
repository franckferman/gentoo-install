#!/usr/bin/env bats
#
# gentoo-install — accounts, groups, per-account privilege and the root lock
# ----------------------------------------------------------------------------
# The record format is checked the way lib/disk.sh checks disk_volumes: every
# field, before anything is created, because useradd refuses a whole account
# over one unknown group and a half-applied account list is worse than a
# refused one.
#
# The last group of tests is the reason this file exists. Locking root without
# another account that both escalates and can log in gives a machine nobody can
# administer, recoverable only from a LiveUSB. That refusal is a proof, not a
# confirmation, so --force does not lift it (DESIGN.md §12).
#
# Nothing here chroots, creates an account or touches a group: every check
# reads a throwaway /etc built under $BATS_TEST_TMPDIR.
#

bats_require_minimum_version 1.5.0

load helper

gi_target_tree() {
  # A tree that looks enough like a fresh stage3 for a record to be checked
  # against it: the groups a stage3 ships, root and nothing else in passwd, and
  # the three shells a record is likely to name. A returned value.
  local dir
  dir="$(gi_tmp)/target"
  mkdir -p "${dir}/etc" "${dir}/bin" "${dir}/sbin" "${dir}/home"
  printf 'root:x:0:0:root:/root:/bin/bash\n' >"${dir}/etc/passwd"
  printf 'root:x:0:\nwheel:x:10:\naudio:x:18:\nvideo:x:27:\nusb:x:85:\nusers:x:100:\nportage:x:250:\n' \
    >"${dir}/etc/group"
  printf 'root:*:19000:0:99999:7:::\n' >"${dir}/etc/shadow"
  : >"${dir}/bin/bash"
  : >"${dir}/bin/sh"
  : >"${dir}/sbin/nologin"
  printf '%s\n' "$dir"
}

gi_parse() {
  # Parse a record set against a tree and print one "name|groups|shell|priv"
  # line per account. Args: $1 = tree, $2 = accounts, $3 = groups (optional).
  gi_bash '
    config_init_defaults
    CFG[chroot_dir]="$1"
    CFG[accounts]="$2"
    CFG[groups]="${3:-}"
    _sys_accounts_load "$1" || exit 1
    for ((i = 0; i < ${#_SYS_ACC_NAME[@]}; i++)); do
      printf "%s|%s|%s|%s\n" "${_SYS_ACC_NAME[i]}" "${_SYS_ACC_GROUPS[i]}" \
        "${_SYS_ACC_SHELL[i]}" "${_SYS_ACC_PRIV[i]}"
    done
  ' "$@"
}

# --------------------------------------------------------------------------- #
#  The record format                                                          #
# --------------------------------------------------------------------------- #
@test "a full record keeps every field it was given" {
  local tree
  tree="$(gi_target_tree)"
  gi_parse "$tree" "alice:wheel,audio,video:/bin/bash:sudo"
  [ "$status" -eq 0 ]
  [ "$output" = "alice|wheel,audio,video|/bin/bash|sudo" ]
}

@test "an empty field takes the default, and a missing one does too" {
  # 'bob::/bin/sh:none' leaves the groups empty; 'carol' leaves everything but
  # the name away. Both must land on the single-account settings, which is what
  # makes the short form worth writing.
  local tree
  tree="$(gi_target_tree)"
  gi_parse "$tree" "bob::/bin/sh:none;carol"
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | sed -n 1p)" = "bob|wheel,audio,video,usb,portage|/bin/sh|none" ]
  [ "$(printf '%s\n' "$output" | sed -n 2p)" = "carol|wheel,audio,video,usb,portage|/bin/bash|sudo" ]
}

@test "the defaults an empty field takes come from the single-account settings" {
  local tree
  tree="$(gi_target_tree)"
  gi_bash '
    config_init_defaults
    CFG[chroot_dir]="$1"
    CFG[user_groups]="users"
    CFG[user_shell]="/bin/sh"
    CFG[privilege]="doas"
    CFG[accounts]="dave"
    _sys_accounts_load "$1" || exit 1
    printf "%s|%s|%s\n" "${_SYS_ACC_GROUPS[0]}" "${_SYS_ACC_SHELL[0]}" "${_SYS_ACC_PRIV[0]}"
  ' "$tree"
  [ "$status" -eq 0 ]
  [ "$output" = "users|/bin/sh|doas" ]
}

@test "the last group of a list must survive the split" {
  # The list is split on ',' with no trailing newline, so a plain `while read`
  # drops the last item: portage was silently missing from every account this
  # step created. One character of the default list is the whole regression.
  local tree
  tree="$(gi_target_tree)"
  gi_parse "$tree" "alice:wheel,audio,video,usb,portage::"
  [ "$status" -eq 0 ]
  [[ "$output" == "alice|wheel,audio,video,usb,portage|"* ]]
}

@test "a record with a fifth field must be refused, not silently truncated" {
  local tree
  tree="$(gi_target_tree)"
  gi_parse "$tree" "alice:wheel:/bin/bash:sudo:extra"
  [ "$status" -eq 1 ]
  [ "$output" = "" ]
  [[ "$stderr" == *"Malformed account record"* ]]
  [[ "$stderr" == *"name:groups:shell:privilege"* ]]
  [[ "$stderr" == *"example:"* ]]
}

@test "an invalid account name must be refused with the rule it broke" {
  local tree
  tree="$(gi_target_tree)"
  gi_parse "$tree" "9lives:wheel:/bin/bash:sudo"
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"Invalid account name: 9lives"* ]]
  [[ "$stderr" == *"example:"* ]]
}

@test "the same account declared twice must be refused rather than half applied" {
  local tree
  tree="$(gi_target_tree)"
  gi_parse "$tree" "alice:wheel::;alice:audio::"
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"declared twice"* ]]
}

@test "an unknown privilege must be refused, and the message must list the five" {
  local tree
  tree="$(gi_target_tree)"
  gi_parse "$tree" "alice:wheel:/bin/bash:sudo-nopassword"
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"Unknown privilege"* ]]
  [[ "$stderr" == *"sudo-nopasswd"* ]]
  [[ "$stderr" == *"doas-nopasswd"* ]]
  [[ "$stderr" == *"none"* ]]
  [[ "$stderr" == *"example:"* ]]
}

@test "a shell absent from the target must be refused before useradd sees it" {
  local tree
  tree="$(gi_target_tree)"
  gi_parse "$tree" "alice:wheel:/usr/bin/zsh:sudo"
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"No such shell in the target: /usr/bin/zsh"* ]]
  [[ "$stderr" == *"/bin/bash"* ]]
}

@test "a group that exists nowhere and is not created must be refused" {
  # useradd refuses the whole account over one unknown group. Catching it here
  # costs a grep; catching it there costs a half-configured machine.
  local tree
  tree="$(gi_target_tree)"
  gi_parse "$tree" "alice:wheel,plugdev:/bin/bash:sudo"
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"No such group in the target: plugdev"* ]]
  [[ "$stderr" == *'groups = "plugdev"'* ]]
}

@test "a group this run is about to create counts as existing" {
  local tree
  tree="$(gi_target_tree)"
  gi_parse "$tree" "alice:wheel,media:/bin/bash:sudo" "media:1500"
  [ "$status" -eq 0 ]
  [ "$output" = "alice|wheel,media|/bin/bash|sudo" ]
}

@test "a malformed group record must be refused with the two shapes it accepts" {
  local tree
  tree="$(gi_target_tree)"
  gi_parse "$tree" "alice:wheel::" "media:1500:extra"
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"Malformed group record"* ]]
  [[ "$stderr" == *"name:gid"* ]]
}

# --------------------------------------------------------------------------- #
#  Precedence: accounts against the single-account settings                   #
# --------------------------------------------------------------------------- #
@test "accounts wins over user, and the run says so instead of merging" {
  # Merging two lists of accounts silently is how a machine ends up with a
  # login nobody wrote down.
  local tree
  tree="$(gi_target_tree)"
  gi_bash '
    config_init_defaults
    CFG[chroot_dir]="$1"
    CFG[accounts]="alice:wheel:/bin/bash:sudo"
    CFG[user]="frank"
    _sys_accounts_load "$1" || exit 1
    printf "%s\n" "${_SYS_ACC_NAME[@]}"
  ' "$tree"
  [ "$status" -eq 0 ]
  [ "$output" = "alice" ]
  [[ "$stderr" == *"'accounts' wins and 'user' is ignored"* ]]
  [[ "$stderr" == *"frank is not created"* ]]
}

@test "user alone still describes one account, exactly as it used to" {
  local tree
  tree="$(gi_target_tree)"
  gi_bash '
    config_init_defaults
    CFG[chroot_dir]="$1"
    CFG[user]="frank"
    CFG[user_groups]="wheel,audio"
    CFG[user_shell]="/bin/sh"
    CFG[privilege]="sudo"
    _sys_accounts_load "$1" || exit 1
    printf "%s|%s|%s|%s\n" "${_SYS_ACC_NAME[0]}" "${_SYS_ACC_GROUPS[0]}" \
      "${_SYS_ACC_SHELL[0]}" "${_SYS_ACC_PRIV[0]}"
  ' "$tree"
  [ "$status" -eq 0 ]
  [ "$output" = "frank|wheel,audio|/bin/sh|sudo" ]
  [[ "$stderr" != *"wins"* ]]
}

# --------------------------------------------------------------------------- #
#  root_lock — a proof, and --force does not lift it (DESIGN.md §12)          #
# --------------------------------------------------------------------------- #
gi_root_lock() {
  # Args: $1 = tree, $2 = accounts, $3.. = extra "key=value" settings.
  gi_bash '
    config_init_defaults
    CFG[chroot_dir]="$1"
    CFG[accounts]="$2"
    CFG[root_lock]="yes"
    shift 2
    for kv in "$@"; do CFG["${kv%%=*}"]="${kv#*=}"; done
    config_export_runtime
    _sys_root_lock "$(cfg chroot_dir)"
  ' "$@"
}

@test "root_lock = yes must be refused when no account escalates" {
  local tree
  tree="$(gi_target_tree)"
  gi_root_lock "$tree" "dave:users:/bin/sh:none"
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"Refusing root_lock = yes"* ]]
  [[ "$stderr" == *"no account has a privilege other than 'none'"* ]]
  [[ "$stderr" == *"LiveUSB"* ]]
  [[ "$stderr" == *"root_lock = no"* ]] # the way out is named
}

@test "root_lock = yes must be refused under --force too: it lifts confirmations, never proofs" {
  local tree
  tree="$(gi_target_tree)"
  gi_root_lock "$tree" "dave:users:/bin/sh:none" "force=yes" "assume_yes=yes"
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"Refusing root_lock = yes"* ]]
  [[ "$stderr" == *"--force does not lift this"* ]]
}

@test "root_lock = yes must be refused when the account that escalates cannot log in" {
  # sudo on an account with no password and no key is not a way in: it is a
  # locked root with a locked door in front of it.
  local tree
  tree="$(gi_target_tree)"
  printf 'dave:!:19000:0:99999:7:::\n' >>"${tree}/etc/shadow"
  gi_root_lock "$tree" "dave:wheel:/bin/bash:sudo"
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"Refusing root_lock = yes"* ]]
  [[ "$stderr" == *"dave can become root, and cannot log in"* ]]
  [[ "$stderr" == *"passwd dave"* ]]
}

@test "root_lock = yes must be allowed once an account escalates and has a password" {
  local tree
  tree="$(gi_target_tree)"
  printf 'dave:$y$j9T$notarealhash:19000:0:99999:7:::\n' >>"${tree}/etc/shadow"
  gi_root_lock "$tree" "dave:wheel:/bin/bash:sudo"
  [ "$status" -eq 0 ]
  [[ "$stderr" != *"Refusing root_lock"* ]]
  # The tree carries no passwd(1), so the lock is left as a to-do rather than
  # run; what this test pins is that the proof was accepted.
  [[ "$stderr" == *"passwd is not in the target tree"* ]]
}

@test "root_lock = yes must be allowed on an ssh key when there is no password" {
  local tree
  tree="$(gi_target_tree)"
  mkdir -p "${tree}/home/dave/.ssh"
  printf 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5 dave@example\n' \
    >"${tree}/home/dave/.ssh/authorized_keys"
  gi_root_lock "$tree" "dave:wheel:/bin/bash:doas"
  [ "$status" -eq 0 ]
  [[ "$stderr" != *"Refusing root_lock"* ]]
}

@test "root_lock = no leaves root alone and says so" {
  local tree
  tree="$(gi_target_tree)"
  gi_bash '
    config_init_defaults
    CFG[chroot_dir]="$1"
    CFG[accounts]="dave:users:/bin/sh:none"
    _sys_root_lock "$1"
  ' "$tree"
  [ "$status" -eq 0 ]
  [[ "$stderr" == *"root_lock = no"* ]]
}

# --------------------------------------------------------------------------- #
#  The journal records what was done, never with what (DESIGN.md §9)          #
# --------------------------------------------------------------------------- #
@test "no key step 90 journals may look like a secret" {
  # _state_check_key kills the run on a key holding password, passphrase,
  # secret, _key or _token. A step that journals one is a step that dies in
  # front of an operator, so the keys are checked here instead.
  local key rejected=""
  while IFS= read -r key; do
    case "$key" in
      *password* | *passphrase* | *secret* | *_key | *_token)
        rejected+="  system.${key}"$'\n'
        ;;
    esac
  done < <(grep -oE '_sys_record [a-z_]+' "${GI_ROOT}/steps/90_system.sh" \
    | awk '{ print $2 }' | sort -u)

  [ -z "$rejected" ] || {
    printf 'step 90 journals keys the state journal refuses:\n%s' "$rejected" >&2
    return 1
  }
}
