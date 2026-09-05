#!/usr/bin/env bash
#
# gentoo-install — config: the settings table and its precedence rules
# ----------------------------------------------------------------------------
# One associative array holds every setting, one holds the sentinel that says
# "the operator asked for this". set_default() and set_explicit() are written
# once and used for every setting, so the precedence
#
#     built-in default  <  profile  <  configuration file  <  explicit flag
#
# holds for all of them and not just for the handful somebody remembered.
# Values are checked against an enumeration at parse time, in ten milliseconds,
# rather than in the middle of a kernel build.
#
# Nothing here runs at source time.
#
# Usage:  source lib/config.sh   (needs lib/core.sh)
#
set -euo pipefail

if [[ -n "${_GI_CONFIG_LOADED:-}" ]]; then
  return 0
fi
_GI_CONFIG_LOADED=1

# --------------------------------------------------------------------------- #
#  The tables                                                                 #
# --------------------------------------------------------------------------- #
declare -A CFG=()
declare -A _EXPLICIT=()

# --------------------------------------------------------------------------- #
#  Precedence                                                                 #
# --------------------------------------------------------------------------- #
set_default() {
  # Apply a value unless the operator already asked for one.
  local k="$1" v="$2"
  [[ -n "${_EXPLICIT[$k]:-}" ]] || CFG[$k]="$v"
}

set_explicit() {
  # The operator asked. Nothing may override this afterwards.
  local k="$1" v="$2"
  CFG[$k]="$v"
  _EXPLICIT[$k]=1
}

is_explicit() {
  [[ -n "${_EXPLICIT[$1]:-}" ]]
}

target_fact() {
  # Args: $1 = CFG key ("" for none), $2 = state key ("" for none),
  #       $3 = fallback. A returned value, so stdout.
  #
  # The order is: explicit setting, then the state journal, then the built-in
  # default, then the fallback.
  #
  # An explicit value wins because that is the operator talking, and §5 says
  # nothing may override an intention. A *default* loses to the journal, and
  # that ordering is the whole point: config_init_defaults gives crypt, layout,
  # kernel and bootloader non-empty defaults, so a --resume run with no
  # configuration file would otherwise answer "crypt = none" about a machine
  # step 30 encrypted three hours ago. Every later check would then verify a
  # plain install that does not exist. A verifier that trusts the plan over the
  # machine is not a verifier.
  local cfg_key="$1" state_key="${2:-}" fallback="${3:-}" value=""

  if [[ -n "$cfg_key" ]] && is_explicit "$cfg_key"; then
    value="$(cfg "$cfg_key")"
  fi
  if [[ -z "$value" && -n "$state_key" ]]; then
    value="$(state_get "$state_key" 2>/dev/null || true)"
  fi
  if [[ -z "$value" && -n "$cfg_key" ]]; then
    value="$(cfg "$cfg_key")"
  fi
  printf '%s\n' "${value:-$fallback}"
}

cfg() {
  # Read a setting. Prints on stdout because it is a returned value.
  printf '%s\n' "${CFG[$1]:-}"
}

cfg_is() {
  [[ "${CFG[$1]:-}" == "$2" ]]
}

cfg_yes() {
  [[ "${CFG[$1]:-no}" == "yes" ]]
}

cfg_known() {
  [[ -n "${CFG[$1]+set}" ]]
}

cfg_keys() {
  printf '%s\n' "${!CFG[@]}" | sort
}

# --------------------------------------------------------------------------- #
#  Secrets                                                                    #
# --------------------------------------------------------------------------- #
_is_secret_key() {
  # Anything matching this never reaches the log, the state journal, --json or
  # --dump-config. Kept as one predicate so all four honour the same list.
  case "$1" in
    *password* | *passphrase* | *secret* | *_key | *_token) return 0 ;;
    *) return 1 ;;
  esac
}

cfg_display() {
  # A setting's value, masked when it is a secret. For rendering only.
  local k="$1"
  if _is_secret_key "$k" && [[ -n "${CFG[$k]:-}" ]]; then
    printf '%s\n' "<redacted>"
  else
    printf '%s\n' "${CFG[$k]:-}"
  fi
}

# --------------------------------------------------------------------------- #
#  Validation — stage 1 of 3 (DESIGN.md §5): the value must be spellable       #
# --------------------------------------------------------------------------- #
validate_enum() {
  # Die in the project's error voice unless <value> is one of the listed ones.
  # Args: $1 = what it is, $2 = value, $3 = the flag that sets it,
  #       $4.. = "value:one line saying what it means".
  # Stage 2 (is it available on this machine?) belongs to pre-flight, stage 3
  # (did it disappear since?) to the step that uses it.
  local what="$1" value="$2" flag="$3"
  shift 3
  local entry name width=0 first=""
  local -a lines=()

  for entry in "$@"; do
    name="${entry%%:*}"
    if [[ -z "$first" ]]; then
      first="$name"
    fi
    if ((${#name} > width)); then
      width=${#name}
    fi
    if [[ "$value" == "$name" ]]; then
      return 0
    fi
  done

  for entry in "$@"; do
    name="${entry%%:*}"
    lines+=("$(printf '%-*s  %s' "$width" "$name" "${entry#*:}")")
  done
  lines+=("example:  ${flag} ${first}")

  die_usage "Unknown ${what}: ${value}" "${lines[@]}"
}

validate_list() {
  # Same voice, for an enumeration whose members come from a data file and so
  # carry no hand-written description.
  # Args: $1 = what it is, $2 = value, $3 = flag, $4.. = valid values.
  local what="$1" value="$2" flag="$3"
  shift 3
  local candidate
  for candidate in "$@"; do
    if [[ "$value" == "$candidate" ]]; then
      return 0
    fi
  done
  die_usage "Unknown ${what}: ${value}" \
    "valid values: $*" \
    "example:  ${flag} ${1}"
}

# --------------------------------------------------------------------------- #
#  Built-in defaults                                                          #
# --------------------------------------------------------------------------- #
# --------------------------------------------------------------------------- #
#  Enumerations                                                               #
# --------------------------------------------------------------------------- #
# A value that is not one of these is refused at parse time, in the project's
# error voice, before anything is touched (DESIGN.md §5). parse_args validates
# the few flags it owns as it reads them; this table exists because a value out
# of a configuration file went through no check at all, so `bootloader =
# frobnicate` was accepted and only failed two hours later, inside step 80.
#
# disk_swap is deliberately absent: it takes auto, none, or a size, so it has no
# closed set to check against.
declare -A CFG_ENUM=(
  [assume_yes]="yes|no"
  [bootloader]="grub|efistub|systemd-boot"
  [color]="auto|never"
  [crypt]="none|luks-passphrase|luks-tpm|luks-keyfile-gpg"
  [crypt_pbkdf]="argon2id|argon2i|pbkdf2"
  [crypt_recovery]="yes|no"
  [crypt_wipe_luks]="ask|yes|no"
  [disk_filesystem]="ext4|xfs|btrfs|f2fs"
  [disk_erase]="quick|luks|discard|zero"
  [disk_layout]="minimal|server|desktop|custom"
  [disk_lvm]="auto|yes|no"
  [dry_run]="yes|no"
  [force]="yes|no"
  [init]="openrc|systemd"
  [initramfs]="dracut|genkernel"
  [json]="yes|no"
  [kernel]="dist-kernel|genkernel|manual"
  [non_interactive]="yes|no"
  [on_conflict]="overwrite|skip|prompt|backup"
  [portage_sync]="webrsync|rsync|none"
  [privilege]="sudo|sudo-nopasswd|doas|doas-nopasswd|none"
  [reboot]="ask|yes|no"
  [restart]="yes|no"
  [resume]="yes|no"
  [root_lock]="yes|no"
  [wipe_disk]="ask|yes|no"
  [wipe_foreign]="ask|yes|no"
)

config_validate_enums() {
  # Called once, after every source has been merged: defaults, then the
  # configuration file, then the flags, then the profile. Checking earlier would
  # judge a value the operator was still in the middle of setting.
  local key allowed value bad=0
  for key in "${!CFG_ENUM[@]}"; do
    value="${CFG[$key]:-}"
    [[ -n "$value" ]] || continue
    allowed="|${CFG_ENUM[$key]}|"
    if [[ "$allowed" != *"|${value}|"* ]]; then
      err "Invalid value for ${key}: ${value}"
      err "       one of: ${CFG_ENUM[$key]//|/, }"
      err "       example:  ${key} = ${CFG_ENUM[$key]%%|*}"
      bad=$((bad + 1))
    fi
  done
  ((bad == 0)) || return 1
  return 0
}

config_init_defaults() {
  # Every setting the project knows about is declared here and nowhere else:
  # the configuration-file loader rejects any key that is not in this list, so
  # a typo in a .conf is caught before anything is touched.
  #
  # Safe by default: the careful operator's choice.
  # Conservative by default: off, and the comment names what turning it on
  # would break.

  # Behaviour
  set_default dry_run "no"         # yes|no
  set_default assume_yes "no"      # yes|no
  set_default force "no"           # yes|no — lifts confirmations, never proofs
  set_default non_interactive "no" # yes|no
  set_default resume "no"          # yes|no
  set_default restart "no"         # yes|no
  set_default json "no"            # yes|no
  set_default color "auto"         # auto|never
  set_default on_conflict "backup" # overwrite|skip|prompt|backup

  # Paths
  set_default log_file "/var/log/gentoo-install.log"
  set_default state_dir "/var/lib/gentoo-install"

  # Target system
  set_default profile "default" # meta-profile, see apply_profile()
  set_default arch "amd64"
  set_default init "openrc"        # openrc|systemd
  set_default flavour "base"       # a flavour column of data/stages.tsv
  set_default libc "glibc"         # derived from the stage row, not a flag
  set_default stage_variant ""     # derived from the stage row, not a flag
  set_default stage_constraints "" # derived from the stage row, not a flag
  set_default mirror "https://distfiles.gentoo.org"
  set_default verify_signatures "yes" # no: a compromised mirror picks your stage

  # Anything whose wrong answer destroys something defaults to ask.
  set_default wipe_disk "ask"    # ask|yes|no
  set_default wipe_foreign "ask" # ask|yes|no
  set_default reboot "ask"       # ask|yes|no

  # ------------------------------------------------------------------------- #
  # Settings the steps and variants read through target_fact.
  #
  # An empty default is deliberate: target_fact falls through to the state
  # journal and then to its own fallback, so declaring the key here only makes
  # it settable and changes no behaviour. A non-empty default is a real choice,
  # and it settles the four keys whose call sites disagreed with each other.
  # ------------------------------------------------------------------------- #
  # Disk and layout
  set_default root_fstype ""
  set_default vg_name ""
  set_default root_lv ""
  set_default esp_mount ""
  set_default esp_device ""
  set_default esp_uuid ""
  set_default root_device ""
  set_default root_uuid ""
  set_default boot_device ""
  set_default boot_disk ""
  set_default chroot_dir ""
  set_default target_root ""
  set_default firmware ""
  # Encryption
  set_default crypt_keyfile ""
  set_default crypt_keyfile_uuid ""
  set_default luks_uuid ""
  # Kernel and initramfs
  set_default kernel "dist-kernel" # dist-kernel|genkernel|manual
  set_default kernel_build ""
  set_default kernel_sources ""
  set_default kernel_source_dir ""
  set_default kernel_config ""
  set_default kernel_version ""
  set_default kernel_menuconfig ""
  set_default kernel_firmware ""
  set_default kernel_embed_cmdline ""
  set_default kernel_cmdline_extra ""
  set_default initramfs ""
  set_default dracut_modules_extra ""
  # Bootloader
  set_default bootloader "grub" # grub|efistub|systemd-boot
  set_default boot_label ""
  set_default boot_timeout ""
  set_default boot_removable ""
  set_default efistub_cmdline ""
  set_default secureboot_cert ""
  set_default secureboot_keyfile ""
  # System
  set_default hostname ""
  set_default timezone ""
  set_default locale ""
  set_default keymap ""

  # Accounts. `accounts` is the declarative form and it takes precedence; the
  # three single-account settings below it are the shorthand for one account and
  # supply the defaults an empty field in a record takes.
  #
  #   accounts = "alice:wheel,audio:/bin/bash:sudo;svc:docker:/bin/sh:none"
  set_default accounts ""      # "name:groups:shell:privilege;..."
  set_default accounts_file "" # a file of the same records, one per line
  set_default groups ""        # "name;name:gid;..." — created before the accounts
  set_default user ""
  set_default user_shell ""  # empty: /bin/bash
  set_default user_groups "" # empty: wheel,audio,video,usb,portage
  set_default privilege ""   # sudo|sudo-nopasswd|doas|doas-nopasswd|none

  # Conservative by default: locking root is refused unless another account is
  # shown to escalate and to be able to log in, because a machine where neither
  # is true is recovered from a LiveUSB and from nowhere else.
  set_default root_lock "no" # yes|no

  set_default network ""
  set_default sshd ""
  # Build
  set_default jobs ""
  # Each module owns its own settings and declares them itself, so that a module
  # stays one file. They are called from here, once, because cfg_known() must
  # know every name before config_load_file() reads a .conf — otherwise a file
  # naming disk_layout is refused for a key the project does in fact have.
  #
  # set_default never overwrites, so calling these again from their own step
  # (which steps/20_disk.sh and steps/40_stage.sh do, to stay drivable alone) is
  # harmless.
  local fn
  # portage_init_defaults lives in steps/60_portage.sh rather than a lib, and it
  # was missed when the other three were wired: its seventeen settings were
  # declared and unreachable, spellable neither in a .conf nor as a flag. The
  # declare -F guard is what makes listing a step function here safe.
  for fn in disk_init_defaults crypt_config_defaults stage_init_defaults \
    portage_init_defaults; do
    if declare -F "$fn" >/dev/null; then
      "$fn"
    fi
  done
}

# --------------------------------------------------------------------------- #
#  Configuration file                                                         #
# --------------------------------------------------------------------------- #
config_load_file() {
  # key = value, one per line, # starts a full-line comment. A value may
  # contain # and =, so only the first = splits and only a leading # comments.
  #
  # A file value beats a profile and loses to a flag, whatever the order on the
  # command line: it is applied with set_default (a flag already parsed wins)
  # and then marked explicit (a profile applied later cannot touch it).
  local file="$1"
  if [[ ! -r "$file" ]]; then
    die_usage "Cannot read configuration file: ${file}" \
      "expected a readable file of 'key = value' lines" \
      "example:  --config /etc/gentoo-install.conf"
  fi

  local line key value lineno=0 trimmed
  while IFS= read -r line || [[ -n "$line" ]]; do
    lineno=$((lineno + 1))
    trimmed="${line#"${line%%[![:space:]]*}"}"
    trimmed="${trimmed%"${trimmed##*[![:space:]]}"}"
    [[ -n "$trimmed" ]] || continue
    [[ "${trimmed:0:1}" != "#" ]] || continue

    if [[ "$trimmed" != *"="* ]]; then
      die_usage "Malformed line ${lineno} in ${file}: ${trimmed}" \
        "every setting line reads 'key = value'" \
        "a line starting with # is a comment" \
        "example:  init = systemd"
    fi

    key="${trimmed%%=*}"
    value="${trimmed#*=}"
    key="${key%"${key##*[![:space:]]}"}"
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    # Strip one matching pair of surrounding quotes, if present.
    if [[ ${#value} -ge 2 && "${value:0:1}" == '"' && "${value: -1}" == '"' ]]; then
      value="${value:1:${#value}-2}"
    elif [[ ${#value} -ge 2 && "${value:0:1}" == "'" && "${value: -1}" == "'" ]]; then
      value="${value:1:${#value}-2}"
    fi

    if [[ ! "$key" =~ ^[a-z][a-z0-9_]*$ ]]; then
      die_usage "Invalid setting name on line ${lineno} of ${file}: ${key}" \
        "a name is lowercase letters, digits and underscores" \
        "example:  on_conflict = prompt"
    fi
    if ! cfg_known "$key"; then
      die_usage "Unknown setting on line ${lineno} of ${file}: ${key}" \
        "--dump-config lists every setting this version knows" \
        "example:  init = systemd"
    fi

    set_default "$key" "$value"
    _EXPLICIT[$key]=1
  done <"$file"

  log "configuration read from ${file}"
}

# --------------------------------------------------------------------------- #
#  Export to the runtime switches                                             #
# --------------------------------------------------------------------------- #
# shellcheck disable=SC2034  # every name below lives in lib/core.sh
config_export_runtime() {
  # The one place where CFG becomes the globals that core.sh and ui.sh read on
  # the hot path. Called once, after parsing and after the profile.
  DRY_RUN="${CFG[dry_run]}"
  ASSUME_YES="${CFG[assume_yes]}"
  FORCE="${CFG[force]}"
  NON_INTERACTIVE="${CFG[non_interactive]}"
  ON_CONFLICT="${CFG[on_conflict]}"
  COLOUR_MODE="${CFG[color]}"
}

# --------------------------------------------------------------------------- #
#  Rendering                                                                  #
# --------------------------------------------------------------------------- #
dump_config() {
  # Prints on stdout: it is the value --dump-config was asked for. Secrets are
  # masked, and each line says where the value came from, which is the only way
  # to debug a precedence complaint.
  local key origin width=0
  local -a keys=()
  mapfile -t keys < <(cfg_keys)
  for key in "${keys[@]}"; do
    if ((${#key} > width)); then
      width=${#key}
    fi
  done
  for key in "${keys[@]}"; do
    if is_explicit "$key"; then
      origin="explicit"
    else
      origin="default"
    fi
    printf '%-*s = %-28s # %s\n' "$width" "$key" "$(cfg_display "$key")" "$origin"
  done
}
