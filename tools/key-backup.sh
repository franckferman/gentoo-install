#!/usr/bin/env bash
#
# gentoo-install — take the wrapped LUKS key off the machine
# ----------------------------------------------------------------------------
# The key file lives on the machine's own EFI partition: if the disk dies, it
# dies with it. What matters is not copying a file, it is copying a file that
# still works, so the key is decrypted and tested against a real keyslot before
# the copy is called a backup.
#
# Usage:  ./key-backup.sh <command> [options]   (--help for the list)
#
set -euo pipefail

readonly EXIT_SUCCESS=0
readonly EXIT_FAILURE=1
readonly EXIT_USAGE=2

# Configuration
SUBCOMMAND="backup"
FORCE="false"
DEVICE=""         # --device : container the key is checked against
KEY_PATH=""       # --key    : source file, otherwise found on the ESP
ROOT_PREFIX=""    # --root   : installed tree, when run from a LiveCD
OUT_DIR=""        # --out    : where the copy is written
NO_VERIFY="false" # --no-verify : skip the proof, not recommended
PASSPHRASE=""
PASSPHRASE_SOURCE="none"
PASSPHRASE_STDIN="false"
MAX_TRIES=3

KEY_CANDIDATES=("/boot/efi/luks-key.gpg" "/boot/efi/luks-master-key.gpg")
ERR_LOG="/tmp/gentoo-install-key-backup.log"

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
Usage: ./key-backup.sh [COMMAND] [OPTIONS]

================================================================================
gentoo-install - key backup
Extracts luks-key.gpg for the password manager, proves it still works first
================================================================================

WHY IT EXISTS:
    The LUKS key belongs in the password manager entry of the machine it opens,
    and nothing automates that. The file lives on the machine's own EFI
    partition: if the disk dies, it dies with it.

    What matters is not copying a file, it is copying a file that still works.
    So the key is decrypted and tested against a real keyslot before the copy is
    called a backup.

WHAT GOES INTO THE PASSWORD MANAGER:
    The file itself, as an attachment, and the passphrase that opens it, as the
    entry's password. Neither is any use without the other.

    Recording only the passphrase is the mistake this tool exists to prevent:
    keyslot 0 holds a random key that exists nowhere but inside this file, and
    the TPM holds a different secret of its own. Lose the file and one of the
    two ways in is gone for good.

COMMANDS:
    backup              Verify, then copy out (default)
    verify              Prove the key still opens the container, copy nothing
    show                Where the key is and what state it is in

OPTIONS:
    -h, --help          Show this help
    -q, --quiet         Essential output only
        --device DEV    Container to test against. Detected from the volume
                        group inside it when omitted
        --key FILE      Source file. Found on the EFI partition when omitted
        --root DIR      Root of the installed system, for a run from a LiveCD
        --out DIR       Where to write the copy (default: the current directory)
        --no-verify     Copy without proving the key works. Only for a machine
                        whose container cannot be reached at all
        --force         Skip every confirmation (non-interactive)

PASSPHRASE (opens the key file, so it can be tested):
        (nothing)               Asked, not echoed, q cancels
        GI_PASSPHRASE          Environment variable
        --passphrase-file FILE  First line of a file, keep it mode 600
        --passphrase-stdin      Read from stdin
        --passphrase PASS       Literal value, visible in `ps`

WHERE THE COPY GOES:
    --out names the directory, and the current one is used without it. Written
    onto the machine's own root or onto its EFI partition, the copy dies with
    the disk it was meant to survive, so the tool says so when it recognises
    one of those. It writes anyway: the operator knows things the script does
    not, and a copy in the wrong place still beats no copy at all.

EXAMPLES:
    ./key-backup.sh
        Tests the key, copies it out under a name carrying the service tag.

    ./key-backup.sh verify
        Only the proof. Worth running on a machine in service, to know the
        recovery path is still sound.

    ./key-backup.sh --root /mnt/rescue --out /mnt/usb
        From a LiveCD, on a machine opened with luks-open.sh.

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
      --no-verify)
        NO_VERIFY="true"
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
      --out)
        [[ $# -ge 2 ]] || {
          err "--out requires a value"
          exit "${EXIT_USAGE}"
        }
        [[ -d "$2" ]] || {
          err "Not a directory: $2"
          exit "${EXIT_USAGE}"
        }
        OUT_DIR="${2%/}"
        shift 2
        ;;
      --passphrase)
        [[ $# -ge 2 ]] || {
          err "--passphrase requires a value"
          exit "${EXIT_USAGE}"
        }
        PASSPHRASE="$2"
        PASSPHRASE_SOURCE="argv"
        shift 2
        ;;
      --passphrase-file)
        [[ $# -ge 2 ]] || {
          err "--passphrase-file requires a value"
          exit "${EXIT_USAGE}"
        }
        [[ -r "$2" ]] || {
          err "Cannot read $2"
          exit "${EXIT_USAGE}"
        }
        # head strips the \n, not the \r a file written on Windows
        # carries. The secret often comes out of a password manager on
        # a Windows workstation, and gpg would then be handed a
        # passphrase nobody typed.
        PASSPHRASE="$(head -n 1 "$2" | tr -d '\r')"
        PASSPHRASE_SOURCE="file:$2"
        shift 2
        ;;
      --passphrase-stdin)
        PASSPHRASE_STDIN="true"
        shift
        ;;
      *)
        err "Unknown option: $1"
        err "       Use --help for usage information"
        exit "${EXIT_USAGE}"
        ;;
    esac
  done

  if [[ -z "$PASSPHRASE" && -n "${GI_PASSPHRASE:-}" ]]; then
    PASSPHRASE="$GI_PASSPHRASE"
    PASSPHRASE_SOURCE="env:GI_PASSPHRASE"
  fi

  # Exported by the caller, it would otherwise be inherited by gpg and by
  # cryptsetup, and readable in /proc/PID/environ for as long as they run.
  # The value is held in PASSPHRASE now.
  unset GI_PASSPHRASE
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
# Locating
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

  # Every volume group, not one named in advance: this asked about "vg1", the
  # group the machine this tooling grew up on happened to have, while
  # gentoo-install creates vg0. A group whose physical volume is an open LUKS
  # mapper is a group inside a container, whatever it is called.
  local group
  while read -r group; do
    [[ -n "$group" ]] || continue
    pv="$(vgs --noheadings -o pv_name "$group" 2>/dev/null | tr -d ' ' | head -n 1)"
    [[ -n "$pv" && "$pv" == /dev/mapper/* ]] || continue
    name="$(basename "$pv")"
    dev="$(cryptsetup status "$name" 2>/dev/null | awk '/device:/ {print $2}')"
    if [[ -n "$dev" ]] && cryptsetup isLuks "$dev" 2>/dev/null; then
      echo "$dev"
      return 0
    fi
  done < <(vgs --noheadings -o vg_name 2>/dev/null | tr -d ' ')
  return 1
}

on_encrypted_volume() {
  # True when this path sits on a logical volume inside a LUKS container —
  # that is, on the machine being backed up rather than on the medium the
  # operator arrived with. Args: $1 = source device of the mountpoint.
  local src="$1" group pv
  [[ "$src" == /dev/mapper/* || "$src" == /dev/*/* ]] || return 1
  group="$(lvs --noheadings -o vg_name -- "$src" 2>/dev/null | tr -d '[:space:]')"
  [[ -n "$group" ]] || return 1
  pv="$(vgs --noheadings -o pv_name "$group" 2>/dev/null | tr -d ' ' | head -n 1)"
  [[ -n "$pv" && "$pv" == /dev/mapper/* ]] || return 1
  cryptsetup status "$(basename "$pv")" >/dev/null 2>&1
}

key_candidates_searched() {
  # The paths actually looked at, prefix included. Printing the bare candidates
  # made a run with --root read as though --root had been ignored: the search
  # used <root>/boot/efi/luks-key.gpg and the message said /boot/efi/luks-key.gpg,
  # which is the LiveCD's own. An operator debugging a missing key should be told
  # where it was really looked for.
  local candidate out=""
  for candidate in "${KEY_CANDIDATES[@]}"; do
    out+="${ROOT_PREFIX}${candidate} "
  done
  printf '%s\n' "${out% }"
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

machine_id() {
  # The DMI serial number names the machine everywhere else: the inventory,
  # the password manager entry, the certificate. A backup file that carries
  # it can be matched to a machine a year later.
  local id=""
  if command -v dmidecode >/dev/null 2>&1; then
    id="$(dmidecode -s system-serial-number 2>/dev/null | head -n 1 | tr -d ' ')"
  fi
  case "$id" in
    "" | None | "NotSpecified" | "ToBeFilledByO.E.M." | "SystemSerialNumber") id="" ;;
  esac
  if [[ -z "$id" && -r /sys/class/dmi/id/product_serial ]]; then
    # dmidecode is not in the stage, but the kernel exposes the same value
    id="$(tr -d ' \n' </sys/class/dmi/id/product_serial 2>/dev/null)"
    case "$id" in
      "" | None | "NotSpecified" | "ToBeFilledByO.E.M." | "SystemSerialNumber") id="" ;;
    esac
  fi

  [[ -n "$id" ]] || id="unknown-$(od -An -N3 -tx1 </dev/urandom | tr -d ' \n')"
  echo "$id"
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

  if [[ "$FORCE" == "true" ]]; then
    err "--force, but no passphrase was given"
    err "  GI_PASSPHRASE, or --passphrase-file FILE"
    return 1
  fi

  local tries=0
  while [[ $tries -lt $MAX_TRIES ]]; do
    tries=$((tries + 1))
    echo -n "Passphrase for the key file (q to cancel): " >&2
    read -rs PASSPHRASE || {
      echo "" >&2
      err "No input available"
      return 1
    }
    echo "" >&2
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

warn_if_on_the_machine() {
  # A copy written onto the machine it protects is not a backup: the day the
  # disk dies they go together. The default destination is the current
  # directory, and that is the machine's own root as often as not.
  local out="$1" dir src

  dir="$(readlink -f "$(dirname "$out")")" || dir="$(dirname "$out")"

  if [[ "$dir" == *"/boot/efi"* ]]; then
    warn "$out would sit on the EFI partition, beside the key it copies"
    warn "  Both would travel with the machine. Write it elsewhere: --out"
    return 0
  fi

  if [[ -n "$ROOT_PREFIX" && "$dir" == "$(readlink -f "$ROOT_PREFIX")"* ]]; then
    warn "$out would land inside the tree of the machine being backed up"
    warn "  Write it to the medium you came with instead: --out"
    return 0
  fi

  src="$(findmnt -no SOURCE --target "$out" 2>/dev/null || true)"
  if [[ -n "$src" ]] && on_encrypted_volume "$src"; then
    warn "$out would land on $src, a volume of the machine itself"
    warn "  A copy that dies with the disk is not a backup: --out DIR"
  fi
  return 0
}

################################################################################
# The proof
################################################################################

verify_key() {
  # Decrypted and fed straight to cryptsetup through a pipe: the key never
  # touches the disk, and --test-passphrase unlocks nothing.
  local key="$1" dev="$2"
  local status=()

  : >"$ERR_LOG"
  chmod 600 "$ERR_LOG" 2>/dev/null || true

  if [[ -z "${GPG_TTY:-}" ]]; then
    GPG_TTY="$(tty 2>/dev/null || echo /dev/tty)"
    export GPG_TTY
  fi

  set +e
  gpg --quiet --batch --pinentry-mode loopback --passphrase-fd 3 \
    --decrypt "$key" 3<<<"$PASSPHRASE" 2>>"$ERR_LOG" \
    | cryptsetup open --test-passphrase --disable-external-tokens \
      --key-file - "$dev" 2>>"$ERR_LOG"
  status=("${PIPESTATUS[@]}")
  set -e

  if [[ "${status[0]}" -ne 0 ]]; then
    err "GPG could not decrypt $key"
    err "  Wrong passphrase, or the file is damaged"
    err "  Passphrase source: $PASSPHRASE_SOURCE"
    sed 's/^/    /' "$ERR_LOG" >&2 2>/dev/null || true
    return 1
  fi
  if [[ "${status[1]}" -ne 0 ]]; then
    err "The key decrypted, but opens no keyslot on $dev"
    err "  It belongs to another machine, or this container was"
    err "  reprovisioned since the file was written"
    sed 's/^/    /' "$ERR_LOG" >&2 2>/dev/null || true
    return 1
  fi

  ok "Proven: this key opens $dev"
  return 0
}

################################################################################
# Commands
################################################################################

do_show() {
  local key dev

  echo "" >&2
  echo -e "${C_B}=== Key file ===${C_0}" >&2
  echo "" >&2

  if key="$(resolve_key)"; then
    printf "  %-16s %b %s\n" "Found:" "${C_G}yes${C_0}" "$key" >&2
    printf "  %-16s %s bytes, mode %s\n" "Size:" "$(stat -c%s "$key")" "$(stat -c%a "$key")" >&2
    printf "  %-16s %s\n" "Modified:" "$(stat -c%y "$key" | cut -d. -f1)" >&2
  else
    printf "  %-16s %b\n" "Found:" "${C_R}no${C_0}" >&2
    echo "" >&2
    echo "  Looked in: $(key_candidates_searched)" >&2
    echo "  From a LiveCD, point at the mounted tree with --root" >&2
    echo "" >&2
    echo "  A machine without this file has only the TPM left. A BIOS update" >&2
    echo "  would then make it unrecoverable." >&2
    return 1
  fi

  echo "" >&2
  if dev="$(resolve_device)"; then
    printf "  %-16s %s\n" "Container:" "$dev" >&2
    printf "  %-16s %s\n" "LUKS UUID:" "$(cryptsetup luksUUID "$dev" 2>/dev/null || echo unknown)" >&2
  else
    printf "  %-16s %b\n" "Container:" "${C_Y}not reachable from here${C_0}" >&2
    echo "  The key cannot be tested without it. Open the machine first, or" >&2
    echo "  pass --device." >&2
  fi

  echo "" >&2
  printf "  %-16s %s\n" "Service tag:" "$(machine_id)" >&2
  echo "" >&2
  return 0
}

do_verify() {
  local key dev
  key="$(resolve_key)" || {
    err "No key file found"
    exit "${EXIT_FAILURE}"
  }
  log "Key file: $key"

  dev="$(resolve_device)" || {
    err "No container to test against. Pass --device"
    exit "${EXIT_FAILURE}"
  }
  log "Container: $dev"

  resolve_passphrase || exit "${EXIT_FAILURE}"
  verify_key "$key" "$dev" || exit "${EXIT_FAILURE}"
}

do_backup() {
  local key dev tag out

  key="$(resolve_key)" || {
    err "No key file found in: $(key_candidates_searched)"
    err "From a LiveCD, point at the mounted tree with --root"
    exit "${EXIT_FAILURE}"
  }
  ok "Key file: $key"

  if [[ "$NO_VERIFY" == "true" ]]; then
    warn "Skipping the proof (--no-verify)"
    warn "  The copy may be a key that no longer opens anything."
  else
    dev="$(resolve_device)" || {
      err "No container to test the key against"
      err "  Open the machine first, pass --device, or accept a blind"
      err "  copy with --no-verify"
      exit "${EXIT_FAILURE}"
    }
    log "Container: $dev"
    resolve_passphrase || exit "${EXIT_FAILURE}"
    verify_key "$key" "$dev" || exit "${EXIT_FAILURE}"
  fi

  tag="$(machine_id)"
  out="${OUT_DIR:-$PWD}/luks-key-${tag}.gpg"

  warn_if_on_the_machine "$out"

  # Never silently overwrite: an older file may be the one that matches a
  # container still in service somewhere.
  if [[ -e "$out" ]]; then
    warn "$out already exists"
    if ! confirm "Overwrite it?" "N"; then
      out="${out%.gpg}-$(date +%Y%m%d-%H%M%S).gpg"
      log "Writing to $out instead"
    fi
  fi

  local previous_umask
  previous_umask="$(umask)"
  umask 077
  cp -p "$key" "$out"
  umask "$previous_umask"
  # Only a regular file: see the note in luks-header.sh. A device node named
  # as --out must not have its mode changed by a root-run tool.
  if [[ -f "$out" && ! -L "$out" ]]; then
    chmod 600 "$out"
  fi

  ok "Copied to $out (mode 600)"

  if verbose_enough; then
    echo "" >&2
    echo -e "${C_G}==================================================${C_0}" >&2
    echo -e "${C_G}  Backup written${C_0}" >&2
    echo -e "${C_G}==================================================${C_0}" >&2
    echo "" >&2
    echo "  File        : $out" >&2
    echo "  Service tag : $tag" >&2
    echo "  Size        : $(stat -c%s "$out") bytes" >&2
    echo "" >&2
    echo "  Into your password manager, in the entry of this machine:" >&2
    echo "    - the file above, as an attachment" >&2
    echo "    - the passphrase that opens it, as the entry password" >&2
    echo "" >&2
    echo "  Neither is any use without the other. Recording only the" >&2
    echo "  passphrase leaves nothing: keyslot 0 holds a random key that" >&2
    echo "  exists nowhere but inside this file." >&2
    echo "" >&2
    echo "  Then remove the copy from wherever you wrote it:" >&2
    echo "    shred -u $out" >&2
    echo "" >&2
  fi
}

main() {
  parse_arguments "$@"

  case "$SUBCOMMAND" in
    backup)
      check_root
      do_backup
      ;;
    verify)
      check_root
      do_verify
      ;;
    show)
      check_root
      do_show
      ;;
    *)
      err "Unknown command: $SUBCOMMAND"
      err "       Use --help for usage information"
      exit "${EXIT_USAGE}"
      ;;
  esac
}

main "$@"
