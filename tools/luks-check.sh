#!/usr/bin/env bash
#
# gentoo-install — LUKS container diagnostics, read-only
# ----------------------------------------------------------------------------
# Reports on a LUKS container without changing it: keyslots, clevis tokens, the
# TPM policy, the recovery key file, and whether a passphrase or a key file
# still opens it. It opens nothing, writes nothing and touches no keyslot, so
# it is the first thing to run on a machine that will not boot, before any
# decision is taken. It carries its own helpers and sources no library: a
# rescue tool that cannot be copied alone onto a USB stick is useless exactly
# when it is needed.
#
# Usage:  ./luks-check.sh <command> [options]   (--help for the list)
#
set -euo pipefail

readonly EXIT_SUCCESS=0
readonly EXIT_FAILURE=1
readonly EXIT_USAGE=2

# Configuration
SUBCOMMAND="report"
DEVICE=""               # --device          : bypasses detection
KEY_PATH=""             # --key             : GPG-wrapped key to test
KEY_SLOT=""             # --key-slot        : test this slot alone, not any
WHICH_SLOT="false"      # --which-slot      : name the slot that answered
SHOW_VOLUME_KEY="false" # --show-volume-key : print the master key, guarded
PASSPHRASE=""           # never exposed on the command line internally
PASSPHRASE_SOURCE="none"
PASSPHRASE_STDIN="false"
MAX_TRIES=3

# Root of the installed system. Empty means "here", which is the case inside
# the chroot or on the machine itself. From a LiveCD the tree is mounted
# somewhere else, and --root /mnt/gentoo points the key lookup at it.
ROOT_PREFIX=""

# Paths tried when --key is not given, in order, under ROOT_PREFIX
KEY_CANDIDATES=("/boot/efi/luks-key.gpg" "/boot/efi/luks-master-key.gpg")
ERR_LOG="/tmp/gentoo-install-luks-check.log"

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
  exit "$EXIT_FAILURE"
}
skip() { printf '%s[=]%s %s\n' "$C_D" "$C_0" "$*" >&2; }

verbose_enough() { [[ "$QUIET" != "true" ]]; }

show_help() {
  cat <<'HELP_EOF'
Usage: ./luks-check.sh [COMMAND] [OPTIONS]

Reports on a LUKS container without modifying anything.

Read-only by design. It opens nothing, writes nothing, and touches no keyslot.
Meant as the first thing to run on a machine that will not boot, before any
decision is taken.

COMMANDS:
    report              Full report: keyslots, tokens, TPM policy (default)
    slots               Keyslots and clevis tokens only
    tpm                 TPM binding and its PCR policy
    testpass            Does a passphrase open this container?
    testkey             Does the GPG-wrapped key file open this container?
    volumekey           Is the master key of an open volume readable at all?

OPTIONS:
    -h, --help          Show this help
    -q, --quiet         Essential output only
        --device DEV    LUKS container (nvme0n1p2 or /dev/nvme0n1p2)
                        Detected from the volume group inside it when omitted
        --key FILE      GPG-wrapped key to test, for 'testkey'
                        Default: /boot/efi/luks-key.gpg, then luks-master-key.gpg
        --key-slot N    Test slot N alone. Without it cryptsetup tries every
                        slot and reports that one answered, never which one
        --which-slot    Name the slot that answered, by asking each slot in
                        turn. One PBKDF run per slot, so it is not the default
        --show-volume-key
                        For 'volumekey': print the master key itself, after
                        the mapping name has been typed back. No --force
        --root DIR      Root of the installed system. Inside the chroot or on
                        the machine itself, leave it out. From a LiveCD with the
                        tree mounted elsewhere: --root /mnt/gentoo

PASSPHRASE (for testpass, and for testkey which must open the GPG file first):
        (nothing)               Asked, not echoed
        GI_PASSPHRASE           Environment variable
        --passphrase-file FILE  First line of a file, keep it mode 600
        --passphrase-stdin      Read from stdin
        --passphrase PASS       Literal value, visible in `ps`

WHAT IT NEVER DOES:
    No luksOpen, no luksAddKey, no clevis bind or unbind, no mount of the
    container. 'testpass' uses --test-passphrase, which asks cryptsetup to try
    a key and report, without unlocking anything. 'volumekey' uses
    'dmsetup table', which reads a mapping that is already running and writes
    nothing back to it.

    It prints no secret of its own accord. The single exception is
    'volumekey --show-volume-key', which prints the master key of a volume
    that is already open, and only after the mapping name has been typed
    back. There is deliberately no --force for it: a key that prints itself
    unattended ends up in a log.

WHEN THE VOLUME KEY IS ALL THAT IS LEFT:
    Root, the volume still open, and no secret at all: that is the last case
    of the recovery procedure, and 'volumekey' is what reads it. The master
    key of a running mapping is held in one of two places, and everything
    depends on which:

    A raw hexadecimal string means the key sits in the dm-crypt table and can
    be read. It feeds 'cryptsetup --volume-key-file'. It opens the container
    with no passphrase and no keyslot, it cannot be revoked, and it survives
    every rotation. It is the one secret of the model that never changes.

    ':64:logon:cryptsetup:<uuid>' means the key sits in the kernel keyring,
    which is the LUKS2 default on a current kernel. That is a reference, not
    a key: the kernel never hands back the payload of a 'logon' key, not even
    to root. Being root does not make this container recoverable, and the
    procedure says so in as many words. Try clevis, then the GPG key file,
    then any known passphrase, and if none answers, copy the data out while
    the mapping still holds.

EXAMPLES:
    ./luks-check.sh
        Full report on the container the volume group sits in.

    ./luks-check.sh --device nvme0n1p2
        Same, on a named container.

    ./luks-check.sh testpass
        Asks for a passphrase and says whether it opens the container.

    ./luks-check.sh testkey --key-slot 0
        Says whether luks-key.gpg still opens slot 0, and not merely some
        slot. That is the question worth asking before a slot is removed.

    ./luks-check.sh testpass --which-slot
        Same test, then names the slot that answered by asking each slot in
        turn. Slower, and the only way to know when several slots are filled.

    ./luks-check.sh volumekey
        Says whether the master key of the open volume can be read at all.
        The answer is usually no, and knowing that early saves an hour.

    ./luks-check.sh tpm
        TPM binding and PCR policy, which is what a BIOS update invalidates.

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
      --device)
        [[ $# -ge 2 ]] || die "--device requires a value"
        DEVICE="$2"
        shift 2
        ;;
      --which-slot)
        WHICH_SLOT="true"
        shift
        ;;
      --show-volume-key)
        SHOW_VOLUME_KEY="true"
        shift
        ;;
      --key)
        [[ $# -ge 2 ]] || die "--key requires a value"
        KEY_PATH="$2"
        shift 2
        ;;
      --key-slot)
        [[ $# -ge 2 ]] || die "--key-slot requires a number"
        [[ "$2" =~ ^[0-9]+$ ]] || die "Invalid --key-slot: $2"
        KEY_SLOT="$2"
        shift 2
        ;;
      --root)
        [[ $# -ge 2 ]] || die "--root requires a value"
        [[ -d "$2" ]] || die "Not a directory: $2"
        ROOT_PREFIX="${2%/}"
        shift 2
        ;;
      --passphrase)
        [[ $# -ge 2 ]] || die "--passphrase requires a value"
        PASSPHRASE="$2"
        PASSPHRASE_SOURCE="argv"
        shift 2
        ;;
      --passphrase-file)
        [[ $# -ge 2 ]] || die "--passphrase-file requires a value"
        [[ -r "$2" ]] || die "Cannot read passphrase file: $2"
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
        exit "$EXIT_USAGE"
        ;;
    esac
  done

  if [[ -z "$PASSPHRASE" && -n "${GI_PASSPHRASE:-}" ]]; then
    PASSPHRASE="$GI_PASSPHRASE"
    PASSPHRASE_SOURCE="env:GI_PASSPHRASE"
  fi

  # Naming a slot and asking which slot answered are the same question asked
  # twice, and the scan would run its PBKDF for nothing. Refusing is clearer
  # than quietly ignoring one of the two.
  if [[ -n "$KEY_SLOT" && "$WHICH_SLOT" == "true" ]]; then
    err "--which-slot conflicts with --key-slot $KEY_SLOT"
    err "  --key-slot already names the slot being tested"
    exit "$EXIT_FAILURE"
  fi
}

check_root() {
  if [[ $EUID -ne 0 ]]; then
    err "Need root access. Run: sudo -i"
    exit "$EXIT_FAILURE"
  fi
}

################################################################################
# Device resolution
################################################################################

normalize_device() {
  local input="${1:-}"
  input="${input%/}"
  input="${input#/dev/}"
  echo "$input"
}

is_luks() { cryptsetup isLuks "$1" 2>/dev/null; }

open_mapper_of() {
  # Name of the open mapper backed by this container, or "no".
  # The loop swallows its own failures: a mapper that does not match is the
  # normal case, and under set -e a bare failing grep would end the script.
  local dev="$1" name
  for name in $(dmsetup ls --target crypt 2>/dev/null | awk '{print $1}'); do
    [[ -n "$name" ]] || continue
    if cryptsetup status "$name" 2>/dev/null | grep -q "device:.*${dev}\$"; then
      echo "$name"
      return 0
    fi
  done
  echo "no"
  return 0
}

detect_from_vg() {
  # The route the installer itself takes: a volume group living inside a LUKS
  # container. Every group is asked, not one named in advance — this looked for
  # "vg1", the group the machine this tooling grew up on happened to have,
  # while gentoo-install creates vg0.
  local pv name dev group
  while read -r group; do
    [[ -n "$group" ]] || continue
    # vgs, not pvs: pvs takes physical volumes as arguments, not a group name
    pv="$(vgs --noheadings -o pv_name "$group" 2>/dev/null | tr -d ' ' | head -n 1)"
    [[ -n "$pv" && "$pv" == /dev/mapper/* ]] || continue
    name="$(basename "$pv")"
    dev="$(cryptsetup status "$name" 2>/dev/null | awk '/device:/ {print $2}')"
    if [[ -n "$dev" ]] && is_luks "$dev"; then
      echo "$dev"
      return 0
    fi
  done < <(vgs --noheadings -o vg_name 2>/dev/null | tr -d ' ')
  return 1
}

detect_any_internal() {
  # The volume group is closed on a machine that will not boot, which is
  # precisely when this tool is useful. Fall back to scanning for LUKS
  # partitions on non-removable disks.
  local part dev found=()
  for part in $(lsblk -lno NAME,TYPE 2>/dev/null | awk '$2 == "part" { print $1 }'); do
    dev="/dev/$part"
    is_luks "$dev" || continue
    local disk tran
    disk="$(lsblk -dno PKNAME "$dev" 2>/dev/null | head -n 1 | tr -d ' ')"
    tran="$(lsblk -dno TRAN "/dev/${disk:-$part}" 2>/dev/null | tr -d ' ')"
    [[ "$tran" == "usb" ]] && continue
    found+=("$dev")
  done

  if [[ ${#found[@]} -eq 1 ]]; then
    echo "${found[0]}"
    return 0
  fi
  if [[ ${#found[@]} -gt 1 ]]; then
    warn "Several internal LUKS containers: ${found[*]}"
    warn "Name one with --device"
  fi
  return 1
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
  local dev

  if [[ -n "$DEVICE" ]]; then
    dev="/dev/$(normalize_device "$DEVICE")"
    if [[ ! -b "$dev" ]]; then
      err "Device not found: $dev"
      return 1
    fi
    if ! is_luks "$dev"; then
      err "$dev is not a LUKS container"
      return 1
    fi
    echo "$dev"
    return 0
  fi

  # What the installer recorded about this machine, before searching for it.
  if dev="$(journal_device)"; then
    log "Container from the install journal: $dev"
    echo "$dev"
    return 0
  fi

  if dev="$(detect_from_vg)"; then
    log "Container from a volume group inside it: $dev"
    echo "$dev"
    return 0
  fi

  log "no active volume group inside a container, scanning internal disks"
  if dev="$(detect_any_internal)"; then
    log "Container found: $dev"
    echo "$dev"
    return 0
  fi

  err "No LUKS container found. Name one with --device"
  return 1
}

################################################################################
# Key file
################################################################################

journal_var() {
  # One value from the installer's state journal, or nothing. Args: $1 = key.
  local key="$1" file="${ROOT_PREFIX}/var/lib/gentoo-install/state"
  [[ -r "$file" ]] || return 0
  sed -n "s/^${key}=//p" "$file" | tail -n 1
}

esp_mount_point() {
  # Where the ESP is, asked of the journal before being assumed.
  #
  # This was /boot/efi, hardcoded — the layout of the machine this tooling grew
  # up on. gentoo-install's own layouts mount the ESP at /boot, so on a machine
  # it installed this said "the ESP is not mounted, cannot look for the key"
  # about a filesystem that was mounted all along, one directory away.
  local esp
  esp="$(journal_var disk.esp_mount)"
  [[ -n "$esp" ]] || esp="/boot/efi"
  printf '%s\n' "${esp%/}"
}

journal_key_path() {
  # The key file as the installed system sees it: the path the initramfs is
  # given is relative to the root of the filesystem that carries it, and the
  # ESP's mountpoint is where that filesystem sits. Neither entry is enough on
  # its own. A returned value, so stdout; empty when the journal says nothing.
  local rel
  rel="$(journal_var crypt.keyfile)"
  [[ -n "$rel" ]] || return 0
  printf '%s/%s\n' "$(esp_mount_point)" "${rel#/}"
}

efi_is_mounted() { mountpoint -q "${ROOT_PREFIX}$(esp_mount_point)" 2>/dev/null; }

resolve_key() {
  # Only reports a path, never reads the key itself
  local candidate recorded
  if [[ -n "$KEY_PATH" ]]; then
    [[ -f "$KEY_PATH" ]] || {
      err "Key not found: $KEY_PATH"
      return 1
    }
    echo "$KEY_PATH"
    return 0
  fi

  # What the installer recorded, before the two conventional names.
  recorded="$(journal_key_path)"
  if [[ -n "$recorded" && -f "${ROOT_PREFIX}${recorded}" ]]; then
    echo "${ROOT_PREFIX}${recorded}"
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
  fi

  [[ -n "$PASSPHRASE" ]] && return 0

  local tries=0
  while [[ $tries -lt $MAX_TRIES ]]; do
    tries=$((tries + 1))
    echo -n "Passphrase (q to cancel): " >&2
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
      # shellcheck disable=SC2034  # written for the record of where the
      # passphrase came from; nothing reads it back
      PASSPHRASE_SOURCE="interactive"
      return 0
    }
    err "Empty, try again"
  done

  err "Giving up after $MAX_TRIES empty answers"
  return 1
}

################################################################################
# Keyslots
################################################################################

list_slots() {
  # One occupied slot number per line on stdout, 1 when none is readable.
  # Named apart from report_slots because the tests need the same list to say
  # which slot answered, and two parsers of luksDump would drift apart.
  local dev="$1" slots

  # Bounded to the Keyslots section: Data segments, Tokens and Digests use
  # the same "  N: type" shape, and a bare grep would mix them in. Only the
  # leading number is taken, or the 2 of "luks2" would count as a slot too.
  slots="$(cryptsetup luksDump "$dev" 2>/dev/null | awk '
        /^Keyslots:/     { in_slots = 1; next }
        /^[A-Za-z]/      { in_slots = 0 }
        in_slots && /^  [0-9]+:/ { sub(":", "", $1); print $1 }')"
  if [[ -z "$slots" ]]; then
    # LUKS1 numbers its slots differently
    slots="$(cryptsetup luksDump "$dev" 2>/dev/null | awk '/^Key Slot [0-9]+: ENABLED/ {print $3}' | tr -d ':')"
  fi

  [[ -n "$slots" ]] || return 1
  echo "$slots"
  return 0
}

slot_is_occupied() {
  local dev="$1" slot="$2" s
  for s in $(list_slots "$dev" || true); do
    [[ "$s" == "$slot" ]] && return 0
  done
  return 1
}

################################################################################
# Reports
################################################################################

report_slots() {
  local dev="$1"

  echo "" >&2
  echo "${C_B}=== Keyslots ===${C_0}" >&2
  echo "" >&2

  local slots
  slots="$(list_slots "$dev" | tr '\n' ' ')" || true

  if [[ -z "$slots" ]]; then
    err "  no readable keyslot on $dev"
    return 1
  fi

  local s meaning
  for s in $slots; do
    # The numbers are the installer's defaults — crypt_primary_slot,
    # crypt_recovery_slot, crypt_tpm_slot — not a law. They are described by the
    # role they are given rather than by one encryption variant's shape: saying
    # "usually the key wrapped in luks-key.gpg" told a passphrase install, which
    # is the default, that its perfectly ordinary slot 0 was something else.
    case "$s" in
      0) meaning="the everyday way in: a passphrase, or a wrapped key file" ;;
      1) meaning="the recovery passphrase" ;;
      2) meaning="the TPM binding, when clevis sealed one" ;;
      *) meaning="added by hand" ;;
    esac
    printf "  slot %-3s %s  %s\n" "$s" "${C_G}occupied${C_0}" "$meaning" >&2
  done

  echo "" >&2
  echo "  What is nominal depends on how the machine was encrypted:" >&2
  echo "    passphrase   slots 0 and 1 — the everyday one and the recovery one" >&2
  echo "    keyfile      the same two, and the file itself must exist as well" >&2
  echo "    tpm          those two and slot 2; slot 2 gone means the machine" >&2
  echo "                 still boots, but stops to ask for the passphrase" >&2
  return 0
}

report_tpm() {
  local dev="$1"

  echo "" >&2
  echo "${C_B}=== TPM binding ===${C_0}" >&2
  echo "" >&2

  if ! command -v clevis >/dev/null 2>&1; then
    warn "  clevis is not installed here, cannot read the binding"
    warn "  Run this from inside the chroot, or on the installed system"
    return 1
  fi

  local listing
  listing="$(clevis luks list -d "$dev" 2>/dev/null || true)"

  if [[ -z "$listing" ]]; then
    warn "  no clevis binding on $dev"
    echo "" >&2
    echo "  Expected after a BIOS update, which changes PCR 0 and makes the" >&2
    echo "  TPM refuse to release the key. The machine still boots with the" >&2
    echo "  passphrase, and the binding is redone with tpm-reseal.sh." >&2
    return 1
  fi

  # shellcheck disable=SC2001  # a per-line prefix is not a ${var//a/b} job
  echo "$listing" | sed 's/^/  /' >&2
  echo "" >&2

  # The PCR list is what a BIOS update invalidates, so it is worth naming
  local pcrs
  pcrs="$(echo "$listing" | grep -oE '"pcr_ids":"[^"]*"' | head -n 1 | cut -d'"' -f4)"
  if [[ -n "$pcrs" ]]; then
    echo "  Sealed against PCR $pcrs" >&2
    local p
    for p in ${pcrs//,/ }; do
      case "$p" in
        0) echo "    0  UEFI firmware code       changed by a BIOS update" >&2 ;;
        2) echo "    2  option ROM code          changed by adding a card" >&2 ;;
        3) echo "    3  option ROM configuration" >&2 ;;
        6) echo "    6  suspend and resume events" >&2 ;;
        4) echo "    4  boot loader and partitions, changed at every kernel build" >&2 ;;
        7) echo "    7  Secure Boot state" >&2 ;;
        *) echo "    $p" >&2 ;;
      esac
    done
  fi
  return 0
}

report_header() {
  local dev="$1"

  echo "" >&2
  echo "${C_B}=== Container ===${C_0}" >&2
  echo "" >&2
  printf "  %-16s %s\n" "Device:" "$dev" >&2
  printf "  %-16s %s\n" "Size:" "$(lsblk -dno SIZE "$dev" 2>/dev/null | tr -d ' ')" >&2
  printf "  %-16s %s\n" "LUKS UUID:" "$(cryptsetup luksUUID "$dev" 2>/dev/null || echo unknown)" >&2
  printf "  %-16s %s\n" "Version:" "$(cryptsetup luksDump "$dev" 2>/dev/null | awk '/^Version:/ {print $2}')" >&2
  printf "  %-16s %s\n" "Cipher:" "$(cryptsetup luksDump "$dev" 2>/dev/null | awk '/cipher:/ {print $2; exit}')" >&2

  printf "  %-16s %s\n" "Currently open:" "$(open_mapper_of "$dev")" >&2
}

report_key() {
  local key
  echo "" >&2
  echo "${C_B}=== Recovery key file ===${C_0}" >&2
  echo "" >&2

  if ! efi_is_mounted && [[ -z "$KEY_PATH" ]]; then
    warn "  ${ROOT_PREFIX}$(esp_mount_point) is not mounted, cannot look for the key"
    warn "  From a LiveCD, point at the mounted tree: --root /mnt/gentoo"
    warn "  Or name the file directly: --key FILE"
    return 1
  fi

  if key="$(resolve_key)"; then
    printf "  %-16s %s %s\n" "Key file:" "${C_G}present${C_0}" "$key" >&2
    printf "  %-16s %s bytes, mode %s\n" "Size:" "$(stat -c%s "$key")" "$(stat -c%a "$key")" >&2
    echo "" >&2
    echo "  Its presence is what lets the machine be unlocked by hand when the" >&2
    echo "  TPM refuses. Use 'testkey' to check it still matches a keyslot." >&2
    return 0
  fi

  # Not an error on its own. A passphrase install — the default — keeps no key
  # file anywhere, and reporting that in red told the operator of a healthy
  # machine that it could not be opened. It is only a failure when a file was
  # named and is not there, which resolve_key has already refused above.
  warn "  no key file in: ${KEY_CANDIDATES[*]}"
  echo "" >&2
  echo "  Expected when the machine was encrypted with a passphrase: there is" >&2
  echo "  no file to keep, and the passphrase is the way in." >&2
  echo "" >&2
  echo "  A problem when it was encrypted with a wrapped key file or bound to" >&2
  echo "  the TPM: without the file, and without the TPM, the key of slot 0" >&2
  echo "  exists nowhere else. The TPM section above says which this is." >&2
  return 1
}

################################################################################
# Tests
################################################################################

check_key_slot() {
  # A slot number that no slot holds is not a failed test, it is a mistyped
  # argument: cryptsetup would answer "no" and the operator would read it as
  # "this key is dead".
  local dev="$1"

  [[ -n "$KEY_SLOT" ]] || return 0

  if ! slot_is_occupied "$dev" "$KEY_SLOT"; then
    err "Slot $KEY_SLOT is not occupied on $dev"
    err "  Occupied slots: $(list_slots "$dev" | tr '\n' ' ' || echo none)"
    err "  Nothing can answer there, whatever the key"
    return 1
  fi
  log "Testing slot $KEY_SLOT only"
  return 0
}

slot_args() {
  # Nothing when --key-slot is absent, so cryptsetup keeps its own behaviour
  # of trying every slot.
  [[ -n "$KEY_SLOT" ]] && echo "--key-slot $KEY_SLOT"
  return 0
}

try_slot_passphrase() {
  local dev="$1" slot="$2"
  printf '%s' "$PASSPHRASE" \
    | cryptsetup open --test-passphrase --disable-external-tokens \
      --key-slot "$slot" "$dev" 2>/dev/null
}

try_slot_key() {
  local dev="$1" slot="$2" key="$3" status=()
  set +e
  gpg --quiet --batch --pinentry-mode loopback --passphrase-fd 3 \
    --decrypt "$key" 3<<<"$PASSPHRASE" 2>/dev/null \
    | cryptsetup open --test-passphrase --disable-external-tokens \
      --key-slot "$slot" --key-file - "$dev" 2>/dev/null
  status=("${PIPESTATUS[@]}")
  set -e
  [[ "${status[1]}" -eq 0 ]]
}

name_answering_slot() {
  # Called only after the material has been proven to open something, so the
  # question left is which slot did it. cryptsetup never says, and the only
  # way to find out is to ask each slot in turn.
  #
  # Every try runs the PBKDF of that slot: on LUKS2 that is argon2id, a second
  # or two and up to a gigabyte of RAM each time. Making testkey and testpass
  # three times slower to print a number that matters on one run in ten is a
  # bad trade, so the scan is asked for with --which-slot and stops at the
  # first slot that answers. Two cases cost nothing and are always reported:
  # --key-slot N was given, or a single slot is occupied.
  local dev="$1" mode="$2" key="${3:-}" slots count s

  if [[ -n "$KEY_SLOT" ]]; then
    ok "  Slot that answered: $KEY_SLOT (the only one tried)"
    return 0
  fi

  slots="$(list_slots "$dev" || true)"
  [[ -n "$slots" ]] || return 0
  count="$(echo "$slots" | wc -w)"

  if [[ "$count" -eq 1 ]]; then
    ok "  Slot that answered: $slots (the only one occupied)"
    return 0
  fi

  if [[ "$WHICH_SLOT" != "true" ]]; then
    log "  $count slots are occupied and cryptsetup does not say which one"
    log "  answered. --key-slot N asks one slot, --which-slot asks them all."
    return 0
  fi

  log "  Asking each slot in turn, one PBKDF run per slot"
  for s in $slots; do
    if [[ "$mode" == "key" ]]; then
      try_slot_key "$dev" "$s" "$key" && {
        ok "  Slot that answered: $s"
        return 0
      }
    else
      try_slot_passphrase "$dev" "$s" && {
        ok "  Slot that answered: $s"
        return 0
      }
    fi
    log "  slot $s: no"
  done

  warn "  The container opened, yet no single slot did: read the slot list again"
  return 0
}

test_passphrase() {
  # --test-passphrase asks cryptsetup to try a key and report, without
  # unlocking anything. --disable-external-tokens keeps clevis out of the way,
  # so a machine whose TPM still answers cannot make a wrong passphrase look
  # right.
  local dev="$1"

  check_key_slot "$dev" || return 1
  resolve_passphrase || return 1

  log "Testing against $dev"
  : >"$ERR_LOG"
  chmod 600 "$ERR_LOG" 2>/dev/null || true

  # slot_args expands to nothing or to two words. KEY_SLOT is validated as
  # digits, so leaving it unquoted holds no surprise.
  local rc=0
  # shellcheck disable=SC2046  # deliberate: slot_args is empty or two words
  printf '%s' "$PASSPHRASE" \
    | cryptsetup open --test-passphrase --disable-external-tokens \
      $(slot_args) "$dev" 2>>"$ERR_LOG" \
    || rc=$?

  echo "" >&2
  if [[ $rc -eq 0 ]]; then
    ok "This passphrase opens $dev"
    name_answering_slot "$dev" "pass"
    echo "" >&2
    echo "  Note it opens a keyslot directly, so it is a LUKS passphrase," >&2
    echo "  not the passphrase that protects luks-key.gpg. On a machine" >&2
    echo "  built by this installer the two are different: use 'testkey'" >&2
    echo "  for the file." >&2
    return 0
  fi

  if [[ -n "$KEY_SLOT" ]]; then
    err "This passphrase does NOT open slot $KEY_SLOT on $dev"
    err "  Another slot may still answer: drop --key-slot to try them all"
  else
    err "This passphrase does NOT open $dev"
  fi
  sed 's/^/    /' "$ERR_LOG" >&2 2>/dev/null || true
  return 1
}

test_key() {
  # The real question on an installed machine: does luks-key.gpg still match a
  # keyslot? Two things can fail, and they are told apart.
  local dev="$1" key

  if ! key="$(resolve_key)"; then
    err "No key file found. Mount $(esp_mount_point), or pass --key FILE"
    return 1
  fi
  log "Key file: $key"

  check_key_slot "$dev" || return 1
  resolve_passphrase || return 1

  : >"$ERR_LOG"
  chmod 600 "$ERR_LOG" 2>/dev/null || true

  if [[ -z "${GPG_TTY:-}" ]]; then
    GPG_TTY="$(tty 2>/dev/null || echo /dev/tty)"
    export GPG_TTY
  fi

  # The decrypted key goes straight into cryptsetup through a pipe. It is
  # never written to disk, and --test-passphrase unlocks nothing.
  local status=()
  set +e
  # shellcheck disable=SC2046  # deliberate: slot_args is empty or two words
  gpg --quiet --batch --pinentry-mode loopback --passphrase-fd 3 \
    --decrypt "$key" 3<<<"$PASSPHRASE" 2>>"$ERR_LOG" \
    | cryptsetup open --test-passphrase --disable-external-tokens \
      $(slot_args) --key-file - "$dev" 2>>"$ERR_LOG"
  status=("${PIPESTATUS[@]}")
  set -e

  echo "" >&2
  if [[ "${status[0]}" -ne 0 ]]; then
    err "GPG could not decrypt $key"
    err "  Wrong passphrase, or the file is damaged"
    sed 's/^/    /' "$ERR_LOG" >&2 2>/dev/null || true
    return 1
  fi

  if [[ "${status[1]}" -ne 0 ]]; then
    if [[ -n "$KEY_SLOT" ]]; then
      err "The key decrypted, but does not open slot $KEY_SLOT on $dev"
      err "  It may still open another slot: drop --key-slot to find out"
    else
      err "The key decrypted, but matches no keyslot on $dev"
      err "  The file belongs to another machine, or the container was"
      err "  reprovisioned since. Check the LUKS UUID above."
    fi
    sed 's/^/    /' "$ERR_LOG" >&2 2>/dev/null || true
    return 1
  fi

  ok "$key still opens $dev"
  name_answering_slot "$dev" "key" "$key"
  echo "" >&2
  echo "  The recovery path is intact: this file plus its passphrase unlock" >&2
  echo "  the machine even with no TPM at all." >&2
  return 0
}

################################################################################
# Volume key of an open mapping
################################################################################

read_crypt_key_field() {
  # Fifth field of the dm-crypt table, which is the key or a reference to it:
  #   0 <sectors> crypt <cipher> <KEY> <iv offset> <device> <offset> [...]
  # Observed on a LUKS2 container, kernel 6.18:
  #   0 98304 crypt aes-xts-plain64 :64:logon:cryptsetup:<luks uuid>-d0 0 ...
  #   0 98304 crypt aes-xts-plain64 08ef9cd3...71908 0 ...
  # --showkeys only changes what dmsetup prints, never the mapping itself.
  local mapper="$1" table

  if ! table="$(dmsetup table --target crypt --showkeys "$mapper" 2>/dev/null)"; then
    err "dmsetup could not read the table of $mapper"
    return 1
  fi
  [[ -n "$table" ]] || {
    err "$mapper has no crypt target"
    return 1
  }

  echo "$table" | awk '$3 == "crypt" { print $5; exit }'
  return 0
}

confirm_volume_key() {
  # Not the confirm() of the writing tools, and no --force to go with it. This
  # prints a secret that cannot be revoked, so the answer has to be typed on
  # purpose: a y at the wrong moment is one keystroke, a mapping name is not.
  local mapper="$1" answer=""

  echo "" >&2
  warn "About to print the master key of $mapper in the clear"
  warn "  It opens the container with no passphrase and no keyslot"
  warn "  It cannot be revoked, and it outlives every passphrase rotation"
  warn "  It belongs in no file, no log, no ticket and no chat window"
  echo "" >&2
  echo -n "Type the mapping name to print it, anything else cancels: " >&2
  read -r answer || {
    echo "" >&2
    return 1
  }
  [[ "$answer" == "$mapper" ]]
}

report_volume_key_raw() {
  local mapper="$1" key="$2"
  # Two statements, not one 'local': inside a single 'local' the earlier word
  # is not yet visible to the later one, and the length printed came out 0.
  local bytes=$((${#key} / 2))

  ok "The master key is in the dm-crypt table, and it is readable"
  echo "" >&2
  printf "  %-16s %s\n" "Form:" "raw hexadecimal" >&2
  printf "  %-16s %s bytes, %s bits\n" "Length:" "$bytes" "$((bytes * 8))" >&2
  echo "" >&2
  echo "  The last resort can be answered here. Turn it into a file on tmpfs," >&2
  echo "  in mode 600 and never on a disk. Straight from dmsetup, so the key" >&2
  echo "  crosses neither the screen nor the shell history:" >&2
  echo "" >&2
  echo "    (umask 077; dmsetup table --target crypt --showkeys $mapper \\" >&2
  echo "        | awk '{print \$5}' | xxd -r -p > /run/volume.key)" >&2
  echo "    cryptsetup open --volume-key-file /run/volume.key DEV NAME" >&2
  echo "    cryptsetup luksAddKey --volume-key-file /run/volume.key DEV" >&2
  echo "    shred -u /run/volume.key" >&2
  echo "" >&2
  echo "  What it does not give you. It is not a passphrase and it hands none" >&2
  echo "  back: it saves a container, not a secret. It needs the header to be" >&2
  echo "  intact, since --volume-key-file still reads the header for the" >&2
  echo "  cipher and the data offset. And it is the one secret of the model" >&2
  echo "  that never changes: rotating every passphrase leaves it valid." >&2

  if [[ "$SHOW_VOLUME_KEY" != "true" ]]; then
    echo "" >&2
    echo "  Not printed, and the recipe above does not print it either." >&2
    echo "  --show-volume-key puts it on the screen, once the mapping name" >&2
    echo "  has been typed back. Only reach for it to read the value with" >&2
    echo "  your own eyes: the file route above is the one that works." >&2
    return 0
  fi

  if ! confirm_volume_key "$mapper"; then
    echo "" >&2
    log "Cancelled, nothing printed"
    return 0
  fi

  echo "" >&2
  echo "$key" >&2
  echo "" >&2
  return 0
}

report_volume_key_keyring() {
  local key="$1" klen ktype kdesc

  IFS=: read -r _ klen ktype kdesc <<<"$key"

  err "The master key is held by the kernel keyring, and cannot be read"
  echo "" >&2
  printf "  %-16s %s\n" "Form:" "keyring reference, not a key" >&2
  printf "  %-16s %s\n" "Reference:" "$key" >&2
  printf "  %-16s %s bytes\n" "Length:" "${klen:-unknown}" >&2
  printf "  %-16s %s\n" "Keyring type:" "${ktype:-unknown}" >&2
  printf "  %-16s %s\n" "Description:" "${kdesc:-unknown}" >&2
  echo "" >&2
  echo "  This is the LUKS2 default on a current kernel, so it is the usual" >&2
  echo "  case and not a fault. The kernel never hands back the payload of a" >&2
  echo "  'logon' key, not to root and not to anyone: there is no option, no" >&2
  echo "  keyctl call and no privilege that reads it from user space." >&2
  echo "" >&2
  echo "  Say it plainly: being root on an open volume does not make this" >&2
  echo "  container recoverable. The recovery path calls this last case 'not" >&2
  echo "  guaranteed', and this is what that means." >&2
  echo "" >&2
  echo "  Three routes come before this one, and all three are better. Try" >&2
  echo "  them now, without rebooting and without closing the mapping:" >&2
  echo "" >&2
  echo "    ./luks-addkey.sh test --from tpm    the TPM may still release it" >&2
  echo "    ./luks-check.sh testkey             luks-key.gpg, on the ESP" >&2
  echo "    ./luks-check.sh testpass            any keyslot passphrase known" >&2
  echo "" >&2
  echo "  If none of them answers, the mapping itself is the last thing" >&2
  echo "  holding the data: copy the data out while it is still open, then" >&2
  echo "  reinstall the machine. The contents stay readable through the" >&2
  echo "  mapping even though the key does not." >&2
  echo "" >&2
  echo "  And the mistake to avoid at exactly this point: no cryptsetup" >&2
  echo "  erase, no luksFormat, no TPM clear to start clean. Each of them" >&2
  echo "  turns a machine that still reads into one that never will." >&2

  if [[ "$SHOW_VOLUME_KEY" == "true" ]]; then
    echo "" >&2
    warn "--show-volume-key has nothing to print here"
    warn "  The reference above is all dmsetup holds, and it is not a key"
  fi
  return 1
}

################################################################################
# Commands
################################################################################

do_volumekey() {
  # The last resort: root, the volume open, no secret at all. dmsetup table
  # reads a running mapping and writes nothing back, so the read-only promise
  # of this tool is untouched. Nothing is appended to ERR_LOG either: the one
  # thing this command handles must not land in a file.
  local dev mapper key

  dev="$(resolve_device)" || exit "$EXIT_FAILURE"
  report_header "$dev"
  mapper="$(open_mapper_of "$dev")"

  echo "" >&2
  echo "${C_B}=== Volume key ===${C_0}" >&2
  echo "" >&2

  if [[ "$mapper" == "no" ]]; then
    err "No open mapping is backed by $dev"
    err "  This last resort reads the key out of a running mapping. With the"
    err "  volume closed there is nothing to read."
    echo "" >&2
    echo "  That is not the end of the road: the three routes that come" >&2
    echo "  before this one all work on a closed container, and all three" >&2
    echo "  are better than this one." >&2
    echo "" >&2
    echo "    ./luks-addkey.sh test --from tpm    the TPM may still answer" >&2
    echo "    ./luks-check.sh testkey             luks-key.gpg, on the ESP" >&2
    echo "    ./luks-check.sh testpass            any keyslot passphrase known" >&2
    exit "$EXIT_FAILURE"
  fi

  printf "  %-16s %s\n" "Mapping:" "$mapper" >&2
  printf "  %-16s %s\n" "Cipher:" \
    "$(cryptsetup status "$mapper" 2>/dev/null | awk '/cipher:/ {print $2; exit}')" >&2
  printf "  %-16s %s\n" "Key location:" \
    "$(cryptsetup status "$mapper" 2>/dev/null | awk '/key location:/ {print $3; exit}')" >&2
  echo "" >&2

  key="$(read_crypt_key_field "$mapper")" || exit "$EXIT_FAILURE"

  if [[ "$key" =~ ^:[0-9]+:[a-z]+: ]]; then
    report_volume_key_keyring "$key" || exit "$EXIT_FAILURE"
    exit "$EXIT_SUCCESS"
  fi

  if [[ "$key" =~ ^[0-9a-fA-F]+$ ]] && [[ $((${#key} % 2)) -eq 0 ]]; then
    report_volume_key_raw "$mapper" "$key" || exit "$EXIT_FAILURE"
    exit "$EXIT_SUCCESS"
  fi

  err "The key field of the table is in neither known form"
  err "  Neither raw hexadecimal nor a ':<len>:<type>:<desc>' reference"
  err "  Read the table yourself: dmsetup table --target crypt $mapper"
  exit "$EXIT_FAILURE"
}

do_report() {
  local dev
  dev="$(resolve_device)" || exit "$EXIT_FAILURE"

  report_header "$dev"
  report_slots "$dev" || true
  report_tpm "$dev" || true
  report_key || true

  echo "" >&2
  echo "${C_B}=== Next ===${C_0}" >&2
  echo "" >&2
  echo "  ./luks-check.sh testkey      does luks-key.gpg still open it" >&2
  echo "  ./luks-check.sh testpass     does a given passphrase open it" >&2
  echo "  ./luks-check.sh volumekey    last resort, and only when it is open" >&2
  echo "  ./tpm-reseal.sh              redo the TPM binding" >&2
  echo "  ./luks-open.sh               open and mount, to repair the system" >&2
  echo "" >&2
}

main() {
  parse_arguments "$@"

  case "$SUBCOMMAND" in
    report | all)
      check_root
      do_report
      ;;
    slots)
      check_root
      local dev
      dev="$(resolve_device)" || exit "$EXIT_FAILURE"
      report_slots "$dev"
      ;;
    tpm)
      check_root
      local dev
      dev="$(resolve_device)" || exit "$EXIT_FAILURE"
      report_tpm "$dev"
      ;;
    testpass)
      check_root
      local dev
      dev="$(resolve_device)" || exit "$EXIT_FAILURE"
      report_header "$dev"
      test_passphrase "$dev"
      ;;
    testkey)
      check_root
      local dev
      dev="$(resolve_device)" || exit "$EXIT_FAILURE"
      report_header "$dev"
      test_key "$dev"
      ;;
    volumekey)
      check_root
      do_volumekey
      ;;
    *)
      err "Unknown command: $SUBCOMMAND"
      err "       Use --help for usage information"
      exit "$EXIT_USAGE"
      ;;
  esac
}

main "$@"
