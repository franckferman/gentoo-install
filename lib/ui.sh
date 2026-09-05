#!/usr/bin/env bash
#
# gentoo-install — ui: the four ways this installer asks a question
# ----------------------------------------------------------------------------
# confirm() for a reversible choice, confirm_typed() for an irreversible one,
# ask_tri() for a setting that can be answered up front or left to the moment,
# prompt_secret() for something that must never be echoed or journalled, and
# menu() for the guided mode.
#
# The line that matters: --force and --yes lift confirmations, they do not lift
# proofs. confirm_typed() asks for a disk name or a UUID because a reflex `y`
# is exactly what it exists to catch, and no flag turns it into a `y`.
#
# Nothing here runs at source time.
#
# Usage:  source lib/ui.sh   (needs lib/core.sh, and lib/config.sh for ask_tri)
#
set -euo pipefail

if [[ -n "${_GI_UI_LOADED:-}" ]]; then
  return 0
fi
_GI_UI_LOADED=1

_ui_input_source() {
  # Prompts read from the terminal, not from stdin, so that a step can pipe
  # data into a helper without eating the operator's answer.
  if [[ -r /dev/tty ]]; then
    printf '%s\n' "/dev/tty"
  else
    printf '%s\n' "/dev/stdin"
  fi
}

# --------------------------------------------------------------------------- #
#  confirm — a reversible choice                                              #
# --------------------------------------------------------------------------- #
confirm() {
  # Args: $1 = question, $2 = default when the operator just presses enter
  #       (yes|no, default no).
  # Returns 0 for yes. Declines on EOF: a closed stdin is not consent.
  local question="$1" default="${2:-no}"

  if [[ "$default" != "yes" && "$default" != "no" ]]; then
    die "internal: confirm() default must be yes or no, got '${default}'"
  fi

  if [[ "$ASSUME_YES" == "yes" ]]; then
    log "assuming yes: ${question}"
    return 0
  fi

  if [[ "$NON_INTERACTIVE" == "yes" ]]; then
    log "non-interactive: ${question} -> ${default}"
    if [[ "$default" == "yes" ]]; then
      return 0
    fi
    return 1
  fi

  core_read_yes_no "$question" "$default"
}

# --------------------------------------------------------------------------- #
#  confirm_typed — a proof, not a confirmation                                #
# --------------------------------------------------------------------------- #
confirm_typed() {
  # Args: $1 = what is about to happen, $2 = the exact string to type.
  # Neither --yes nor --force lifts this (DESIGN.md §12). There is no reflex
  # answer to "type /dev/nvme0n1", which is the entire point.
  local what="$1" expected="$2" reply="" source

  warn "$what"

  if [[ "$NON_INTERACTIVE" == "yes" || ! -r /dev/tty ]]; then
    err "This is irreversible and needs a typed confirmation: ${expected}"
    err "       --yes and --force do not lift it, by design"
    err "       run gentoo-install from a terminal to confirm it"
    return 1
  fi

  source="$(_ui_input_source)"
  printf '%sType %s to confirm:%s ' "$C_Y" "$expected" "$C_0" >&2
  if ! read -r reply <"$source"; then
    printf '\n' >&2
    err "Nothing typed; nothing done."
    return 1
  fi

  if [[ "$reply" == "$expected" ]]; then
    return 0
  fi

  err "Confirmation did not match"
  err "       expected: ${expected}"
  err "       typed:    ${reply}"
  return 1
}

# --------------------------------------------------------------------------- #
#  ask_tri — ask|yes|no                                                       #
# --------------------------------------------------------------------------- #
ask_tri() {
  # A boolean cannot express "ask me". Anything whose wrong answer destroys
  # something is a tri-state defaulting to ask.
  # Args: $1 = CFG key holding ask|yes|no, $2 = question,
  #       $3 = what "ask" resolves to when nobody can be asked (default no).
  local key="$1" question="$2" fallback="${3:-no}"
  local value="${CFG[$key]:-ask}"

  case "$value" in
    yes)
      log "${question} -> yes (${key}=yes)"
      return 0
      ;;
    no)
      skip "${question} -> no (${key}=no)"
      return 1
      ;;
    ask)
      if [[ "$NON_INTERACTIVE" == "yes" && "$ASSUME_YES" != "yes" ]]; then
        skip "${question} -> ${fallback} (non-interactive; set ${key}=yes or ${key}=no to decide up front)"
        if [[ "$fallback" == "yes" ]]; then
          return 0
        fi
        return 1
      fi
      confirm "$question" "$fallback"
      ;;
    *)
      die_usage "Invalid value for ${key}: ${value}" \
        "ask  decide at the moment it matters" \
        "yes  always do it" \
        "no   never do it" \
        "example:  ${key} = ask"
      ;;
  esac
}

# --------------------------------------------------------------------------- #
#  prompt_secret — never echoed, never journalled                             #
# --------------------------------------------------------------------------- #
prompt_secret() {
  # Args: $1 = name of the variable to fill, $2 = prompt,
  #       $3 = ask twice and compare (yes|no, default yes).
  # The value is assigned to the named variable and is never printed, never
  # passed to a log helper and never written to the state journal.
  local varname="$1" prompt="$2" twice="${3:-yes}"
  local first="" second="" source

  if [[ ! "$varname" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
    die "internal: prompt_secret() got an invalid variable name: ${varname}"
  fi

  if [[ "$NON_INTERACTIVE" == "yes" || ! -r /dev/tty ]]; then
    err "Cannot ask for ${prompt} without a terminal"
    err "       supply it through a configuration file or a key file instead"
    err "       secrets are never accepted on the command line: they land in ps and in shell history"
    return 1
  fi

  source="$(_ui_input_source)"
  printf '%s: ' "$prompt" >&2
  if ! read -rs first <"$source"; then
    printf '\n' >&2
    return 1
  fi
  printf '\n' >&2

  if [[ -z "$first" ]]; then
    err "Empty ${prompt}."
    return 1
  fi

  if [[ "$twice" == "yes" ]]; then
    printf '%s (again): ' "$prompt" >&2
    if ! read -rs second <"$source"; then
      printf '\n' >&2
      return 1
    fi
    printf '\n' >&2
    if [[ "$first" != "$second" ]]; then
      err "The two entries do not match."
      return 1
    fi
  fi

  printf -v "$varname" '%s' "$first"
}

# --------------------------------------------------------------------------- #
#  menu — the guided mode                                                     #
# --------------------------------------------------------------------------- #
menu() {
  # Args: $1 = title, $2.. = the entries.
  # The menu is drawn on stderr; the chosen entry is printed on stdout, so
  #   choice="$(menu "Init system" openrc systemd)"
  # works. Returns 1 if the operator gives up.
  local title="$1"
  shift
  local count=$# reply source i

  if ((count == 0)); then
    die "internal: menu() was given no entries"
  fi

  if [[ "$NON_INTERACTIVE" == "yes" || ! -r /dev/tty ]]; then
    skip "${title}: taking the first entry (${1}) — no terminal to ask on"
    printf '%s\n' "$1"
    return 0
  fi

  printf '%s%s%s\n' "$C_B" "$title" "$C_0" >&2
  for ((i = 1; i <= count; i++)); do
    printf '  %2d) %s\n' "$i" "${!i}" >&2
  done

  source="$(_ui_input_source)"
  printf 'Choice [1-%d]: ' "$count" >&2
  if ! read -r reply <"$source"; then
    printf '\n' >&2
    err "Nothing chosen."
    return 1
  fi

  if [[ ! "$reply" =~ ^[0-9]+$ ]] || ((10#$reply < 1 || 10#$reply > count)); then
    err "Invalid choice: ${reply}"
    err "       enter a number between 1 and ${count}"
    return 1
  fi

  reply=$((10#$reply))
  printf '%s\n' "${!reply}"
}
