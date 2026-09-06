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

# What a dry run would have written.
#
# The journal is how one step tells the next what it did: step 20 records
# disk.crypt_device, step 30 reads it. A dry run writes nothing to disk, which
# is the point — but with nothing to read either, step 30 stopped with "No
# device to encrypt" and every step after it fell over the same way. The plan
# an operator asked to see ended in five failures that were artefacts of asking.
#
# So a dry run keeps its writes here instead, and reads find them. Nothing
# reaches the filesystem, and lib/disk.sh's claim that --dry-run is complete by
# construction becomes true for the steps that talk to each other.
declare -A _GI_STATE_DRY=()

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
  local dir_existed="yes"
  [[ -e "$STATE_DIR" ]] || dir_existed="no"
  if ! mkdir -p -- "$STATE_DIR"; then
    die "cannot create the state directory ${STATE_DIR}"
  fi
  # Tighten only a directory this run created. --state-dir names a path the
  # caller chose, and this runs as root: chmod 0700 on a directory that was
  # already there and shared (/tmp, /var/lib, /) would strip its sticky bit
  # and lock every other user out of it.
  if [[ "$dir_existed" == "no" ]]; then
    chmod 0700 -- "$STATE_DIR" 2>/dev/null || true
  fi
  if [[ ! -e "$STATE_FILE" ]]; then
    : >"$STATE_FILE"
  fi
  # Same reasoning one level down: only a regular file gets its mode changed,
  # never a device node or a symlink someone pointed here.
  if _core_plain_file "$STATE_FILE"; then
    chmod 0600 -- "$STATE_FILE" 2>/dev/null || true
  fi

  state_warn_if_volatile
}

state_filesystem() {
  # The filesystem type the journal really sits on, asked rather than assumed.
  # A returned value, so stdout; empty when nothing here can tell.
  #
  # An overlay is followed to the layer that receives the writes, which is the
  # whole point on a live medium: the Gentoo ISO mounts
  #
  #   overlay  LiveOS_rootfs  lowerdir=/run/rootfsbase,upperdir=/run/overlayfs
  #
  # so /var/lib/gentoo-install answers "overlay", the first version of this
  # check saw a filesystem it had no opinion about, and said nothing on exactly
  # the medium it was written for. /run is a tmpfs; the journal is in RAM.
  # Args: $1 = a path (default: the state directory), $2 = recursion depth.
  local path="${1:-$STATE_DIR}" depth="${2:-0}" fstype="" upper=""
  if have findmnt; then
    fstype="$(findmnt -no FSTYPE --target "$path" 2>/dev/null || true)"
  fi
  if [[ -z "$fstype" ]] && have stat; then
    fstype="$(stat -f -c %T -- "$path" 2>/dev/null || true)"
  fi

  if [[ "$fstype" == overlay* ]] && ((depth < 3)) && have findmnt; then
    upper="$(findmnt -no OPTIONS --target "$path" 2>/dev/null \
      | tr ',' '\n' | sed -n 's/^upperdir=//p' | head -n 1)"
    if [[ -n "$upper" && -d "$upper" ]]; then
      state_filesystem "$upper" "$((depth + 1))"
      return 0
    fi
  fi
  printf '%s\n' "$fstype"
}

state_warn_if_volatile() {
  # A journal on a tmpfs is a journal that a reboot forgets.
  #
  # The default is /var/lib/gentoo-install, and on the medium this installer is
  # designed to be run from — a live ISO — that is a tmpfs. So the record of
  # which steps completed, and the disk plan step 20 writes beside it, live in
  # RAM: interrupt the install, reboot the live medium, and --resume has
  # nothing to resume from. It is not a bug in the journal, it is a property of
  # where it lands by default, and it is worth one line before three hours of
  # compiling rather than after.
  local fstype
  fstype="$(state_filesystem)"
  case "$fstype" in
    tmpfs | ramfs) ;;
    *) return 0 ;;
  esac
  warn "the state journal is on a ${fstype}: ${STATE_DIR}"
  warn "       which steps completed, and the disk plan step 20 records, are"
  warn "       in RAM — rebooting this medium loses both, and --resume with"
  warn "       them gone starts from the beginning"
  warn "       --state-dir on something that survives keeps them:"
  warn "       example:  --state-dir /run/media/usb/gi-state"
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
    _GI_STATE_DRY["$key"]="$value"
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
  #
  # A dry run's own writes come first, and only for keys it actually wrote: a
  # dry run resumed over a real journal still reads everything the last real
  # run recorded.
  local key="$1" line
  _state_check_key "$key"
  if [[ "$DRY_RUN" == "yes" && -n "${_GI_STATE_DRY[$key]+set}" ]]; then
    printf '%s\n' "${_GI_STATE_DRY[$key]}"
    return 0
  fi
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
    unset '_GI_STATE_DRY[$key]'
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
