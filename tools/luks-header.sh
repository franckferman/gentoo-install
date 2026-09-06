#!/usr/bin/env bash
#
# gentoo-install — save, check and restore the LUKS2 header
# ----------------------------------------------------------------------------
# The header carries every keyslot, and a header lost is a disk lost even with
# the passphrase, the key file and a working TPM in hand. 'backup' copies it
# out and reads it back; 'restore' writes one back and is the most destructive
# command in this repository, because luksHeaderRestore rewrites all the
# keyslots at once. Nine refusals stand in front of it, and the UUID typed by
# hand is the one that --force cannot answer.
#
# Usage:  ./luks-header.sh <command> [options]   (--help for the list)
#
set -euo pipefail

readonly EXIT_SUCCESS=0
readonly EXIT_FAILURE=1
readonly EXIT_USAGE=2

# Configuration
SUBCOMMAND="backup"
FORCE="false"
DEVICE=""             # --device : bypasses detection
FILE_PATH=""          # --file   : header file, also read as the second word
OUT_DIR=""            # --out    : where backup writes the file
KEY_PATH=""           # --key    : GPG-wrapped key, for --from key
FROM="auto"           # --from   : key | pass | auto
ROOT_PREFIX=""        # --root   : installed tree, when run from a LiveCD
ALLOW_LOCAL="false"   # --allow-local : write onto the machine's own disk
FORCE_UUID="false"    # --force-uuid  : restore a file whose UUID differs
NO_CREDENTIAL="false" # --i-have-no-credential : restore without the proof
PASSPHRASE=""         # never exposed on the command line internally
PASSPHRASE_SOURCE="none"
PASSPHRASE_STDIN="false"
MAX_TRIES=3

# Paths tried when --key is not given, in order, under ROOT_PREFIX
KEY_CANDIDATES=("/boot/efi/luks-key.gpg" "/boot/efi/luks-master-key.gpg")
ERR_LOG="${TMPDIR:-/tmp}/gentoo-install-luks-header.log"

init_err_log() {
  # A fixed name in a world-writable directory is a file any local user can
  # replace with a symlink before this runs, and these tools are run as root:
  # the `: >"$ERR_LOG"` further down then truncates whatever it points at, and
  # the chmod beside it changes that file's mode. The installer learned this
  # one the hard way — `--log-file /dev/null` under sudo reached
  # `chmod 0600 /dev/null` and left the machine without a working shell — and
  # the tools never did.
  #
  # rm unlinks the symlink itself and never follows it. The create that
  # follows is O_EXCL, so if the name is taken again in between it fails
  # rather than writing through what was put back, and an unpredictable name
  # is used instead. Never test-then-open: the test and the open are two
  # moments, and whoever planted the symlink owns the time between them.
  rm -f -- "$ERR_LOG" 2>/dev/null || true
  (
    set -C
    : >"$ERR_LOG"
  ) 2>/dev/null || ERR_LOG="$(umask 077 && mktemp -t gentoo-install-luks-header.XXXXXX)"
  chmod 600 "$ERR_LOG" 2>/dev/null || true
}

# The credential file, at script level so the EXIT trap can still see it. A
# variable local to a function no longer exists when the trap fires, which
# under set -u ends on "unbound variable" and leaves the file behind.
CRED_FILE=""

# Where the header from before a restore was written. At script level too, so
# the failure path can name it: it is the only way back.
PRE_RESTORE=""

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
Usage: ./luks-header.sh [COMMAND] [FILE] [OPTIONS]

================================================================================
gentoo-install - LUKS header
Saves, checks and restores the LUKS2 header, the one thing no secret replaces
================================================================================

WHEN TO USE IT:
    Before anything that writes near the start of the disk: a BIOS update, a
    partitioning tool, a rescue session started on the wrong device. The header
    carries the keyslots, and a header lost is a disk lost even with the
    passphrase, luks-key.gpg and a working TPM in hand. It is the only incident
    of the whole procedure against which no secret protects.

    Run it on the machine, in its chroot, or from a LiveCD with --device.

WHAT IT DOES:
    'backup' copies the header out and reads it back to prove the copy. The
    file it writes holds every keyslot: it is a secret, mode 600, and it is
    kept exactly where luks-key.gpg is kept.

WHAT A RESTORE DESTROYS:
    luksHeaderRestore rewrites all the keyslots at once. Every secret created
    since the file was taken is gone the moment it returns: a user passphrase,
    a maintenance passphrase, the clevis binding sealed in the TPM. Nothing is
    merged, the header is replaced.

COMMANDS:
    backup              Copy the header out, read it back (default)
    verify              Is this file this container's header, and does a
                        credential open a slot inside it
    list                Keyslots and tokens, of the container or of a file
    diff                What the container has today that the file does not
    restore             Write a header file back. Rewrites every keyslot

OPTIONS:
    -h, --help          Show this help
    -q, --quiet         Essential output only
        --device DEV    LUKS container. Detected from the volume group
                        inside it when omitted
        --file FILE     Header file. Also taken as the second word: verify FILE
        --out DIR       Where backup writes (default: the current directory)
        --key FILE      GPG-wrapped key. Default: /boot/efi/luks-key.gpg
        --from SOURCE   key | pass | auto  (default: auto)
        --root DIR      Root of the installed system, for a run from a LiveCD
        --allow-local   Let backup write onto this machine's own disk
        --force-uuid    Restore a file whose UUID differs from the container
        --i-have-no-credential
                        Restore a file nothing was proven to open
        --force         Skip every confirmation (non-interactive)

PASSPHRASE (opens luks-key.gpg with --from key, opens a slot with --from pass):
        (nothing)               Asked, not echoed, q cancels
        GI_PASSPHRASE          Environment variable
        --passphrase-file FILE  First line of a file, keep it mode 600
        --passphrase-stdin      Read from stdin
        --passphrase PASS       Literal value, visible in `ps`

WHAT A REAL VERIFICATION IS:
    That the file looks like a LUKS2 header proves nothing. What proves it is a
    credential opening a slot inside the file itself, which is what 'verify'
    does with --header: the backup, not the container, answers. Give it a
    passphrase or a key and it is a verification; give it nothing and it is
    only a plausibility check, and it says so.

WHAT --force DOES NOT SKIP:
    'restore' asks for the container UUID to be typed back, and --force does
    not answer that one. It is the only confirmation in the whole toolbox that
    --force cannot lift, because a restore aimed at the wrong device destroys
    two machines instead of one. The header saved just before the write is not
    optional either: there is no flag to skip it, and it is the only way back.

EXAMPLES:
    ./luks-header.sh list
        Keyslots and tokens of the container. Changes nothing.

    ./luks-header.sh backup --out /mnt/usb
        Writes luks-header-TAG-UUID-DATE.bin on the stick and reads it back.

    GI_PASSPHRASE="$PW" ./luks-header.sh verify /mnt/usb/luks-header-TAG.bin
        Proves the key opens a slot inside that file. A backup nobody ever
        verified is not a backup.

    ./luks-header.sh diff /mnt/usb/luks-header-TAG.bin
        Which slots exist today and not in the file. Answers "is this backup
        still up to date".

    ./luks-header.sh restore /mnt/usb/luks-header-TAG.bin
        The dangerous one. Refuses on an open container, saves the current
        header first, names what it is about to destroy, and asks for the UUID.

HELP_EOF
}

parse_arguments() {
  if [[ $# -gt 0 ]] && [[ "$1" != -* ]]; then
    SUBCOMMAND="$1"
    shift
  fi

  # A second bare word is the header file: 'verify FILE' is how the procedure
  # writes it, and every command but backup needs one.
  if [[ $# -gt 0 ]] && [[ "$1" != -* ]]; then
    FILE_PATH="$1"
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
      --allow-local)
        ALLOW_LOCAL="true"
        shift
        ;;
      --force-uuid)
        FORCE_UUID="true"
        shift
        ;;
      --i-have-no-credential)
        NO_CREDENTIAL="true"
        shift
        ;;
      --force)
        FORCE="true"
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
      --file)
        [[ $# -ge 2 ]] || {
          err "--file requires a value"
          exit "${EXIT_USAGE}"
        }
        FILE_PATH="$2"
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
      --key)
        [[ $# -ge 2 ]] || {
          err "--key requires a value"
          exit "${EXIT_USAGE}"
        }
        KEY_PATH="$2"
        shift 2
        ;;
      --from)
        [[ $# -ge 2 ]] || {
          err "--from requires key, pass or auto"
          exit "${EXIT_USAGE}"
        }
        case "$2" in
          key | pass | auto) FROM="$2" ;;
          *)
            err "Invalid --from: $2 (expected key, pass or auto)"
            exit "${EXIT_USAGE}"
            ;;
        esac
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
          err "Cannot read passphrase file: $2"
          exit "${EXIT_USAGE}"
        }
        PASSPHRASE="$(head -n 1 "$2")"
        PASSPHRASE_SOURCE="file:$2"
        shift 2
        ;;
      --passphrase-stdin)
        # Deferred: reading here would block --help on a terminal with
        # nothing piped in
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

  # The file is never guessed. Restoring the wrong one destroys a container
  # that still works, and no later check can undo that.
  case "$SUBCOMMAND" in
    verify | check | diff | compare | restore)
      if [[ -z "$FILE_PATH" ]]; then
        err "$SUBCOMMAND needs a header file"
        echo "  ./luks-header.sh $SUBCOMMAND FILE" >&2
        exit "${EXIT_USAGE}"
      fi
      ;;
  esac
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
# Prerequisites and devices
################################################################################

check_tools() {
  local missing=0 t
  for t in cryptsetup lsblk; do
    command -v "$t" >/dev/null 2>&1 || {
      err "  missing: $t"
      missing=$((missing + 1))
    }
  done
  if [[ $missing -gt 0 ]]; then
    err "$missing tool(s) missing"
    err "cryptsetup is on the LiveCD and in the installed system alike."
    err "A stage extracted but not yet configured has it in /usr/sbin."
    return 1
  fi
  return 0
}

reset_err_log() {
  : >"$ERR_LOG"
  chmod 600 "$ERR_LOG" 2>/dev/null || true
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

  err "Cannot tell which container to use. Name it with --device"
  return 1
}

resolve_restore_target() {
  # A restore is precisely what one runs when the header no longer reads, so
  # unlike resolve_device this one accepts a device cryptsetup does not
  # recognise. It then demands --device: a container with no readable header
  # cannot be found through vg1, and guessing here is how the wrong disk gets
  # rewritten.
  local dev

  if [[ -n "$DEVICE" ]]; then
    dev="/dev/$(normalize_device "$DEVICE")"
    [[ -b "$dev" ]] || {
      err "Device not found: $dev"
      return 1
    }
    if ! cryptsetup isLuks "$dev" 2>/dev/null; then
      warn "$dev carries no readable LUKS header"
      warn "  That is the case this command exists for, and also what a"
      warn "  wrong --device looks like. Check the disk before going on."
    fi
    echo "$dev"
    return 0
  fi

  resolve_device
}

open_mapper_of() {
  # Name of the open mapper backed by this container, or "no".
  # The loop swallows its own failures: a mapper that does not match is the
  # normal case, and under set -e a bare failing grep would end the script.
  local dev="$1" name
  for name in $(dmsetup ls --target crypt 2>/dev/null | awk '{print $1}' || true); do
    [[ -n "$name" ]] || continue
    if cryptsetup status "$name" 2>/dev/null | grep -q "device:.*${dev}\$"; then
      echo "$name"
      return 0
    fi
  done
  echo "no"
  return 0
}

disk_behind() {
  # The physical disk under a node, walked down through the whole stack: an
  # LV sits on a LUKS mapping which sits on a partition. lsblk -s prints that
  # chain, and only the disk at its end is comparable between two nodes.
  local node="${1:-}" disk=""
  [[ -n "$node" ]] || return 1
  disk="$(lsblk -s -no NAME,TYPE "$node" 2>/dev/null | awk '$2 == "disk" { d = $1 } END { print d }' || true)"
  [[ -n "$disk" ]] || return 1
  echo "$disk"
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

################################################################################
# Reading a header, device or file alike
################################################################################

header_is_luks2() {
  cryptsetup isLuks --type luks2 "$1" 2>/dev/null
}

header_uuid() {
  # Every reader here ends in "|| true": a container whose header is gone is
  # the case this tool is for, and under pipefail a failing luksUUID would
  # end the script before it could say so.
  cryptsetup luksUUID "$1" 2>/dev/null | tr -d ' \n' || true
}

header_version() {
  cryptsetup luksDump "$1" 2>/dev/null | awk '/^Version:/ { print $2; exit }' || true
}

header_slots() {
  # Bounded to the Keyslots section: Data segments, Tokens and Digests use
  # the same "  N: type" shape, and a bare grep would mix them in. Only the
  # leading number is taken, or the 2 of "luks2" would count as a slot too.
  cryptsetup luksDump "$1" 2>/dev/null | awk '
        /^Keyslots:/     { in_slots = 1; next }
        /^[A-Za-z]/      { in_slots = 0 }
        in_slots && /^  [0-9]+:/ { sub(":", "", $1); print $1 }' || true
}

header_tokens() {
  # Same bounding, same reason. A token is printed as "N: type", and the type
  # is what matters here: 'clevis' is the TPM sealing.
  cryptsetup luksDump "$1" 2>/dev/null | awk '
        /^Tokens:/       { in_tok = 1; next }
        /^[A-Za-z]/      { in_tok = 0 }
        in_tok && /^  [0-9]+:/ { sub(":", "", $1); print $1 " " $2 }' || true
}

header_data_offset() {
  # Where the payload starts. A header restored with another offset opens its
  # slots and reads nothing but noise, which is the worst kind of failure
  # because it looks like a success.
  cryptsetup luksDump "$1" 2>/dev/null | awk '
        /^Data segments:/ { in_seg = 1; next }
        /^[A-Za-z]/       { in_seg = 0 }
        in_seg && /offset:/ { gsub(/[^0-9]/, "", $2); print $2; exit }' || true
}

slots_line() {
  # One line for a report, without the trailing separator a tr would leave.
  header_slots "$1" | awk '{ printf "%s%s", (NR > 1 ? " " : ""), $0 } END { if (NR) printf "\n" }' || true
}

tokens_line() {
  header_tokens "$1" | awk '{ printf "%s%s", (NR > 1 ? ", " : ""), $0 } END { if (NR) printf "\n" }' || true
}

slot_meaning() {
  case "$1" in
    0) echo "the key luks-key.gpg opens, this machine's only master secret" ;;
    2) echo "the clevis key sealed in the TPM, what unlocks at boot" ;;
    *) echo "added by hand, a user or maintenance passphrase" ;;
  esac
}

describe_header() {
  # Structure only. The dump also prints salts and digests, and none of that
  # is ever put on screen: the tools of this box show no cryptographic
  # material, from a container or from a file.
  local target="$1" label="$2" slots tokens s id type

  slots="$(slots_line "$target")"
  tokens="$(header_tokens "$target")"

  printf "  %-14s %s\n" "$label" "$target" >&2
  printf "  %-14s %s\n" "LUKS version:" "$(header_version "$target")" >&2
  printf "  %-14s %s\n" "LUKS UUID:" "$(header_uuid "$target")" >&2
  printf "  %-14s %s\n" "Data offset:" "$(header_data_offset "$target") bytes" >&2
  echo "" >&2

  if [[ -z "$slots" ]]; then
    printf "  %-14s %b\n" "Keyslots:" "${C_R}none readable${C_0}" >&2
  else
    echo "  Keyslots:" >&2
    for s in $slots; do
      printf "    slot %-3s %b  %s\n" "$s" "${C_G}occupied${C_0}" "$(slot_meaning "$s")" >&2
    done
  fi
  echo "" >&2

  if [[ -z "$tokens" ]]; then
    printf "  %-14s %b\n" "Tokens:" "${C_Y}none${C_0}" >&2
    echo "    No token means no automatic unlock: the machine asks for the" >&2
    echo "    passphrase at every boot. ./tpm-reseal.sh puts one back." >&2
  else
    echo "  Tokens:" >&2
    while read -r id type; do
      [[ -n "$id" ]] || continue
      if [[ "$type" == "clevis" ]]; then
        printf "    token %-3s %-10s %s\n" "$id" "$type" "the TPM sealing, what unlocks at boot" >&2
      else
        printf "    token %-3s %-10s %s\n" "$id" "$type" "not written by this project" >&2
      fi
    done <<<"$tokens"
  fi
}

################################################################################
# Credential material
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

make_cred_file() {
  CRED_FILE="$(umask 077 && mktemp "$(secure_tmpdir)/gi-header-cred.XXXXXX")" || {
    err "Cannot create a temporary file"
    return 1
  }
  trap 'rm -f "${CRED_FILE:-}"' EXIT INT TERM
  return 0
}

drop_cred_file() {
  [[ -n "$CRED_FILE" ]] && rm -f "$CRED_FILE"
  CRED_FILE=""
  trap - EXIT INT TERM
  return 0
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

  if [[ "$FORCE" == "true" ]]; then
    err "--force, but no secret was given"
    echo "" >&2
    echo "  With --from key it opens luks-key.gpg, the one given when that" >&2
    echo "  file was created. With --from pass it is a LUKS passphrase itself." >&2
    echo "" >&2
    echo "    GI_PASSPHRASE=\"\$PW\" ./luks-header.sh --force" >&2
    echo "    ./luks-header.sh --force --passphrase-file FILE" >&2
    echo "" >&2
    return 1
  fi

  local tries=0
  while [[ $tries -lt $MAX_TRIES ]]; do
    tries=$((tries + 1))
    echo -n "Existing secret (q to cancel): " >&2
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

credential_from_key() {
  # The key material is written to a file because cryptsetup reads it from
  # one. umask keeps it unreadable to anyone else, and the trap removes it
  # even on Ctrl-C.
  local key rc=0
  key="$(resolve_key)" || {
    log "  no key file found"
    return 1
  }
  log "Key file: $key"

  command -v gpg >/dev/null 2>&1 || {
    err "  gpg is not installed here, the key file cannot be opened"
    err "  It lives in the installed system, not on the LiveCD"
    return 1
  }

  resolve_passphrase || return 1

  if [[ -z "${GPG_TTY:-}" ]]; then
    GPG_TTY="$(tty 2>/dev/null || echo /dev/tty)"
    export GPG_TTY
  fi

  # fd 3 carries the passphrase, so it never reaches argv
  gpg --quiet --batch --pinentry-mode loopback --passphrase-fd 3 \
    --decrypt "$key" 3<<<"$PASSPHRASE" >"$CRED_FILE" 2>>"$ERR_LOG" || rc=$?

  if [[ $rc -ne 0 ]]; then
    err "  GPG could not decrypt $key"
    err "  Wrong passphrase, or the file is damaged"
    err "  Passphrase source: $PASSPHRASE_SOURCE"
    sed 's/^/    /' "$ERR_LOG" >&2 2>/dev/null || true
    return 1
  fi

  [[ -s "$CRED_FILE" ]] || {
    err "  decryption produced an empty key"
    return 1
  }
  return 0
}

credential_from_pass() {
  resolve_passphrase || return 1
  printf '%s' "$PASSPHRASE" >"$CRED_FILE"
  return 0
}

credential_opens_header() {
  # The proof that decides a restore: the slot has to exist in the FILE, not
  # on the device. --header points the test at the backup, --test-passphrase
  # unlocks nothing, and --disable-external-tokens keeps a still-working TPM
  # from answering in place of the credential.
  local file="$1" dev="$2"

  cryptsetup open --test-passphrase --disable-external-tokens \
    --header "$file" --key-file "$CRED_FILE" "$dev" 2>>"$ERR_LOG"
}

credential_opens_device() {
  local dev="$1"

  cryptsetup open --test-passphrase --disable-external-tokens \
    --key-file "$CRED_FILE" "$dev" 2>>"$ERR_LOG"
}

credential_was_given() {
  # Whether the operator handed over something to prove with. Nothing given
  # is not an error for 'verify': it downgrades the answer, and the answer
  # says so rather than pretending.
  [[ -n "$PASSPHRASE" ]] && return 0
  [[ "$PASSPHRASE_STDIN" == "true" ]] && return 0
  [[ "$FROM" != "auto" ]] && return 0
  return 1
}

obtain_credential() {
  # Fills CRED_FILE from whichever route is asked for. Nothing is tested here:
  # the caller decides what the material has to open, the file or the device.
  local order=() m

  make_cred_file || return 1

  case "$FROM" in
    auto) order=(key pass) ;;
    *) order=("$FROM") ;;
  esac

  for m in "${order[@]}"; do
    log "Credential from: $m"
    : >"$CRED_FILE"
    case "$m" in
      key) credential_from_key || continue ;;
      pass) credential_from_pass || continue ;;
    esac
    return 0
  done

  err "No credential could be built"
  echo "" >&2
  echo "  key   luks-key.gpg plus the passphrase that opens it" >&2
  echo "  pass  a LUKS passphrase, typed or given" >&2
  echo "" >&2
  return 1
}

################################################################################
# Backup files
################################################################################

backup_file_name() {
  local dir="$1" tag="$2" uuid="$3" suffix="${4:-}"
  echo "${dir}/luks-header-${tag}-${uuid}-$(date +%Y%m%d-%H%M%S)${suffix}.bin"
}

write_header_backup() {
  # umask before the copy, chmod after: luksHeaderBackup creates the file
  # 0400, and a header holds every keyslot of the container. It is opened by
  # the same secrets as the disk, so it is kept like luks-key.gpg.
  local dev="$1" out="$2" bytes="${3:-16777216}" rc=0

  reset_err_log
  (umask 077 && cryptsetup luksHeaderBackup --header-backup-file "$out" "$dev") 2>>"$ERR_LOG" || rc=$?

  if [[ $rc -ne 0 ]]; then
    # A container whose header no longer reads has no luksHeaderBackup, and
    # that is exactly when a copy of what is there matters most.
    warn "luksHeaderBackup refused, falling back to a raw copy"
    sed 's/^/    /' "$ERR_LOG" >&2 2>/dev/null || true
    rc=0
    (umask 077 && dd if="$dev" of="$out" bs=4096 count=$(((bytes + 4095) / 4096)) \
      status=none) 2>>"$ERR_LOG" || rc=$?
    if [[ $rc -ne 0 ]]; then
      err "Could not copy the header of $dev at all"
      sed 's/^/    /' "$ERR_LOG" >&2 2>/dev/null || true
      return 1
    fi
    warn "  Raw copy of the first $bytes bytes of $dev"
  fi

  # Only a regular file. Running as root, chmod on a device node the caller
  # named (--out /dev/null) would change a node the whole system shares.
  if [[ -f "$out" && ! -L "$out" ]]; then
    chmod 600 "$out" 2>/dev/null || true
  fi
  [[ -s "$out" ]] || {
    err "The written file is empty: $out"
    return 1
  }
  return 0
}

file_sha256() {
  command -v sha256sum >/dev/null 2>&1 || {
    echo "unavailable"
    return 0
  }
  sha256sum "$1" 2>/dev/null | awk '{print $1}' || true
}

write_meta_file() {
  # Plain text, no secret: what the header looked like when it was taken.
  # Without it a restore is done blind, on a file nobody can date.
  local out="$1" dev="$2" tag="$3" meta="${1}.meta"

  {
    echo "# gentoo-install luks-header backup metadata - contains no secret"
    echo "file=$(basename "$out")"
    echo "sha256=$(file_sha256 "$out")"
    echo "uuid=$(header_uuid "$out")"
    echo "device=$dev"
    echo "service_tag=$tag"
    echo "header_version=$(header_version "$out")"
    echo "data_offset=$(header_data_offset "$out")"
    echo "keyslots=$(slots_line "$out")"
    echo "tokens=$(tokens_line "$out")"
    echo "cryptsetup=$(cryptsetup --version 2>/dev/null | awk '{print $2}')"
    echo "date=$(date -Is)"
  } >"$meta" 2>/dev/null || {
    warn "Could not write $meta"
    return 1
  }

  if [[ -f "$meta" && ! -L "$meta" ]]; then
    chmod 644 "$meta" 2>/dev/null || true
  fi
  return 0
}

file_looks_like_header() {
  # Read back before the copy is called a backup. A backup that was never
  # verified is not a backup: it gives the illusion of a way out.
  local file="$1"

  [[ -f "$file" ]] || {
    err "Not a file: $file"
    return 1
  }
  [[ -r "$file" ]] || {
    err "Cannot read: $file"
    return 1
  }
  [[ -s "$file" ]] || {
    err "Empty file: $file"
    return 1
  }

  if ! header_is_luks2 "$file"; then
    err "$file is not a LUKS2 header"
    err "  A header backup is 16 MiB of binary starting with LUKS2 magic."
    err "  This one is $(stat -c%s "$file" 2>/dev/null || echo '?') bytes."
    return 1
  fi

  [[ -n "$(header_slots "$file")" ]] || {
    err "$file holds no readable keyslot"
    err "  Nothing would open the container after restoring it."
    return 1
  }
  return 0
}

file_matches_device() {
  local file="$1" dev="$2" fu du

  fu="$(header_uuid "$file")"
  du="$(header_uuid "$dev")"

  if [[ -z "$du" ]]; then
    warn "The container has no readable UUID, nothing to compare against"
    return 1
  fi
  if [[ "$fu" != "$du" ]]; then
    err "UUID mismatch"
    err "  file      : $fu"
    err "  container : $du"
    err "  This file is another machine's header."
    return 1
  fi
  return 0
}

################################################################################
# Commands
################################################################################

do_backup() {
  local dev uuid tag dir out disk_dev disk_out

  check_tools || exit "${EXIT_FAILURE}"
  dev="$(resolve_device)" || exit "${EXIT_FAILURE}"
  uuid="$(header_uuid "$dev")"
  tag="$(machine_id)"
  dir="${OUT_DIR:-$PWD}"

  ok "Container   : $dev"
  ok "LUKS UUID   : $uuid"
  ok "Service tag : $tag"

  # The header belongs off the machine. One saved on the disk it protects is
  # lost with that disk, which is the only case it serves.
  disk_dev="$(disk_behind "$dev" 2>/dev/null || true)"
  disk_out="$(disk_behind "$(df --output=source "$dir" 2>/dev/null | tail -n 1)" 2>/dev/null || true)"
  if [[ -z "$disk_dev" || -z "$disk_out" ]]; then
    warn "Could not tell which disk carries $dir"
    warn "  Check by hand that it is not this machine's own disk."
  elif [[ "$disk_dev" == "$disk_out" ]]; then
    if [[ "$ALLOW_LOCAL" == "true" ]]; then
      warn "$dir is on $disk_dev, the machine's own disk (--allow-local)"
      warn "  This copy dies with the disk it is meant to rescue."
    else
      err "$dir is on $disk_dev, the disk that carries the container"
      err "  A header saved there is gone with the disk it protects."
      err "  Write it on a stick or a share: --out /mnt/usb"
      err "  Or accept it, knowingly: --allow-local"
      exit "${EXIT_FAILURE}"
    fi
  fi

  if [[ -n "$FILE_PATH" ]]; then
    out="$FILE_PATH"
  else
    out="$(backup_file_name "$dir" "$tag" "$uuid")"
  fi

  # Never silently overwrite: an older file may be the only header that
  # matches a container still in service somewhere.
  if [[ -e "$out" ]]; then
    warn "$out already exists"
    if ! confirm "Overwrite it?" "N"; then
      out="${out%.bin}-$(date +%Y%m%d-%H%M%S).bin"
      log "Writing to $out instead"
    else
      rm -f "$out"
    fi
  fi

  log "Writing the header"
  write_header_backup "$dev" "$out" || exit "${EXIT_FAILURE}"

  log "Reading it back"
  file_looks_like_header "$out" || {
    err "The copy is not a usable header. It is not a backup."
    exit "${EXIT_FAILURE}"
  }
  file_matches_device "$out" "$dev" || {
    err "The copy does not match the container it was taken from"
    exit "${EXIT_FAILURE}"
  }

  write_meta_file "$out" "$dev" "$tag" || true

  if verbose_enough; then
    echo "" >&2
    echo -e "${C_G}==================================================${C_0}" >&2
    echo -e "${C_G}  Header saved${C_0}" >&2
    echo -e "${C_G}==================================================${C_0}" >&2
    echo "" >&2
    echo "  File        : $out" >&2
    echo "  Metadata    : ${out}.meta" >&2
    echo "  Size        : $(stat -c%s "$out") bytes, mode 600" >&2
    echo "  Service tag : $tag" >&2
    echo "  LUKS UUID   : $uuid" >&2
    echo "  Keyslots    : $(slots_line "$out")" >&2
    echo "" >&2
    echo "  This file holds every keyslot of the container. It is not a key" >&2
    echo "  in clear, but the same secrets open it: keep it where" >&2
    echo "  luks-key.gpg is kept, in your password manager, with the machine" >&2
    echo "  it belongs to, and never on the disk it protects." >&2
    echo "" >&2
    echo "  It has been read back, but nothing has been proven to open it." >&2
    echo "  Do that now, once:" >&2
    echo "    ./luks-header.sh verify $out" >&2
    echo "" >&2
  else
    ok "Header saved to $out (mode 600)"
  fi
}

do_verify() {
  local file="$FILE_PATH" dev="" proven="false" recorded="" current=""

  check_tools || exit "${EXIT_FAILURE}"
  reset_err_log

  log "Checking $file"
  file_looks_like_header "$file" || exit "${EXIT_FAILURE}"
  ok "  LUKS2 header, UUID $(header_uuid "$file"), slots $(slots_line "$file")"

  if [[ -f "${file}.meta" ]]; then
    recorded="$(awk -F= '/^sha256=/ {print $2}' "${file}.meta" 2>/dev/null || true)"
    current="$(file_sha256 "$file")"
    if [[ -n "$recorded" && "$recorded" != "unavailable" && "$recorded" != "$current" ]]; then
      err "  The file no longer matches its own .meta checksum"
      err "  It was truncated or rewritten since it was taken."
      exit "${EXIT_FAILURE}"
    fi
    log "  Checksum matches ${file}.meta"
  fi

  if dev="$(resolve_device 2>/dev/null)"; then
    log "Container: $dev"
    file_matches_device "$file" "$dev" || exit "${EXIT_FAILURE}"
    ok "  Same UUID as $dev, this file is this container's header"
  else
    dev="$file"
    warn "No container found here, the UUID was compared against nothing"
    warn "  Name it with --device to make this a full verification."
  fi

  if credential_was_given; then
    obtain_credential || exit "${EXIT_FAILURE}"
    log "Testing the credential against the file itself"
    if credential_opens_header "$file" "$dev"; then
      proven="true"
      ok "  It opens a keyslot inside $file"
    else
      err "  It opens no keyslot inside $file"
      err "  Passphrase source: $PASSPHRASE_SOURCE"
      err "  The file is a header, but not one this secret can open."
      sed 's/^/    /' "$ERR_LOG" >&2 2>/dev/null || true
      drop_cred_file
      exit "${EXIT_FAILURE}"
    fi
    drop_cred_file
  else
    warn "No credential given, nothing was proven to open this file"
    warn "  GI_PASSPHRASE, --passphrase-file, or --from pass"
  fi

  if verbose_enough; then
    echo "" >&2
    echo -e "${C_G}==================================================${C_0}" >&2
    if [[ "$proven" == "true" ]]; then
      echo -e "${C_G}  Verified${C_0}" >&2
    else
      echo -e "${C_G}  Plausible, not proven${C_0}" >&2
    fi
    echo -e "${C_G}==================================================${C_0}" >&2
    echo "" >&2
    echo "  File     : $file" >&2
    echo "  UUID     : $(header_uuid "$file")" >&2
    echo "  Keyslots : $(slots_line "$file")" >&2
    echo "" >&2
    if [[ "$proven" == "true" ]]; then
      echo "  A credential opened a slot inside the file. This backup is" >&2
      echo "  one a restore could be run from." >&2
    else
      echo "  The file is a LUKS2 header, and that is all this run knows." >&2
      echo "  A backup nobody ever opened is not a backup: run it again" >&2
      echo "  with the secret, and keep the result with the file." >&2
    fi
    echo "" >&2
  else
    ok "Verify: $file, proven=$proven"
  fi
}

do_list() {
  local target label

  check_tools || exit "${EXIT_FAILURE}"

  if [[ -n "$FILE_PATH" ]]; then
    file_looks_like_header "$FILE_PATH" || exit "${EXIT_FAILURE}"
    target="$FILE_PATH"
    label="Header file:"
  else
    target="$(resolve_device)" || exit "${EXIT_FAILURE}"
    label="Container:"
  fi

  echo "" >&2
  echo -e "${C_B}=== Keyslots and tokens ===${C_0}" >&2
  echo "" >&2
  describe_header "$target" "$label"
  echo "" >&2
  echo "  Slots 0 and 2 occupied, one clevis token, is the nominal state of a" >&2
  echo "  machine installed by this project. Slot 0 alone means the sealing" >&2
  echo "  is gone." >&2
  echo "" >&2
}

do_diff() {
  local file="$FILE_PATH" dev only_dev="" only_file="" common="" s
  local dev_slots file_slots dev_tokens file_tokens

  check_tools || exit "${EXIT_FAILURE}"
  file_looks_like_header "$file" || exit "${EXIT_FAILURE}"
  dev="$(resolve_device)" || exit "${EXIT_FAILURE}"

  echo "" >&2
  echo -e "${C_B}=== Backup against the live header ===${C_0}" >&2
  echo "" >&2
  printf "  %-14s %s\n" "File:" "$file" >&2
  printf "  %-14s %s\n" "Container:" "$dev" >&2

  if [[ "$(header_uuid "$file")" != "$(header_uuid "$dev")" ]]; then
    printf "  %-14s %b\n" "UUID:" "${C_R}different${C_0}" >&2
    echo "" >&2
    err "  file      : $(header_uuid "$file")"
    err "  container : $(header_uuid "$dev")"
    err "  These are two different containers, and nothing else here is"
    err "  comparable between them."
    exit "${EXIT_FAILURE}"
  fi
  printf "  %-14s %b\n" "UUID:" "${C_G}same${C_0}" >&2

  if [[ "$(header_data_offset "$file")" != "$(header_data_offset "$dev")" ]]; then
    printf "  %-14s %b\n" "Data offset:" "${C_R}different${C_0}" >&2
  else
    printf "  %-14s %b\n" "Data offset:" "${C_G}same${C_0}" >&2
  fi

  # Structure only, never the material: two slots holding different secrets
  # are told apart by nothing this tool is allowed to read.
  dev_slots="$(slots_line "$dev")"
  file_slots="$(slots_line "$file")"

  for s in $dev_slots; do
    if [[ " $file_slots " == *" $s "* ]]; then
      common="$common $s"
    else
      only_dev="$only_dev $s"
    fi
  done
  for s in $file_slots; do
    [[ " $dev_slots " == *" $s "* ]] || only_file="$only_file $s"
  done

  echo "" >&2
  echo "  Keyslots:" >&2
  for s in $common; do
    printf "    slot %-3s %b  %s\n" "$s" "${C_G}in both${C_0}" "$(slot_meaning "$s")" >&2
  done
  for s in $only_dev; do
    printf "    slot %-3s %b  %s\n" "$s" "${C_R}only on the container${C_0}" "$(slot_meaning "$s")" >&2
  done
  for s in $only_file; do
    printf "    slot %-3s %b  %s\n" "$s" "${C_Y}only in the file${C_0}" "$(slot_meaning "$s")" >&2
  done

  dev_tokens="$(tokens_line "$dev")"
  file_tokens="$(tokens_line "$file")"
  echo "" >&2
  if [[ "$dev_tokens" == "$file_tokens" ]]; then
    printf "  %-14s %b %s\n" "Tokens:" "${C_G}same${C_0}" "${dev_tokens:-none}" >&2
  else
    printf "  %-14s %b\n" "Tokens:" "${C_Y}different${C_0}" >&2
    printf "    %-12s %s\n" "container:" "${dev_tokens:-none}" >&2
    printf "    %-12s %s\n" "file:" "${file_tokens:-none}" >&2
  fi

  echo "" >&2
  if [[ -z "$only_dev" && "$dev_tokens" == "$file_tokens" ]]; then
    echo "  Nothing on the container is missing from the file: this backup" >&2
    echo "  is still up to date." >&2
  elif [[ -n "$only_dev" ]]; then
    echo "  The container holds keyslots this file does not. A restore" >&2
    echo "  removes them, and 'restore' names them one by one before it" >&2
    echo "  writes. Take a fresh backup instead:" >&2
    echo "    ./luks-header.sh backup --out DIR" >&2
  else
    echo "  Every keyslot of the container is also in the file, only the" >&2
    echo "  tokens differ. A restore would put the file's tokens back;" >&2
    echo "  ./tpm-reseal.sh reseal is what seals against this TPM." >&2
  fi
  echo "" >&2
}

confirm_uuid() {
  # Not confirm(): --force answers every other question in this box, and this
  # is the one it must not answer. Typing the UUID is what separates the right
  # device from the one next to it, and no flag can type it for the operator.
  local expected="$1" typed="" tries=0

  if [[ "$FORCE" == "true" ]]; then
    warn "--force does not answer this one"
  fi

  while [[ $tries -lt $MAX_TRIES ]]; do
    tries=$((tries + 1))
    echo -n "Type the UUID above to confirm (q to cancel): " >&2
    read -r typed || {
      echo "" >&2
      err "No input available"
      return 1
    }
    [[ "$typed" == "q" ]] && return 1
    [[ "$typed" == "$expected" ]] && return 0
    err "That is not the UUID"
  done
  return 1
}

announce_losses() {
  # Named, not counted. "The keyslots will be rewritten" is a category, and a
  # category is not something an operator can weigh. Each slot about to go is
  # printed with the secret it carries and what stops working without it.
  local dev="$1" file="$2" dev_slots file_slots dev_tokens file_tokens s lost=0

  dev_slots="$(slots_line "$dev")"
  file_slots="$(slots_line "$file")"
  dev_tokens="$(tokens_line "$dev")"
  file_tokens="$(tokens_line "$file")"

  if [[ -z "$dev_slots" ]]; then
    warn "  No readable keyslot on the container today: nothing to lose"
    return 0
  fi

  for s in $dev_slots; do
    if [[ " $file_slots " == *" $s "* ]]; then
      continue
    fi
    lost=$((lost + 1))
    warn "  slot $s, occupied today, absent from the file"
    case "$s" in
      0)
        warn "      it holds the key luks-key.gpg opens, and that file"
        warn "      stops opening this machine the moment it is gone"
        ;;
      2)
        warn "      it holds the clevis key sealed in the TPM: the"
        warn "      machine asks for the passphrase at every boot until"
        warn "      ./tpm-reseal.sh reseal is run"
        ;;
      *)
        warn "      a passphrase added by hand, a user's or a"
        warn "      maintenance one: whoever types it is locked out"
        ;;
    esac
  done

  if [[ "$dev_tokens" != "$file_tokens" && -n "$dev_tokens" ]]; then
    lost=$((lost + 1))
    warn "  tokens: $dev_tokens today, ${file_tokens:-none} in the file"
    warn "      a clevis token that goes away takes the automatic unlock"
    warn "      with it, and ./tpm-reseal.sh reseal puts it back"
  elif [[ "$dev_tokens" != "$file_tokens" ]]; then
    warn "  tokens: none today, $file_tokens in the file"
    warn "      that token comes back, sealed against the firmware as it"
    warn "      was then. ./tpm-reseal.sh reseal is what settles it"
  fi

  if [[ $lost -eq 0 ]]; then
    skip "  Every slot and token present today is also in the file"
  fi
  return 0
}

do_restore() {
  local file="$FILE_PATH" dev mapper uuid_file uuid_dev expected dir tag
  local off_file off_dev bytes

  check_tools || exit "${EXIT_FAILURE}"
  reset_err_log
  dev="$(resolve_restore_target)" || exit "${EXIT_FAILURE}"

  ok "Container : $dev"
  ok "File      : $file"

  # 1. An open container is rewritten under a live mapping, and the first
  # write after that lands on data no key describes any more. Checked before
  # anything else because it is the one refusal that costs data, not time.
  mapper="$(open_mapper_of "$dev")"
  if [[ "$mapper" != "no" ]]; then
    err "$dev is open as /dev/mapper/$mapper"
    err "  Swapping the header under a live mapping corrupts the data on"
    err "  the first write. --force does not lift this one."
    err "  Close it first: ./luks-open.sh close, or cryptsetup close $mapper"
    exit "${EXIT_FAILURE}"
  fi

  # 2. The file is a LUKS2 header, and it is this container's header.
  file_looks_like_header "$file" || exit "${EXIT_FAILURE}"
  uuid_file="$(header_uuid "$file")"
  uuid_dev="$(header_uuid "$dev")"

  if [[ -z "$uuid_dev" ]]; then
    warn "No readable header on $dev, its UUID cannot be compared"
    warn "  Which is the case this command exists for. The file's UUID is"
    warn "  the only one available, and it is what will be asked for."
    expected="$uuid_file"
  elif [[ "$uuid_file" != "$uuid_dev" ]]; then
    if [[ "$FORCE_UUID" != "true" ]]; then
      err "UUID mismatch, this file is not this container's header"
      err "  file      : $uuid_file"
      err "  container : $uuid_dev"
      err "  Restoring it would destroy a container that still works,"
      err "  and would not open the one the file came from."
      err "  If the container was reprovisioned since: --force-uuid"
      exit "${EXIT_FAILURE}"
    fi
    warn "UUID mismatch, allowed by --force-uuid"
    warn "  file      : $uuid_file"
    warn "  container : $uuid_dev"
    expected="$uuid_file"
  else
    expected="$uuid_dev"
  fi

  # 2b. Geometry, the check the audit adds to the eight. A header put back
  # with another payload offset opens its slots and reads noise, which is the
  # failure that looks like a success.
  off_file="$(header_data_offset "$file")"
  off_dev="$(header_data_offset "$dev")"
  if [[ -n "$off_dev" && -n "$off_file" && "$off_file" != "$off_dev" ]]; then
    err "Data offset mismatch: $off_file in the file, $off_dev on $dev"
    err "  The slots would open and the volume would read as noise."
    err "  This one has no override."
    exit "${EXIT_FAILURE}"
  fi

  # 3. Nothing is restored that nobody can open. Tested against the file,
  # because it is the file's keyslots that will be there afterwards.
  if [[ "$NO_CREDENTIAL" == "true" ]]; then
    warn "No credential will be proven (--i-have-no-credential)"
    warn "  After the write, the only secrets that open $dev are the ones"
    warn "  inside $file. If none of them is known, the machine is lost"
    warn "  and this run is what loses it."
    if ! confirm "Restore a header nothing was proven to open?" "N"; then
      log "Cancelled, nothing changed"
      exit "${EXIT_SUCCESS}"
    fi
  else
    obtain_credential || exit "${EXIT_FAILURE}"
    log "Testing the credential against the file"
    if ! credential_opens_header "$file" "$dev"; then
      err "The credential opens no keyslot inside $file"
      err "  Passphrase source: $PASSPHRASE_SOURCE"
      err "  Restoring it would leave a container nothing here can open."
      sed 's/^/    /' "$ERR_LOG" >&2 2>/dev/null || true
      err "  Nothing has been written."
      drop_cred_file
      exit "${EXIT_FAILURE}"
    fi
    ok "  The credential opens a keyslot inside the file"
  fi

  # 4. The header on the disk right now, saved first. No option skips it:
  # after luksHeaderRestore it is the only way back.
  tag="$(machine_id)"
  dir="${OUT_DIR:-$(dirname "$file")}"
  [[ -w "$dir" ]] || {
    warn "$dir is not writable, saving the current header in /tmp instead"
    warn "  /tmp does not survive a reboot: copy it out before rebooting."
    dir="/tmp"
  }
  bytes="$(stat -c%s "$file" 2>/dev/null || echo 16777216)"
  PRE_RESTORE="$(backup_file_name "$dir" "$tag" "${uuid_dev:-unknown}" "-before-restore")"

  log "Saving the header that is on $dev right now"
  write_header_backup "$dev" "$PRE_RESTORE" "$bytes" || {
    err "The current header could not be saved, so nothing will be written"
    err "  There would be no way back. Free some space, or --out DIR."
    drop_cred_file
    exit "${EXIT_FAILURE}"
  }
  ok "  Saved: $PRE_RESTORE"

  # 5. What disappears, named one by one. Then 6, the UUID typed back.
  echo "" >&2
  warn "About to rewrite every keyslot of $dev with those of $file."
  announce_losses "$dev" "$file"
  echo "" >&2
  warn "LUKS UUID of the container: $expected"

  if ! confirm_uuid "$expected"; then
    log "Cancelled, nothing changed"
    log "  The header saved a moment ago is still at $PRE_RESTORE"
    drop_cred_file
    exit "${EXIT_SUCCESS}"
  fi

  # cryptsetup asks its own question on stdin. --batch-mode takes it out of
  # the way: the UUID typed above is the stronger of the two, and two prompts
  # fighting over stdin is how a script ends up answering for the operator.
  log "Restoring"
  if ! cryptsetup --batch-mode luksHeaderRestore \
    --header-backup-file "$file" "$dev" 2>>"$ERR_LOG"; then
    err "luksHeaderRestore failed"
    sed 's/^/    /' "$ERR_LOG" >&2 2>/dev/null || true
    err "The header on $dev may be half written. To put back the one"
    err "from before this run:"
    err "  cryptsetup luksHeaderRestore --header-backup-file $PRE_RESTORE $dev"
    drop_cred_file
    exit "${EXIT_FAILURE}"
  fi

  # 7. The same credential, now against the disk. And 8 when it says no:
  # where the header from before this run is, and the line that puts it back.
  if [[ "$NO_CREDENTIAL" != "true" ]]; then
    log "Testing the credential against the container"
    if credential_opens_device "$dev"; then
      ok "  It opens $dev: the restored header is usable"
    else
      err "  It opens nothing on $dev"
      echo "" >&2
      err "  The credential opened a slot inside the file a moment ago,"
      err "  so the write is what went wrong. Go back now, before"
      err "  anything else touches this disk:"
      err "    cryptsetup luksHeaderRestore --header-backup-file $PRE_RESTORE $dev"
      echo "" >&2
      err "  That file is the header $dev had before this run. Keep it"
      err "  until the machine boots again, whatever the outcome."
      drop_cred_file
      exit "${EXIT_FAILURE}"
    fi
  else
    warn "Nothing was proven before, so nothing is re-tested now"
    warn "  Whether $dev opens is unknown until someone tries a secret."
  fi

  drop_cred_file

  if verbose_enough; then
    echo "" >&2
    echo -e "${C_G}==================================================${C_0}" >&2
    echo -e "${C_G}  Header restored${C_0}" >&2
    echo -e "${C_G}==================================================${C_0}" >&2
    echo "" >&2
    echo "  Container   : $dev" >&2
    echo "  From        : $file" >&2
    echo "  Previous    : $PRE_RESTORE" >&2
    echo "  Keyslots    : $(slots_line "$dev")" >&2
    echo "  Tokens      : $(tokens_line "$dev")" >&2
    echo "" >&2
    echo "  What is left to do:" >&2
    echo "    - the clevis binding comes from the file, not from this TPM:" >&2
    echo "      run ./tpm-reseal.sh reseal and reboot to check it holds" >&2
    echo "    - every keyslot added since the file was taken is gone, and" >&2
    echo "      the people who used those passphrases have to be told" >&2
    echo "    - your password manager entry for this machine lists slots" >&2
    echo "      that may no longer exist: correct it now, while it is fresh" >&2
    echo "" >&2
    echo "  Keep $PRE_RESTORE until the machine has booted on its own." >&2
    echo "" >&2
  else
    ok "Header restored on $dev from $file, previous at $PRE_RESTORE"
  fi
}

main() {
  parse_arguments "$@"
  init_err_log

  case "$SUBCOMMAND" in
    backup | save)
      check_root
      do_backup
      ;;
    verify | check)
      check_root
      do_verify
      ;;
    list | show)
      check_root
      do_list
      ;;
    diff | compare)
      check_root
      do_diff
      ;;
    restore)
      check_root
      do_restore
      ;;
    *)
      err "Unknown command: $SUBCOMMAND"
      err "       Use --help for usage information"
      exit "${EXIT_USAGE}"
      ;;
  esac
}

main "$@"
