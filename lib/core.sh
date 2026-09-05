#!/usr/bin/env bash
#
# gentoo-install — core: output, exit codes, execution, lifecycle, file writes
# ----------------------------------------------------------------------------
# Sourced first by every other file. It owns the six output helpers (all on
# stderr), the four exit codes, the dry-run-aware command runner, the run
# lifecycle (traps, tracked mounts, tracked temporaries, timestamped backups)
# and the three file-writing primitives: marked block, whole-file, and
# write-then-validate-then-roll-back.
#
# Nothing here runs at source time. The entry point calls core_init_colours(),
# core_open_log() and core_install_traps() once, in that order.
#
# Usage:  source lib/core.sh   (never executed directly)
#
set -euo pipefail

if [[ -n "${_GI_CORE_LOADED:-}" ]]; then
  return 0
fi
_GI_CORE_LOADED=1

# --------------------------------------------------------------------------- #
#  Exit codes                                                                 #
# --------------------------------------------------------------------------- #
# A step returns one of these. Only gentoo-install.sh ever calls exit.
# shellcheck disable=SC2034  # read by gentoo-install.sh, not by this file
readonly EXIT_SUCCESS=0
readonly EXIT_FAILURE=1
readonly EXIT_USAGE=2
readonly EXIT_INTERRUPTED=130

# --------------------------------------------------------------------------- #
#  Runtime switches                                                           #
# --------------------------------------------------------------------------- #
# CFG (lib/config.sh) is the parsed truth. These five are the hot-path mirrors
# read by run_cmd(), the file writers and lib/ui.sh; they are filled exactly
# once, by config_export_runtime(). Nothing else assigns them.
DRY_RUN="no" # yes|no                            — --dry-run
# shellcheck disable=SC2034  # read by lib/ui.sh
ASSUME_YES="no" # yes|no                            — --yes
# shellcheck disable=SC2034  # reserved for the steps; --force lifts confirmations
FORCE="no"           # yes|no                            — --force
NON_INTERACTIVE="no" # yes|no                            — --non-interactive
ON_CONFLICT="backup" # overwrite|skip|prompt|backup      — --on-conflict
COLOUR_MODE="auto"   # auto|never                        — --no-color

# Set by the last successful call to a file writer, so a caller can tell the
# three outcomes apart without parsing output (DESIGN.md §7, §9).
WRITE_RESULT="none" # written|unchanged|skipped|failed|none

# --------------------------------------------------------------------------- #
#  Colours                                                                    #
# --------------------------------------------------------------------------- #
# Declared empty so that the helpers work under `set -u` even when a caller
# forgot core_init_colours(); no colour is the safe degradation.
C_R=""
C_G=""
C_Y=""
C_B=""
C_D=""
C_0=""

core_init_colours() {
  # Colour only on a terminal, never when NO_COLOR is set, never with --no-color.
  #
  # The test is on fd 2, not fd 1, and that is a deliberate departure from the
  # snippet in docs/DESIGN.md §3. Every coloured byte this project writes goes
  # to stderr — the same section says so two paragraphs later — so `-t 1` asks
  # about a stream that never carries an escape sequence. It answers "no" for
  # `./gentoo-install.sh --dry-run | tee install.log` and for
  # `./gentoo-install.sh --json > plan.json`, both of which still have a real
  # terminal on stderr, and the operator loses the colour for no reason.
  if [[ "$COLOUR_MODE" != "never" && -t 2 && -z "${NO_COLOR:-}" ]]; then
    C_R=$'\033[1;31m'
    C_G=$'\033[1;32m'
    C_Y=$'\033[1;33m'
    C_B=$'\033[1;34m'
    C_D=$'\033[2m'
    C_0=$'\033[0m'
  else
    C_R=""
    C_G=""
    C_Y=""
    C_B=""
    C_D=""
    C_0=""
  fi
}

# --------------------------------------------------------------------------- #
#  Journal                                                                    #
# --------------------------------------------------------------------------- #
# Every helper line is mirrored, timestamped, into LOG_FILE. Empty until
# core_open_log() succeeds, so the helpers are usable before the log exists.
LOG_FILE=""

core_open_log() {
  # Best effort: a run that cannot write its log is still a run worth having.
  # Args: $1 = path. Returns 0 always.
  local path="$1" dir
  [[ -n "$path" ]] || return 0
  dir="${path%/*}"
  [[ "$dir" != "$path" ]] || dir="."
  if ! mkdir -p -- "$dir" 2>/dev/null; then
    warn "cannot create log directory ${dir}; continuing without a log file"
    return 0
  fi
  if ! { : >>"$path"; } 2>/dev/null; then
    warn "cannot write ${path}; continuing without a log file"
    return 0
  fi
  chmod 0600 -- "$path" 2>/dev/null || true
  LOG_FILE="$path"
  _journal '[*]' "gentoo-install log opened"
}

_journal() {
  # Args: $1 = glyph, $2 = message. Never fails the run.
  [[ -n "$LOG_FILE" ]] || return 0
  printf '%s %s %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$1" "$2" >>"$LOG_FILE" 2>/dev/null || true
}

# --------------------------------------------------------------------------- #
#  The six helpers — all on stderr                                            #
# --------------------------------------------------------------------------- #
# stdout belongs to values a function returns to its caller, and to --json.
# A helper that printed on stdout would poison every $( ) that wraps a callee.
_emit() {
  local glyph="$1" colour="$2"
  shift 2
  printf '%s%s%s %s\n' "$colour" "$glyph" "$C_0" "$*" >&2
  _journal "$glyph" "$*"
}

log() { _emit '[*]' "$C_B" "$@"; }
ok() { _emit '[+]' "$C_G" "$@"; }
warn() { _emit '[!]' "$C_Y" "$@"; }
err() { _emit '[x]' "$C_R" "$@"; }
skip() { _emit '[=]' "$C_D" "$@"; }
die() {
  err "$*"
  exit "${EXIT_FAILURE}"
}

die_usage() {
  # The error voice of DESIGN.md §6: what is wrong, then the valid values with
  # one line each, then a copyable example. Seven spaces of continuation, which
  # lands the text one column past the message column of the first line.
  # Args: $1 = what is wrong, $2.. = continuation lines.
  local first="$1" line
  shift
  err "$first"
  for line in "$@"; do
    err "       ${line}"
  done
  exit "${EXIT_USAGE}"
}

# --------------------------------------------------------------------------- #
#  Environment helpers                                                        #
# --------------------------------------------------------------------------- #
have() {
  # True when a command exists. `command -v`, never `which` (DESIGN.md §13).
  command -v "$1" >/dev/null 2>&1
}

require_root() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    die_usage "gentoo-install must run as root" \
      "it partitions disks, unpacks a stage tarball and chroots" \
      "--dry-run needs no privileges, so review the plan first" \
      "example:  sudo ./gentoo-install.sh --steps 10"
  fi
}

require_cmds() {
  # Args: $@ = command names. Names every missing one, not just the first.
  local cmd
  local -a missing=()
  for cmd in "$@"; do
    if ! have "$cmd"; then
      missing+=("$cmd")
    fi
  done
  if ((${#missing[@]} > 0)); then
    err "Missing required command(s): ${missing[*]}"
    for cmd in "${missing[@]}"; do
      err "       ${cmd}  not found in PATH"
    done
    return 1
  fi
  return 0
}

_cmdline() {
  # Render an argv as a line the operator can paste back into a shell.
  local out="" arg
  for arg in "$@"; do
    out+="${out:+ }$(printf '%q' "$arg")"
  done
  printf '%s' "$out"
}

# --------------------------------------------------------------------------- #
#  Command execution                                                          #
# --------------------------------------------------------------------------- #
run_cmd() {
  # The single door every side effect goes through, so --dry-run is complete by
  # construction rather than by remembering to check a flag in each step.
  if [[ "$DRY_RUN" == "yes" ]]; then
    log "dry-run: $(_cmdline "$@")"
    return 0
  fi
  _journal '[$]' "$(_cmdline "$@")"
  "$@"
}

run_quiet() {
  # Same contract as run_cmd, but the command's own output is discarded.
  if [[ "$DRY_RUN" == "yes" ]]; then
    log "dry-run: $(_cmdline "$@")"
    return 0
  fi
  _journal '[$]' "$(_cmdline "$@")"
  "$@" >/dev/null 2>&1
}

# --------------------------------------------------------------------------- #
#  Interactive primitive                                                      #
# --------------------------------------------------------------------------- #
core_read_yes_no() {
  # The raw y/n reader. lib/ui.sh builds confirm() on top of it and adds the
  # policy (--yes, --non-interactive); core keeps only the I/O so that the
  # file writers can honour `--on-conflict prompt` without depending on ui.sh.
  # Args: $1 = prompt, $2 = default (yes|no). Declines on EOF.
  local prompt="$1" default="${2:-no}" reply="" hint="[y/N]" source="/dev/stdin"
  if [[ "$default" == "yes" ]]; then
    hint="[Y/n]"
  fi
  if [[ -r /dev/tty ]]; then
    source="/dev/tty"
  fi
  printf '%s%s%s %s ' "$C_Y" "$prompt" "$C_0" "$hint" >&2
  if ! read -r reply <"$source"; then
    printf '\n' >&2
    return 1
  fi
  reply="${reply,,}"
  [[ -n "$reply" ]] || reply="$default"
  if [[ "$reply" == "y" || "$reply" == "yes" ]]; then
    return 0
  fi
  return 1
}

# --------------------------------------------------------------------------- #
#  Lifecycle                                                                  #
# --------------------------------------------------------------------------- #
# cleanup() undoes what this run did and nothing else: ownership is recorded at
# the moment of the act, never guessed by scanning the system afterwards.
_GI_MOUNTS=()
_GI_TEMPS=()
_GI_BACKUPS=()
declare -A _GI_BACKUP_OF=()
_GI_CLEANED="no"

track_mount() {
  # Record a mountpoint this run created, so cleanup can unmount it.
  _GI_MOUNTS+=("$1")
}

track_temp() {
  # Record a file or directory this run created, so cleanup can remove it.
  _GI_TEMPS+=("$1")
}

make_temp() {
  # A tracked temporary file. Prints its path (a returned value, so stdout).
  local path
  path="$(mktemp "${TMPDIR:-/tmp}/gentoo-install.XXXXXXXX")"
  track_temp "$path"
  printf '%s\n' "$path"
}

cleanup() {
  local rc=$?
  if [[ "$_GI_CLEANED" == "yes" ]]; then
    return "$rc"
  fi
  _GI_CLEANED="yes"

  local i path
  # Reverse order: the last mount is the innermost one.
  for ((i = ${#_GI_MOUNTS[@]} - 1; i >= 0; i--)); do
    path="${_GI_MOUNTS[i]}"
    if mountpoint -q -- "$path" 2>/dev/null; then
      if ! umount -R -- "$path" 2>/dev/null; then
        warn "could not unmount ${path}; unmount it before rebooting"
      fi
    fi
  done

  if ((${#_GI_TEMPS[@]} > 0)); then
    for path in "${_GI_TEMPS[@]}"; do
      rm -rf -- "$path" 2>/dev/null || true
    done
  fi

  # A backup directory full of identical copies is a backup directory nobody
  # reads: keep them only when the run failed and they may be needed.
  if ((${#_GI_BACKUPS[@]} > 0)); then
    if ((rc == 0)); then
      for path in "${_GI_BACKUPS[@]}"; do
        rm -f -- "$path" 2>/dev/null || true
      done
    else
      warn "run failed; ${#_GI_BACKUPS[@]} backup(s) kept:"
      for path in "${_GI_BACKUPS[@]}"; do
        warn "       ${path}"
      done
    fi
  fi

  return "$rc"
}

handle_interrupt() {
  warn "Interrupted."
  exit "${EXIT_INTERRUPTED}"
}

core_install_traps() {
  trap cleanup EXIT
  trap handle_interrupt INT TERM
}

# --------------------------------------------------------------------------- #
#  Backups                                                                    #
# --------------------------------------------------------------------------- #
backup_file() {
  # Timestamped copy beside the original, remembered so restore_backup() and
  # cleanup() can find it. A missing target is not an error: nothing to save.
  local target="$1" stamp backup previous
  [[ -e "$target" ]] || return 0
  # One backup per target per state: writers stack (write_validated backs up,
  # then write_file may ask resolve_conflict to back up again) and a directory
  # of identical copies is a directory nobody reads.
  previous="${_GI_BACKUP_OF[$target]:-}"
  if [[ -n "$previous" && -e "$previous" ]] && cmp -s -- "$target" "$previous"; then
    return 0
  fi
  stamp="$(date -u '+%Y%m%dT%H%M%SZ')"
  backup="${target}.gi-${stamp}.bak"
  if [[ "$DRY_RUN" == "yes" ]]; then
    log "dry-run: would back up ${target} -> ${backup}"
    return 0
  fi
  if ! cp -a -- "$target" "$backup" 2>/dev/null; then
    err "could not back up ${target}"
    return 1
  fi
  _GI_BACKUPS+=("$backup")
  _GI_BACKUP_OF["$target"]="$backup"
  log "backed up ${target} -> ${backup}"
}

restore_backup() {
  # Put the most recent backup of a target back in place.
  local target="$1"
  local backup="${_GI_BACKUP_OF[$target]:-}"
  if [[ -z "$backup" || ! -e "$backup" ]]; then
    err "no backup recorded for ${target}"
    return 1
  fi
  if ! cp -a -- "$backup" "$target"; then
    err "could not restore ${target} from ${backup}"
    return 1
  fi
  ok "restored ${target} from ${backup}"
}

discard_backups() {
  local path
  if ((${#_GI_BACKUPS[@]} > 0)); then
    for path in "${_GI_BACKUPS[@]}"; do
      rm -f -- "$path" 2>/dev/null || true
    done
  fi
  _GI_BACKUPS=()
  _GI_BACKUP_OF=()
}

# --------------------------------------------------------------------------- #
#  Conflict policy                                                            #
# --------------------------------------------------------------------------- #
resolve_conflict() {
  # Called by the writers when the target already holds something different.
  # Returns 0 to go ahead with the write, 1 to leave the target alone.
  # Args: $1 = target, $2 = short description of what differs.
  local target="$1" what="${2:-content}"
  case "$ON_CONFLICT" in
    overwrite)
      return 0
      ;;
    skip)
      skip "${target}: ${what} differs, left untouched (--on-conflict skip)"
      return 1
      ;;
    backup)
      backup_file "$target" || return 1
      return 0
      ;;
    prompt)
      warn "${target}: ${what} differs from what gentoo-install would write."
      if [[ "$NON_INTERACTIVE" == "yes" ]]; then
        skip "${target}: left untouched (--on-conflict prompt with --non-interactive)"
        return 1
      fi
      if core_read_yes_no "Replace it?" "no"; then
        backup_file "$target" || return 1
        return 0
      fi
      skip "${target}: left untouched"
      return 1
      ;;
    *)
      die "internal: --on-conflict holds an unvalidated value: ${ON_CONFLICT}"
      ;;
  esac
}

# --------------------------------------------------------------------------- #
#  File writes                                                                #
# --------------------------------------------------------------------------- #
# All three writers take their content on stdin. Feed them from a HEREDOC or a
# redirect, never from a pipe:
#
#     write_file /etc/fstab <<'EOF'      # right
#     printf '...' | write_file /etc/fstab   # wrong
#
# The right-hand side of a pipe runs in a subshell, and everything the writer
# records there — WRITE_RESULT, the backup it took, so the rollback path and
# cleanup() both lose track of it — dies with that subshell.
block_open_marker() { printf '# >>> gentoo-install: %s >>>' "$1"; }
block_close_marker() { printf '# <<< gentoo-install: %s <<<' "$1"; }

write_block() {
  # Manage one marked block inside a file we do not own. A rerun replaces its
  # own block and nothing else, so hand edits elsewhere in the file survive.
  # Content comes from stdin.
  #   write_block /etc/portage/make.conf "portage make.conf" <<'EOF'
  #   MAKEOPTS="-j8"
  #   EOF
  # Args: $1 = target, $2 = tag, $3 = mode for a file we create (default 0644).
  local target="$1" tag="$2" mode="${3:-0644}"
  local open close body rendered current present="no" dir tmp
  WRITE_RESULT="failed"

  open="$(block_open_marker "$tag")"
  close="$(block_close_marker "$tag")"
  body="$(cat)"
  rendered="${open}"$'\n'"${body}"$'\n'"${close}"

  if [[ -f "$target" ]] && grep -qxF -- "$open" "$target" 2>/dev/null; then
    present="yes"
    current="$(awk -v o="$open" -v c="$close" '$0==o{f=1} f{print} $0==c{f=0}' "$target")"
    if [[ "$current" == "$rendered" ]]; then
      skip "${target}: block '${tag}' already up to date"
      WRITE_RESULT="unchanged"
      return 0
    fi
    if ! resolve_conflict "$target" "block '${tag}'"; then
      WRITE_RESULT="skipped"
      return 0
    fi
  fi

  if [[ "$DRY_RUN" == "yes" ]]; then
    log "dry-run: would write block '${tag}' into ${target}"
    printf '%s\n' "$rendered" | sed 's/^/       | /' >&2
    WRITE_RESULT="written"
    return 0
  fi

  dir="${target%/*}"
  [[ "$dir" != "$target" ]] || dir="."
  mkdir -p -- "$dir" || {
    err "cannot create ${dir}"
    return 1
  }
  tmp="$(mktemp "${dir}/.gentoo-install.XXXXXX")"

  if [[ "$present" == "yes" ]]; then
    awk -v o="$open" -v c="$close" -v repl="$rendered" '
      $0==o { print repl; f=1; next }
      f     { if ($0==c) { f=0 } ; next }
      { print }
    ' "$target" >"$tmp"
  else
    if [[ -f "$target" ]]; then
      cat -- "$target" >"$tmp"
    fi
    printf '%s\n' "$rendered" >>"$tmp"
  fi

  if [[ -f "$target" ]]; then
    chmod --reference="$target" -- "$tmp" 2>/dev/null || chmod "$mode" -- "$tmp"
  else
    chmod "$mode" -- "$tmp"
  fi
  backup_file "$target" || {
    rm -f -- "$tmp"
    return 1
  }
  mv -f -- "$tmp" "$target"
  ok "${target}: block '${tag}' written"
  WRITE_RESULT="written"
}

write_file() {
  # Whole-file atomic write from stdin, for files gentoo-install owns outright
  # (fstab, make.conf on a fresh stage, a bootloader snippet). Idempotent: an
  # identical file is reported, not rewritten.
  # Args: $1 = target, $2 = mode (default 0644).
  local target="$1" mode="${2:-0644}"
  local body dir tmp
  WRITE_RESULT="failed"
  body="$(cat)"

  if [[ -f "$target" ]]; then
    if [[ "$(cat -- "$target")" == "$body" ]]; then
      skip "${target}: already up to date"
      WRITE_RESULT="unchanged"
      return 0
    fi
    if ! resolve_conflict "$target" "content"; then
      WRITE_RESULT="skipped"
      return 0
    fi
  fi

  if [[ "$DRY_RUN" == "yes" ]]; then
    log "dry-run: would write ${target} (mode ${mode})"
    printf '%s\n' "$body" | sed 's/^/       | /' >&2
    WRITE_RESULT="written"
    return 0
  fi

  dir="${target%/*}"
  [[ "$dir" != "$target" ]] || dir="."
  mkdir -p -- "$dir" || {
    err "cannot create ${dir}"
    return 1
  }
  tmp="$(mktemp "${dir}/.gentoo-install.XXXXXX")"
  printf '%s\n' "$body" >"$tmp"
  chmod "$mode" -- "$tmp"
  mv -f -- "$tmp" "$target"
  ok "${target}: written"
  WRITE_RESULT="written"
}

write_validated() {
  # Write, then let the file's own checker have the last word; restore the
  # backup and fail if it objects. sshd -t, visudo -c, grub-script-check,
  # findmnt --verify: each of these turns a silent brick into a caught error.
  # Content comes from stdin; the validator is run exactly as given.
  #   write_validated /etc/fstab findmnt --verify --fstab /etc/fstab <<'EOF'
  # Args: $1 = target, $2.. = validator argv.
  local target="$1"
  shift
  if (($# == 0)); then
    die "internal: write_validated ${target} was given no validator"
  fi

  # Back up before the write, unconditionally: the rollback needs a copy even
  # when --on-conflict would not have made one.
  backup_file "$target" || return 1

  write_file "$target" || return 1
  if [[ "$WRITE_RESULT" != "written" ]]; then
    return 0
  fi

  if [[ "$DRY_RUN" == "yes" ]]; then
    log "dry-run: would validate ${target} with: $(_cmdline "$@")"
    return 0
  fi

  if "$@" >/dev/null 2>&1; then
    ok "${target}: accepted by $(_cmdline "$@")"
    return 0
  fi

  err "${target}: rejected by $(_cmdline "$@")"
  if restore_backup "$target"; then
    err "       the previous content is back in place"
  else
    err "       there was no previous content; ${target} is left as written"
  fi
  WRITE_RESULT="failed"
  return 1
}

ensure_line() {
  # Idempotence by state check on a single line (DESIGN.md §9): read, compare,
  # write only if different, and say which of the three happened.
  # Args: $1 = target, $2 = line.
  local target="$1" line="$2" dir
  WRITE_RESULT="failed"
  if [[ -f "$target" ]] && grep -qxF -- "$line" "$target" 2>/dev/null; then
    skip "${target}: already contains '${line}'"
    WRITE_RESULT="unchanged"
    return 0
  fi
  if [[ "$DRY_RUN" == "yes" ]]; then
    log "dry-run: would append to ${target}: ${line}"
    WRITE_RESULT="written"
    return 0
  fi
  backup_file "$target" || return 1
  dir="${target%/*}"
  [[ "$dir" != "$target" ]] || dir="."
  mkdir -p -- "$dir" || {
    err "cannot create ${dir}"
    return 1
  }
  printf '%s\n' "$line" >>"$target"
  ok "${target}: appended '${line}'"
  WRITE_RESULT="written"
}
