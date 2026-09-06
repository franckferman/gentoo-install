#!/usr/bin/env bash
#
# gentoo-install — TPM resealing: redo the clevis binding after a firmware change
# ----------------------------------------------------------------------------
# Removes the clevis token from the keyslot clevis owns and seals a new one
# against the firmware as it stands now. Keyslot 0, the one the GPG-wrapped key
# file opens, is never touched.
#
# The part that matters: after the bind it asks the TPM to release what was
# just sealed and tests the released key against the keyslot. A token in
# `clevis luks list` reads the same whether the TPM honours it or refuses it,
# so the token alone is never the verdict.
#
# Usage:  ./tpm-reseal.sh <command> [options]   (--help for the list)
#
set -euo pipefail

readonly EXIT_SUCCESS=0
readonly EXIT_FAILURE=1
readonly EXIT_USAGE=2

# Configuration
SUBCOMMAND="reseal"
FORCE="false"
DEVICE=""                # --device : bypasses detection
KEY_PATH=""              # --key    : GPG-wrapped key
KEYSLOT=2                # --slot   : the slot clevis owns
KEYSLOT_EXPLICIT="false" # --slot given by hand: do not second-guess it
PCR_POLICY='{"pcr_bank":"sha256","pcr_ids":"0,2,3,6"}'
PCRS_EXPLICIT="false" # --pcrs given by hand: do not second-guess it either
ROOT_PREFIX=""        # --root   : installed tree, when run from a LiveCD
PASSPHRASE=""         # never exposed on the command line internally
PASSPHRASE_SOURCE="none"
PASSPHRASE_STDIN="false"
MAX_TRIES=3

KEY_CANDIDATES=("/boot/efi/luks-key.gpg" "/boot/efi/luks-master-key.gpg")
ERR_LOG="/tmp/gentoo-install-tpm-reseal.log"

# The decrypted key file, at script level so the EXIT trap can still see it.
# A variable local to a function no longer exists when the trap fires, which
# under set -u ends on "unbound variable" and leaves the file behind.
TEMP_KEY=""

# The key clevis releases from the TPM, kept at script level for the same
# reason: the EXIT trap must still see it after the function that made it
# returned.
TEMP_PASS=""

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
Usage: ./tpm-reseal.sh [COMMAND] [OPTIONS]

================================================================================
gentoo-install - TPM resealing
Redoes the clevis binding after a BIOS update invalidated it
================================================================================

WHEN TO USE IT:
    The machine boots but asks for the passphrase, where it used to unlock on
    its own. The TPM sealing is bound to PCR 0, 2, 3 and 6: a BIOS update
    changes PCR 0, an added card changes 2 and 3, and the TPM then refuses to
    release the key. Nothing is broken, the sealing simply no longer matches.

    Run it on the machine itself, once booted with the passphrase. It also runs
    inside a chroot, which is how a machine gets its first sealing during an
    install.

WHAT IT DOES:
    Removes the clevis token from the keyslot clevis owns and creates a new
    one against the firmware as it is now. Keyslot 0, the one luks-key.gpg
    opens, is never touched: the passphrase keeps working throughout,
    including if this fails.

    It then asks the TPM to release what it just sealed, and checks that what
    comes back opens the keyslot. A token in `clevis luks list` reads the same
    whether the TPM honours it or refuses it, so the token alone is not a
    verdict. Without this last step a machine can be handed back believing it
    unlocks on its own, and ask for the passphrase at the next boot.

COMMANDS:
    reseal              Remove the old binding, create a new one (default)
    status              Current binding and PCR policy, change nothing
    unbind              Remove the binding without recreating it. Proves the
                        key file still opens the container first, so it asks
                        for the passphrase like reseal does.

OPTIONS:
    -h, --help          Show this help
    -q, --quiet         Essential output only
        --device DEV    LUKS container. Detected from the volume group
                        inside it when omitted
        --key FILE      GPG-wrapped key. Default: /boot/efi/luks-key.gpg
        --root DIR      Root of the installed system, for a run from a LiveCD
        --slot N        Keyslot clevis owns (default: 2)
        --pcr LIST      PCR list, comma separated (default: 0,2,3,6)
        --force         Skip every confirmation (non-interactive)

PASSPHRASE (opens luks-key.gpg, the one the key file was wrapped with):
        (nothing)               Asked, not echoed, q cancels
        GI_PASSPHRASE           Environment variable, the route --force needs
        --passphrase-file FILE  First line of a file, keep it mode 600
        --passphrase-stdin      Read from stdin
        --passphrase PASS       Literal value, visible in `ps`

WHY PCR 4 IS NOT IN THE LIST:
    PCR 4 measures the boot file, and bootx64.efi is rewritten at every kernel
    build. Binding it would break automatic unlocking after every update, which
    is a worse trade than the coverage it buys.

EXAMPLES:
    ./tpm-reseal.sh status
        What the binding looks like today. Changes nothing.

    ./tpm-reseal.sh
        Asks for the passphrase, reseals against the current firmware.

    GI_PASSPHRASE="$PW" ./tpm-reseal.sh --force
        Same, unattended.

    ./tpm-reseal.sh unbind
        Removes the binding and stops there. The machine then always asks for
        the passphrase, which is sometimes what a hardware operation needs.
        Asks for the passphrase first, to prove the machine still has a way in
        once the binding is gone.

HELP_EOF
}

parse_arguments() {
  if [[ $# -gt 0 ]] && [[ "$1" != -* ]]; then
    SUBCOMMAND="$1"
    shift
  fi

  local pcrs=""
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
      --slot)
        [[ $# -ge 2 ]] || {
          err "--slot requires a number"
          exit "$EXIT_USAGE"
        }
        [[ "$2" =~ ^[0-9]+$ ]] || {
          err "Invalid --slot: $2"
          exit "$EXIT_USAGE"
        }
        if [[ "$2" == "0" ]]; then
          err "Slot 0 holds the key luks-key.gpg opens"
          err "Resealing it would destroy the recovery path"
          exit "$EXIT_USAGE"
        fi
        KEYSLOT="$2"
        KEYSLOT_EXPLICIT="true"
        shift 2
        ;;
      --pcr)
        [[ $# -ge 2 ]] || {
          err "--pcr requires a list, e.g. 0,2,3,6"
          exit "$EXIT_USAGE"
        }
        [[ "$2" =~ ^[0-9]+(,[0-9]+)*$ ]] || {
          err "Invalid --pcr: $2"
          exit "$EXIT_USAGE"
        }
        pcrs="$2"
        shift 2
        ;;
      --passphrase)
        [[ $# -ge 2 ]] || {
          err "--passphrase requires a value"
          exit "$EXIT_USAGE"
        }
        PASSPHRASE="$2"
        PASSPHRASE_SOURCE="argv"
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
        PASSPHRASE_SOURCE="file:$2"
        shift 2
        ;;
      --passphrase-stdin)
        PASSPHRASE_STDIN="true"
        shift
        ;;
      *)
        err "Unknown option: $1"
        err "Use --help for usage information"
        exit "$EXIT_USAGE"
        ;;
    esac
  done

  if [[ -n "$pcrs" ]]; then
    PCR_POLICY="{\"pcr_bank\":\"sha256\",\"pcr_ids\":\"$pcrs\"}"
    PCRS_EXPLICIT="true"
  fi

  if [[ -z "$PASSPHRASE" && -n "${GI_PASSPHRASE:-}" ]]; then
    PASSPHRASE="$GI_PASSPHRASE"
    PASSPHRASE_SOURCE="env:GI_PASSPHRASE"
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
# Prerequisites
################################################################################

check_tools() {
  local missing=0 t
  for t in cryptsetup clevis gpg; do
    command -v "$t" >/dev/null 2>&1 || {
      err "  missing: $t"
      missing=$((missing + 1))
    }
  done
  if [[ $missing -gt 0 ]]; then
    err "$missing tool(s) missing"
    err "clevis and gpg live in the installed system, not on the LiveCD."
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

  err "Cannot tell which container to reseal. Name it with --device"
  return 1
}

resolve_key() {
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

resolve_passphrase() {
  if [[ "$PASSPHRASE_STDIN" == "true" && -z "$PASSPHRASE" ]]; then
    IFS= read -r PASSPHRASE || true
    PASSPHRASE_SOURCE="stdin"
    [[ -n "$PASSPHRASE" ]] || {
      err "--passphrase-stdin was given but stdin held nothing"
      return 1
    }
    return 0
  fi

  [[ -n "$PASSPHRASE" ]] && return 0

  # Unattended, gpg would sit waiting on a console nobody is watching, and
  # the old binding is already gone by then.
  if [[ "$FORCE" == "true" ]]; then
    err "--force, but no passphrase for the key file"
    printf '\n' >&2
    printf '%s\n' "  It is the passphrase the key file was wrapped with when this" >&2
    printf '%s\n' "  machine was installed, not the root password." >&2
    printf '\n' >&2
    printf '%s\n' "    GI_PASSPHRASE=\"\$PW\" ./tpm-reseal.sh --force" >&2
    printf '%s\n' "    ./tpm-reseal.sh --force --passphrase-file FILE" >&2
    printf '\n' >&2
    return 1
  fi

  local tries=0
  while [[ $tries -lt $MAX_TRIES ]]; do
    tries=$((tries + 1))
    printf '%s' "Passphrase for the key file (q to cancel): " >&2
    read -rs PASSPHRASE || {
      printf '\n' >&2
      err "No input available"
      return 1
    }
    printf '\n' >&2
    [[ "$PASSPHRASE" == "q" ]] && {
      PASSPHRASE=""
      log "Cancelled"
      return 1
    }
    [[ -n "$PASSPHRASE" ]] && {
      PASSPHRASE_SOURCE="interactive"
      return 0
    }
    err "Empty, try again"
  done

  err "Giving up after $MAX_TRIES empty answers"
  return 1
}

################################################################################
# Binding
################################################################################

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

cleanup_temp_files() {
  [[ -n "${TEMP_KEY:-}" ]] && rm -f "$TEMP_KEY"
  [[ -n "${TEMP_PASS:-}" ]] && rm -f "$TEMP_PASS"
  return 0
}

current_binding() {
  clevis luks list -d "$1" 2>/dev/null || true
}

clevis_slot_of() {
  # The slot clevis really owns, read from its own listing rather than
  # assumed. A machine bound to another slot would otherwise keep its old
  # binding while a second one was created next to it.
  local dev="$1" s
  command -v clevis >/dev/null 2>&1 || return 1
  # The tpm2 binding, named rather than taken first. clevis holds several pins
  # at once by design — a tpm2 pin for the machine that unlocks itself and a
  # tang pin for the one that asks the network — and `head -n 1` gave whichever
  # was created first. On a tang-first machine this script then resealed, or
  # reported on, a binding that has nothing to do with the TPM.
  s="$(clevis luks list -d "$dev" 2>/dev/null \
    | awk '$2 == "tpm2" { sub(":", "", $1); print $1; exit }')" || true
  [[ "$s" =~ ^[0-9]+$ ]] || return 1
  echo "$s"
  return 0
}

policy_of_binding() {
  # The configuration clevis stored for this slot, verbatim, as it prints it:
  #
  #   2: tpm2 '{"hash":"sha256","key":"ecc","pcr_bank":"sha256","pcr_ids":"0,2,3,6"}'
  #
  # That JSON is exactly what `clevis luks bind` takes, so reusing it byte for
  # byte reseals what is there rather than what this script's defaults happen
  # to be. Args: $1 = device, $2 = slot.
  local dev="$1" slot="$2" json
  command -v clevis >/dev/null 2>&1 || return 1
  json="$(clevis luks list -d "$dev" 2>/dev/null \
    | awk -v s="${slot}:" '$1 == s' | sed -n "s/.*'\(.*\)'.*/\1/p" | head -n 1)"
  [[ "$json" == \{*\} ]] || return 1
  printf '%s\n' "$json"
}

adopt_real_policy() {
  # A reseal reproduces the policy in force. It used to impose this script's
  # default — pcr_ids 0,2,3,6 — on whatever it found, so a machine installed
  # with another set of registers, or with an RSA key instead of ECC, came back
  # from a reseal bound to something its operator never chose. The listing was
  # even printed on screen, two lines under the policy about to replace it.
  # --pcrs given by hand always wins.
  # Args: $1 = device.
  local dev="$1" found
  [[ "$PCRS_EXPLICIT" == "true" ]] && return 0
  found="$(policy_of_binding "$dev" "$KEYSLOT")" || return 0
  [[ "$found" != "$PCR_POLICY" ]] || return 0
  log "policy taken from the binding in place, not from this script's default"
  log "  in place: $found"
  log "  default : $PCR_POLICY"
  log "  Pass --pcrs to seal against a different set."
  PCR_POLICY="$found"
}

adopt_real_slot() {
  # Called before anything is removed. --slot given by hand always wins.
  local dev="$1" found
  [[ "$KEYSLOT_EXPLICIT" == "true" ]] && return 0
  found="$(clevis_slot_of "$dev")" || return 0
  if [[ "$found" != "$KEYSLOT" ]]; then
    warn "clevis owns keyslot $found, not $KEYSLOT: working on $found"
    warn "  Pass --slot to override."
    KEYSLOT="$found"
  fi
  if [[ "$KEYSLOT" == "0" ]]; then
    err "clevis reports keyslot 0, the one luks-key.gpg opens"
    err "  Refusing: touching it would destroy the recovery path"
    exit "$EXIT_FAILURE"
  fi
  return 0
}

verify_seal_works() {
  # A token in `clevis luks list` proves the token exists, nothing more. It
  # reads identically whether the TPM releases the key or refuses it. The
  # only proof is to make the TPM do it, and that proof is what a machine
  # owes its user before it goes back to them.
  local dev="$1" slot="$2"

  TEMP_PASS="$(umask 077 && mktemp "$(secure_tmpdir)/gentoo-install-reseal-pass.XXXXXX")" || {
    err "  cannot create a temporary file"
    return 1
  }

  if ! clevis luks pass -d "$dev" -s "$slot" >"$TEMP_PASS" 2>>"$ERR_LOG"; then
    err "  the TPM refused to release the key it was just sealed with"
    return 1
  fi
  if [[ ! -s "$TEMP_PASS" ]]; then
    err "  clevis released an empty key"
    return 1
  fi
  if ! cryptsetup open --test-passphrase --key-slot "$slot" \
    --key-file "$TEMP_PASS" "$dev" 2>>"$ERR_LOG"; then
    err "  the key the TPM released opens no keyslot $slot"
    return 1
  fi

  rm -f "$TEMP_PASS"
  TEMP_PASS=""
  return 0
}

decrypt_key_to_temp() {
  # Written to a file because clevis reads its key from one. umask keeps it
  # unreadable to anyone else, and the trap removes it even on Ctrl-C.
  local key="$1"

  TEMP_KEY="$(umask 077 && mktemp "$(secure_tmpdir)/gentoo-install-reseal-key.XXXXXX")" || {
    err "Cannot create a temporary file"
    return 1
  }
  trap cleanup_temp_files EXIT INT TERM

  if [[ -z "${GPG_TTY:-}" ]]; then
    GPG_TTY="$(tty 2>/dev/null || echo /dev/tty)"
    export GPG_TTY
  fi

  : >"$ERR_LOG"
  chmod 600 "$ERR_LOG" 2>/dev/null || true

  local rc=0
  if [[ -n "$PASSPHRASE" ]]; then
    # fd 3 carries the passphrase, so it never reaches argv
    gpg --quiet --batch --pinentry-mode loopback --passphrase-fd 3 \
      --decrypt "$key" 3<<<"$PASSPHRASE" >"$TEMP_KEY" 2>>"$ERR_LOG" || rc=$?
  else
    gpg --quiet --pinentry-mode loopback \
      --decrypt "$key" >"$TEMP_KEY" 2>>"$ERR_LOG" || rc=$?
  fi

  if [[ $rc -ne 0 ]]; then
    err "Could not decrypt $key"
    err "  Wrong passphrase, or the file is damaged"
    err "  Passphrase source: $PASSPHRASE_SOURCE"
    sed 's/^/    /' "$ERR_LOG" >&2 2>/dev/null || true
    return 1
  fi

  [[ -s "$TEMP_KEY" ]] || {
    err "Decryption produced an empty key"
    return 1
  }
  return 0
}

verify_key_opens() {
  # Checked before the old binding is removed. Resealing starts by destroying
  # what works, so the replacement material is proven first.
  local dev="$1"

  if cryptsetup open --test-passphrase --disable-external-tokens \
    --key-file "$TEMP_KEY" "$dev" 2>>"$ERR_LOG"; then
    log "The key file opens $dev, the recovery path is sound"
    return 0
  fi

  err "The key decrypted, but opens no keyslot on $dev"
  err "  It belongs to another machine, or this container was reprovisioned"
  err "  Nothing has been removed."
  return 1
}

do_reseal() {
  local dev key existing

  check_tools || exit "$EXIT_FAILURE"
  dev="$(resolve_device)" || exit "$EXIT_FAILURE"
  key="$(resolve_key)" || {
    err "No key file found in: ${KEY_CANDIDATES[*]}"
    err "From a LiveCD, mount the EFI partition and pass --root or --key"
    exit "$EXIT_FAILURE"
  }

  existing="$(current_binding "$dev")"
  if [[ -n "$existing" ]]; then
    adopt_real_slot "$dev"
    adopt_real_policy "$dev"
  fi

  ok "Container : $dev"
  ok "Key file  : $key"
  ok "Keyslot   : $KEYSLOT"
  ok "Policy    : $PCR_POLICY"

  printf '\n' >&2
  if [[ -n "$existing" ]]; then
    log "Current binding:"
    printf '%s\n' "$existing" | sed 's/^/    /' >&2
  else
    warn "No binding today: the machine asks for the passphrase at boot"
  fi

  resolve_passphrase || exit "$EXIT_FAILURE"
  decrypt_key_to_temp "$key" || exit "$EXIT_FAILURE"
  verify_key_opens "$dev" || exit "$EXIT_FAILURE"

  printf '\n' >&2
  warn "About to remove the binding on slot $KEYSLOT and create a new one."
  warn "Keyslot 0 is untouched: the passphrase keeps working whatever happens."
  if ! confirm "Reseal now?" "Y"; then
    log "Cancelled, nothing changed"
    exit "$EXIT_SUCCESS"
  fi

  if [[ -n "$existing" ]]; then
    log "Removing the old binding"
    # Not survivable: carrying on either fails on an occupied slot, or
    # leaves an orphan token beside a new binding. Neither state is one
    # to hand a machine back in.
    if ! clevis luks unbind -d "$dev" -s "$KEYSLOT" -f 2>>"$ERR_LOG"; then
      err "unbind failed on keyslot $KEYSLOT"
      sed 's/^/    /' "$ERR_LOG" >&2 2>/dev/null || true
      printf '\n' >&2
      err "Nothing was created. The machine still boots with the"
      err "passphrase: keyslot 0 is intact and was proved above."
      exit "$EXIT_FAILURE"
    fi
  fi

  log "Sealing against the firmware as it is now"
  if ! clevis luks bind -k "$TEMP_KEY" -s "$KEYSLOT" -d "$dev" tpm2 "$PCR_POLICY"; then
    err "Binding failed"
    printf '\n' >&2
    err "The machine still boots with the passphrase: keyslot 0 is intact."
    err "To retry by hand:"
    err "  d=\$(mktemp -d)   # pick one on a tmpfs: /run, or /tmp in a chroot"
    err "  (umask 077; gpg --decrypt $key > \$d/k)"
    err "  clevis luks bind -k \$d/k -s $KEYSLOT -d $dev tpm2 '$PCR_POLICY'"
    err "  rm -f \$d/k; rmdir \$d"
    exit "$EXIT_FAILURE"
  fi

  rm -f "$TEMP_KEY"
  TEMP_KEY=""

  printf '\n' >&2
  log "Verifying"
  if clevis luks list -d "$dev" 2>/dev/null | grep -q tpm2; then
    ok "  tpm2 token present on $dev"
  else
    die "  no tpm2 token after binding, something went wrong"
  fi

  # The token existing is not the sealing working. Ask the TPM to release
  # the key, and check what it releases against the keyslot.
  log "  asking the TPM to release what was just sealed"
  if verify_seal_works "$dev" "$KEYSLOT"; then
    ok "  the TPM released the key, and it opens keyslot $KEYSLOT"
  else
    sed 's/^/    /' "$ERR_LOG" >&2 2>/dev/null || true
    printf '\n' >&2
    err "The binding was created, but the TPM does not honour it."
    err "Do not hand this machine back as unlocking on its own: it will"
    err "ask for the passphrase at the next boot."
    err "Keyslot 0 is intact, so it does boot."
    exit "$EXIT_FAILURE"
  fi
  trap - EXIT INT TERM

  if verbose_enough; then
    echo ""
    printf '%s\n' "${C_G}==================================================${C_0}"
    printf '%s\n' "${C_G}  Resealed${C_0}"
    printf '%s\n' "${C_G}==================================================${C_0}"
    echo ""
    echo "  The machine should unlock on its own at the next boot."
    echo "  If it still asks for the passphrase, the firmware changed again"
    echo "  between the reseal and the reboot."
    echo ""
  else
    ok "Resealed on $dev, slot $KEYSLOT"
  fi
}

do_unbind() {
  local dev key existing

  check_tools || exit "$EXIT_FAILURE"
  dev="$(resolve_device)" || exit "$EXIT_FAILURE"

  existing="$(current_binding "$dev")"
  if [[ -z "$existing" ]]; then
    skip "No binding on $dev, nothing to remove"
    exit "$EXIT_SUCCESS"
  fi

  printf '\n' >&2
  log "Current binding:"
  printf '%s\n' "$existing" | sed 's/^/    /' >&2

  adopt_real_slot "$dev"

  # `clevis luks unbind` destroys a keyslot. Removing a way in without
  # proving another one still works is what this toolbox promises never to
  # do, and reseal already proves it before it touches anything. Same proof
  # here, for the same reason.
  key="$(resolve_key)" || {
    err "No key file found in: ${KEY_CANDIDATES[*]}"
    err "  Unbinding without it would leave no proven way into $dev."
    err "  From a LiveCD, mount the EFI partition and pass --root or --key"
    exit "$EXIT_FAILURE"
  }
  printf '\n' >&2
  ok "Key file  : $key"
  resolve_passphrase || exit "$EXIT_FAILURE"
  decrypt_key_to_temp "$key" || exit "$EXIT_FAILURE"
  verify_key_opens "$dev" || exit "$EXIT_FAILURE"

  printf '\n' >&2
  warn "Removing it makes the machine ask for the passphrase at every boot."
  warn "Keyslot 0 opens $dev, just proved, so it stays bootable."

  if ! confirm "Remove the binding on slot $KEYSLOT?" "N"; then
    log "Cancelled, nothing changed"
    exit "$EXIT_SUCCESS"
  fi

  if clevis luks unbind -d "$dev" -s "$KEYSLOT" -f; then
    ok "Binding removed from $dev, slot $KEYSLOT"
    printf '\n' >&2
    printf '%s\n' "  Reseal it later with: ./tpm-reseal.sh" >&2
  else
    die "unbind failed"
  fi
}

do_status() {
  local dev existing

  dev="$(resolve_device)" || exit "$EXIT_FAILURE"

  echo ""
  printf '%s\n' "${C_B}=== TPM binding ===${C_0}"
  echo ""
  printf "  %-14s %s\n" "Container:" "$dev"
  printf "  %-14s %s\n" "LUKS UUID:" "$(cryptsetup luksUUID "$dev" 2>/dev/null || echo unknown)"

  if ! command -v clevis >/dev/null 2>&1; then
    echo ""
    warn "clevis is not installed here, cannot read the binding"
    warn "Run this on the machine itself, or from inside its chroot"
    return 1
  fi

  existing="$(current_binding "$dev")"
  echo ""
  if [[ -n "$existing" ]]; then
    printf "  %-14s %s\n" "Binding:" "${C_G}present${C_0}"
    printf '%s\n' "$existing" | sed 's/^/    /'
    echo ""
    echo "  The machine unlocks on its own as long as the PCR values match"
    echo "  what they were at sealing time."
  else
    printf "  %-14s %s\n" "Binding:" "${C_Y}none${C_0}"
    echo ""
    echo "  The machine asks for the passphrase at every boot."
    echo "  Redo the binding with: ./tpm-reseal.sh"
  fi
  echo ""
}

main() {
  parse_arguments "$@"

  case "$SUBCOMMAND" in
    reseal | run)
      check_root
      do_reseal
      ;;
    unbind)
      check_root
      do_unbind
      ;;
    status)
      check_root
      do_status
      ;;
    *)
      err "Unknown command: $SUBCOMMAND"
      err "Use --help for usage information"
      exit "$EXIT_USAGE"
      ;;
  esac
}

main "$@"
