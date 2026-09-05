#!/usr/bin/env bash
#
# gentoo-install — state: the resume journal
# ----------------------------------------------------------------------------
# A Gentoo install compiles a kernel. An interruption three hours in must not
# start over, so every step that completes is recorded in a key=value journal
# that --resume reads and --restart throws away.
#
# The journal says what was done. It never says with what: no passphrase, no
# key, no password reaches it, and state_set() refuses a key that looks like
# one rather than trusting the caller to remember.
#
# Nothing here runs at source time. The entry point calls state_init() once.
#
# Usage:  source lib/state.sh   (needs lib/core.sh)
#
set -euo pipefail

if [[ -n "${_GI_STATE_LOADED:-}" ]]; then
  return 0
fi
_GI_STATE_LOADED=1

STATE_DIR="/var/lib/gentoo-install"
STATE_FILE=""

# --------------------------------------------------------------------------- #
#  Guards                                                                     #
# --------------------------------------------------------------------------- #
_state_require_init() {
  if [[ -z "$STATE_FILE" ]]; then
    die "internal: state_init() was never called"
  fi
}

_state_check_key() {
  # Keys are matched with a ^key= regex when rewriting, so they stay boring.
  local key="$1"
  if [[ ! "$key" =~ ^[A-Za-z][A-Za-z0-9._-]*$ ]]; then
    die "internal: invalid state key: ${key}"
  fi
  case "$key" in
    *password* | *passphrase* | *secret* | *_key | *_token)
      die "internal: refusing to journal '${key}' — the state journal records what was done, never with what"
      ;;
  esac
}

# --------------------------------------------------------------------------- #
#  Lifecycle                                                                  #
# --------------------------------------------------------------------------- #
state_attach() {
  # Point at a journal without creating anything. --json and the plan need to
  # read it before the run has earned the right to write it, and a read that
  # created a root-owned directory as a side effect would be a nasty surprise.
  # Args: $1 = state directory (optional, defaults to the current STATE_DIR).
  STATE_DIR="${1:-$STATE_DIR}"
  STATE_FILE="${STATE_DIR}/state"
}

state_init() {
  # Args: $1 = state directory (optional, defaults to the current STATE_DIR).
  state_attach "${1:-$STATE_DIR}"
  if [[ "$DRY_RUN" == "yes" ]]; then
    log "dry-run: would use the state journal ${STATE_FILE}"
    return 0
  fi
  if ! mkdir -p -- "$STATE_DIR"; then
    die "cannot create the state directory ${STATE_DIR}"
  fi
  chmod 0700 -- "$STATE_DIR" 2>/dev/null || true
  if [[ ! -e "$STATE_FILE" ]]; then
    : >"$STATE_FILE"
  fi
  chmod 0600 -- "$STATE_FILE" 2>/dev/null || true
}

state_reset() {
  # --restart: forget everything and run from the top.
  local file="${STATE_FILE:-${STATE_DIR}/state}"
  if [[ "$DRY_RUN" == "yes" ]]; then
    log "dry-run: would clear the state journal ${file}"
    return 0
  fi
  if [[ -e "$file" ]]; then
    rm -f -- "$file"
    ok "state journal cleared (${file})"
  else
    skip "no state journal to clear (${file})"
  fi
}

# --------------------------------------------------------------------------- #
#  Entries                                                                    #
# --------------------------------------------------------------------------- #
state_set() {
  # Args: $1 = key, $2 = value. Rewrites the journal atomically, mode 600.
  local key="$1" value="$2" tmp
  _state_check_key "$key"
  _state_require_init
  if [[ "$DRY_RUN" == "yes" ]]; then
    log "dry-run: would record ${key}=${value}"
    return 0
  fi
  tmp="$(mktemp "${STATE_DIR}/.state.XXXXXX")"
  chmod 0600 -- "$tmp"
  if [[ -f "$STATE_FILE" ]]; then
    grep -v -- "^${key}=" "$STATE_FILE" >>"$tmp" || true
  fi
  printf '%s=%s\n' "$key" "$value" >>"$tmp"
  mv -f -- "$tmp" "$STATE_FILE"
  chmod 0600 -- "$STATE_FILE" 2>/dev/null || true
}

state_get() {
  # Prints the value on stdout (a returned value). Returns 1 when absent.
  local key="$1" line
  _state_check_key "$key"
  [[ -n "$STATE_FILE" && -f "$STATE_FILE" ]] || return 1
  line="$(grep -m1 -- "^${key}=" "$STATE_FILE" 2>/dev/null)" || return 1
  printf '%s\n' "${line#*=}"
}

state_unset() {
  local key="$1" tmp
  _state_check_key "$key"
  _state_require_init
  if [[ "$DRY_RUN" == "yes" ]]; then
    log "dry-run: would forget ${key}"
    return 0
  fi
  [[ -f "$STATE_FILE" ]] || return 0
  tmp="$(mktemp "${STATE_DIR}/.state.XXXXXX")"
  chmod 0600 -- "$tmp"
  grep -v -- "^${key}=" "$STATE_FILE" >>"$tmp" || true
  mv -f -- "$tmp" "$STATE_FILE"
  chmod 0600 -- "$STATE_FILE" 2>/dev/null || true
}

# --------------------------------------------------------------------------- #
#  Steps                                                                      #
# --------------------------------------------------------------------------- #
state_done() {
  # Args: $1 = step number. The value carries the completion timestamp so the
  # journal reads as a history, not just a set of flags.
  state_set "step.${1}" "done $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
}

state_is_done() {
  local value
  value="$(state_get "step.${1}")" || return 1
  if [[ "$value" == done* ]]; then
    return 0
  fi
  return 1
}

state_dump() {
  # Prints the journal on stdout, for --json and for an operator's eyes.
  [[ -n "$STATE_FILE" && -f "$STATE_FILE" ]] || return 0
  sort -- "$STATE_FILE"
}
