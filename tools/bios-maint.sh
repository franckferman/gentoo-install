#!/usr/bin/env bash
#
# gentoo-install — BIOS maintenance: a firmware update without a rescue medium
# ----------------------------------------------------------------------------
# Calls the other tools of the box in the one order that works, remembers where
# it got to across the reboots, and refuses to go on when the step before was
# not proven. It implements none of what they do: no luksAddKey, no clevis
# bind, no luksHeaderBackup lives in this file.
#
# The step that makes the difference is the test reboot before the flash. A
# keyslot that answers --test-passphrase is not a machine that came back up.
#
# Usage:  ./bios-maint.sh <command> [options]   (--help for the list)
#
set -euo pipefail

readonly EXIT_SUCCESS=0
readonly EXIT_FAILURE=1
readonly EXIT_USAGE=2

# Configuration
SUBCOMMAND="plan"
FORCE="false"
DEVICE=""            # --device     : bypasses detection
KEY_PATH=""          # --key        : GPG-wrapped key, passed on as it is
ROOT_PREFIX=""       # --root       : installed tree, when run from a LiveCD
BACKUP_DIR=""        # --backup-dir : where the header backup is written
CAB_PATH=""          # --cab        : firmware capsule, handed to bios-update.sh
GEN_NEW="false"      # --gen-passphrase : let luks-addkey.sh draw it
NEW_PASS_OUT=""      # --new-passphrase-out : where the drawn one is written
REMOVE_MAINT="false" # --remove-maint-pass : cleanup takes the keyslot away
PASSPHRASE=""        # never exposed on the command line internally
PASSPHRASE_STDIN="false"
# No PASSPHRASE_SOURCE here, unlike tpm-reseal.sh: nothing in this file reports
# where the secret came from, because nothing in this file decrypts anything.
MAINT_PASSPHRASE="" # --maint-passphrase : the one the test reboot uses
MAINT_FILE=""       # --maint-passphrase-file : a path, never read here

# Paths of the installed system, always read under ROOT_PREFIX
STATE_DIR="/var/lib/gentoo-install"
STATE_FILE="/var/lib/gentoo-install/bios-maint.state"

# The tags this workflow reserves in the tpm-pcr.sh snapshot store. The first
# has to exist before the flash, or "which PCR moved" has no answer after it.
PCR_TAG="before-flash"
PCR_TAG_AFTER="after-flash"

ERR_LOG="/tmp/gentoo-install-bios-maint.log"

# Where this script sits, so its siblings are called without guessing a path.
# The siblings it orchestrates are luks-check.sh, luks-addkey.sh,
# luks-header.sh, tpm-pcr.sh, tpm-reseal.sh and bios-update.sh, and each
# command names the subset it needs. They are looked up here and never in PATH.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"

# The file that holds the drawn maintenance passphrase, at script level so the
# EXIT trap can still see it. A variable local to a function no longer exists
# when the trap fires, which under set -u ends on "unbound variable" and leaves
# the file behind. Only the one this script creates itself goes in here: a path
# given with --new-passphrase-out belongs to the operator and is never removed.
TEMP_PASS_FILE=""

QUIET="${GI_QUIET:-false}"

# --------------------------------------------------------------------------- #
#  Output                                                                     #
# --------------------------------------------------------------------------- #
# Colour only on a terminal, never when NO_COLOR is set. The stream tested is
# stderr, because that is the stream every coloured byte here goes to.
if [[ -t 2 && -z "${NO_COLOR:-}" ]]; then
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

# Everything goes to stderr so that functions can return values on stdout.
log() { [[ "$QUIET" == "true" ]] || printf '%s[*]%s %s\n' "$C_B" "$C_0" "$*" >&2; }
ok() { printf '%s[+]%s %s\n' "$C_G" "$C_0" "$*" >&2; }
warn() { printf '%s[!]%s %s\n' "$C_Y" "$C_0" "$*" >&2; }
err() { printf '%s[x]%s %s\n' "$C_R" "$C_0" "$*" >&2; }
skip() { printf '%s[=]%s %s\n' "$C_D" "$C_0" "$*" >&2; }
die() {
  err "$*"
  exit "$EXIT_FAILURE"
}

verbose_enough() { [[ "$QUIET" != "true" ]]; }

show_help() {
  cat <<'HELP_EOF'
Usage: ./bios-maint.sh [COMMAND] [OPTIONS]

================================================================================
gentoo-install - BIOS maintenance
Walks a BIOS update through the toolbox so no LiveUSB is ever needed
================================================================================

WHEN TO USE IT:
    A firmware update is waiting on a machine that unlocks on its own today.
    The flash changes PCR 0, the clevis policy seals on 0, 2, 3 and 6, and the
    TPM stops releasing the key. That is August 2026: LiveUSB, mount the ESP,
    decrypt luks-key.gpg, open LUKS, LVM, chroot, unbind, rebind, one to three
    hours a machine.

    Run it before the flash, on the machine itself, while the TPM still works.
    It is the only moment when any of this is cheap.

WHAT IT DOES:
    Nothing of its own. It calls the tools of the box in the one order that
    works, remembers where it got to across the reboots, and refuses to go on
    when the step before was not proven. No luksAddKey, no clevis bind, no
    luksHeaderBackup lives in this file: they live in luks-addkey.sh,
    tpm-reseal.sh and luks-header.sh, and there is one truth per subject.

WHAT IT NEVER DOES:
    It never removes a way into the container before another one has been
    opened, here and now. It never writes a passphrase into its state file:
    the state says what was done, never with what. It never flashes on a
    reboot that was hoped for rather than seen.

COMMANDS:
    plan                The whole sequence, where it stands, what is left
                        (default). Changes nothing
    prepare             Credential from the TPM, maintenance passphrase, its
                        proof, header backup, PCR snapshot, clevis removed
    verify-boot         After the test reboot: the machine came up without
                        clevis and the maintenance passphrase is what opened it
    flash               bios-update.sh preflight, then flash. Refused until
                        verify-boot has passed
    rebind              PCR comparison against the snapshot, then reseal
    cleanup             Close the operation. Keeps the maintenance passphrase
                        unless --remove-maint-pass says otherwise
    status              The state file and what the machine looks like now,
                        change nothing
    abort               Put the clevis binding back and say what is left to do

OPTIONS:
    -h, --help          Show this help
    -q, --quiet         Essential output only
        --device DEV    LUKS container. Detected from the volume group
                        inside it when omitted
        --key FILE      GPG-wrapped key. Default: /boot/efi/luks-key.gpg
        --root DIR      Root of the installed system, for a run from a LiveCD
        --backup-dir DIR
                        Where prepare writes the header backup. Not on the
                        disk it protects: a stick, a share
        --cab FILE      Firmware capsule, handed to bios-update.sh by flash
        --gen-passphrase
                        Let luks-addkey.sh draw the maintenance passphrase,
                        16 characters out of an alphabet dracut can type
        --new-passphrase-out FILE
                        Where the drawn one is written, mode 600. Required
                        together with --gen-passphrase --force
        --remove-maint-pass
                        cleanup removes the maintenance keyslot. Without it
                        cleanup keeps it, which is the safe default
        --force         Skip every confirmation (non-interactive)

PASSPHRASE (opens luks-key.gpg, what the delegated tools ask for):
        (nothing)               Asked by the tool that needs it, not here
        GI_PASSPHRASE           Environment variable, the route --force needs
        --passphrase-file FILE  First line of a file, keep it mode 600
        --passphrase-stdin      Read from stdin
        --passphrase PASS       Literal value, visible in `ps`

THE MAINTENANCE PASSPHRASE, the one the test reboot is opened with:
        (nothing)               Asked by luks-check.sh when it proves the slot
        GI_MAINT_PASSPHRASE     Environment variable
        --maint-passphrase-file FILE
                                A path, read by luks-check.sh and not here
        --maint-passphrase PASS Literal value, visible in `ps`

WHY THE TEST REBOOT IS THE WHOLE POINT:
    Everything before it says the maintenance passphrase should open the
    machine. Only the reboot says it did. A slot that answers
    --test-passphrase is a slot cryptsetup agrees with; the initramfs prompt,
    the keymap it loaded and the characters actually typed are a different
    question, and it is the one that costs the LiveUSB when it is skipped.
    flash refuses until verify-boot has answered it.

    This is not a theoretical worry. During the August 2026 incident the
    early-userspace kept failing on the TPM and never offered a usable
    interactive prompt, while the passphrase of the slot was perfectly valid.
    That machine still carried its clevis token, and prepare removes the token
    together with the slot, so the state is not the same one. Not the same is
    not proven, and that is exactly why the reboot comes first.

    If the machine comes back without asking anything, do NOT flash. Nothing
    is lost: keyslot 0 and /boot/efi/luks-key.gpg were never touched, so a
    LiveUSB still opens it with ./luks-open.sh open. Run 'abort' to put the
    clevis binding back, and raise the missing prompt as a dracut finding
    before this method is used on a fleet.

WHY CLEANUP KEEPS THE PASSPHRASE:
    A strong passphrase in a slot of its own costs the user nothing: it is
    never asked for as long as clevis works. Removing it means walking this
    whole sequence again the day the TPM stops answering, and that day is the
    one when the TPM cannot hand out a credential any more. So keeping it is
    the default and --remove-maint-pass is the exception. Record it in the
    password manager entry of the machine either way.

WHERE THE STATE LIVES:
    /var/lib/gentoo-install/bios-maint.state, mode 600, one key=value a line.
    It carries the LUKS UUID, the maintenance slot, the header backup and a
    timestamp per step. It carries no secret. Root is needed for every command,
    plan and status included: a file nobody can read makes plan say the
    operation has not started when it has.

EXAMPLES:
    ./bios-maint.sh
        The plan and where this machine stands in it. Changes nothing.

    ./bios-maint.sh prepare --backup-dir /mnt/usb --gen-passphrase
        The whole preparation. Draws the maintenance passphrase, shows it,
        makes you type it back, and ends by removing the clevis binding.

    ./bios-maint.sh verify-boot
        Run it after the reboot. It is what unlocks flash.

    ./bios-maint.sh flash --cab /opt/firmware.cab
        Delegates to ./bios-update.sh preflight, then flash. Refuses if the
        reboot was never proven.

    ./bios-maint.sh abort
        Puts the clevis binding back from wherever the sequence stopped, and
        names what is left to do by hand. It runs from any state.

HELP_EOF
}

parse_arguments() {
  if [[ $# -gt 0 ]] && [[ "$1" != -* ]]; then
    SUBCOMMAND="$1"
    shift
  fi

  while [[ $# -gt 0 ]]; do
    case $1 in
      -h | --help)
        show_help
        exit "$EXIT_SUCCESS"
        ;;
      -q | --quiet)
        QUIET="true"
        shift
        ;;
      --force)
        FORCE="true"
        shift
        ;;
      --gen-passphrase)
        GEN_NEW="true"
        shift
        ;;
      --remove-maint-pass)
        REMOVE_MAINT="true"
        shift
        ;;
      --device)
        [[ $# -ge 2 ]] || {
          err "--device requires a value"
          exit "$EXIT_USAGE"
        }
        DEVICE="$2"
        shift 2
        ;;
      --key)
        [[ $# -ge 2 ]] || {
          err "--key requires a value"
          exit "$EXIT_USAGE"
        }
        KEY_PATH="$2"
        shift 2
        ;;
      --root)
        [[ $# -ge 2 ]] || {
          err "--root requires a value"
          exit "$EXIT_USAGE"
        }
        [[ -d "$2" ]] || {
          err "Not a directory: $2"
          exit "$EXIT_USAGE"
        }
        ROOT_PREFIX="${2%/}"
        shift 2
        ;;
      --backup-dir)
        [[ $# -ge 2 ]] || {
          err "--backup-dir requires a directory"
          exit "$EXIT_USAGE"
        }
        [[ -d "$2" ]] || {
          err "Not a directory: $2"
          exit "$EXIT_USAGE"
        }
        BACKUP_DIR="${2%/}"
        shift 2
        ;;
      --cab)
        [[ $# -ge 2 ]] || {
          err "--cab requires a value"
          exit "$EXIT_USAGE"
        }
        [[ -r "$2" ]] || {
          err "Cannot read capsule: $2"
          exit "$EXIT_USAGE"
        }
        CAB_PATH="$2"
        shift 2
        ;;
      --new-passphrase-out)
        [[ $# -ge 2 ]] || {
          err "--new-passphrase-out requires a file path"
          exit "$EXIT_USAGE"
        }
        [[ -d "$2" ]] && {
          err "--new-passphrase-out points at a directory: $2"
          exit "$EXIT_USAGE"
        }
        NEW_PASS_OUT="$2"
        shift 2
        ;;
      --passphrase)
        [[ $# -ge 2 ]] || {
          err "--passphrase requires a value"
          exit "$EXIT_USAGE"
        }
        PASSPHRASE="$2"
        shift 2
        ;;
      --passphrase-file)
        [[ $# -ge 2 ]] || {
          err "--passphrase-file requires a value"
          exit "$EXIT_USAGE"
        }
        [[ -r "$2" ]] || {
          err "Cannot read passphrase file: $2"
          exit "$EXIT_USAGE"
        }
        PASSPHRASE="$(head -n 1 "$2")"
        shift 2
        ;;
      --passphrase-stdin)
        # Deferred: reading here would block --help on a terminal with
        # nothing piped in
        PASSPHRASE_STDIN="true"
        shift
        ;;
      --maint-passphrase)
        [[ $# -ge 2 ]] || {
          err "--maint-passphrase requires a value"
          exit "$EXIT_USAGE"
        }
        MAINT_PASSPHRASE="$2"
        shift 2
        ;;
      --maint-passphrase-file)
        [[ $# -ge 2 ]] || {
          err "--maint-passphrase-file requires a value"
          exit "$EXIT_USAGE"
        }
        [[ -r "$2" ]] || {
          err "Cannot read passphrase file: $2"
          exit "$EXIT_USAGE"
        }
        MAINT_FILE="$2"
        shift 2
        ;;
      *)
        err "Unknown option: $1"
        err "Use --help for usage information"
        exit "$EXIT_USAGE"
        ;;
    esac
  done

  if [[ -z "$PASSPHRASE" && -n "${GI_PASSPHRASE:-}" ]]; then
    PASSPHRASE="$GI_PASSPHRASE"
  fi
  if [[ -z "$MAINT_PASSPHRASE" && -n "${GI_MAINT_PASSPHRASE:-}" ]]; then
    MAINT_PASSPHRASE="$GI_MAINT_PASSPHRASE"
  fi

  # A path given by hand wins over one this script would make for itself:
  # the operator named where the drawn passphrase has to survive.
  if [[ -z "$MAINT_FILE" && -n "$NEW_PASS_OUT" ]]; then
    MAINT_FILE="$NEW_PASS_OUT"
  fi

  if [[ -n "$NEW_PASS_OUT" && "$GEN_NEW" != "true" ]]; then
    err "--new-passphrase-out only applies to --gen-passphrase"
    err "A passphrase you already hold does not need to be written back"
    exit "$EXIT_USAGE"
  fi

  # Unattended, luks-addkey.sh skips the typed read-back and nothing shows
  # the drawn passphrase to anyone. The clevis binding is removed at the end
  # of prepare, so a passphrase held nowhere is a machine that opens for
  # nobody at the next boot.
  if [[ "$GEN_NEW" == "true" && "$FORCE" == "true" && -z "$NEW_PASS_OUT" ]]; then
    err "--gen-passphrase with --force requires --new-passphrase-out"
    err "  Nobody watches the screen, and prepare ends by taking the"
    err "  clevis binding away. The file is then the only thing that"
    err "  holds the passphrase this machine will ask for."
    err "    ./bios-maint.sh prepare --gen-passphrase \\"
    err "        --new-passphrase-out /mnt/usb/maint.txt --force"
    exit "$EXIT_USAGE"
  fi
}

check_root() {
  if [[ $EUID -ne 0 ]]; then
    die "Need root access. Run: sudo -i"
  fi
}

confirm() {
  local question="$1" default="${2:-N}" answer=""

  if [[ "$FORCE" == "true" ]]; then
    warn "$question -> auto-yes (--force)"
    return 0
  fi

  if [[ "$default" == "Y" ]]; then
    printf '%s (Y/n): ' "$question" >&2
    read -r answer || return 1
    [[ "$answer" != "n" && "$answer" != "N" ]]
  else
    printf '%s (y/N): ' "$question" >&2
    read -r answer || return 1
    [[ "$answer" == "y" || "$answer" == "Y" ]]
  fi
}

################################################################################
# Prerequisites and the container
################################################################################

init_err_log() {
  : >"$ERR_LOG"
  chmod 600 "$ERR_LOG" 2>/dev/null || true
}

check_tools() {
  local missing=0 t
  for t in cryptsetup clevis; do
    command -v "$t" >/dev/null 2>&1 || {
      err "  missing: $t"
      missing=$((missing + 1))
    }
  done
  if [[ $missing -gt 0 ]]; then
    err "$missing tool(s) missing"
    err "clevis lives in the installed system, not on the LiveCD."
    err "Run this on the machine itself, or from inside its chroot."
    return 1
  fi
  return 0
}

normalize_device() {
  local input="${1:-}"
  input="${input%/}"
  input="${input#/dev/}"
  echo "$input"
}

journal_device() {
  # The container the installer recorded, when there is a journal to read and
  # the device it names is still a container.
  #
  # The journal is a fact about this machine and the enumeration below is a
  # search, so the fact comes first. It is checked rather than trusted: a disk
  # is /dev/vda2 to the machine that was installed and can be /dev/sdb2 to the
  # rescue medium looking at it, and a name that no longer points at a LUKS
  # header is worth less than the search.
  local file="${ROOT_PREFIX}/var/lib/gentoo-install/state" dev
  [[ -r "$file" ]] || return 1
  dev="$(sed -n 's/^crypt\.device=//p' "$file" | tail -n 1)"
  [[ -n "$dev" && -b "$dev" ]] || return 1
  cryptsetup isLuks "$dev" 2>/dev/null || return 1
  printf '%s\n' "$dev"
}

resolve_device() {
  local dev pv name

  if [[ -n "$DEVICE" ]]; then
    dev="/dev/$(normalize_device "$DEVICE")"
    [[ -b "$dev" ]] || {
      err "Device not found: $dev"
      return 1
    }
    cryptsetup isLuks "$dev" 2>/dev/null || {
      err "$dev is not a LUKS container"
      return 1
    }
    echo "$dev"
    return 0
  fi

  # What the installer recorded about this machine, before searching for it.
  if dev="$(journal_device)"; then
    log "Container from the install journal: $dev"
    echo "$dev"
    return 0
  fi

  # Every volume group on this machine, not one named in advance.
  #
  # This asked vgs about "vg1", which is the group the machine this tooling
  # grew up on happened to have. gentoo-install creates vg0, and a layout
  # without LVM has no group at all, so on the machines this project installs
  # the answer was always "Cannot tell which container to check" — which is
  # exactly the moment an operator does not want to be told to work it out.
  #
  # A group whose physical volume is an open LUKS mapper is a group inside a
  # container, whatever it is called. One of those is an answer; several is a
  # question only the operator can settle.
  local -a found=()
  local group
  while read -r group; do
    [[ -n "$group" ]] || continue
    # vgs, not pvs: pvs takes physical volumes as arguments, not a group name
    pv="$(vgs --noheadings -o pv_name "$group" 2>/dev/null | tr -d ' ' | head -n 1)"
    [[ -n "$pv" && "$pv" == /dev/mapper/* ]] || continue
    name="$(basename "$pv")"
    dev="$(cryptsetup status "$name" 2>/dev/null | awk '/device:/ {print $2}')"
    if [[ -z "$dev" ]] || ! cryptsetup isLuks "$dev" 2>/dev/null; then
      continue
    fi
    found+=("${group}:${dev}")
  done < <(vgs --noheadings -o vg_name 2>/dev/null | tr -d ' ')

  if ((${#found[@]} == 1)); then
    group="${found[0]%%:*}"
    dev="${found[0]#*:}"
    log "Container from the ${group} volume group: $dev"
    echo "$dev"
    return 0
  fi
  if ((${#found[@]} > 1)); then
    err "More than one volume group sits inside a LUKS container:"
    for group in "${found[@]}"; do
      err "  ${group%%:*} on ${group#*:}"
    done
    err "Name the one you mean with --device"
    return 1
  fi

  err "Cannot tell which container to work on. Name it with --device"
  return 1
}

resolve_passphrase() {
  # Nothing is prompted here. Every delegated tool asks for the secret it
  # needs, with the wording that names which one it is, and a prompt in
  # front of theirs would only make the operator answer the same question
  # twice. This reads stdin, which is the one source that cannot be handed
  # down to a child.
  if [[ "$PASSPHRASE_STDIN" == "true" && -z "$PASSPHRASE" ]]; then
    IFS= read -r PASSPHRASE || true
    [[ -n "$PASSPHRASE" ]] || {
      err "--passphrase-stdin was given but stdin held nothing"
      return 1
    }
  fi
  return 0
}

secure_tmpdir() {
  # The decrypted key must not land on a persistent filesystem. Which
  # directory is in RAM depends on where this runs, and the cases are
  # opposites: on a booted machine /run is a tmpfs and /tmp sits on the root
  # LV, while inside a chroot whichever of the two the live environment bound
  # in is the one in RAM and the other is the target's own directory, on disk.
  # Asking the filesystem is the only answer that is right in every case.
  local d fstype
  for d in /run /dev/shm /tmp; do
    if [[ ! -d "$d" || ! -w "$d" ]]; then
      continue
    fi
    fstype=""
    if command -v findmnt >/dev/null 2>&1; then
      fstype="$(findmnt -no FSTYPE --target "$d" 2>/dev/null || true)"
    elif command -v stat >/dev/null 2>&1; then
      fstype="$(stat -f -c %T "$d" 2>/dev/null || true)"
    fi
    if [[ "$fstype" == "tmpfs" ]]; then
      echo "$d"
      return 0
    fi
  done

  # Nothing in RAM. Said out loud rather than written somewhere persistent
  # behind the operator's back: a removed file is not an erased one.
  warn "No tmpfs among /run, /dev/shm and /tmp"
  warn "  The decrypted key will touch a persistent filesystem for the time"
  warn "  this runs. It is removed on exit, deleted is not erased."
  echo "/tmp"
  return 0
}

make_temp_pass_file() {
  # luks-addkey.sh writes the drawn passphrase there, and this script hands
  # the path straight to luks-check.sh so the proof needs no retyping. It
  # never reads the file itself.
  TEMP_PASS_FILE="$(umask 077 && mktemp "$(secure_tmpdir)/gentoo-install-bios-maint-pass.XXXXXX")" || {
    err "Cannot create a temporary file for the drawn passphrase"
    return 1
  }
  trap 'rm -f "${TEMP_PASS_FILE:-}"' EXIT INT TERM
  return 0
}

################################################################################
# The sibling tools
################################################################################

tool_path() {
  # Two statements: local expands all of its arguments before any of them has
  # taken effect, so a second one reading the first sees the caller's variable
  # of that name instead of this one. bios-update.sh carries the same note.
  local name="$1" path
  path="$SCRIPT_DIR/$name"
  if [[ ! -x "$path" ]]; then
    err "Missing: $path"
    return 1
  fi
  echo "$path"
  return 0
}

check_siblings() {
  # Looked up beside this script, never in PATH: a copy found in PATH could
  # be another version of the box, and two versions of what a clevis slot is
  # would be worse than a missing file.
  local missing=0 t
  for t in "$@"; do
    [[ -x "$SCRIPT_DIR/$t" ]] || {
      err "  missing: $SCRIPT_DIR/$t"
      missing=$((missing + 1))
    }
  done
  if [[ $missing -gt 0 ]]; then
    err "$missing tool(s) of the box missing next to bios-maint.sh"
    err "This script implements none of what they do: without them there"
    err "is nothing to orchestrate. Copy the whole tools/ directory over."
    return 1
  fi
  return 0
}

common_args() {
  # Every delegated call carries the same context. Two tools of one run
  # looking at two different containers is how an operation ends up proving
  # something about a machine that was never touched.
  local dev="${1:-}"
  [[ "$QUIET" == "true" ]] && printf '%s\n' "-q"
  [[ -n "$dev" ]] && printf '%s\n' "--device" "$dev"
  [[ -n "$ROOT_PREFIX" ]] && printf '%s\n' "--root" "$ROOT_PREFIX"
  return 0
}

run_tool() {
  local name="$1" secret="$2" path rc=0
  shift 2

  path="$(tool_path "$name")" || return 1
  log "-> ./$name $*"

  if [[ -n "$secret" ]]; then
    # The secret travels in the child's environment, never in its argv:
    # GI_PASSPHRASE is the route every tool of the box already reads, and
    # an argument would sit in `ps` for as long as the child runs.
    (
      export GI_PASSPHRASE="$secret"
      "$path" "$@"
    ) || rc=$?
  else
    # Cleared, not merely left alone. This script handles two different
    # secrets, and a GI_PASSPHRASE exported by the operator would answer
    # the maintenance passphrase prompt with the one that opens
    # luks-key.gpg, then report the wrong slot as broken.
    (
      unset GI_PASSPHRASE
      "$path" "$@"
    ) || rc=$?
  fi
  return "$rc"
}

maint_source_args() {
  # A path, not a value: the maintenance passphrase is never read into this
  # script. luks-check.sh opens the file itself.
  [[ -n "$MAINT_FILE" && -r "$MAINT_FILE" ]] && printf '%s\n' "--passphrase-file" "$MAINT_FILE"
  return 0
}

step() {
  printf '\n' >&2
  printf '%s\n' "${C_B}=== Step $1: $2 ===${C_0}" >&2
  printf '\n' >&2
}

################################################################################
# The state, which has to survive the reboots
################################################################################

state_value() {
  # Read, not sourced: a state file is data. Sourcing it would run whatever
  # a stale or hand-edited file happens to contain. A key that is not there
  # returns 1 rather than an empty line, so a caller's "|| echo never" fires
  # instead of printing a blank where a date belongs.
  local name="$1" file="${ROOT_PREFIX}${STATE_FILE}" out
  [[ -r "$file" ]] || return 1
  out="$(sed -n "s/^${name}=\(.*\)\$/\1/p" "$file" | tail -n 1)"
  [[ -n "$out" ]] || return 1
  echo "$out"
  return 0
}

when() {
  # Epochs are what the state file carries, because they compare. An
  # operator reading a report wants a date.
  local ts="${1:-}"
  [[ "$ts" =~ ^[0-9]+$ ]] || {
    echo "never"
    return 0
  }
  date -d "@$ts" -Is 2>/dev/null || echo "$ts"
  return 0
}

current_state() {
  local s
  s="$(state_value state 2>/dev/null || true)"
  [[ -n "$s" ]] || s="none"
  echo "$s"
}

state_set() {
  local name="$1" value="$2"
  local file="${ROOT_PREFIX}${STATE_FILE}" dir="${ROOT_PREFIX}${STATE_DIR}" tmp

  if ! mkdir -p "$dir" 2>>"$ERR_LOG"; then
    err "Cannot create $dir, the state cannot be kept"
    err "  Every command that follows would refuse for lack of it."
    sed 's/^/    /' "$ERR_LOG" >&2 2>/dev/null || true
    return 1
  fi
  if [[ ! -e "$file" ]]; then
    (umask 077 && echo "# gentoo-install bios-maint.sh state, do not edit" >"$file") 2>>"$ERR_LOG" || {
      err "Cannot write $file"
      sed 's/^/    /' "$ERR_LOG" >&2 2>/dev/null || true
      return 1
    }
  fi

  tmp="${file}.new"
  (umask 077 && grep -v "^${name}=" "$file" >"$tmp") 2>>"$ERR_LOG" || true
  echo "${name}=${value}" >>"$tmp"
  mv -f "$tmp" "$file" 2>>"$ERR_LOG" || {
    err "Cannot update $file"
    return 1
  }
  chmod 600 "$file" 2>/dev/null || true
  return 0
}

state_stamp() {
  local new="$1"
  state_set state "$new" || return 1
  state_set updated "$(date +%s)" || return 1
  state_set updated_iso "$(date -Is)" || return 1
  return 0
}

next_command() {
  case "$1" in
    none | aborted | done) echo "./bios-maint.sh prepare --backup-dir DIR" ;;
    preparing) echo "./bios-maint.sh abort" ;;
    prepared) echo "reboot, unlock with the maintenance passphrase, then ./bios-maint.sh verify-boot" ;;
    boot-proven) echo "./bios-maint.sh flash --cab FILE" ;;
    flashed) echo "reboot, then ./bios-maint.sh rebind" ;;
    rebound) echo "reboot to see it unlock on its own, then ./bios-maint.sh cleanup" ;;
    *) echo "./bios-maint.sh status" ;;
  esac
}

print_position() {
  local cur="$1"
  err "The operation stands at: $cur"
  err "  Next: $(next_command "$cur")"
  return 0
}

require_state() {
  # Each command refuses on any state but the one it follows. A sequence run
  # out of order is what the whole file exists to prevent, and a refusal
  # that does not say where the operation stands sends the operator guessing.
  local want cur
  cur="$(current_state)"
  for want in "$@"; do
    [[ "$cur" == "$want" ]] && return 0
  done

  err "'$SUBCOMMAND' runs only from: $*"
  if [[ "$cur" == "none" ]]; then
    err "  Nothing has been prepared on this machine yet."
    err "  There is no ${ROOT_PREFIX}${STATE_FILE}."
  fi
  print_position "$cur"
  return 1
}

require_same_machine() {
  # A state file naming another container came over on a stick, or was left
  # behind by a reprovisioning. Going on with it would prove things about a
  # machine that is not here.
  local dev="$1" recorded current
  recorded="$(state_value luks_uuid 2>/dev/null || true)"
  [[ -n "$recorded" ]] || return 0
  current="$(cryptsetup luksUUID "$dev" 2>/dev/null || true)"
  [[ "$recorded" == "$current" ]] && return 0

  err "The state file belongs to another container"
  err "  state file  : $recorded"
  err "  this machine: ${current:-unreadable}"
  err "  This is not the machine the sequence was started on. Refusing."
  return 1
}

################################################################################
# Facts read off the machine
################################################################################

slot_list() {
  # Read-only. The orchestrator has to record which slot the maintenance
  # passphrase landed in, and cryptsetup names no slot when luks-addkey.sh
  # lets it choose one. Bounded to the Keyslots section: Data segments,
  # Tokens and Digests use the same "  N: type" shape.
  local out=""
  out="$(cryptsetup luksDump "$1" 2>/dev/null | awk '
        /^Keyslots:/ { in_slots = 1; next }
        /^[A-Za-z]/  { in_slots = 0 }
        in_slots && /^  [0-9]+:/ { sub(":", "", $1); print $1 }')" || true
  printf '%s\n' "$out" | tr '\n' ' '
  return 0
}

added_slot() {
  local before="$1" after="$2" s
  for s in $after; do
    case " $before " in
      *" $s "*) ;;
      *)
        echo "$s"
        return 0
        ;;
    esac
  done
  return 1
}

clevis_slot_of() {
  # Read from clevis rather than assumed. A machine bound to another slot
  # would otherwise have its binding recorded against a slot it never owned.
  local dev="$1" s
  command -v clevis >/dev/null 2>&1 || return 1
  s="$(clevis luks list -d "$dev" 2>/dev/null | head -n 1 | cut -d: -f1 | tr -d ' ' || true)"
  [[ "$s" =~ ^[0-9]+$ ]] || return 1
  echo "$s"
  return 0
}

boot_id() {
  # Changes at every boot and at nothing else, which is exactly the question
  # verify-boot asks. Uptime answers it too, and lies across a suspend.
  local id=""
  [[ -r /proc/sys/kernel/random/boot_id ]] && id="$(cat /proc/sys/kernel/random/boot_id 2>/dev/null || true)"
  echo "${id:-unknown}"
  return 0
}

bios_version() {
  local v=""
  [[ -r /sys/class/dmi/id/bios_version ]] && v="$(tr -d '\n' </sys/class/dmi/id/bios_version 2>/dev/null || true)"
  echo "${v:-unknown}"
  return 0
}

newest_header() {
  # The name luks-header.sh writes carries a timestamp, so the newest .bin
  # in the directory is the one it has just made. Asking the directory beats
  # rebuilding the file name here and getting its format wrong a year later.
  local dir="$1" newest=""
  newest="$(find "$dir" -maxdepth 1 -type f -name '*.bin' -printf '%T@ %p\n' 2>/dev/null \
    | sort -rn | head -n 1 | cut -d' ' -f2- || true)"
  [[ -n "$newest" ]] || return 1
  echo "$newest"
  return 0
}

mark() {
  local done_at="$1"
  if [[ -n "$done_at" ]]; then
    printf '%s' "${C_G}done${C_0}"
  else
    printf '%s' "pending"
  fi
  return 0
}

################################################################################
# Commands
################################################################################

do_plan() {
  local cur dev

  cur="$(current_state)"
  dev="$(resolve_device 2>/dev/null || true)"

  # A report has to stay readable on a machine that has no container at all,
  # so the detection failure is soft. A --device typed by hand is different:
  # it was named, and saying nothing about it would read as agreement.
  if [[ -z "$dev" && -n "$DEVICE" ]]; then
    warn "--device $DEVICE resolved to no LUKS container"
  fi

  echo ""
  printf '%s\n' "${C_B}=== The manoeuvre, in order ===${C_0}"
  echo ""
  echo "  The TPM still works today. That is the only moment when a way into"
  echo "  this machine can be had for free, and the flash is what ends it."
  echo ""
  printf "  %-14s %s\n" "prepare" "credential from the TPM, maintenance passphrase,"
  printf "  %-14s %s\n" "" "its proof, header backup, PCR snapshot, clevis off"
  printf "  %-14s %s\n" "-> reboot" "the machine has to ask for a passphrase"
  printf "  %-14s %s\n" "verify-boot" "it asked, and the maintenance slot answered"
  printf "  %-14s %s\n" "flash" "bios-update.sh preflight, then the capsule"
  printf "  %-14s %s\n" "-> reboot" "passphrase again, PCR 0 has moved"
  printf "  %-14s %s\n" "rebind" "which PCR moved, then reseal against them"
  printf "  %-14s %s\n" "-> reboot" "the machine unlocks on its own again"
  printf "  %-14s %s\n" "cleanup" "close it. The maintenance passphrase stays"
  echo ""
  echo "  The reboot before the flash is the whole point. It proves there is"
  echo "  no LiveUSB in this operation, instead of hoping there is not."
  echo ""

  printf '%s\n' "${C_B}=== Where this machine stands ===${C_0}"
  echo ""
  printf "  %-22s %s\n" "Container:" "${dev:-not found}"
  printf "  %-22s %s\n" "State:" "$cur"
  printf "  %-22s %s\n" "State file:" "${ROOT_PREFIX}${STATE_FILE}"
  echo ""
  printf "  %-22s %s\n" "prepare" "$(mark "$(state_value clevis_removed 2>/dev/null || true)")"
  printf "  %-22s %s\n" "verify-boot" "$(mark "$(state_value boot_proven 2>/dev/null || true)")"
  printf "  %-22s %s\n" "flash" "$(mark "$(state_value flashed 2>/dev/null || true)")"
  printf "  %-22s %s\n" "rebind" "$(mark "$(state_value rebound 2>/dev/null || true)")"
  printf "  %-22s %s\n" "cleanup" "$(mark "$(state_value closed 2>/dev/null || true)")"
  echo ""
  echo "  Next: $(next_command "$cur")"
  echo ""
  echo "  This command changed nothing. It is the default so that typing the"
  echo "  name of the script with no argument starts nothing."
  echo ""
}

do_status() {
  local cur dev file line

  cur="$(current_state)"
  dev="$(resolve_device 2>/dev/null || true)"
  file="${ROOT_PREFIX}${STATE_FILE}"

  if [[ -z "$dev" && -n "$DEVICE" ]]; then
    warn "--device $DEVICE resolved to no LUKS container"
  fi

  echo ""
  printf '%s\n' "${C_B}=== BIOS maintenance ===${C_0}"
  echo ""
  printf "  %-22s %s\n" "State:" "$cur"
  printf "  %-22s %s\n" "Since:" "$(state_value updated_iso 2>/dev/null || echo never)"
  printf "  %-22s %s\n" "Container now:" "${dev:-not found}"
  printf "  %-22s %s\n" "Recorded container:" "$(state_value device 2>/dev/null || echo none)"
  printf "  %-22s %s\n" "Recorded LUKS UUID:" "$(state_value luks_uuid 2>/dev/null || echo none)"
  echo ""

  if [[ ! -r "$file" ]]; then
    echo "  No state file at $file."
    echo "  Nothing has been prepared on this machine, or this is not the"
    echo "  machine it was prepared on."
    echo ""
    echo "  Next: $(next_command "$cur")"
    echo ""
    return 0
  fi

  printf '%s\n' "${C_B}=== What was proven, and when ===${C_0}"
  echo ""
  printf "  %-22s %s\n" "Maintenance slot:" "$(state_value maint_slot 2>/dev/null || echo none)"
  printf "  %-22s %s\n" "Slot proven at:" "$(when "$(state_value maint_proven 2>/dev/null || true)")"
  printf "  %-22s %s\n" "Clevis slot recorded:" "$(state_value clevis_slot 2>/dev/null || echo none)"
  printf "  %-22s %s\n" "Clevis removed at:" "$(when "$(state_value clevis_removed 2>/dev/null || true)")"
  printf "  %-22s %s\n" "Boot proven at:" "$(when "$(state_value boot_proven 2>/dev/null || true)")"
  printf "  %-22s %s\n" "Flashed at:" "$(when "$(state_value flashed 2>/dev/null || true)")"
  printf "  %-22s %s\n" "Rebound at:" "$(when "$(state_value rebound 2>/dev/null || true)")"
  printf "  %-22s %s\n" "Header backup:" "$(state_value header_backup 2>/dev/null || echo none)"
  printf "  %-22s %s\n" "PCR snapshot tag:" "$(state_value pcr_tag 2>/dev/null || echo none)"
  printf "  %-22s %s\n" "BIOS before:" "$(state_value bios_before 2>/dev/null || echo unknown)"
  printf "  %-22s %s\n" "BIOS now:" "$(bios_version)"
  echo ""

  if [[ -n "$dev" ]]; then
    line="$(clevis_slot_of "$dev" 2>/dev/null || true)"
    if [[ -n "$line" ]]; then
      printf "  %-22s %s\n" "Clevis binding now:" "${C_G}present, slot $line${C_0}"
    else
      printf "  %-22s %s\n" "Clevis binding now:" "${C_Y}none${C_0}"
    fi
    printf "  %-22s %s\n" "Keyslots in use:" "$(slot_list "$dev")"
    echo ""
  fi

  echo "  Next: $(next_command "$cur")"
  echo ""
}

do_prepare() {
  local dev uuid clevis_slot maint header pass_out slots_before slots_after
  local -a base=() extra=()

  require_state none aborted "done" || exit "$EXIT_FAILURE"
  check_siblings luks-check.sh luks-addkey.sh luks-header.sh tpm-pcr.sh tpm-reseal.sh \
    || exit "$EXIT_FAILURE"
  check_tools || exit "$EXIT_FAILURE"
  resolve_passphrase || exit "$EXIT_FAILURE"

  if [[ -z "$BACKUP_DIR" ]]; then
    err "prepare has nowhere to write the header backup"
    err "  The header carries every keyslot, and it is the one accident no"
    err "  secret recovers from. Name a place off this machine's disk:"
    err "    ./bios-maint.sh prepare --backup-dir /mnt/usb"
    exit "$EXIT_USAGE"
  fi

  if [[ "$FORCE" == "true" && -z "$PASSPHRASE" ]]; then
    err "--force, but no passphrase was given"
    err "  luks-header.sh verify and tpm-reseal.sh unbind both need the"
    err "  one that opens luks-key.gpg, and neither can ask for it here."
    printf '\n' >&2
    printf '%s\n' "    GI_PASSPHRASE=\"\$PW\" ./bios-maint.sh prepare --force" >&2
    printf '%s\n' "    ./bios-maint.sh prepare --force --passphrase-file FILE" >&2
    printf '\n' >&2
    exit "$EXIT_USAGE"
  fi

  if [[ "$FORCE" == "true" && "$GEN_NEW" != "true" && -z "$MAINT_PASSPHRASE" && -z "$MAINT_FILE" ]]; then
    err "--force, but nothing says what the maintenance passphrase is"
    err "  Step 4 proves the new slot, and unattended it cannot be typed."
    err "  Draw one, or hand one over:"
    err "    --gen-passphrase --new-passphrase-out FILE"
    err "    --maint-passphrase-file FILE"
    exit "$EXIT_USAGE"
  fi

  dev="$(resolve_device)" || exit "$EXIT_FAILURE"
  uuid="$(cryptsetup luksUUID "$dev" 2>/dev/null || echo unknown)"

  clevis_slot="$(clevis_slot_of "$dev")" || clevis_slot=""
  if [[ -z "$clevis_slot" ]]; then
    err "No clevis binding on $dev"
    err "  There is nothing to take away before the flash and nothing to"
    err "  put back after it. This machine already asks for a passphrase"
    err "  at boot, so a flash changes nothing about how it opens:"
    err "    ./bios-update.sh preflight"
    exit "$EXIT_FAILURE"
  fi

  mapfile -t base < <(common_args "$dev")

  ok "Container     : $dev"
  ok "LUKS UUID     : $uuid"
  ok "Clevis slot   : $clevis_slot"
  ok "Header backup : $BACKUP_DIR"

  printf '\n' >&2
  warn "prepare adds a keyslot, saves the header, and removes the clevis"
  warn "binding. From the next boot on this machine asks for a passphrase."
  warn "Keyslot 0 is not touched: luks-key.gpg keeps opening the container,"
  warn "whatever happens between here and the end."
  if ! confirm "Start the BIOS maintenance on $dev?" "Y"; then
    log "Cancelled, nothing changed"
    exit "$EXIT_SUCCESS"
  fi

  init_err_log
  state_stamp "preparing" || exit "$EXIT_FAILURE"
  state_set device "$dev" || exit "$EXIT_FAILURE"
  state_set luks_uuid "$uuid" || exit "$EXIT_FAILURE"
  state_set clevis_slot "$clevis_slot" || exit "$EXIT_FAILURE"
  state_set prepare_boot_id "$(boot_id)" || exit "$EXIT_FAILURE"
  state_set bios_before "$(bios_version)" || exit "$EXIT_FAILURE"

  step "1/7" "The starting state, recorded before anything moves"
  run_tool luks-check.sh "$PASSPHRASE" report ${base[@]+"${base[@]}"} || true

  step "2/7" "The TPM still releases its key, while it still can"
  if ! run_tool luks-addkey.sh "$PASSPHRASE" test --from tpm ${base[@]+"${base[@]}"}; then
    err "The TPM does not release the key any more"
    err "  This is the incident, not its prevention: there is nothing left"
    err "  to prepare. Open the machine with luks-key.gpg and reseal:"
    err "    ./tpm-reseal.sh reseal"
    err "  Nothing has been changed."
    exit "$EXIT_FAILURE"
  fi

  step "3/7" "Adding the maintenance passphrase in a free slot"
  slots_before="$(slot_list "$dev")"
  pass_out=""
  extra=()
  if [[ "$GEN_NEW" == "true" ]]; then
    pass_out="$NEW_PASS_OUT"
    if [[ -z "$pass_out" ]]; then
      make_temp_pass_file || exit "$EXIT_FAILURE"
      pass_out="$TEMP_PASS_FILE"
    fi
    MAINT_FILE="$pass_out"
    extra+=(--gen-passphrase --new-passphrase-out "$pass_out")
  fi
  [[ "$FORCE" == "true" ]] && extra+=(--force)
  if ! run_tool luks-addkey.sh "$PASSPHRASE" add --from tpm --slot auto \
    ${base[@]+"${base[@]}"} ${extra[@]+"${extra[@]}"}; then
    err "The maintenance passphrase was not added"
    err "  Nothing else was done: the clevis binding is still in place and"
    err "  this machine still unlocks on its own."
    exit "$EXIT_FAILURE"
  fi

  slots_after="$(slot_list "$dev")"
  maint="$(added_slot "$slots_before" "$slots_after")" || {
    err "Cannot tell which keyslot was written"
    err "  The passphrase may well be there, but a slot nobody can name"
    err "  cannot be proven later, and cleanup would have nothing to aim"
    err "  at. Look at the slots, then abort:"
    err "    ./luks-addkey.sh slots --device $dev"
    exit "$EXIT_FAILURE"
  }
  state_set maint_slot "$maint" || exit "$EXIT_FAILURE"
  ok "The maintenance passphrase went into keyslot $maint"

  step "4/7" "Proving that keyslot $maint really opens $dev"
  mapfile -t extra < <(maint_source_args)
  if [[ ${#extra[@]} -eq 0 && -z "$MAINT_PASSPHRASE" ]]; then
    log "luks-check.sh asks next: type the maintenance passphrase, not the"
    log "  one that opens luks-key.gpg"
  fi
  if ! run_tool luks-check.sh "$MAINT_PASSPHRASE" testpass --key-slot "$maint" \
    ${base[@]+"${base[@]}"} ${extra[@]+"${extra[@]}"}; then
    err "Keyslot $maint does not open with that passphrase"
    err "  Nothing has been removed. The clevis binding is still there and"
    err "  the machine still unlocks on its own. A slot too many costs"
    err "  nothing, a slot too few costs the machine."
    err "  Take the extra slot away once you know why:"
    err "    ./luks-addkey.sh remove --slot $maint --device $dev"
    exit "$EXIT_FAILURE"
  fi
  state_set maint_proven "$(date +%s)" || exit "$EXIT_FAILURE"

  step "5/7" "Saving the header, now that it carries the new slot"
  if ! run_tool luks-header.sh "$PASSPHRASE" backup --out "$BACKUP_DIR" ${base[@]+"${base[@]}"}; then
    err "The header was not saved"
    err "  Nothing has been removed: the binding is still in place."
    exit "$EXIT_FAILURE"
  fi
  header="$(newest_header "$BACKUP_DIR")" || {
    err "No header file in $BACKUP_DIR after the backup"
    err "  Nothing has been removed."
    exit "$EXIT_FAILURE"
  }
  if ! run_tool luks-header.sh "$PASSPHRASE" verify "$header" ${base[@]+"${base[@]}"}; then
    err "The header backup could not be verified"
    err "  A backup nobody ever verified is not a backup, and a binding is"
    err "  not removed on the strength of one. Nothing has been removed."
    exit "$EXIT_FAILURE"
  fi
  state_set header_backup "$header" || exit "$EXIT_FAILURE"
  state_set header_sha "$(sha256sum "$header" 2>/dev/null | awk '{print $1}' || echo unknown)" \
    || exit "$EXIT_FAILURE"

  step "6/7" "Freezing the PCR values under the tag $PCR_TAG"
  if ! run_tool tpm-pcr.sh "" snapshot --tag "$PCR_TAG" ${base[@]+"${base[@]}"}; then
    err "No PCR snapshot was taken"
    err "  Without a reading from before the flash, 'which PCR moved' has"
    err "  no answer afterwards and rebind becomes a guess."
    err "  Nothing has been removed."
    exit "$EXIT_FAILURE"
  fi
  state_set pcr_tag "$PCR_TAG" || exit "$EXIT_FAILURE"

  step "7/7" "Removing the clevis binding, before the flash and not after"
  printf '\n' >&2
  warn "This is the destructive step, and it is the one that is reversible:"
  warn "./bios-maint.sh abort puts the binding back. What is not reversible"
  warn "is flashing with the binding still on, which is the August 2026 case."
  extra=()
  [[ "$FORCE" == "true" ]] && extra+=(--force)
  [[ -n "$KEY_PATH" ]] && extra+=(--key "$KEY_PATH")
  if ! run_tool tpm-reseal.sh "$PASSPHRASE" unbind --slot "$clevis_slot" \
    ${base[@]+"${base[@]}"} ${extra[@]+"${extra[@]}"}; then
    err "The clevis binding is still in place"
    err "  Everything before this held: keyslot $maint carries the"
    err "  maintenance passphrase and the header is saved. Nothing is lost."
    err "  Go back to a clean state with: ./bios-maint.sh abort"
    exit "$EXIT_FAILURE"
  fi
  state_set clevis_removed "$(date +%s)" || exit "$EXIT_FAILURE"
  state_stamp "prepared" || exit "$EXIT_FAILURE"

  # The one failure this whole sequence is arranged around, said out loud at
  # the moment the operator is about to reboot into it.
  printf '\n' >&2
  warn "At the next boot this machine must ASK for a passphrase."
  warn "  If it boots straight through, or hangs without a prompt, do not"
  warn "  flash. In August the initramfs failed on the TPM and offered no"
  warn "  usable prompt even though the slot was valid, and dracut has not"
  warn "  been cleared since. Keyslot 0 and luks-key.gpg are untouched, so a"
  warn "  LiveUSB still opens this machine, with ./luks-open.sh open."
  warn "  Then ./bios-maint.sh abort puts the clevis binding back."

  if [[ -n "$NEW_PASS_OUT" ]]; then
    printf '\n' >&2
    warn "$NEW_PASS_OUT holds the maintenance passphrase in clear, mode 600."
    warn "  Put it in the password manager entry of this machine, then remove it."
  fi

  if verbose_enough; then
    echo ""
    printf '%s\n' "${C_G}==================================================${C_0}"
    printf '%s\n' "${C_G}  Prepared${C_0}"
    printf '%s\n' "${C_G}==================================================${C_0}"
    echo ""
    echo "  Keyslot $maint  holds the maintenance passphrase, proven here."
    echo "  Header      : $header"
    echo "  PCR frozen  : tag $PCR_TAG"
    echo "  Clevis      : removed from slot $clevis_slot"
    echo ""
    echo "  Reboot now. The machine will ask for a passphrase: type the"
    echo "  maintenance one. Then, once it is up:"
    echo ""
    echo "    ./bios-maint.sh verify-boot"
    echo ""
    echo "  Do not flash before that. The reboot is what turns 'it should"
    echo "  open' into 'it opened', and flash refuses without it."
    echo ""
  else
    ok "Prepared on $dev: maintenance slot $maint, clevis slot $clevis_slot removed"
  fi
}

do_verify_boot() {
  local dev maint recorded now_boot
  local -a base=() extra=()

  require_state prepared || exit "$EXIT_FAILURE"
  check_siblings luks-check.sh || exit "$EXIT_FAILURE"
  check_tools || exit "$EXIT_FAILURE"
  resolve_passphrase || exit "$EXIT_FAILURE"

  dev="$(resolve_device)" || exit "$EXIT_FAILURE"
  require_same_machine "$dev" || exit "$EXIT_FAILURE"
  mapfile -t base < <(common_args "$dev")

  maint="$(state_value maint_slot 2>/dev/null || true)"
  if [[ ! "$maint" =~ ^[0-9]+$ ]]; then
    err "The state file names no maintenance slot"
    err "  There is nothing to prove this boot against. Start again:"
    err "    ./bios-maint.sh abort, then ./bios-maint.sh prepare"
    exit "$EXIT_FAILURE"
  fi

  # The reboot is the subject of this command, so it is checked and not taken
  # on trust. The boot id changes at every boot and at nothing else.
  recorded="$(state_value prepare_boot_id 2>/dev/null || true)"
  now_boot="$(boot_id)"
  if [[ -n "$recorded" && "$recorded" == "$now_boot" ]]; then
    err "This is still the boot that prepare ran in"
    err "  Nothing has been proven. Reboot the machine, unlock it with the"
    err "  maintenance passphrase, and run this again from the machine"
    err "  that came up."
    exit "$EXIT_FAILURE"
  fi

  # A binding again means somebody resealed in between, and this boot could
  # have come from the TPM. It would say nothing about the passphrase.
  if clevis_slot_of "$dev" >/dev/null 2>&1; then
    err "There is a clevis binding on $dev again"
    err "  This boot may well have come from the TPM, so it proves nothing"
    err "  about the maintenance passphrase, which is the only thing that"
    err "  will be left once the flash moves PCR 0."
    err "  Start the sequence again: ./bios-maint.sh abort"
    exit "$EXIT_FAILURE"
  fi

  ok "Container : $dev"
  ok "No clevis binding: this boot came from a typed passphrase"

  step "1/1" "Proving keyslot $maint is the one that answered"
  mapfile -t extra < <(maint_source_args)
  if ! run_tool luks-check.sh "$MAINT_PASSPHRASE" testpass --key-slot "$maint" \
    ${base[@]+"${base[@]}"} ${extra[@]+"${extra[@]}"}; then
    err "Keyslot $maint does not open with that passphrase"
    err "  The machine did come up without clevis, so something opened it,"
    err "  but not the slot this sequence counted on. Find out which one"
    err "  before flashing anything:"
    err "    ./luks-check.sh testpass --which-slot --device $dev"
    exit "$EXIT_FAILURE"
  fi

  init_err_log
  state_set boot_proven "$(date +%s)" || exit "$EXIT_FAILURE"
  state_set boot_id "$now_boot" || exit "$EXIT_FAILURE"
  state_stamp "boot-proven" || exit "$EXIT_FAILURE"

  if verbose_enough; then
    echo ""
    printf '%s\n' "${C_G}==================================================${C_0}"
    printf '%s\n' "${C_G}  Boot proven${C_0}"
    printf '%s\n' "${C_G}==================================================${C_0}"
    echo ""
    echo "  This machine came up with no TPM path at all, and keyslot $maint"
    echo "  opened it. The flash can now move PCR 0 as much as it likes:"
    echo "  there is a way in that does not go through the TPM, and it was"
    echo "  not assumed, it was used."
    echo ""
    echo "  Next: ./bios-maint.sh flash --cab /opt/firmware.cab"
    echo ""
  else
    ok "Boot proven on $dev with keyslot $maint"
  fi
}

do_flash() {
  local dev backup
  local -a base=() extra=()

  require_state boot-proven || exit "$EXIT_FAILURE"
  check_siblings bios-update.sh || exit "$EXIT_FAILURE"
  resolve_passphrase || exit "$EXIT_FAILURE"

  if [[ -z "$CAB_PATH" ]]; then
    err "flash needs the capsule"
    err "  ./bios-maint.sh flash --cab /opt/firmware.cab"
    exit "$EXIT_USAGE"
  fi

  dev="$(resolve_device)" || exit "$EXIT_FAILURE"
  require_same_machine "$dev" || exit "$EXIT_FAILURE"
  mapfile -t base < <(common_args "$dev")

  # The preflight checks the header backup, and prepare already wrote one.
  # Pointing at it beats asking the operator to retype a path the state
  # file has been carrying since step 5.
  backup="$BACKUP_DIR"
  if [[ -z "$backup" ]]; then
    backup="$(state_value header_backup 2>/dev/null || true)"
    [[ -n "$backup" ]] && backup="$(dirname "$backup")"
  fi

  extra=()
  [[ -n "$backup" && -d "$backup" ]] && extra+=(--backup-dir "$backup")
  [[ "$FORCE" == "true" ]] && extra+=(--force)

  step "1/2" "Preflight, which writes the attestation flash reads"
  if ! run_tool bios-update.sh "$PASSPHRASE" preflight --cab "$CAB_PATH" \
    ${base[@]+"${base[@]}"} ${extra[@]+"${extra[@]}"}; then
    err "The preflight did not pass"
    err "  Nothing was flashed. Fix what it reported and run this again."
    exit "$EXIT_FAILURE"
  fi

  step "2/2" "Flashing, under that attestation"
  if ! run_tool bios-update.sh "$PASSPHRASE" flash --cab "$CAB_PATH" \
    ${base[@]+"${base[@]}"} ${extra[@]+"${extra[@]}"}; then
    err "The flash did not complete"
    err "  The maintenance passphrase still opens this machine, which is"
    err "  what prepare and verify-boot were for. Read the fwupd output"
    err "  above before trying again."
    exit "$EXIT_FAILURE"
  fi

  init_err_log
  state_set flashed "$(date +%s)" || exit "$EXIT_FAILURE"
  state_set cab "$CAB_PATH" || exit "$EXIT_FAILURE"
  state_stamp "flashed" || exit "$EXIT_FAILURE"

  if verbose_enough; then
    echo ""
    printf '%s\n' "${C_G}==================================================${C_0}"
    printf '%s\n' "${C_G}  Flashed${C_0}"
    printf '%s\n' "${C_G}==================================================${C_0}"
    echo ""
    echo "  Reboot so the new firmware runs and the PCR settle, then:"
    echo ""
    echo "    ./bios-maint.sh rebind"
    echo ""
    echo "  The machine asks for the maintenance passphrase again on the"
    echo "  way. Do not turn Secure Boot or the TPM off to avoid that: the"
    echo "  passphrase is the plan, not a symptom."
    echo ""
  else
    ok "Flashed from $CAB_PATH, reboot then run rebind"
  fi
}

do_rebind() {
  local dev tag
  local -a base=() extra=()

  require_state flashed || exit "$EXIT_FAILURE"
  check_siblings tpm-pcr.sh tpm-reseal.sh || exit "$EXIT_FAILURE"
  check_tools || exit "$EXIT_FAILURE"
  resolve_passphrase || exit "$EXIT_FAILURE"

  if [[ "$FORCE" == "true" && -z "$PASSPHRASE" ]]; then
    err "--force, but no passphrase was given"
    err "  tpm-reseal.sh opens luks-key.gpg to seal it into the TPM."
    printf '\n' >&2
    printf '%s\n' "    GI_PASSPHRASE=\"\$PW\" ./bios-maint.sh rebind --force" >&2
    printf '%s\n' "    ./bios-maint.sh rebind --force --passphrase-file FILE" >&2
    printf '\n' >&2
    exit "$EXIT_USAGE"
  fi

  dev="$(resolve_device)" || exit "$EXIT_FAILURE"
  require_same_machine "$dev" || exit "$EXIT_FAILURE"
  mapfile -t base < <(common_args "$dev")
  tag="$(state_value pcr_tag 2>/dev/null || true)"
  [[ -n "$tag" ]] || tag="$PCR_TAG"

  ok "Container   : $dev"
  ok "BIOS before : $(state_value bios_before 2>/dev/null || echo unknown)"
  ok "BIOS now    : $(bios_version)"

  step "1/3" "Freezing the values the new firmware leaves, tag $PCR_TAG_AFTER"
  run_tool tpm-pcr.sh "" snapshot --tag "$PCR_TAG_AFTER" ${base[@]+"${base[@]}"} || {
    warn "No snapshot taken of the state after the flash"
    warn "  The comparison below still works. It is the next BIOS update"
    warn "  that will have no reference to start from."
  }

  step "2/3" "Which PCR moved, and whether the policy looks at them"
  if ! run_tool tpm-pcr.sh "" compare --since "$tag" ${base[@]+"${base[@]}"}; then
    err "The comparison against '$tag' failed"
    err "  A snapshot taken by prepare should be there. Look at what is:"
    err "    ./tpm-pcr.sh list"
    exit "$EXIT_FAILURE"
  fi

  step "3/3" "Sealing a new key against the firmware as it stands now"
  extra=()
  [[ "$FORCE" == "true" ]] && extra+=(--force)
  [[ -n "$KEY_PATH" ]] && extra+=(--key "$KEY_PATH")
  if ! run_tool tpm-reseal.sh "$PASSPHRASE" reseal ${base[@]+"${base[@]}"} ${extra[@]+"${extra[@]}"}; then
    err "The binding was not recreated"
    err "  The machine keeps asking for a passphrase, and keyslot"
    err "  $(state_value maint_slot 2>/dev/null || echo '?') still opens it, so nothing is lost."
    err "  tpm-reseal.sh said above whether the TPM refused the seal or"
    err "  the key never decrypted. Those are two different repairs."
    exit "$EXIT_FAILURE"
  fi

  init_err_log
  state_set rebound "$(date +%s)" || exit "$EXIT_FAILURE"
  state_set bios_after "$(bios_version)" || exit "$EXIT_FAILURE"
  state_stamp "rebound" || exit "$EXIT_FAILURE"

  if verbose_enough; then
    echo ""
    printf '%s\n' "${C_G}==================================================${C_0}"
    printf '%s\n' "${C_G}  Rebound${C_0}"
    printf '%s\n' "${C_G}==================================================${C_0}"
    echo ""
    echo "  tpm-reseal.sh asked the TPM to release what it had just sealed"
    echo "  and checked what came back against the keyslot. The sealing is"
    echo "  not merely present, it was exercised."
    echo ""
    echo "  Reboot. The machine should unlock on its own. Then:"
    echo ""
    echo "    ./bios-maint.sh cleanup"
    echo ""
  else
    ok "Rebound on $dev, reboot then run cleanup"
  fi
}

do_cleanup() {
  local dev maint
  local -a base=() extra=()

  require_state rebound || exit "$EXIT_FAILURE"
  resolve_passphrase || exit "$EXIT_FAILURE"

  dev="$(resolve_device)" || exit "$EXIT_FAILURE"
  require_same_machine "$dev" || exit "$EXIT_FAILURE"
  mapfile -t base < <(common_args "$dev")
  maint="$(state_value maint_slot 2>/dev/null || true)"

  if [[ "$REMOVE_MAINT" != "true" ]]; then
    init_err_log
    state_set closed "$(date +%s)" || exit "$EXIT_FAILURE"
    state_stamp "done" || exit "$EXIT_FAILURE"

    if verbose_enough; then
      echo ""
      printf '%s\n' "${C_G}==================================================${C_0}"
      printf '%s\n' "${C_G}  Closed, maintenance passphrase kept${C_0}"
      printf '%s\n' "${C_G}==================================================${C_0}"
      echo ""
      echo "  Keyslot ${maint:-?} still holds the maintenance passphrase, and"
      echo "  that is deliberate. It is never asked for as long as clevis"
      echo "  works, so it costs the user nothing, and it is the whole of"
      echo "  this sequence the day the TPM stops answering again."
      echo ""
      echo "  Record it in the password manager entry of this machine."
      echo ""
      echo "  Removing it is optional and not advised. If a rule demands"
      echo "  it, this is the command, and it proves another slot opens"
      echo "  the container before it takes anything away:"
      echo ""
      echo "    ./bios-maint.sh cleanup --remove-maint-pass"
      echo ""
    else
      ok "Closed on $dev, keyslot ${maint:-?} kept"
    fi
    return 0
  fi

  check_siblings luks-addkey.sh || exit "$EXIT_FAILURE"
  if [[ ! "$maint" =~ ^[0-9]+$ ]]; then
    err "The state file names no maintenance slot"
    err "  Nothing is guessed here. List them, then remove by hand:"
    err "    ./luks-addkey.sh slots --device $dev"
    exit "$EXIT_FAILURE"
  fi

  printf '\n' >&2
  warn "About to remove keyslot $maint, the maintenance passphrase."
  warn "Keeping it is the advice: a strong passphrase in a slot of its own"
  warn "is never asked for while clevis works, and it is what saves the next"
  warn "BIOS update from a LiveUSB."
  warn "Keyslot 0 and the clevis slot are not touched by this."

  step "1/1" "Removing keyslot $maint, once another one is proven"
  extra=()
  [[ "$FORCE" == "true" ]] && extra+=(--force)
  if ! run_tool luks-addkey.sh "$PASSPHRASE" remove --slot "$maint" \
    ${base[@]+"${base[@]}"} ${extra[@]+"${extra[@]}"}; then
    err "Keyslot $maint was not removed"
    err "  luks-addkey.sh refuses to take a slot away until another one"
    err "  has been opened in front of it. Nothing was removed."
    exit "$EXIT_FAILURE"
  fi

  init_err_log
  state_set maint_removed "$(date +%s)" || exit "$EXIT_FAILURE"
  state_set closed "$(date +%s)" || exit "$EXIT_FAILURE"
  state_stamp "done" || exit "$EXIT_FAILURE"

  if verbose_enough; then
    echo ""
    printf '%s\n' "${C_G}==================================================${C_0}"
    printf '%s\n' "${C_G}  Closed, maintenance passphrase removed${C_0}"
    printf '%s\n' "${C_G}==================================================${C_0}"
    echo ""
    echo "  Keyslot $maint is gone. Update the password manager entry of this"
    echo "  machine: what was in that slot opens nothing any more."
    echo ""
    echo "  The next BIOS update starts this sequence again from prepare,"
    echo "  and it will need the TPM to be answering when it does."
    echo ""
  else
    ok "Closed on $dev, keyslot $maint removed"
  fi
}

do_abort() {
  local dev cur maint clevis_slot removed
  local -a base=() extra=()

  cur="$(current_state)"
  if [[ "$cur" == "none" ]]; then
    skip "No operation in progress on this machine, nothing to abort"
    exit "$EXIT_SUCCESS"
  fi

  dev="$(resolve_device 2>/dev/null || true)"
  maint="$(state_value maint_slot 2>/dev/null || true)"
  clevis_slot="$(state_value clevis_slot 2>/dev/null || true)"
  removed="$(state_value clevis_removed 2>/dev/null || true)"

  ok "State       : $cur"
  ok "Container   : ${dev:-not found}"
  ok "Maint slot  : ${maint:-none recorded}"
  ok "Clevis slot : ${clevis_slot:-none recorded}"

  if [[ -z "$dev" ]]; then
    err "No LUKS container here, so nothing can be put back"
    err "  The state file stays as it is, so this can be run again on the"
    err "  machine it belongs to. By hand, there: ./tpm-reseal.sh reseal"
    exit "$EXIT_FAILURE"
  fi
  require_same_machine "$dev" || exit "$EXIT_FAILURE"

  mapfile -t base < <(common_args "$dev")

  if [[ -z "$removed" ]]; then
    skip "The clevis binding was never removed, there is nothing to put back"
  elif clevis_slot_of "$dev" >/dev/null 2>&1; then
    skip "A clevis binding is already on $dev, nothing to put back"
  else
    resolve_passphrase || exit "$EXIT_FAILURE"
    printf '\n' >&2
    warn "The clevis binding is gone and this machine asks for a passphrase."
    warn "Sealing it again is what puts it back the way it was."

    if ! check_siblings tpm-reseal.sh; then
      err "By hand, on this machine:"
      err "  ./tpm-reseal.sh reseal --device $dev"
      exit "$EXIT_FAILURE"
    fi

    step "1/1" "Sealing again against the firmware as it stands"
    extra=()
    [[ "$FORCE" == "true" ]] && extra+=(--force)
    [[ -n "$KEY_PATH" ]] && extra+=(--key "$KEY_PATH")
    if ! run_tool tpm-reseal.sh "$PASSPHRASE" reseal ${base[@]+"${base[@]}"} ${extra[@]+"${extra[@]}"}; then
      err "The binding was not put back"
      err "  Keyslot ${maint:-0} still opens this machine, so it boots, but it"
      err "  boots asking for a passphrase. The state file is left alone"
      err "  so this can be run again once the reason is understood."
      exit "$EXIT_FAILURE"
    fi
  fi

  init_err_log
  state_stamp "aborted" || exit "$EXIT_FAILURE"

  if verbose_enough; then
    echo ""
    printf '%s\n' "${C_G}==================================================${C_0}"
    printf '%s\n' "${C_G}  Aborted${C_0}"
    printf '%s\n' "${C_G}==================================================${C_0}"
    echo ""
    echo "  What this put back:"
    echo "    the clevis binding, when it had been removed"
    echo ""
    echo "  What it deliberately left:"
    if [[ -n "$maint" ]]; then
      echo "    keyslot $maint, the maintenance passphrase. It is a way into"
      echo "    this machine, and an abort is no reason to take one away."
      echo "    Remove it when you want to, in front of the machine:"
      echo "      ./luks-addkey.sh remove --slot $maint --device $dev"
    else
      echo "    nothing: no maintenance slot was ever recorded"
    fi
    echo ""
    echo "  What is left to check by hand:"
    echo "    the header backup, if step 5 had written one, is still where"
    echo "    it was written and is still valid"
    echo "    the PCR snapshot '$PCR_TAG' is still stored, and prepare will"
    echo "    overwrite it next time"
    echo ""
    echo "  The sequence can be started again with: ./bios-maint.sh prepare"
    echo ""
  else
    ok "Aborted on $dev, keyslot ${maint:-none} kept"
  fi
}

main() {
  parse_arguments "$@"

  case "$SUBCOMMAND" in
    plan | show)
      check_root
      do_plan
      ;;
    prepare)
      check_root
      do_prepare
      ;;
    verify-boot | verify)
      check_root
      do_verify_boot
      ;;
    flash)
      check_root
      do_flash
      ;;
    rebind)
      check_root
      do_rebind
      ;;
    cleanup)
      check_root
      do_cleanup
      ;;
    status)
      check_root
      do_status
      ;;
    abort)
      check_root
      do_abort
      ;;
    *)
      err "Unknown command: $SUBCOMMAND"
      err "Use --help for usage information"
      exit "$EXIT_USAGE"
      ;;
  esac
}

main "$@"
