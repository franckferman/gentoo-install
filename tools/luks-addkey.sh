#!/usr/bin/env bash
#
# gentoo-install — add or remove a LUKS keyslot
# ----------------------------------------------------------------------------
# Adds a passphrase into a free keyslot, and takes one away only after another
# slot has been opened with the material at hand, here and now. No slot is ever
# overwritten and slot 0 is never removed: it holds the key the wrapped key
# file opens, and losing it turns a repair into a reinstall. Every write is
# read back with the TPM held out of the way, so the answer comes from the
# keyslot and from nothing else.
#
# Usage:  ./luks-addkey.sh <command> [options]   (--help for the list)
#
set -euo pipefail

readonly EXIT_SUCCESS=0
readonly EXIT_FAILURE=1
readonly EXIT_USAGE=2

# Configuration
SUBCOMMAND="add"
FORCE="false"
DEVICE=""         # --device : bypasses detection
KEY_PATH=""       # --key    : GPG-wrapped key, for --from key
ROOT_PREFIX=""    # --root   : installed tree, when run from a LiveCD
FROM="auto"       # --from   : key | tpm | pass | auto
SLOT=""           # --slot   : slot to write into or remove, auto picks a free one
OLD_PASSPHRASE="" # unlocks an existing slot
# Where the existing secret came from. Kept for symmetry with NEW_SOURCE and
# read by nothing: this tool names the route it tried, not the hand it was
# dealt.
OLD_SOURCE="none"
NEW_PASSPHRASE="" # the one being added
NEW_SOURCE="none"
GEN_NEW="false" # --gen-passphrase
NEW_PASS_OUT="" # --new-passphrase-out : file the drawn one is written to
PASS_LENGTH=16
MAX_TRIES=3

KEY_CANDIDATES=("/boot/efi/luks-key.gpg" "/boot/efi/luks-master-key.gpg")
ERR_LOG="/tmp/gentoo-install-luks-addkey.log"

# The unlock material, at script level so the EXIT trap can still see it.
# A variable local to a function no longer exists when the trap fires.
UNLOCK_FILE=""

# 32 unambiguous characters: no l/1, no o/0, no punctuation. Typeable at the
# dracut prompt whatever keymap the initramfs happens to load.
PASS_ALPHABET='abcdefghijkmnpqrstuvwxyz23456789'

QUIET="${GI_QUIET:-false}"

# Colours only when the stream that carries them is a terminal, and never when
# NO_COLOR is set. That stream is stderr: every coloured byte here goes there,
# so that `| tee` and a redirected stdout keep their colour.
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

# Output helpers - everything goes to stderr so functions can return values on
# stdout. log() is the only one -q silences, which is what -q meant here before
# the six levels existed: an action being announced is noise on a rerun, a
# result and a refusal never are.
log() { [[ "$QUIET" == "true" ]] || printf '%s[*]%s %s\n' "$C_B" "$C_0" "$*" >&2; }
ok() { printf '%s[+]%s %s\n' "$C_G" "$C_0" "$*" >&2; }
warn() { printf '%s[!]%s %s\n' "$C_Y" "$C_0" "$*" >&2; }
err() { printf '%s[x]%s %s\n' "$C_R" "$C_0" "$*" >&2; }
die() {
  err "$*"
  exit "${EXIT_FAILURE}"
}
skip() { printf '%s[=]%s %s\n' "$C_D" "$C_0" "$*" >&2; }

verbose_enough() { [[ "$QUIET" != "true" ]]; }

show_help() {
  cat <<'HELP_EOF'
Usage: ./luks-addkey.sh [COMMAND] [OPTIONS]

================================================================================
gentoo-install - add or remove a LUKS keyslot
Adds a keyslot, and removes one only once another is proven to still open
================================================================================

WHEN TO USE IT:
    Two cases, and the second is the one that saves a machine.

    Giving a user their own passphrase, the one thing a handover needs. The
    master key stays exactly where it is.

    Recovering a machine whose passphrase nobody knows any more. As long as the
    TPM still unlocks it at boot, the key can be read back from clevis and used
    to authorise a new passphrase. Lose that too and the container is gone.

WHAT UNLOCKS THE NEW SLOT (--from):
    key     the GPG-wrapped file, opened with its passphrase. The nominal case
            on a machine installed by this project, where luks-key.gpg sits on
            the EFI partition.
    tpm     clevis reads its own key back from the TPM. Needs no passphrase at
            all, and only works on the machine itself, booted, with the sealing
            still valid.
    pass    an existing LUKS passphrase, typed. For a slot added by hand.
    auto    tries key, then tpm, then pass (default)

WHAT IT NEVER DOES:
    No slot is ever overwritten. cryptsetup picks a free slot unless --slot
    names one, and a slot already in use is refused rather than replaced.
    Slot 0 is never removed, whatever is asked of it: it holds the key
    luks-key.gpg opens, and losing the master key turns a repair into a
    reinstall.

COMMANDS:
    add                 Add a passphrase (default)
    remove              Remove a keyslot, once another one is proven
    slots               Which slots are in use, change nothing
    test                Try the unlock material without adding anything

OPTIONS:
    -h, --help          Show this help
    -q, --quiet         Essential output only
        --device DEV    LUKS container. Detected from the volume group
                        inside it when omitted
        --from SOURCE   key | tpm | pass | auto  (default: auto)
        --key FILE      GPG-wrapped key, for --from key
        --root DIR      Root of the installed system, for a run from a LiveCD
        --slot N        Write into this slot, or remove it. Refused for add if
                        already in use. auto picks the first free slot outside
                        slot 0 and outside the one clevis owns
        --force         Skip every confirmation (non-interactive)

THE EXISTING SECRET, to authorise the operation:
        GI_PASSPHRASE          Environment variable
        --old-passphrase-file FILE
        --old-passphrase PASS   Literal value, visible in `ps`
    Not needed with --from tpm, which is the whole point of that mode.

THE NEW PASSPHRASE, the one being added:
        (nothing)               Asked twice, with confirmation
        GI_NEW_PASSPHRASE      Environment variable
        --new-passphrase-file FILE
        --new-passphrase PASS   Literal value, visible in `ps`
        --gen-passphrase        Draw one, 16 characters, 80 bits. Displayed,
                                then typed back to catch transcription errors
        --new-passphrase-out FILE
                                Write the drawn one there, mode 600, and read
                                it back. Required with --gen-passphrase --force,
                                where nobody is watching the screen: the file
                                is then the only thing that holds it

THE NEW SLOT IS READ BACK, before this tool says it worked:
    Once written, the passphrase is tried against the slot it was meant for:
    cryptsetup open --test-passphrase --key-slot N --disable-external-tokens.
    That last flag is what makes the test mean anything. Without it a TPM in
    working order answers for the container, and a write that never landed
    still looks like a success.

WHAT REMOVING PROVES FIRST:
    Slot 0 is refused outright, and so is the last slot left in use. The slot
    clevis owns is refused too: luksKillSlot would leave its token behind,
    pointing at a slot that no longer exists, and ./tpm-reseal.sh unbind is the
    tool for that one. Above all, nothing is destroyed until another slot has
    been opened with --test-passphrase, here, now. A slot too many costs
    nothing; a slot too few costs the machine.

EXAMPLES:
    ./luks-addkey.sh test --from tpm
        Says whether that would work, adds nothing.

    ./luks-addkey.sh
        Adds a passphrase, unlocking with whatever works.

    ./luks-addkey.sh --from tpm
        The recovery case: nobody knows the passphrase, the TPM still opens the
        machine, and a new passphrase is added on its authority.

    ./luks-addkey.sh --from key --root /mnt/rescue --gen-passphrase
        From a LiveCD, on a machine opened with luks-open.sh.

    ./luks-addkey.sh add --from tpm --slot auto --gen-passphrase \
        --new-passphrase-out /run/maint.txt --force
        The unattended route, the one bios-maint.sh takes before a BIOS flash.
        The drawn passphrase is read back from the file, not from the screen.

    ./luks-addkey.sh remove --slot 3
        Removes the maintenance passphrase once the machine is back on its
        feet. Another slot has to open the container first, in front of you.

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
        exit "${EXIT_SUCCESS}"
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
      --device)
        [[ $# -ge 2 ]] || {
          err "--device requires a value"
          exit "${EXIT_USAGE}"
        }
        DEVICE="$2"
        shift 2
        ;;
      --key)
        [[ $# -ge 2 ]] || {
          err "--key requires a value"
          exit "${EXIT_USAGE}"
        }
        KEY_PATH="$2"
        shift 2
        ;;
      --root)
        [[ $# -ge 2 ]] || {
          err "--root requires a value"
          exit "${EXIT_USAGE}"
        }
        [[ -d "$2" ]] || {
          err "Not a directory: $2"
          exit "${EXIT_USAGE}"
        }
        ROOT_PREFIX="${2%/}"
        shift 2
        ;;
      --from)
        [[ $# -ge 2 ]] || {
          err "--from requires key, tpm, pass or auto"
          exit "${EXIT_USAGE}"
        }
        case "$2" in
          key | tpm | pass | auto) FROM="$2" ;;
          *)
            err "Invalid --from: $2 (expected key, tpm, pass or auto)"
            exit "${EXIT_USAGE}"
            ;;
        esac
        shift 2
        ;;
      --slot)
        [[ $# -ge 2 ]] || {
          err "--slot requires a number, or auto"
          exit "${EXIT_USAGE}"
        }
        [[ "$2" =~ ^([0-9]+|auto)$ ]] || {
          err "Invalid --slot: $2 (expected a number or auto)"
          exit "${EXIT_USAGE}"
        }
        SLOT="$2"
        shift 2
        ;;
      --old-passphrase)
        [[ $# -ge 2 ]] || {
          err "--old-passphrase requires a value"
          exit "${EXIT_USAGE}"
        }
        OLD_PASSPHRASE="$2"
        OLD_SOURCE="argv"
        shift 2
        ;;
      --old-passphrase-file)
        [[ $# -ge 2 ]] || {
          err "--old-passphrase-file requires a value"
          exit "${EXIT_USAGE}"
        }
        [[ -r "$2" ]] || {
          err "Cannot read $2"
          exit "${EXIT_USAGE}"
        }
        OLD_PASSPHRASE="$(head -n 1 "$2")"
        OLD_SOURCE="file:$2"
        shift 2
        ;;
      --new-passphrase)
        [[ $# -ge 2 ]] || {
          err "--new-passphrase requires a value"
          exit "${EXIT_USAGE}"
        }
        NEW_PASSPHRASE="$2"
        NEW_SOURCE="argv"
        shift 2
        ;;
      --new-passphrase-file)
        [[ $# -ge 2 ]] || {
          err "--new-passphrase-file requires a value"
          exit "${EXIT_USAGE}"
        }
        [[ -r "$2" ]] || {
          err "Cannot read $2"
          exit "${EXIT_USAGE}"
        }
        NEW_PASSPHRASE="$(head -n 1 "$2")"
        NEW_SOURCE="file:$2"
        shift 2
        ;;
      --new-passphrase-out)
        [[ $# -ge 2 ]] || {
          err "--new-passphrase-out requires a file path"
          exit "${EXIT_USAGE}"
        }
        [[ -d "$2" ]] && {
          err "--new-passphrase-out points at a directory: $2"
          exit "${EXIT_USAGE}"
        }
        NEW_PASS_OUT="$2"
        shift 2
        ;;
      *)
        err "Unknown option: $1"
        err "       Use --help for usage information"
        exit "${EXIT_USAGE}"
        ;;
    esac
  done

  if [[ -z "$OLD_PASSPHRASE" && -n "${GI_PASSPHRASE:-}" ]]; then
    OLD_PASSPHRASE="$GI_PASSPHRASE"
    OLD_SOURCE="env:GI_PASSPHRASE"
  fi
  if [[ -z "$NEW_PASSPHRASE" && -n "${GI_NEW_PASSPHRASE:-}" ]]; then
    NEW_PASSPHRASE="$GI_NEW_PASSPHRASE"
    NEW_SOURCE="env:GI_NEW_PASSPHRASE"
  fi

  # Generating and supplying the new one are mutually exclusive: silently
  # picking one over the other would decide which secret opens the machine.
  if [[ "$GEN_NEW" == "true" && -n "$NEW_PASSPHRASE" ]]; then
    err "--gen-passphrase conflicts with $NEW_SOURCE"
    err "Choose one: let the script draw it, or supply it"
    exit "${EXIT_USAGE}"
  fi

  if [[ -n "$NEW_PASS_OUT" && "$GEN_NEW" != "true" ]]; then
    err "--new-passphrase-out only applies to --gen-passphrase"
    err "A passphrase you already hold does not need to be written back"
    exit "${EXIT_USAGE}"
  fi

  # --force skips the typed read-back and nobody watches the screen, so the
  # drawn passphrase would live only in a terminal buffer. The file takes its
  # place: it is what an orchestrator reads, and re-reading it is what proves
  # the passphrase was written whole.
  if [[ "$GEN_NEW" == "true" && "$FORCE" == "true" && -z "$NEW_PASS_OUT" ]]; then
    err "--gen-passphrase with --force requires --new-passphrase-out"
    err "  Unattended, the read-back is skipped and the drawn passphrase"
    err "  would be held nowhere: the slot would open for nobody."
    err "  Give it a path:"
    err "    ./luks-addkey.sh --gen-passphrase --new-passphrase-out FILE --force"
    exit "${EXIT_USAGE}"
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
    echo -n "$question (Y/n): " >&2
    read -r answer || return 1
    [[ "$answer" != "n" && "$answer" != "N" ]]
  else
    echo -n "$question (y/N): " >&2
    read -r answer || return 1
    [[ "$answer" == "y" || "$answer" == "Y" ]]
  fi
}

################################################################################
# Device and slots
################################################################################

normalize_device() {
  local input="${1:-}"
  input="${input%/}"
  input="${input#/dev/}"
  echo "$input"
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

  # Every volume group on this machine, not one named in advance: this asked
  # about "vg1", the group the machine this tooling grew up on happened to
  # have, while gentoo-install creates vg0. A group whose physical volume is an
  # open LUKS mapper is a group inside a container, whatever it is called.
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

  err "Cannot tell which container to use. Name it with --device"
  return 1
}

used_slots() {
  # Bounded to the Keyslots section: Data segments, Tokens and Digests use the
  # same "  N: type" shape. Only the leading number is taken, or the 2 of
  # "luks2" would count as a slot too.
  local out
  out="$(cryptsetup luksDump "$1" 2>/dev/null | awk '
        /^Keyslots:/ { in_slots = 1; next }
        /^[A-Za-z]/  { in_slots = 0 }
        in_slots && /^  [0-9]+:/ { sub(":", "", $1); print $1 }')" || true

  # A LUKS1 header has no Keyslots section, and the parser above returns
  # nothing on it. Left there, every guard below would read an empty header as
  # a container with no slot at all, which is the one answer that is never
  # true.
  if [[ -z "$out" ]]; then
    out="$(cryptsetup luksDump "$1" 2>/dev/null \
      | awk '/^Key Slot [0-9]+: ENABLED/ { sub(":", "", $3); print $3 }')" || true
  fi

  [[ -n "$out" ]] && printf '%s\n' "$out"
  return 0
}

slot_count() {
  # LUKS2 holds 32 keyslots, LUKS1 holds 8. Offering slot 9 on a LUKS1 header
  # would name a slot that cryptsetup then refuses to write.
  local v
  v="$(cryptsetup luksDump "$1" 2>/dev/null | awk '/^Version/ { gsub(/[^0-9]/, "", $2); print $2; exit }')" || true
  [[ "$v" == "1" ]] && {
    echo 8
    return 0
  }
  echo 32
}

clevis_slot() {
  # Asked of clevis, never assumed. The binding sits on slot 2 after a
  # nominal install, and on whatever slot was free the day it was made
  # everywhere else.
  local dev="$1" s
  command -v clevis >/dev/null 2>&1 || return 1
  s="$(clevis luks list -d "$dev" 2>/dev/null | head -n 1 | cut -d: -f1 | tr -d ' ')" || true
  [[ -n "$s" ]] || return 1
  echo "$s"
  return 0
}

slot_label() {
  local dev="$1" slot="$2" cs
  cs="$(clevis_slot "$dev")" || cs=""

  if [[ -n "$cs" && "$slot" == "$cs" ]]; then
    echo "the clevis key sealed in the TPM"
  elif [[ "$slot" == "0" ]]; then
    # Named by its role, not by one encryption variant's shape: on a passphrase
    # install — the installer's default — there is no wrapped key file at all,
    # and calling slot 0 that told the operator their machine was something it
    # is not.
    echo "the everyday way in: a passphrase, or a wrapped key file"
  elif [[ -z "$cs" && "$slot" == "2" ]]; then
    echo "added by hand, or clevis: it cannot be asked from here"
  else
    echo "added by hand"
  fi
}

show_slots() {
  local dev="$1" s
  echo "" >&2
  echo -e "${C_B}=== Keyslots on $dev ===${C_0}" >&2
  echo "" >&2
  for s in $(used_slots "$dev"); do
    printf "  slot %-3s in use   %s\n" "$s" "$(slot_label "$dev" "$s")" >&2
  done
  echo "" >&2
}

slot_is_free() {
  local dev="$1" want="$2" s
  for s in $(used_slots "$dev"); do
    [[ "$s" == "$want" ]] && return 1
  done
  return 0
}

resolve_target_slot() {
  # --slot auto. Left to cryptsetup the choice lands on the lowest free slot,
  # which an orchestrator cannot predict and which may be the one clevis is
  # about to be rebound into.
  local dev="$1" cs max s
  cs="$(clevis_slot "$dev")" || cs=""
  max="$(slot_count "$dev")"

  for ((s = 1; s < max; s++)); do
    [[ -n "$cs" && "$s" == "$cs" ]] && continue
    if slot_is_free "$dev" "$s"; then
      echo "$s"
      return 0
    fi
  done

  err "No free keyslot outside slot 0 on $dev"
  err "  Remove one that is no longer used first, or name a slot yourself"
  return 1
}

added_slot() {
  # cryptsetup does not say which slot it picked, and that number is exactly
  # what the read-back below has to aim at.
  local dev="$1" before=" $2 " s
  for s in $(used_slots "$dev"); do
    [[ "$before" == *" $s "* ]] && continue
    echo "$s"
    return 0
  done
  return 1
}

################################################################################
# Unlock material
################################################################################

secure_tmpdir() {
  # The decrypted key must not land on a persistent filesystem. Which
  # directory is in RAM depends on where this runs, and the two cases are
  # opposites: on a booted machine /run is a tmpfs and /tmp sits on the root
  # LV, while an install chroot that binds the live medium's /tmp but not
  # /run leaves /run as the target's own directory, on disk. Asking the
  # filesystem is the only answer that is right in every case.
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

cleanup_unlock() {
  # shred first: on a tmpfs it changes nothing, and this file also gets
  # written under /dev/shm or, on a system without /run, wherever is left.
  if [[ -n "${UNLOCK_FILE:-}" && -e "${UNLOCK_FILE:-}" ]]; then
    shred -u "$UNLOCK_FILE" 2>/dev/null || rm -f "$UNLOCK_FILE"
  fi
  UNLOCK_FILE=""
}

make_unlock_file() {
  # --from tpm writes the LUKS key clevis releases into this file, and --from
  # key the key of slot 0: both open the container on their own. They belong
  # in RAM, and secure_tmpdir is what knows where that is here.
  UNLOCK_FILE="$(umask 077 && mktemp "$(secure_tmpdir)/gi-addkey-unlock.XXXXXX")" || {
    err "Cannot create a temporary file"
    return 1
  }
  # Armed here and nowhere else: a second trap on the same signals would
  # replace this one and leave the key behind.
  trap 'cleanup_unlock' EXIT INT TERM
  return 0
}

resolve_key_file() {
  local candidate
  if [[ -n "$KEY_PATH" ]]; then
    [[ -f "$KEY_PATH" ]] || {
      err "Key not found: $KEY_PATH"
      return 1
    }
    echo "$KEY_PATH"
    return 0
  fi
  for candidate in "${KEY_CANDIDATES[@]}"; do
    [[ -f "${ROOT_PREFIX}${candidate}" ]] && {
      echo "${ROOT_PREFIX}${candidate}"
      return 0
    }
  done
  return 1
}

ask_old_passphrase() {
  [[ -n "$OLD_PASSPHRASE" ]] && return 0

  if [[ "$FORCE" == "true" ]]; then
    err "--force, but no existing secret was given"
    err "  GI_PASSPHRASE, --old-passphrase-file, or --from tpm"
    return 1
  fi

  local tries=0
  while [[ $tries -lt $MAX_TRIES ]]; do
    tries=$((tries + 1))
    echo -n "Existing passphrase (q to cancel): " >&2
    read -rs OLD_PASSPHRASE || {
      echo "" >&2
      err "No input available"
      return 1
    }
    echo "" >&2
    [[ "$OLD_PASSPHRASE" == "q" ]] && {
      OLD_PASSPHRASE=""
      log "Cancelled"
      return 1
    }
    [[ -n "$OLD_PASSPHRASE" ]] && {
      # shellcheck disable=SC2034  # recorded at every entry point, read by none
      OLD_SOURCE="interactive"
      return 0
    }
    err "Empty, try again"
  done
  err "Giving up after $MAX_TRIES empty answers"
  return 1
}

# from key: decrypt luks-key.gpg into the unlock file
unlock_from_key() {
  local dev="$1" key
  key="$(resolve_key_file)" || {
    log "  no key file found"
    return 1
  }
  log "Key file: $key"

  ask_old_passphrase || return 1

  if [[ -z "${GPG_TTY:-}" ]]; then
    GPG_TTY="$(tty 2>/dev/null || echo /dev/tty)"
    export GPG_TTY
  fi

  local rc=0
  gpg --quiet --batch --pinentry-mode loopback --passphrase-fd 3 \
    --decrypt "$key" 3<<<"$OLD_PASSPHRASE" >"$UNLOCK_FILE" 2>>"$ERR_LOG" || rc=$?
  if [[ $rc -ne 0 ]]; then
    err "  GPG could not decrypt $key, wrong passphrase or damaged file"
    return 1
  fi
  [[ -s "$UNLOCK_FILE" ]] || {
    err "  decryption produced an empty key"
    return 1
  }
  return 0
}

# from tpm: clevis reads its own key back. This is the recovery path, and the
# only one that needs no secret from the operator at all.
unlock_from_tpm() {
  local dev="$1" s

  command -v clevis >/dev/null 2>&1 || {
    log "  clevis not installed here"
    return 1
  }

  s="$(clevis_slot "$dev")" || {
    log "  no clevis binding, or it names no slot"
    return 1
  }
  log "clevis owns slot $s, asking the TPM to release it"

  if ! clevis luks pass -d "$dev" -s "$s" >"$UNLOCK_FILE" 2>>"$ERR_LOG"; then
    err "  the TPM refused to release the key"
    err "  The sealing is invalid: a BIOS update is enough to cause it"
    return 1
  fi
  [[ -s "$UNLOCK_FILE" ]] || {
    err "  the TPM returned nothing"
    return 1
  }
  return 0
}

# from pass: an existing LUKS passphrase, used directly
unlock_from_pass() {
  ask_old_passphrase || return 1
  printf '%s' "$OLD_PASSPHRASE" >"$UNLOCK_FILE"
  return 0
}

verify_unlock() {
  # Proven before anything is written. --test-passphrase unlocks nothing,
  # and --disable-external-tokens keeps a still-working TPM from making a
  # wrong key look right.
  local dev="$1"
  if cryptsetup open --test-passphrase --disable-external-tokens \
    --key-file "$UNLOCK_FILE" "$dev" 2>>"$ERR_LOG"; then
    return 0
  fi
  return 1
}

slot_opens() {
  # One named slot, and only that one: without --key-slot the answer would be
  # "some slot opens", which is not the question asked before a removal.
  local dev="$1" slot="$2"
  cryptsetup open --test-passphrase --disable-external-tokens \
    --key-slot "$slot" --key-file "$UNLOCK_FILE" "$dev" 2>>"$ERR_LOG"
}

prove_other_slot() {
  # The rule the README states for the whole toolbox: no keyslot goes away
  # until another one has been opened, here, now. The slot number is returned
  # on stdout so the caller can name it, and check it again afterwards.
  local dev="$1" target="$2" s
  for s in $(used_slots "$dev"); do
    [[ "$s" == "$target" ]] && continue
    if slot_opens "$dev" "$s"; then
      log "Slot $s opens $dev with the material given"
      echo "$s"
      return 0
    fi
  done

  err "No slot other than $target could be opened with this material"
  err "  The material given opens slot $target and nothing else, or the"
  err "  other slots hold secrets nobody here has."
  err "  Nothing has been removed."
  return 1
}

obtain_unlock() {
  local dev="$1" order=()

  : >"$ERR_LOG"
  chmod 600 "$ERR_LOG" 2>/dev/null || true
  make_unlock_file || return 1

  case "$FROM" in
    auto) order=(key tpm pass) ;;
    *) order=("$FROM") ;;
  esac

  local m
  for m in "${order[@]}"; do
    log "Trying to unlock from: $m"
    : >"$UNLOCK_FILE"
    case "$m" in
      key) unlock_from_key "$dev" || continue ;;
      tpm) unlock_from_tpm "$dev" || continue ;;
      pass) unlock_from_pass || continue ;;
    esac
    if verify_unlock "$dev"; then
      ok "Unlocked from: $m"
      return 0
    fi
    warn "  material from '$m' opens no keyslot here"
  done

  err "No usable unlock material"
  echo "" >&2
  echo "  Without one of the three, the container cannot be modified at all:" >&2
  echo "    key   luks-key.gpg plus its passphrase" >&2
  echo "    tpm   a valid sealing, on the machine itself" >&2
  echo "    pass  a LUKS passphrase added by hand" >&2
  echo "" >&2
  return 1
}

################################################################################
# The new passphrase
################################################################################

random_index() {
  # Uniform in [0,n). Plain "byte % n" is biased whenever n does not divide
  # 256; bytes landing in the incomplete last block are discarded instead.
  local n="$1" byte limit
  limit=$((256 - (256 % n)))
  while true; do
    byte="$(od -An -N1 -tu1 </dev/urandom | tr -d ' ')"
    [[ "$byte" -lt "$limit" ]] && {
      echo $((byte % n))
      return 0
    }
  done
}

generate_passphrase() {
  local n=${#PASS_ALPHABET} out="" grouped="" i
  for ((i = 0; i < PASS_LENGTH; i++)); do
    out+="${PASS_ALPHABET:$(random_index "$n"):1}"
  done
  # Grouped in fours, to be read aloud and transcribed without mistakes
  for ((i = 0; i < ${#out}; i += 4)); do
    [[ -n "$grouped" ]] && grouped+="-"
    grouped+="${out:i:4}"
  done
  echo "$grouped"
}

write_new_passphrase_out() {
  # Under --force nothing is typed back and nobody reads the screen: this
  # file is the read-back. Written, then reread and compared, so a truncated
  # write is caught now and not the morning the machine asks for it.
  local target="$1" dir resolved back previous_umask

  dir="$(dirname "$target")"
  [[ -d "$dir" ]] || {
    err "Directory does not exist: $dir"
    return 1
  }
  resolved="$(readlink -f "$dir")" || resolved="$dir"

  # The ESP travels with the machine, and it is where luks-key.gpg lives. A
  # passphrase left there ships with the disk it is supposed to protect.
  if [[ "$resolved" == *"/boot/efi"* ]]; then
    err "Refusing to write the passphrase under $resolved"
    err "  That is where luks-key.gpg lives: the passphrase would travel"
    err "  with the machine it protects, which cancels the encryption"
    return 1
  fi

  previous_umask="$(umask)"
  umask 077
  printf '%s\n' "$NEW_PASSPHRASE" >"$target" || {
    umask "$previous_umask"
    err "Cannot write $target"
    return 1
  }
  umask "$previous_umask"
  if [[ -f "$target" && ! -L "$target" ]]; then
    chmod 600 "$target"
  fi

  back="$(head -n 1 "$target")" || {
    err "Cannot read $target back"
    return 1
  }
  if [[ "$back" != "$NEW_PASSPHRASE" ]]; then
    err "$target does not hold what was drawn"
    err "  Nothing has been added. The disk is full, or something else"
    err "  is writing to that path."
    return 1
  fi

  ok "Passphrase written to $target (mode 600), read back and identical"
  return 0
}

resolve_new_passphrase() {
  if [[ "$GEN_NEW" == "true" ]]; then
    NEW_PASSPHRASE="$(generate_passphrase)"
    NEW_SOURCE="generated"
    echo "" >&2
    echo -e "${C_Y}  ==================================================${C_0}" >&2
    echo -e "${C_Y}   NEW PASSPHRASE${C_0}" >&2
    echo -e "${C_Y}  ==================================================${C_0}" >&2
    echo "" >&2
    echo -e "        ${C_G}${NEW_PASSPHRASE}${C_0}" >&2
    echo "" >&2
    echo "   Store it in your password manager, with the machine it belongs" >&2
    echo "   to, before going on." >&2
    echo "" >&2
    if [[ -n "$NEW_PASS_OUT" ]]; then
      write_new_passphrase_out "$NEW_PASS_OUT" || return 1
    fi
    if [[ "$FORCE" != "true" ]]; then
      local check
      while true; do
        echo -n "   Type it back to confirm: " >&2
        read -r check
        [[ "$check" == "$NEW_PASSPHRASE" ]] && break
        err "Does not match, try again or Ctrl-C to abort"
      done
      ok "Transcription confirmed"
    else
      warn "Nothing typed back (--force): $NEW_PASS_OUT is what holds it"
    fi
    return 0
  fi

  [[ -n "$NEW_PASSPHRASE" ]] && return 0

  if [[ "$FORCE" == "true" ]]; then
    err "--force, but no new passphrase was given"
    err "  GI_NEW_PASSPHRASE, --new-passphrase-file, or --gen-passphrase"
    return 1
  fi

  local first second
  while true; do
    echo -n "New passphrase: " >&2
    read -rs first || {
      echo "" >&2
      err "No input available"
      return 1
    }
    echo "" >&2
    [[ -n "$first" ]] || {
      err "Cannot be empty"
      continue
    }
    echo -n "Confirm: " >&2
    read -rs second || {
      echo "" >&2
      err "No input available"
      return 1
    }
    echo "" >&2
    [[ "$first" == "$second" ]] || {
      err "They do not match"
      continue
    }
    NEW_PASSPHRASE="$first"
    NEW_SOURCE="interactive"
    return 0
  done
}

verify_new_slot() {
  # This tool used to print a line telling the operator to go and check
  # elsewhere. A slot written and never read back is a slot whose state
  # nobody knows, and this is the last moment where the material to test it
  # is still at hand.
  local dev="$1" slot="$2"
  local -a args=(open --test-passphrase --disable-external-tokens)

  [[ -n "$slot" ]] && args+=(--key-slot "$slot")
  args+=(--key-file - "$dev")

  if printf '%s' "$NEW_PASSPHRASE" | cryptsetup "${args[@]}" 2>>"$ERR_LOG"; then
    if [[ -n "$slot" ]]; then
      ok "Read back: the new passphrase opens slot $slot on $dev"
    else
      ok "Read back: the new passphrase opens $dev"
    fi
    return 0
  fi

  err "The keyslot was written, but the new passphrase does not open it"
  sed 's/^/    /' "$ERR_LOG" >&2 2>/dev/null || true
  err "  Nothing has been removed: a slot too many is harmless, a slot too"
  err "  few is a machine nobody can open. Look at the slots above, and"
  err "  keep the existing secrets until this is understood."
  return 1
}

################################################################################
# Commands
################################################################################

do_add() {
  local dev target before written
  dev="$(resolve_device)" || exit "${EXIT_FAILURE}"
  ok "Container: $dev"

  show_slots "$dev"

  target="$SLOT"
  if [[ "$target" == "auto" ]]; then
    target="$(resolve_target_slot "$dev")" || exit "${EXIT_FAILURE}"
    log "Free slot picked: $target, outside slot 0 and outside clevis"
  fi

  if [[ -n "$target" ]]; then
    if ! slot_is_free "$dev" "$target"; then
      err "Slot $target is already in use"
      err "  This tool never overwrites a slot: pick a free one, or drop"
      err "  --slot and let cryptsetup choose"
      exit "${EXIT_FAILURE}"
    fi
    log "Will write into slot $target"
  else
    log "cryptsetup will pick a free slot"
  fi

  obtain_unlock "$dev" || exit "${EXIT_FAILURE}"
  resolve_new_passphrase || exit "${EXIT_FAILURE}"

  echo "" >&2
  warn "About to add a keyslot on $dev."
  warn "No existing slot is touched: the master key and the TPM stay as they are."
  if ! confirm "Add it now?" "Y"; then
    log "Cancelled, nothing changed"
    exit "${EXIT_SUCCESS}"
  fi

  # Taken before the write, because cryptsetup names no slot when it chooses
  # one itself
  before="$(used_slots "$dev" | tr '\n' ' ')"

  local -a args=(luksAddKey "$dev" --key-file "$UNLOCK_FILE")
  [[ -n "$target" ]] && args+=(--new-key-slot "$target")

  # The new passphrase arrives on stdin, so it never reaches argv
  if ! printf '%s' "$NEW_PASSPHRASE" | cryptsetup "${args[@]}" - 2>>"$ERR_LOG"; then
    err "luksAddKey failed"
    sed 's/^/    /' "$ERR_LOG" >&2 2>/dev/null || true
    err "Nothing was added. Existing slots are untouched."
    exit "${EXIT_FAILURE}"
  fi

  written="$target"
  if [[ -z "$written" ]]; then
    written="$(added_slot "$dev" "$before")" || {
      written=""
      warn "Cannot tell which slot cryptsetup used: the read-back below"
      warn "will not be able to name one"
    }
  fi

  verify_new_slot "$dev" "$written" || exit "${EXIT_FAILURE}"

  cleanup_unlock
  trap - EXIT INT TERM

  ok "Keyslot added on $dev"
  show_slots "$dev"

  if verbose_enough; then
    echo "" >&2
    echo -e "${C_G}==================================================${C_0}" >&2
    echo -e "${C_G}  Passphrase added${C_0}" >&2
    echo -e "${C_G}==================================================${C_0}" >&2
    echo "" >&2
    echo "  Slot ${written:-unknown} answered to the new passphrase, here and now." >&2
    echo "  The TPM was held out of the way for that test, so the answer" >&2
    echo "  came from the slot and from nothing else." >&2
    echo "  Store it in your password manager, with the machine it belongs to." >&2
    echo "" >&2
  else
    ok "Slot ${written:-unknown} on $dev opens with the new passphrase"
  fi
}

do_remove() {
  local dev target proven answer count cs s

  dev="$(resolve_device)" || exit "${EXIT_FAILURE}"
  ok "Container: $dev"
  show_slots "$dev"

  if [[ -z "$SLOT" || "$SLOT" == "auto" ]]; then
    err "remove needs the slot to take away: --slot N"
    err "  Nothing is guessed here. './luks-addkey.sh slots' lists them"
    exit "${EXIT_FAILURE}"
  fi
  target="$SLOT"

  # Slot 0 is the everyday way in, whatever shape it takes: the passphrase
  # typed at boot, or the key a wrapped file holds. Either way it is the one
  # slot whose loss locks the machine, so no condition makes this tool take it
  # away.
  if [[ "$target" == "0" ]]; then
    err "Slot 0 is never removed"
    err "  It is the everyday way into this machine — the passphrase, or the"
    err "  key a wrapped file holds — and removing it locks the container"
    err "  Add the new key first, prove it opens, then remove the old slot"
    exit "${EXIT_FAILURE}"
  fi

  if slot_is_free "$dev" "$target"; then
    err "Slot $target holds nothing on $dev"
    err "  Nothing has been removed."
    exit "${EXIT_FAILURE}"
  fi

  count=0
  for s in $(used_slots "$dev"); do
    count=$((count + 1))
  done
  if [[ $count -le 1 ]]; then
    err "Slot $target is the only slot still in use on $dev"
    err "  Removing it leaves a container that nothing opens, and a"
    err "  header backup does not bring a keyslot back"
    exit "${EXIT_FAILURE}"
  fi

  cs="$(clevis_slot "$dev")" || cs=""
  if [[ -n "$cs" && "$target" == "$cs" ]]; then
    err "Slot $target is the one clevis owns"
    err "  luksKillSlot would leave its token behind, pointing at a slot"
    err "  that no longer exists. Take the binding away instead:"
    err "    ./tpm-reseal.sh unbind --slot $target"
    exit "${EXIT_FAILURE}"
  fi

  obtain_unlock "$dev" || exit "${EXIT_FAILURE}"

  proven="$(prove_other_slot "$dev" "$target")" || exit "${EXIT_FAILURE}"

  echo "" >&2
  warn "About to remove keyslot $target on $dev: $(slot_label "$dev" "$target")."
  warn "Slot $proven stays, and was just opened with the material given."
  if [[ "$FORCE" == "true" ]]; then
    warn "Remove keyslot $target? -> auto-yes (--force)"
  else
    # The number, not a y: a keyslot removed on a mistyped answer does not
    # come back.
    echo -n "Type the slot number to remove it (q to cancel): " >&2
    read -r answer || {
      echo "" >&2
      err "No input available"
      exit "${EXIT_FAILURE}"
    }
    if [[ "$answer" != "$target" ]]; then
      log "Cancelled, nothing removed"
      exit "${EXIT_SUCCESS}"
    fi
  fi

  if ! cryptsetup luksKillSlot --disable-external-tokens \
    --key-file "$UNLOCK_FILE" "$dev" "$target" 2>>"$ERR_LOG"; then
    err "luksKillSlot failed on slot $target"
    sed 's/^/    /' "$ERR_LOG" >&2 2>/dev/null || true
    err "  Nothing was removed. Every slot is as it was."
    exit "${EXIT_FAILURE}"
  fi

  # Read back rather than trusted: the slot has to be gone, and the one
  # proven a minute ago has to still answer.
  if ! slot_is_free "$dev" "$target"; then
    err "Slot $target is still in use after luksKillSlot"
    exit "${EXIT_FAILURE}"
  fi
  if ! slot_opens "$dev" "$proven"; then
    err "Slot $proven no longer opens $dev, and it did a minute ago"
    err "  Do not reboot this machine before understanding why:"
    err "    ./luks-check.sh report --device $dev"
    exit "${EXIT_FAILURE}"
  fi

  cleanup_unlock
  trap - EXIT INT TERM

  ok "Keyslot $target removed from $dev"
  show_slots "$dev"

  if verbose_enough; then
    echo "" >&2
    echo -e "${C_G}==================================================${C_0}" >&2
    echo -e "${C_G}  Keyslot removed${C_0}" >&2
    echo -e "${C_G}==================================================${C_0}" >&2
    echo "" >&2
    echo "  Slot $target is gone, slot $proven still opens $dev." >&2
    echo "  Update your password manager entry for this machine: what was in" >&2
    echo "  slot $target opens nothing any more." >&2
    echo "" >&2
  else
    ok "Slot $target removed, slot $proven still opens $dev"
  fi
}

do_test() {
  local dev
  dev="$(resolve_device)" || exit "${EXIT_FAILURE}"
  ok "Container: $dev"
  show_slots "$dev"

  if obtain_unlock "$dev"; then
    cleanup_unlock
    trap - EXIT INT TERM
    echo "" >&2
    ok "Usable unlock material found, a passphrase could be added"
    return 0
  fi
  return 1
}

main() {
  parse_arguments "$@"

  case "$SUBCOMMAND" in
    add)
      check_root
      do_add
      ;;
    remove)
      check_root
      do_remove
      ;;
    slots)
      check_root
      local dev
      dev="$(resolve_device)" || exit "${EXIT_FAILURE}"
      show_slots "$dev"
      ;;
    test)
      check_root
      do_test
      ;;
    *)
      err "Unknown command: $SUBCOMMAND"
      err "       Use --help for usage information"
      exit "${EXIT_USAGE}"
      ;;
  esac
}

main "$@"
