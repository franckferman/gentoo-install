#!/usr/bin/env bash
#
# gentoo-install — BIOS update: prove the flash can be survived, then flash it
# ----------------------------------------------------------------------------
# preflight answers one question in nine checks: is there a proven way into
# this container that does not go through the TPM? It writes what it found into
# an attestation, and flash refuses to run without a fresh one. The rest signs
# fwupdx64.efi with the Secure Boot db key, configures the Shim bypass, and
# verifies the capsule before fwupd is allowed near it.
#
# One rule to keep when touching this file: `sbverify --list` returns 0 on an
# unsigned binary, so its text is what decides, never its exit status.
#
# Usage:  ./bios-update.sh <command> [options]   (--help for the list)
#
set -euo pipefail

readonly EXIT_SUCCESS=0
readonly EXIT_FAILURE=1
readonly EXIT_USAGE=2

# Configuration
SUBCOMMAND="preflight"
FORCE="false"
CAB_PATH=""           # --cab        : firmware capsule, for preflight and flash
CAB_CHECKSUM=""       # --checksum   : expected sha256, a mismatch is a refusal
SIGN_KEY=""           # --key        : Secure Boot signing key, not the LUKS key
SIGN_CERT=""          # --cert       : certificate that goes with it
BACKUP_DIR=""         # --backup-dir : where the LUKS header backup was written
DEVICE=""             # --device     : bypasses detection
ROOT_PREFIX=""        # --root       : installed tree, when run from a LiveCD
NO_SIGN="false"       # --no-sign    : preflight without a signed fwupdx64.efi
ALLOW_BATTERY="false" # --allow-battery : lifts the mains refusal, and says so
DRY_RUN="false"       # --dry-run    : prints what writes, runs none of it

# Paths of the installed system, always read under ROOT_PREFIX
STATE_DIR="/var/lib/gentoo-install"
STATE_FILE="/var/lib/gentoo-install/bios-update.state"
FWUPD_CONF="/etc/fwupd/fwupd.conf"
FWUPD_EFI="/usr/libexec/fwupd/efi/fwupdx64.efi"
PACKAGE_USE="/etc/portage/package.use/fwupd"
BUILDKERNEL_CONF="/etc/buildkernel-next.conf"
EFIKEYS_KEY="/etc/efikeys/db.key"
EFIKEYS_CERT="/etc/efikeys/db.crt"
EFI_MOUNT="/boot/efi"

# Secure Boot lives in the global UEFI namespace, hence the fixed GUID
SECUREBOOT_GUID="8be4df61-93ca-11d2-aa0d-00e098032b8c"
EFIVARS_DIR="/sys/firmware/efi/efivars"

# The policy this project seals with. A flash changes PCR 0, PCR 0 is in the
# list, so every flash invalidates the sealing. That is the whole subject.
PCR_POLICY='{"pcr_bank":"sha256","pcr_ids":"0,2,3,6"}'

# An attestation older than this is not evidence any more: a cable gets
# unplugged, a container gets reprovisioned, someone reboots in between.
STATE_MAX_AGE=3600
MIN_ESP_FREE_KB=32768
MIN_BATTERY=25

ERR_LOG="${TMPDIR:-/tmp}/gentoo-install-bios-update.log"

# Where this script sits, so its siblings are called without guessing a path
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"

# Facts the checks establish and the attestation records. At script level
# because a check that ran in a subshell could not record anything.
FACT_DEVICE=""
FACT_UUID=""
FACT_CLEVIS="unknown"
FACT_CREDENTIAL="unproven"
FACT_HEADER=""
FACT_CAB_SHA=""
CHECK_INDEX=0
CHECK_TOTAL=9
HARD_FAILS=0
WARNINGS=0
CHECK_LINES=()

# The rewritten configuration file, at script level so the EXIT trap can still
# see it. A variable local to a function no longer exists when the trap fires,
# which under set -u ends on "unbound variable" and leaves the file behind.
TEMP_CONF=""

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
Usage: ./bios-update.sh [COMMAND] [OPTIONS]

================================================================================
gentoo-install - BIOS update
Proves a BIOS flash can be survived, then signs fwupd and flashes it
================================================================================

WHEN TO USE IT:
    A firmware update is waiting and the machine unlocks on its own today. The
    flash changes PCR 0, the clevis policy seals on PCR 0, 2, 3 and 6, so the
    TPM stops releasing the key and the machine asks for a passphrase nobody
    kept. That is the August 2026 incident, start to finish.

    Run it on the machine itself, before the flash. preflight changes nothing
    and can be run as often as wanted.

WHAT IT DOES:
    preflight answers one question: is there a proven way into this container
    that does not go through the TPM? It writes what it found into an
    attestation, and flash refuses to run without a fresh one.

WHAT IT NEVER DOES:
    It never adds, removes or tests a keyslot on its own: keyslots belong to
    luks-addkey.sh and bios-maint.sh. It never turns Secure Boot or the TPM
    off, and it never flashes on a preflight it did not read.

COMMANDS:
    preflight           The nine checks a flash needs, and an attestation (default)
    check-cab           file, sha256, cabextract and fwupdmgr get-details
    sign                Sign fwupdx64.efi with the Secure Boot db key
    noshim              DisableShimForSecureBoot=true in /etc/fwupd/fwupd.conf
    flash               fwupdmgr install, under a fresh attestation only
    status              What each piece looks like today, change nothing

OPTIONS:
    -h, --help          Show this help
    -q, --quiet         Essential output only
        --cab FILE      Firmware capsule. Also the first word after the command
        --checksum SUM  Expected sha256 of the capsule. A mismatch is a refusal
        --key FILE      Secure Boot signing key. Here it is not the LUKS key
        --cert FILE     Certificate that goes with the signing key
        --backup-dir DIR
                        Where the LUKS header backup was written, to check it
        --device DEV    LUKS container. Detected from the volume group
                        inside it when omitted
        --root DIR      Root of the installed system, for a run from a LiveCD
        --no-sign       Preflight without requiring a signed fwupdx64.efi
        --allow-battery Accept mains being absent. Written into the attestation
        --dry-run       Print every command that writes, run none of them
        --force         Skip every confirmation (non-interactive)

THE ONE QUESTION PREFLIGHT ASKS:
    Every check but one is a comfort check. The one that matters is number six:
    a credential that opens the container without the TPM, proven now, not
    assumed. It is delegated to ./luks-check.sh testkey, which tests with
    --disable-external-tokens so a TPM that still answers cannot make a dead
    key look valid. GI_PASSPHRASE is passed through to it, so an unattended
    preflight works the same way the rest of the toolbox does.

WHICH SIGNING KEY, AND WHY IT CAN REFUSE TO CHOOSE:
    Two sources name the db key. The conventional location is
    /etc/efikeys/db.key and db.crt, while buildkernel-next signs the kernel
    with SECUREBOOT_KEY and SECUREBOOT_CERT read from
    /etc/buildkernel-next.conf. When both exist and point at different files,
    sign refuses and prints both paths: signing fwupd with one key and the
    kernel with the other gives a machine that boots but does not flash.
    --force does not lift that refusal, only --key and --cert.

EXAMPLES:
    ./bios-update.sh
        The nine checks. Writes the attestation, changes nothing else.

    ./bios-update.sh check-cab /opt/firmware.cab --checksum "$SUM"
        Is this capsule intact, and is it for this machine? Reads only.

    ./bios-update.sh preflight --cab /opt/firmware.cab --backup-dir /mnt/backup
        The full set, capsule and header backup included. This is the one to
        run before a flash.

    ./bios-update.sh flash /opt/firmware.cab
        Refuses unless a preflight passed less than an hour ago, on this same
        container, with a credential proven.

    ./bios-update.sh status
        Version, signature, configuration and last attestation. Changes nothing.

HELP_EOF
}

parse_arguments() {
  if [[ $# -gt 0 ]] && [[ "$1" != -* ]]; then
    SUBCOMMAND="$1"
    shift
  fi

  # A second bare word is the capsule: the documented commands are
  # 'fwupdmgr install FILE' and 'check-cab FILE', and an operator retypes what
  # the procedure they are following shows.
  if [[ $# -gt 0 ]] && [[ "$1" != -* ]]; then
    CAB_PATH="$1"
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
      --no-sign)
        NO_SIGN="true"
        shift
        ;;
      --allow-battery)
        ALLOW_BATTERY="true"
        shift
        ;;
      --dry-run)
        DRY_RUN="true"
        shift
        ;;
      --force)
        FORCE="true"
        shift
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
      --checksum)
        [[ $# -ge 2 ]] || {
          err "--checksum requires a sha256 sum"
          exit "$EXIT_USAGE"
        }
        [[ "$2" =~ ^[0-9a-fA-F]{64}$ ]] || {
          err "Invalid --checksum: $2 (expected 64 hex characters)"
          exit "$EXIT_USAGE"
        }
        # Already constrained to hex by the pattern above, so the shell's own
        # lowercase expansion is the whole conversion.
        CAB_CHECKSUM="${2,,}"
        shift 2
        ;;
      --key)
        [[ $# -ge 2 ]] || {
          err "--key requires a value"
          exit "$EXIT_USAGE"
        }
        [[ -r "$2" ]] || {
          err "Cannot read signing key: $2"
          exit "$EXIT_USAGE"
        }
        SIGN_KEY="$2"
        shift 2
        ;;
      --cert)
        [[ $# -ge 2 ]] || {
          err "--cert requires a value"
          exit "$EXIT_USAGE"
        }
        [[ -r "$2" ]] || {
          err "Cannot read certificate: $2"
          exit "$EXIT_USAGE"
        }
        SIGN_CERT="$2"
        shift 2
        ;;
      --backup-dir)
        [[ $# -ge 2 ]] || {
          err "--backup-dir requires a value"
          exit "$EXIT_USAGE"
        }
        [[ -d "$2" ]] || {
          err "Not a directory: $2"
          exit "$EXIT_USAGE"
        }
        BACKUP_DIR="${2%/}"
        shift 2
        ;;
      --device)
        [[ $# -ge 2 ]] || {
          err "--device requires a value"
          exit "$EXIT_USAGE"
        }
        DEVICE="$2"
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
      *)
        err "Unknown option: $1"
        err "Use --help for usage information"
        exit "$EXIT_USAGE"
        ;;
    esac
  done

  # Naming one half of the pair and letting the other be detected would sign
  # with a key and a certificate that have no reason to match.
  if [[ -n "$SIGN_KEY" && -z "$SIGN_CERT" ]] || [[ -z "$SIGN_KEY" && -n "$SIGN_CERT" ]]; then
    err "--key and --cert go together"
    err "  Give both, or neither and let the pair be detected"
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
# Prerequisites and small readers
################################################################################

tool_package() {
  case "$1" in
    fwupdmgr | fwupdtool) echo "sys-apps/fwupd" ;;
    cryptsetup) echo "sys-fs/cryptsetup" ;;
    clevis) echo "app-crypt/clevis" ;;
    gpg) echo "app-crypt/gnupg" ;;
    sbsign | sbverify) echo "app-crypt/sbsigntools" ;;
    cabextract) echo "app-arch/cabextract" ;;
    efibootmgr) echo "sys-boot/efibootmgr" ;;
    openssl) echo "dev-libs/openssl" ;;
    *) echo "unknown package" ;;
  esac
}

check_tools() {
  local missing=0 t

  for t in fwupdmgr cryptsetup; do
    if ! command -v "$t" >/dev/null 2>&1; then
      err "  missing: $t ($(tool_package "$t"))"
      missing=$((missing + 1))
    fi
  done

  # The optional ones are named, never fatal. cabextract is absent from the
  # reference machine, and clevis lives in the installed system, not here.
  for t in clevis gpg sbsign sbverify cabextract efibootmgr openssl; do
    command -v "$t" >/dev/null 2>&1 || warn "  optional: $t is absent ($(tool_package "$t"))"
  done

  if [[ $missing -gt 0 ]]; then
    err "$missing required tool(s) missing"
    err "fwupd and cryptsetup live in the installed system, not on a LiveCD."
    err "Run this on the machine itself, or from inside its chroot."
    HARD_FAILS=$((HARD_FAILS + missing))
    return 1
  fi
  return 0
}

init_err_log() {
  # A fixed name in a world-writable directory is a file any local user can
  # replace with a symlink before this runs, and these tools are run as root:
  # `: >"$ERR_LOG"` then truncates whatever it points at, and the chmod beside
  # it changes that file's mode. The installer learned this one the hard way —
  # `--log-file /dev/null` under sudo reached `chmod 0600 /dev/null` and left
  # the machine without a working shell — and the tools never did.
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
  ) 2>/dev/null || ERR_LOG="$(umask 077 && mktemp -t gentoo-install-bios-update.XXXXXX)"
  chmod 600 "$ERR_LOG" 2>/dev/null || true
}

run_cmd() {
  # The single place a system-modifying command is either run or printed.
  # Everything that writes goes through here, so --dry-run cannot miss one.
  if [[ "$DRY_RUN" == "true" ]]; then
    warn "dry-run: $*"
    return 0
  fi
  "$@"
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

  err "Cannot tell which container to check. Name it with --device"
  return 1
}

occupied_slots() {
  # Bounded to the Keyslots section: Data segments, Tokens and Digests use
  # the same "  N: type" shape, and the 2 of "luks2" would count as a slot.
  cryptsetup luksDump "$1" 2>/dev/null | awk '
        /^Keyslots:/ { inside = 1; next }
        /^[A-Za-z]/  { inside = 0 }
        inside && /^[[:space:]]+[0-9]+:/ { gsub(/[^0-9]/, "", $1); print $1 }'
}

header_tokens() {
  # clevis is not installed on a LiveCD, but the token it wrote is in the
  # header and luksDump shows it. A missing clevis must never read as
  # "nothing is sealed here".
  cryptsetup luksDump "$1" 2>/dev/null | awk '
        /^Tokens:/  { inside = 1; next }
        /^[A-Za-z]/ { inside = 0 }
        inside && NF { print }'
}

secureboot_byte() {
  # The efivar is five bytes: four of UEFI attributes, then the value. Reading
  # the file as text gives the attribute byte, which is never 0 or 1.
  local name="$1" file
  # Two statements: local expands all its arguments before assigning any of
  # them, so a second one reading the first would expand to nothing.
  file="${EFIVARS_DIR}/${name}-${SECUREBOOT_GUID}"
  [[ -r "$file" ]] || return 1
  od -An -tu1 -j 4 -N 1 "$file" 2>/dev/null | tr -d '[:space:]'
}

dmi_value() {
  local file="/sys/class/dmi/id/$1"
  if [[ -r "$file" ]]; then
    tr -d '\n' <"$file"
  else
    echo "unknown"
  fi
}

################################################################################
# Verdicts
################################################################################

# One line per check, and one fact recorded for the attestation. A failed check
# does not stop the run: an operator preparing a flash wants the whole list in
# one pass, not one refusal per attempt.
#
# This is the file's own verdict vocabulary, PASS / FAIL / SKIP / WARN, and it
# is deliberately not the log/ok/warn/err set: nine checks read as a table, not
# as nine log lines.
verdict() {
  local status="$1" key="$2" title="$3" detail="$4" colour="$C_0"

  CHECK_INDEX=$((CHECK_INDEX + 1))
  case "$status" in
    PASS) colour="$C_G" ;;
    WARN)
      colour="$C_Y"
      WARNINGS=$((WARNINGS + 1))
      ;;
    FAIL)
      colour="$C_R"
      HARD_FAILS=$((HARD_FAILS + 1))
      ;;
    SKIP) colour="$C_B" ;;
  esac

  printf "  %d/%d  %s%-6s%s %-22s %s\n" "$CHECK_INDEX" "$CHECK_TOTAL" \
    "$colour" "[$status]" "$C_0" "$title" "$detail" >&2
  CHECK_LINES+=("check_${key}=${status}")
}

verdict_note() {
  printf '        %s\n' "$1" >&2
}

check_power() {
  local supply type online capacity="" mains_seen="false" mains_online="false" seen="false"

  for supply in /sys/class/power_supply/*; do
    [[ -e "$supply/type" ]] || continue
    seen="true"
    type="$(cat "$supply/type" 2>/dev/null || echo unknown)"
    if [[ "$type" == "Mains" ]]; then
      mains_seen="true"
      online="$(cat "$supply/online" 2>/dev/null || echo 0)"
      [[ "$online" == "1" ]] && mains_online="true"
    elif [[ "$type" == "Battery" && -r "$supply/capacity" ]]; then
      capacity="$(cat "$supply/capacity" 2>/dev/null || echo)"
    fi
  done

  if [[ "$seen" == "false" ]]; then
    verdict WARN power "AC power" "no power supply reported"
    verdict_note "A desktop or a virtual machine. There is nothing to check here,"
    verdict_note "and nothing proven either."
    return 0
  fi

  if [[ "$mains_online" == "true" ]]; then
    if [[ -n "$capacity" && "$capacity" -lt "$MIN_BATTERY" ]]; then
      verdict WARN power "AC power" "mains online, battery at ${capacity}%"
      verdict_note "fwupd refuses some capsules below ${MIN_BATTERY}% even on mains."
      verdict_note "Charge first, the flash is not urgent enough to argue with it."
      return 0
    fi
    verdict PASS power "AC power" "mains online${capacity:+, battery ${capacity}%}"
    return 0
  fi

  if [[ "$ALLOW_BATTERY" == "true" ]]; then
    verdict WARN power "AC power" "no mains, --allow-battery given"
    verdict_note "Recorded in the attestation. fwupd still refuses most capsules"
    verdict_note "on battery by itself, so this lifts the check, not the refusal."
    return 0
  fi

  if [[ "$mains_seen" == "true" ]]; then
    verdict FAIL power "AC power" "mains present but offline"
  else
    verdict FAIL power "AC power" "no mains supply found"
  fi
  verdict_note "A flash interrupted by a flat battery is a mainboard, not a retry."
  verdict_note "Plug the machine in, or pass --allow-battery and own the risk."
  return 0
}

check_secureboot() {
  local sb setup

  if [[ ! -d "$EFIVARS_DIR" ]]; then
    verdict FAIL secureboot "Secure Boot" "no efivarfs"
    verdict_note "$EFIVARS_DIR is not there: legacy boot, or efivarfs not mounted."
    verdict_note "fwupd has no capsule path to offer on a machine booted that way."
    return 0
  fi

  sb="$(secureboot_byte SecureBoot || echo)"
  setup="$(secureboot_byte SetupMode || echo)"

  if [[ -z "$sb" ]]; then
    verdict FAIL secureboot "Secure Boot" "variable unreadable"
    verdict_note "SecureBoot-${SECUREBOOT_GUID} could not be read."
    return 0
  fi

  if [[ "$sb" == "1" && "$setup" == "0" ]]; then
    verdict PASS secureboot "Secure Boot" "enabled, setup mode off"
    return 0
  fi

  if [[ "$sb" == "1" ]]; then
    verdict FAIL secureboot "Secure Boot" "enabled, but in setup mode"
    verdict_note "In setup mode the firmware accepts any key that is presented,"
    verdict_note "so a signature proves nothing about what will be trusted."
    return 0
  fi

  verdict FAIL secureboot "Secure Boot" "disabled (SecureBoot=$sb, SetupMode=${setup:-?})"
  verdict_note "Signing fwupdx64.efi buys nothing while Secure Boot is off, and the"
  verdict_note "capsule path this procedure describes is not the one in use."
  verdict_note "During a fresh install the firmware is deliberately in setup mode"
  verdict_note "with Secure Boot off; outside one, this is a finding to raise."
  verdict_note "Never turn Secure Boot off to work around a PCR change: it removes"
  verdict_note "the protection instead of restoring the unlocking."
  return 0
}

check_tpm() {
  local major

  if [[ ! -d /sys/class/tpm/tpm0 ]]; then
    verdict FAIL tpm "TPM" "no /sys/class/tpm/tpm0"
    verdict_note "No TPM exposed: the module is not loaded, or the firmware hides it."
    verdict_note "Without it nothing reseals after the flash, whatever the flash does."
    return 0
  fi

  major="$(cat /sys/class/tpm/tpm0/tpm_version_major 2>/dev/null || echo unknown)"
  if [[ "$major" != "2" ]]; then
    verdict FAIL tpm "TPM" "version $major, clevis needs 2"
    return 0
  fi

  if [[ ! -c /dev/tpmrm0 ]]; then
    verdict WARN tpm "TPM" "2.0 present, /dev/tpmrm0 missing"
    verdict_note "clevis talks to the resource manager /dev/tpmrm0. Without it the"
    verdict_note "reseal after the flash will not run, even with a healthy TPM."
    return 0
  fi

  if [[ -d /sys/class/tpm/tpm0/pcr-sha256 ]]; then
    verdict PASS tpm "TPM" "2.0, sha256 bank readable in sysfs"
  else
    verdict PASS tpm "TPM" "2.0 present"
    verdict_note "No pcr-sha256 in sysfs: PCR values will not be readable without"
    verdict_note "tpm2-tools, so no before/after comparison of the flash."
  fi
  return 0
}

check_luks() {
  local dump version slots count

  FACT_DEVICE="$(resolve_device 2>/dev/null || true)"
  if [[ -z "$FACT_DEVICE" ]]; then
    verdict FAIL luks "LUKS container" "not found"
    verdict_note "No volume group inside a container was found, and no --device given."
    verdict_note "Name it: ./bios-update.sh --device /dev/nvme0n1p2"
    return 0
  fi

  dump="$(cryptsetup luksDump "$FACT_DEVICE" 2>>"$ERR_LOG" || true)"
  if [[ -z "$dump" ]]; then
    verdict FAIL luks "LUKS container" "$FACT_DEVICE, luksDump failed"
    sed 's/^/        /' "$ERR_LOG" >&2 2>/dev/null || true
    return 0
  fi

  FACT_UUID="$(printf '%s\n' "$dump" | awk '/^UUID:/ {print $2}')"
  version="$(printf '%s\n' "$dump" | awk '/^Version:/ {print $2}')"
  slots="$(occupied_slots "$FACT_DEVICE" | tr '\n' ' ' | sed 's/[[:space:]]*$//')"
  count="$(printf '%s' "$slots" | wc -w | tr -d ' ')"

  if [[ "$count" == "0" ]]; then
    verdict FAIL luks "LUKS container" "$FACT_DEVICE, no readable keyslot"
    verdict_note "A container with no keyslot opens with nothing. Stop here and"
    verdict_note "run ./luks-check.sh report before anything else touches it."
    return 0
  fi

  verdict PASS luks "LUKS container" "$FACT_DEVICE, LUKS$version, slots: $slots"
  verdict_note "UUID $FACT_UUID"
  return 0
}

check_clevis() {
  local binding="" tokens=""

  if [[ -z "$FACT_DEVICE" ]]; then
    verdict SKIP clevis "Clevis binding" "no container to look at"
    return 0
  fi

  if command -v clevis >/dev/null 2>&1; then
    binding="$(clevis luks list -d "$FACT_DEVICE" 2>/dev/null || true)"
  fi
  tokens="$(header_tokens "$FACT_DEVICE")"

  if [[ -n "$binding" ]] || printf '%s' "$tokens" | grep -qi clevis; then
    FACT_CLEVIS="present"
    verdict WARN clevis "Clevis binding" "present, sealed on PCR 0,2,3,6"
    [[ -n "$binding" ]] && printf '%s\n' "$binding" | sed 's/^/        /' >&2
    verdict_note "The flash changes PCR 0, and PCR 0 is in $PCR_POLICY."
    verdict_note "This binding stops working the moment the firmware changes. That is"
    verdict_note "expected, and check 6 is what makes it survivable."
    verdict_note "The ordered way through it: ./bios-maint.sh prepare"
    return 0
  fi

  if ! command -v clevis >/dev/null 2>&1 && [[ -z "$tokens" ]]; then
    FACT_CLEVIS="absent"
    verdict PASS clevis "Clevis binding" "no token in the header"
    verdict_note "clevis is not installed here, so the header was read instead."
    verdict_note "Nothing is sealed on the TPM: the flash breaks no unlocking."
    return 0
  fi

  FACT_CLEVIS="absent"
  verdict PASS clevis "Clevis binding" "none"
  verdict_note "The machine already asks for its passphrase at boot. A flash changes"
  verdict_note "nothing about how it opens."
  return 0
}

check_credential() {
  local checker="$SCRIPT_DIR/luks-check.sh" rc=0

  if [[ -z "$FACT_DEVICE" ]]; then
    verdict FAIL credential "TPM-free credential" "nothing to prove it against"
    verdict_note "Without a container there is no way in to prove, and no flash."
    return 0
  fi

  if [[ "$DRY_RUN" == "true" ]]; then
    verdict SKIP credential "TPM-free credential" "--dry-run"
    verdict_note "Would run: $checker testkey --device $FACT_DEVICE"
    return 0
  fi

  if [[ ! -x "$checker" ]]; then
    verdict FAIL credential "TPM-free credential" "luks-check.sh not found"
    verdict_note "Looked for $checker, next to this script."
    verdict_note "This is the check the whole run exists for, so it is not skipped."
    verdict_note "By hand, and it must succeed before any flash:"
    verdict_note "  gpg --decrypt /boot/efi/luks-key.gpg > /tmp/k"
    verdict_note "  cryptsetup open --test-passphrase --disable-external-tokens \\"
    verdict_note "      --key-file /tmp/k $FACT_DEVICE ; echo \$?"
    verdict_note "  rm -f /tmp/k"
    return 0
  fi

  log "Proving a way in that does not go through the TPM"
  if [[ -n "$ROOT_PREFIX" ]]; then
    "$checker" testkey --device "$FACT_DEVICE" --root "$ROOT_PREFIX" || rc=$?
  else
    "$checker" testkey --device "$FACT_DEVICE" || rc=$?
  fi

  if [[ $rc -eq 0 ]]; then
    FACT_CREDENTIAL="proven"
    verdict PASS credential "TPM-free credential" "the key file opens a keyslot"
    verdict_note "Tested with --disable-external-tokens, so a TPM that still answers"
    verdict_note "could not make a dead key look valid."
    return 0
  fi

  FACT_CREDENTIAL="unproven"
  verdict FAIL credential "TPM-free credential" "not proven (luks-check.sh returned $rc)"
  verdict_note "This is the August 2026 incident in one line: the flash changes PCR 0,"
  verdict_note "the TPM stops releasing the key, and nothing else opens the machine."
  verdict_note "Fix this before anything else. Either prove the GPG-wrapped key, or"
  verdict_note "add a maintenance passphrase: ./bios-maint.sh prepare"
  return 0
}

check_header_backup() {
  local newest="" sum uuid dir_disk dev_disk mount_source

  if [[ -z "$BACKUP_DIR" ]]; then
    verdict FAIL header "LUKS header backup" "no --backup-dir given"
    verdict_note "A header backup, off the machine, is required before the flash."
    verdict_note "A corrupt header is the one accident no secret recovers from."
    verdict_note "  ./luks-header.sh backup --out /mnt/backup"
    verdict_note "  cryptsetup luksHeaderBackup --header-backup-file \\"
    verdict_note "      /mnt/backup/luks-header.bin ${FACT_DEVICE:-/dev/nvme0n1p2}"
    return 0
  fi

  newest="$(find "$BACKUP_DIR" -maxdepth 1 -type f -name '*.bin' -printf '%T@ %p\n' 2>/dev/null \
    | sort -rn | head -n 1 | cut -d' ' -f2- || true)"
  if [[ -z "$newest" ]]; then
    verdict FAIL header "LUKS header backup" "no .bin in $BACKUP_DIR"
    verdict_note "The directory exists but holds no header backup."
    return 0
  fi

  if ! uuid="$(cryptsetup luksUUID "$newest" 2>>"$ERR_LOG")"; then
    verdict FAIL header "LUKS header backup" "$(basename "$newest") is not a LUKS header"
    verdict_note "cryptsetup does not recognise it. A truncated copy looks like this."
    return 0
  fi

  if [[ -n "$FACT_UUID" && "$uuid" != "$FACT_UUID" ]]; then
    verdict FAIL header "LUKS header backup" "belongs to another container"
    verdict_note "File UUID  $uuid"
    verdict_note "Device UUID $FACT_UUID"
    verdict_note "Restoring this one would destroy the keyslots of this machine."
    return 0
  fi

  FACT_HEADER="$newest"
  sum="$(sha256sum "$newest" | awk '{print $1}')"

  # "Off the machine" is the requirement, not a preference. A header stored on
  # the disk it protects is gone with the accident it was taken for.
  mount_source="$(LC_ALL=C df --output=source "$BACKUP_DIR" 2>/dev/null | tail -n 1 || true)"
  dir_disk="$(lsblk -no PKNAME "$mount_source" 2>/dev/null | head -n 1 || true)"
  dev_disk="$(lsblk -no PKNAME "${FACT_DEVICE:-/dev/null}" 2>/dev/null | head -n 1 || true)"
  if [[ -n "$dir_disk" && -n "$dev_disk" && "$dir_disk" == "$dev_disk" ]]; then
    verdict WARN header "LUKS header backup" "verified, but on disk $dir_disk"
    verdict_note "$newest"
    verdict_note "That is the disk holding the container it protects. It survives a"
    verdict_note "bad flash, not a dead disk. Copy it off the machine."
    return 0
  fi

  verdict PASS header "LUKS header backup" "verified, UUID matches"
  verdict_note "$newest"
  verdict_note "sha256 $sum"
  return 0
}

check_capsule() {
  if [[ -z "$CAB_PATH" ]]; then
    verdict SKIP capsule "Firmware capsule" "no --cab given"
    verdict_note "The machine was checked, the payload was not. Pass --cab FILE to"
    verdict_note "have the capsule verified and recorded in the attestation."
    return 0
  fi

  log "Capsule, the check below belongs to this one:"
  if verify_cab "$CAB_PATH"; then
    verdict PASS capsule "Firmware capsule" "$(basename "$CAB_PATH")"
  else
    verdict FAIL capsule "Firmware capsule" "$(basename "$CAB_PATH") did not pass"
  fi
  return 0
}

check_esp() {
  local esp="${ROOT_PREFIX}${EFI_MOUNT}" free_kb cab_kb=0

  if [[ ! -d "$esp" ]]; then
    verdict WARN esp "ESP free space" "$esp does not exist"
    verdict_note "From a LiveCD, point at the mounted tree: --root /mnt/gentoo"
    return 0
  fi

  if ! mountpoint -q "$esp" 2>/dev/null; then
    verdict WARN esp "ESP free space" "$esp is not a mount point"
    verdict_note "The directory exists whether the ESP is mounted or not, and what is"
    verdict_note "in it then is not this machine's ESP. Nothing is concluded from it."
    return 0
  fi

  free_kb="$(LC_ALL=C df -Pk "$esp" 2>/dev/null | awk 'NR == 2 {print $4}')"
  if [[ ! "$free_kb" =~ ^[0-9]+$ ]]; then
    verdict WARN esp "ESP free space" "df said nothing about $esp"
    return 0
  fi

  [[ -n "$CAB_PATH" && -r "$CAB_PATH" ]] && cab_kb="$(($(stat -c %s "$CAB_PATH") / 1024))"

  if [[ "$free_kb" -lt "$MIN_ESP_FREE_KB" ]]; then
    verdict FAIL esp "ESP free space" "$((free_kb / 1024)) MB free, ${MIN_ESP_FREE_KB} KB wanted"
    verdict_note "fwupd stages the capsule on the ESP. Too little room and the flash"
    verdict_note "fails after the reboot, not before it."
    return 0
  fi

  if [[ "$cab_kb" -gt 0 && "$free_kb" -lt $((cab_kb * 2)) ]]; then
    verdict WARN esp "ESP free space" "$((free_kb / 1024)) MB free for a $((cab_kb / 1024)) MB capsule"
    verdict_note "Twice the capsule size is the comfortable margin. This is under it."
    return 0
  fi

  verdict PASS esp "ESP free space" "$((free_kb / 1024)) MB free on $esp"
  return 0
}

################################################################################
# The capsule
################################################################################

verify_cab() {
  # Ordered from the cheapest to the only one that answers the real question:
  # is this capsule for THIS machine? Everything before it proves the file is
  # intact, which is a different and much weaker claim.
  local cab="$1" hard=0 kind sum details product bios

  [[ -r "$cab" ]] || {
    err "Cannot read the capsule: $cab"
    return 1
  }

  kind="$(LC_ALL=C file -b "$cab" 2>/dev/null || echo unknown)"
  if [[ "$kind" == *"Microsoft Cabinet"* ]]; then
    log "  file       : $kind"
  else
    err "  file       : $kind"
    err "    Not a Microsoft Cabinet archive. A half-downloaded file and an"
    err "    HTML error page saved under a .cab name both look like this."
    hard=$((hard + 1))
  fi

  sum="$(sha256sum "$cab" | awk '{print $1}')"
  FACT_CAB_SHA="$sum"
  if [[ -n "$CAB_CHECKSUM" ]]; then
    if [[ "$sum" == "$CAB_CHECKSUM" ]]; then
      log "  sha256     : $sum (matches --checksum)"
    else
      err "  sha256     : $sum"
      err "    Expected : $CAB_CHECKSUM"
      err "    The file is not the one the checksum was taken from. Download it"
      err "    again rather than deciding which of the two is right."
      hard=$((hard + 1))
    fi
  else
    ok "  sha256     : $sum"
    log "    No --checksum given, so this is a value to report, not a check."
  fi

  if command -v cabextract >/dev/null 2>&1; then
    if cabextract -t "$cab" >/dev/null 2>>"$ERR_LOG"; then
      log "  cabextract : archive unpacks"
    else
      err "  cabextract : the archive does not unpack"
      hard=$((hard + 1))
    fi
  else
    warn "  cabextract : absent ($(tool_package cabextract)), archive not unpacked here"
    warn "    fwupdmgr get-details below parses the same archive and fails on a"
    warn "    truncated cab too, so the check that follows stays decisive."
  fi

  if ! command -v fwupdmgr >/dev/null 2>&1; then
    err "  get-details: fwupdmgr is absent ($(tool_package fwupdmgr))"
    err "    Nothing else answers 'is this capsule for this machine'."
    return 1
  fi

  details="$(LC_ALL=C timeout 60 fwupdmgr get-details "$cab" 2>>"$ERR_LOG" || true)"
  if [[ -z "$details" ]] || printf '%s' "$details" | grep -qiE "failed to|not supported"; then
    err "  get-details: fwupd does not accept this capsule"
    printf '%s\n' "$details" | sed 's/^/    /' >&2
    sed 's/^/    /' "$ERR_LOG" >&2 2>/dev/null || true
    hard=$((hard + 1))
  else
    log "  get-details: accepted"
    printf '%s\n' "$details" | sed 's/^/    /' >&2

    product="$(dmi_value product_name)"
    bios="$(dmi_value bios_version)"
    log "  machine    : $product, BIOS $bios"
    if printf '%s' "$details" | grep -qi -- "$bios"; then
      warn "    The capsule names the BIOS version already installed ($bios)."
      warn "    Reflashing the same version still changes nothing but the PCR."
    fi
    warn "    Read the model and version above yourself: a downgrade is legal,"
    warn "    and it changes PCR 0 exactly as an upgrade does."
  fi

  [[ $hard -eq 0 ]]
}

################################################################################
# Secure Boot signing
################################################################################

conf_var() {
  # Grepped, not sourced: this runs as root, and sourcing a config file to
  # read two paths executes everything else that config file contains.
  local file="$1" name="$2"
  [[ -r "$file" ]] || return 1
  sed -n "s/^[[:space:]]*${name}=[\"']\{0,1\}\([^\"']*\)[\"']\{0,1\}[[:space:]]*\$/\1/p" \
    "$file" | tail -n 1
}

journal_var() {
  # One value from the installer's state journal, or nothing. The journal is
  # key=value, one per line, and it is the only file here that gentoo-install
  # itself writes. Args: $1 = key.
  local key="$1" file="${ROOT_PREFIX}${STATE_DIR}/state"
  [[ -r "$file" ]] || return 0
  sed -n "s/^${key}=//p" "$file" | tail -n 1
}

resolve_sign_pair() {
  # Two sources name the db key and nobody reconciled them: the conventional
  # location is /etc/efikeys/db.*, buildkernel-next reads SECUREBOOT_KEY and
  # SECUREBOOT_CERT from /etc/buildkernel-next.conf. Signing fwupd with one
  # and the kernel with the other gives a machine that boots but cannot
  # flash, so when both exist and differ this refuses instead of guessing.
  local conf="${ROOT_PREFIX}${BUILDKERNEL_CONF}"
  local conf_key="" conf_cert=""
  local efi_key="${ROOT_PREFIX}${EFIKEYS_KEY}" efi_cert="${ROOT_PREFIX}${EFIKEYS_CERT}"
  local has_conf="false" has_efikeys="false"

  if [[ -n "$SIGN_KEY" && -n "$SIGN_CERT" ]]; then
    ok "Signing pair from the command line"
    ok "  key  : $SIGN_KEY"
    ok "  cert : $SIGN_CERT"
    return 0
  fi

  # The installer's own journal first, because it describes this machine: step
  # 80 records the pair it signed with, and neither source below is written by
  # gentoo-install at all. A machine installed by this project and signed by it
  # used to reach the refusal at the end of this function, having been asked
  # about two files it never creates.
  local journal_key="" journal_cert=""
  journal_key="$(journal_var boot.secureboot_keyfile)"
  journal_cert="$(journal_var boot.secureboot_cert)"
  if [[ -n "$journal_key" && -n "$journal_cert" ]]; then
    journal_key="${ROOT_PREFIX}${journal_key}"
    journal_cert="${ROOT_PREFIX}${journal_cert}"
    if [[ -r "$journal_key" && -r "$journal_cert" ]]; then
      SIGN_KEY="$journal_key"
      SIGN_CERT="$journal_cert"
      ok "Signing pair from the install journal (what step 80 signed with)"
      ok "  key  : $SIGN_KEY"
      ok "  cert : $SIGN_CERT"
      return 0
    fi
    warn "the install journal names a signing pair that is not readable here:"
    warn "  $journal_key"
    warn "  $journal_cert"
    warn "  Looking at the other two sources."
  fi

  conf_key="$(conf_var "$conf" SECUREBOOT_KEY || true)"
  conf_cert="$(conf_var "$conf" SECUREBOOT_CERT || true)"
  [[ -n "$conf_key" && -n "$conf_cert" && -r "$conf_key" && -r "$conf_cert" ]] && has_conf="true"
  [[ -r "$efi_key" && -r "$efi_cert" ]] && has_efikeys="true"

  if [[ "$has_conf" == "true" && "$has_efikeys" == "true" ]]; then
    if [[ "$(readlink -f "$conf_key")" != "$(readlink -f "$efi_key")" ]] \
      || [[ "$(readlink -f "$conf_cert")" != "$(readlink -f "$efi_cert")" ]]; then
      err "Two signing pairs, and they are not the same files"
      err "  $conf says:"
      err "    $conf_key"
      err "    $conf_cert"
      err "  The conventional pair is:"
      err "    $efi_key"
      err "    $efi_cert"
      printf '\n' >&2
      printf '%s\n' "  The kernel is signed with the first pair. Signing fwupdx64.efi with" >&2
      printf '%s\n' "  the second gives a machine that boots and does not flash, or the" >&2
      printf '%s\n' "  other way round, and the symptom appears one reboot later." >&2
      printf '\n' >&2
      err "Nothing was signed. Name the pair explicitly:"
      err "  ./bios-update.sh sign --key FILE --cert FILE"
      err "--force does not lift this refusal."
      return 1
    fi
  fi

  if [[ "$has_conf" == "true" ]]; then
    SIGN_KEY="$conf_key"
    SIGN_CERT="$conf_cert"
    ok "Signing pair from $conf (the one the kernel is signed with)"
    ok "  key  : $SIGN_KEY"
    ok "  cert : $SIGN_CERT"
    return 0
  fi

  if [[ "$has_efikeys" == "true" ]]; then
    SIGN_KEY="$efi_key"
    SIGN_CERT="$efi_cert"
    ok "Signing pair from the conventional /etc/efikeys path"
    ok "  key  : $SIGN_KEY"
    ok "  cert : $SIGN_CERT"
    return 0
  fi

  err "No Secure Boot signing pair found"
  err "  Looked at ${ROOT_PREFIX}${STATE_DIR}/state (boot.secureboot_keyfile / _cert)"
  err "  Looked at $conf (SECUREBOOT_KEY / SECUREBOOT_CERT)"
  err "  Looked at $efi_key and $efi_cert"
  err "The db key lives on the installed machine, not on the admin one."
  err "Run this on the machine itself, or name the pair with --key and --cert"
  return 1
}

verify_pair() {
  local key="$1" cert="$2" key_mod cert_mod

  command -v openssl >/dev/null 2>&1 || {
    warn "openssl is absent ($(tool_package openssl)), key and certificate not compared"
    return 0
  }

  if ! LC_ALL=C openssl x509 -in "$cert" -noout -checkend 0 >/dev/null 2>>"$ERR_LOG"; then
    err "The certificate is expired: $cert"
    err "  A firmware that enrolled it still trusts it, but a new signature"
    err "  made with it is a problem waiting for the next machine."
    return 1
  fi

  cert_mod="$(LC_ALL=C openssl x509 -in "$cert" -noout -modulus 2>/dev/null || true)"
  key_mod="$(LC_ALL=C openssl rsa -in "$key" -noout -modulus 2>/dev/null || true)"
  if [[ -z "$cert_mod" || -z "$key_mod" ]]; then
    warn "Not an RSA pair, or the modulus could not be read: not compared"
    return 0
  fi

  if [[ "$cert_mod" != "$key_mod" ]]; then
    err "The key and the certificate do not go together"
    err "  key  : $key"
    err "  cert : $cert"
    err "  A signature made with them is rejected at boot, and the machine"
    err "  says nothing more useful than 'Security Violation'."
    return 1
  fi

  log "Key and certificate match, certificate is not expired"
  return 0
}

verify_signed() {
  # "Has a signature" is not the question. "Signed by the key this firmware
  # trusts" is, so the common name of the signer is compared with the
  # certificate we signed with.
  #
  # The listing is judged on its text and never on the exit status of
  # sbverify: `sbverify --list` returns 0 on a binary that carries no
  # signature at all. Testing its return code would call an unsigned
  # fwupdx64.efi signed, which is a "Security Violation" one reboot later.
  local signed="$1" cert="$2" listing cert_cn sig_cn

  listing="$(LC_ALL=C sbverify --list "$signed" 2>>"$ERR_LOG" || true)"
  if ! printf '%s' "$listing" | grep -qi "^signature"; then
    err "  sbverify --list finds no signature in $signed"
    return 1
  fi

  printf '%s\n' "$listing" | sed 's/^/    /' >&2

  cert_cn="$(LC_ALL=C openssl x509 -in "$cert" -noout -subject 2>/dev/null \
    | sed -n 's/.*CN *= *\([^,/]*\).*/\1/p' | head -n 1 || true)"
  sig_cn="$(printf '%s\n' "$listing" | sed -n 's/.*CN=\([^,/]*\).*/\1/p' | head -n 1 || true)"

  if [[ -z "$cert_cn" || -z "$sig_cn" ]]; then
    warn "  Signer and certificate could not be compared by name"
    return 0
  fi

  if [[ "${cert_cn// /}" != "${sig_cn// /}" ]]; then
    err "  Signed by another issuer than the certificate given"
    err "    certificate : $cert_cn"
    err "    signature   : $sig_cn"
    return 1
  fi

  log "  Signed by $sig_cn, which is the certificate given"
  return 0
}

ensure_package_use() {
  local file="${ROOT_PREFIX}${PACKAGE_USE}" line="sys-apps/fwupd-efi secureboot"

  if [[ -f "$file" ]] && grep -qF "$line" "$file"; then
    skip "USE flag already in $file"
    return 0
  fi

  warn "About to add to $file:"
  warn "  $line"
  warn "Nothing else in that file is touched."
  if ! confirm "Add the secureboot USE flag?" "Y"; then
    log "Skipped, the portage route will not sign anything"
    return 1
  fi

  run_cmd mkdir -p "$(dirname "$file")" || return 1
  if [[ "$DRY_RUN" == "true" ]]; then
    warn "dry-run: echo '$line' >> $file"
    return 0
  fi
  printf '%s\n' "$line" >>"$file" || return 1
  ok "Added: $line"
  return 0
}

run_emerge() {
  local key="$1" cert="$2"

  if ! command -v emerge >/dev/null 2>&1; then
    warn "emerge is absent here, the portage route is skipped"
    return 1
  fi

  printf '\n' >&2
  warn "About to rebuild sys-apps/fwupd-efi. That writes to the system:"
  warn "  SECUREBOOT_SIGN_KEY=$key"
  warn "  SECUREBOOT_SIGN_CERT=$cert"
  warn "  emerge -1 sys-apps/fwupd-efi"
  if ! confirm "Run emerge now?" "N"; then
    log "Skipped, falling back to signing the binary in place"
    return 1
  fi

  if ! run_cmd env SECUREBOOT_SIGN_KEY="$key" SECUREBOOT_SIGN_CERT="$cert" \
    emerge -1 sys-apps/fwupd-efi; then
    err "emerge failed, see its output above"
    err "  The fallback below signs the binary already installed."
    return 1
  fi
  return 0
}

################################################################################
# fwupd configuration
################################################################################

capsule_option() {
  # Bounded to the [uefi_capsule] section: the same key under another section
  # is a key fwupd ignores, and reading it would report a setting that is not
  # in force.
  local file="$1"
  awk -F= '
        /^[[:space:]]*\[/ { insec = ($0 ~ /^[[:space:]]*\[uefi_capsule\]/); next }
        insec && /^[[:space:]]*DisableShimForSecureBoot[[:space:]]*=/ {
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", $2); print $2; exit }
    ' "$file"
}

has_capsule_section() {
  grep -qE '^[[:space:]]*\[uefi_capsule\][[:space:]]*$' "$1"
}

################################################################################
# The attestation
################################################################################

write_state() {
  local dir="${ROOT_PREFIX}${STATE_DIR}" file="${ROOT_PREFIX}${STATE_FILE}" line result

  result="pass"
  [[ $HARD_FAILS -gt 0 ]] && result="fail"

  # --dry-run says it runs none of what it prints, and an attestation is the
  # one write of this command. Overwriting a passing attestation with a
  # dry-run one -- check 6 is skipped, so it always reads credential=unproven
  # -- would leave flash refusing an operator who had already earned the
  # right to run it, with nothing on screen to explain why.
  if [[ "$DRY_RUN" == "true" ]]; then
    log "Would write the attestation to $file, result=$result"
    if [[ -f "$file" ]]; then
      log "  The one already there is left alone: --dry-run writes nothing"
    fi
    return 0
  fi

  if ! mkdir -p "$dir" 2>>"$ERR_LOG"; then
    warn "Cannot create $dir, no attestation written"
    warn "  flash will refuse for lack of one, which is the safe outcome"
    return 1
  fi

  if ! (umask 077 && : >"$file") 2>>"$ERR_LOG"; then
    warn "Cannot write $file, no attestation written"
    return 1
  fi

  {
    echo "# gentoo-install bios-update.sh preflight attestation, do not edit"
    echo "timestamp=$(date +%s)"
    echo "timestamp_iso=$(date -Is)"
    echo "result=$result"
    echo "hard_fails=$HARD_FAILS"
    echo "warnings=$WARNINGS"
    echo "device=${FACT_DEVICE:-none}"
    echo "luks_uuid=${FACT_UUID:-none}"
    echo "clevis=$FACT_CLEVIS"
    echo "credential=$FACT_CREDENTIAL"
    echo "header_backup=${FACT_HEADER:-none}"
    echo "cab=${CAB_PATH:-none}"
    echo "cab_sha=${FACT_CAB_SHA:-none}"
    echo "allow_battery=$ALLOW_BATTERY"
    echo "product=$(dmi_value product_name)"
    echo "bios_version=$(dmi_value bios_version)"
    echo "kernel=$(uname -r)"
    for line in ${CHECK_LINES[@]+"${CHECK_LINES[@]}"}; do
      echo "$line"
    done
  } >>"$file"

  chmod 600 "$file" 2>/dev/null || true
  ok "Attestation written: $file"
  return 0
}

state_value() {
  # Read, not sourced: an attestation is data. Sourcing it would run whatever
  # a stale or edited file happens to contain.
  local file="$1" name="$2"
  [[ -r "$file" ]] || return 1
  sed -n "s/^${name}=\(.*\)\$/\1/p" "$file" | tail -n 1
}

################################################################################
# Commands
################################################################################

do_preflight() {
  init_err_log

  printf '\n' >&2
  printf '%s\n' "${C_B}=== Tools ===${C_0}" >&2
  printf '\n' >&2
  check_tools || true

  printf '\n' >&2
  printf '%s\n' "${C_B}=== Preflight, nine checks ===${C_0}" >&2
  printf '\n' >&2

  check_power
  check_secureboot
  check_tpm
  check_luks
  check_clevis
  check_credential
  check_header_backup
  check_capsule
  check_esp

  printf '\n' >&2
  if [[ "$NO_SIGN" == "false" && ! -f "${ROOT_PREFIX}${FWUPD_EFI}.signed" ]]; then
    warn "No ${ROOT_PREFIX}${FWUPD_EFI}.signed"
    warn "  Under Secure Boot the capsule loader has to be signed, or the"
    warn "  reboot rejects it. Run ./bios-update.sh sign, or --no-sign to say"
    warn "  this machine does not need it."
  fi

  write_state || true

  if [[ $HARD_FAILS -gt 0 ]]; then
    printf '\n' >&2
    err "Preflight failed: $HARD_FAILS hard, $WARNINGS warning(s)"
    err "  flash refuses to run against this attestation, and that is the point."
    err "  Fix what is red above, then run the preflight again."
    exit "$EXIT_FAILURE"
  fi

  if verbose_enough; then
    echo ""
    printf '%s\n' "${C_G}==================================================${C_0}"
    printf '%s\n' "${C_G}  Preflight passed${C_0}"
    printf '%s\n' "${C_G}==================================================${C_0}"
    echo ""
    echo "  $WARNINGS warning(s). The attestation is valid for $((STATE_MAX_AGE / 60)) minutes:"
    echo "  after that, flash asks for a fresh one rather than trusting it."
    echo ""
    echo "  Next: ./bios-update.sh flash <firmware.cab>"
    echo ""
  else
    ok "Preflight passed on ${FACT_DEVICE:-no container}, $WARNINGS warning(s)"
  fi
}

do_check_cab() {
  init_err_log

  if [[ -z "$CAB_PATH" ]]; then
    err "check-cab needs a capsule"
    err "  ./bios-update.sh check-cab /opt/firmware.cab"
    exit "$EXIT_USAGE"
  fi

  printf '\n' >&2
  printf '%s\n' "${C_B}=== Capsule ===${C_0}" >&2
  printf '\n' >&2
  ok "File       : $CAB_PATH"

  if ! verify_cab "$CAB_PATH"; then
    printf '\n' >&2
    err "This capsule did not pass. Nothing was installed."
    exit "$EXIT_FAILURE"
  fi

  if verbose_enough; then
    echo ""
    printf '%s\n' "${C_G}==================================================${C_0}"
    printf '%s\n' "${C_G}  Capsule accepted${C_0}"
    printf '%s\n' "${C_G}==================================================${C_0}"
    echo ""
    echo "  Intact, and fwupd reads it as firmware for a device it knows."
    echo "  That is not yet a decision to flash: run the preflight."
    echo ""
  else
    ok "Capsule accepted: $CAB_PATH"
  fi
}

do_sign() {
  local unsigned="${ROOT_PREFIX}${FWUPD_EFI}" signed="${ROOT_PREFIX}${FWUPD_EFI}.signed"
  local stamp portage_ok="false" t

  init_err_log

  for t in sbsign sbverify; do
    command -v "$t" >/dev/null 2>&1 || {
      die "missing: $t ($(tool_package "$t"))"
    }
  done

  resolve_sign_pair || exit "$EXIT_FAILURE"
  verify_pair "$SIGN_KEY" "$SIGN_CERT" || exit "$EXIT_FAILURE"

  if [[ ! -f "$unsigned" ]]; then
    err "No fwupdx64.efi at $unsigned"
    err "  Install sys-apps/fwupd-efi first, or point --root at the tree"
    exit "$EXIT_FAILURE"
  fi

  printf '\n' >&2
  log "Portage route first: an ebuild-signed binary is re-signed at every"
  log "update of fwupd-efi, one signed by hand here is not."
  if ensure_package_use && run_emerge "$SIGN_KEY" "$SIGN_CERT"; then
    portage_ok="true"
  fi

  printf '\n' >&2
  if [[ -f "$signed" ]]; then
    log "Checking $signed"
    if verify_signed "$signed" "$SIGN_CERT"; then
      if [[ "$portage_ok" == "true" ]]; then
        log "Produced by the portage route"
      fi
      if verbose_enough; then
        echo ""
        printf '%s\n' "${C_G}==================================================${C_0}"
        printf '%s\n' "${C_G}  fwupdx64.efi is signed${C_0}"
        printf '%s\n' "${C_G}==================================================${C_0}"
        echo ""
        echo "  Next: ./bios-update.sh noshim, then the preflight."
        echo ""
      else
        ok "Signed: $signed"
      fi
      return 0
    fi
    warn "The signature in place is not usable, signing again"
  fi

  printf '\n' >&2
  warn "About to write $signed with sbsign."
  warn "$unsigned itself is left alone."
  if ! confirm "Sign it now?" "Y"; then
    log "Cancelled, nothing changed"
    exit "$EXIT_SUCCESS"
  fi

  if [[ -f "$signed" ]]; then
    stamp="$(date +%Y%m%d-%H%M%S)"
    run_cmd cp -p "$signed" "${signed}.bak.${stamp}" || {
      die "Could not keep a copy of the existing $signed"
    }
    log "Previous signature kept as ${signed}.bak.${stamp}"
  fi

  if ! run_cmd sbsign --key "$SIGN_KEY" --cert "$SIGN_CERT" \
    --output "$signed" "$unsigned" 2>>"$ERR_LOG"; then
    err "sbsign failed"
    sed 's/^/    /' "$ERR_LOG" >&2 2>/dev/null || true
    exit "$EXIT_FAILURE"
  fi

  if [[ "$DRY_RUN" == "true" ]]; then
    warn "dry-run: nothing was written, so nothing is verified"
    return 0
  fi

  if ! verify_signed "$signed" "$SIGN_CERT"; then
    rm -f "$signed"
    err "The signature produced is not the one expected: $signed removed"
    err "  No file is better than a file the firmware refuses at reboot,"
    err "  which is a diagnostic made cold, one reboot later."
    exit "$EXIT_FAILURE"
  fi

  if verbose_enough; then
    echo ""
    printf '%s\n' "${C_G}==================================================${C_0}"
    printf '%s\n' "${C_G}  fwupdx64.efi is signed${C_0}"
    printf '%s\n' "${C_G}==================================================${C_0}"
    echo ""
    echo "  Next: ./bios-update.sh noshim, then the preflight."
    echo ""
  else
    ok "Signed: $signed"
  fi
}

do_noshim() {
  local conf="${ROOT_PREFIX}${FWUPD_CONF}" signed="${ROOT_PREFIX}${FWUPD_EFI}.signed"
  local current stamp

  init_err_log

  if [[ ! -f "$conf" ]]; then
    err "No fwupd configuration at $conf"
    err "  fwupd is not installed here, or the tree is elsewhere: --root DIR"
    exit "$EXIT_FAILURE"
  fi

  if [[ ! -f "$signed" && "$FORCE" != "true" ]]; then
    err "No signed binary at $signed"
    err "  Bypassing Shim without a signed fwupdx64.efi removes the only"
    err "  path that would have worked at the next reboot."
    err "  Run ./bios-update.sh sign first. --force lifts this refusal."
    exit "$EXIT_FAILURE"
  fi

  current="$(capsule_option "$conf")"
  if [[ "$current" == "true" ]]; then
    skip "DisableShimForSecureBoot is already true in $conf"
    skip "Nothing to change"
    return 0
  fi

  printf '\n' >&2
  if [[ -n "$current" ]]; then
    warn "[uefi_capsule] already says DisableShimForSecureBoot=$current"
    warn "Someone set that on purpose, or an update did. Changing it is a"
    warn "decision, not a repair."
    if ! confirm "Set it to true?" "N"; then
      log "Cancelled, nothing changed"
      exit "$EXIT_SUCCESS"
    fi
  elif has_capsule_section "$conf"; then
    warn "Adding DisableShimForSecureBoot=true to the existing [uefi_capsule]"
    warn "section of $conf. Nothing else in the file is rewritten."
    if ! confirm "Write it?" "Y"; then
      log "Cancelled, nothing changed"
      exit "$EXIT_SUCCESS"
    fi
  else
    warn "$conf has no [uefi_capsule] section: it will be appended, with"
    warn "DisableShimForSecureBoot=true under it. The rest is left as it is."
    if ! confirm "Append the section?" "Y"; then
      log "Cancelled, nothing changed"
      exit "$EXIT_SUCCESS"
    fi
  fi

  stamp="$(date +%Y%m%d-%H%M%S)"
  run_cmd cp -p "$conf" "${conf}.bak.${stamp}" || {
    die "Could not back up $conf, nothing was changed"
  }
  log "Backup: ${conf}.bak.${stamp}"

  TEMP_CONF="$(umask 077 && mktemp /tmp/gentoo-install-bios-update-conf.XXXXXX)" || {
    die "Cannot create a temporary file"
  }
  trap 'rm -f "${TEMP_CONF:-}"' EXIT INT TERM

  if has_capsule_section "$conf"; then
    awk '
            /^[[:space:]]*\[/ { insec = ($0 ~ /^[[:space:]]*\[uefi_capsule\]/) }
            insec && /^[[:space:]]*DisableShimForSecureBoot[[:space:]]*=/ { next }
            { print }
            insec && /^[[:space:]]*\[uefi_capsule\]/ { print "DisableShimForSecureBoot=true" }
        ' "$conf" >"$TEMP_CONF"
  else
    cat "$conf" >"$TEMP_CONF"
    printf '\n[uefi_capsule]\nDisableShimForSecureBoot=true\n' >>"$TEMP_CONF"
  fi

  if [[ "$DRY_RUN" == "true" ]]; then
    warn "dry-run: $conf would become"
    sed 's/^/    /' "$TEMP_CONF" >&2
  else
    # cat into the file, not mv: the mode, the owner and the inode of a
    # configuration file are part of it.
    cat "$TEMP_CONF" >"$conf"
  fi

  rm -f "$TEMP_CONF"
  TEMP_CONF=""
  trap - EXIT INT TERM

  if [[ "$DRY_RUN" != "true" ]]; then
    current="$(capsule_option "$conf")"
    if [[ "$current" != "true" ]]; then
      err "Re-read of $conf still says '${current:-nothing}'"
      err "  The backup is ${conf}.bak.${stamp}"
      exit "$EXIT_FAILURE"
    fi
    ok "DisableShimForSecureBoot=true in $conf"
  fi

  # Only on this machine: with --root the daemon that matters runs elsewhere,
  # and stopping the local one changes nothing about the tree being edited.
  if [[ -z "$ROOT_PREFIX" ]]; then
    log "Stopping the running daemon so it rereads its configuration"
    run_cmd fwupdmgr quit >/dev/null 2>&1 || true
    run_cmd pkill -x fwupd >/dev/null 2>&1 || true
  fi

  if verbose_enough; then
    echo ""
    printf '%s\n' "${C_G}==================================================${C_0}"
    printf '%s\n' "${C_G}  Shim bypass configured${C_0}"
    printf '%s\n' "${C_G}==================================================${C_0}"
    echo ""
    echo "  fwupd now loads its own signed binary instead of going through"
    echo "  Shim. That binary has to be signed with the db key, which is"
    echo "  what ./bios-update.sh sign does."
    echo ""
  else
    ok "DisableShimForSecureBoot=true in $conf"
  fi
}

do_flash() {
  local file="${ROOT_PREFIX}${STATE_FILE}" ts result uuid cred clevis state_cab_sha
  local now age dev current_uuid sum

  init_err_log

  if [[ -z "$CAB_PATH" ]]; then
    err "flash needs the capsule"
    err "  ./bios-update.sh flash /opt/firmware.cab"
    exit "$EXIT_USAGE"
  fi
  [[ -r "$CAB_PATH" ]] || die "Cannot read capsule: $CAB_PATH"
  command -v fwupdmgr >/dev/null 2>&1 || {
    die "missing: fwupdmgr ($(tool_package fwupdmgr))"
  }

  if [[ ! -r "$file" ]]; then
    err "No preflight attestation at $file"
    err "  flash reads what preflight proved. Without it there is nothing"
    err "  to say this machine can be opened again after the PCR change."
    err "  Run: ./bios-update.sh preflight --cab $CAB_PATH"
    exit "$EXIT_FAILURE"
  fi

  ts="$(state_value "$file" timestamp || echo)"
  result="$(state_value "$file" result || echo)"
  uuid="$(state_value "$file" luks_uuid || echo)"
  cred="$(state_value "$file" credential || echo)"
  clevis="$(state_value "$file" clevis || echo)"
  state_cab_sha="$(state_value "$file" cab_sha || echo)"

  if [[ "$result" != "pass" ]]; then
    err "The last preflight did not pass (result=${result:-unreadable})"
    err "  Run it again and fix what it reports. --force does not lift this."
    exit "$EXIT_FAILURE"
  fi

  [[ "$ts" =~ ^[0-9]+$ ]] || ts=0
  now="$(date +%s)"
  age=$((now - ts))
  if [[ $ts -eq 0 || $age -gt $STATE_MAX_AGE ]]; then
    err "The attestation is $((age / 60)) minutes old, the limit is $((STATE_MAX_AGE / 60))"
    err "  Between a preflight and a flash a cable gets unplugged and a"
    err "  machine gets rebooted. Run the preflight again, it is cheap."
    exit "$EXIT_FAILURE"
  fi

  dev="$(resolve_device 2>/dev/null || true)"
  current_uuid=""
  [[ -n "$dev" ]] && current_uuid="$(cryptsetup luksUUID "$dev" 2>/dev/null || true)"
  if [[ -z "$current_uuid" ]]; then
    err "No LUKS container readable now, so the attestation cannot be matched"
    err "  It was taken on $uuid. Run the preflight again from this machine."
    exit "$EXIT_FAILURE"
  fi
  if [[ "$current_uuid" != "$uuid" ]]; then
    err "The attestation belongs to another container"
    err "  attestation : $uuid"
    err "  this machine: $current_uuid"
    err "  This is not the machine that was checked. --force does not lift this."
    exit "$EXIT_FAILURE"
  fi

  if [[ "$cred" != "proven" ]]; then
    err "The attestation records credential=$cred"
    err "  Flashing now is the August 2026 incident: PCR 0 changes, the TPM"
    err "  stops releasing the key, and no other way in was ever proven."
    err "  Go through ./bios-maint.sh prepare. --force does not lift this."
    exit "$EXIT_FAILURE"
  fi

  sum="$(sha256sum "$CAB_PATH" | awk '{print $1}')"
  if [[ -n "$state_cab_sha" && "$state_cab_sha" != "none" && "$state_cab_sha" != "$sum" ]]; then
    err "The attestation covers another capsule"
    err "  attestation : $state_cab_sha"
    err "  this file   : $sum"
    err "  Run the preflight against the capsule actually being installed."
    exit "$EXIT_FAILURE"
  fi

  if [[ "$clevis" == "present" ]]; then
    printf '\n' >&2
    warn "A clevis binding is still on this container."
    warn "The flash changes PCR 0, the policy $PCR_POLICY seals on it, and the"
    warn "machine will ask for a passphrase at the next boot. The ordered way"
    warn "through is ./bios-maint.sh prepare, which removes the binding first"
    warn "and proves the maintenance passphrase by an actual reboot."
    if ! confirm "Flash anyway, with the binding still in place?" "N"; then
      log "Cancelled, nothing was flashed"
      exit "$EXIT_SUCCESS"
    fi
  fi

  # Re-checked here and not trusted from the attestation: a power cable is
  # exactly the kind of thing that changes between two commands.
  CHECK_INDEX=0
  CHECK_TOTAL=1
  HARD_FAILS=0
  WARNINGS=0
  check_power
  if [[ $HARD_FAILS -gt 0 ]]; then
    err "Not on mains at the moment of flashing"
    err "  fwupd refuses the capsule itself in this state; this refusal only"
    err "  says so before the reboot rather than after it."
    exit "$EXIT_FAILURE"
  fi

  printf '\n' >&2
  warn "About to write firmware on $(dmi_value product_name), BIOS $(dmi_value bios_version)"
  warn "Capsule: $CAB_PATH"
  warn "No keyslot is touched by this command, and none is created either."
  if ! confirm "Flash now?" "N"; then
    log "Cancelled, nothing was flashed"
    exit "$EXIT_SUCCESS"
  fi

  if ! run_cmd fwupdmgr install "$CAB_PATH"; then
    err "fwupdmgr install failed"
    err "  The firmware in place is unchanged, and so are the PCR values."
    err "  Read the message above: an unsigned loader and a missing"
    err "  DisableShimForSecureBoot both fail here, and both are fixable."
    exit "$EXIT_FAILURE"
  fi

  printf '\n' >&2
  warn "PCR 0 changes at the next boot. It measures the firmware code, and"
  warn "the clevis policy $PCR_POLICY seals on it."
  warn "The TPM will refuse to release keyslot 2, and the machine will ask"
  warn "for its passphrase instead. That is expected, not a failure."

  if verbose_enough; then
    echo ""
    printf '%s\n' "${C_G}==================================================${C_0}"
    printf '%s\n' "${C_G}  Capsule installed${C_0}"
    printf '%s\n' "${C_G}==================================================${C_0}"
    echo ""
    echo "  1. Reboot. Unlock with the credential proven at preflight."
    echo "  2. ./tpm-reseal.sh reseal      seals against the new firmware"
    echo "     or ./bios-maint.sh rebind   which also compares the PCR and"
    echo "                                 proves the new binding really"
    echo "                                 unseals before it trusts it"
    echo "  3. Reboot again and check the machine opens on its own."
    echo ""
    echo "  Do not turn Secure Boot or the TPM off to work around the PCR"
    echo "  change: that removes the protection instead of restoring the"
    echo "  unlocking, and this project forbids it."
    echo ""
  else
    ok "Capsule installed. Reboot, then ./tpm-reseal.sh reseal"
  fi
}

do_status() {
  local signed="${ROOT_PREFIX}${FWUPD_EFI}.signed" unsigned="${ROOT_PREFIX}${FWUPD_EFI}"
  local conf="${ROOT_PREFIX}${FWUPD_CONF}" state="${ROOT_PREFIX}${STATE_FILE}"
  local version devices sb setup option ts age result cred sb_text setup_text

  echo ""
  printf '%s\n' "${C_B}=== fwupd ===${C_0}"
  echo ""
  if command -v fwupdmgr >/dev/null 2>&1; then
    version="$(LC_ALL=C timeout 20 fwupdmgr --version 2>/dev/null \
      | awk '$2 == "org.freedesktop.fwupd" {print $3; exit}')"
    printf "  %-26s %s\n" "fwupdmgr:" "${version:-unknown version}"
    devices="$(LC_ALL=C timeout 30 fwupdmgr get-devices --no-unreported-check 2>/dev/null \
      | grep -c "Updatable" || true)"
    printf "  %-26s %s\n" "Updatable devices:" "${devices:-0}"
  else
    printf "  %-26s %s\n" "fwupdmgr:" "${C_Y}absent${C_0}"
  fi

  echo ""
  printf '%s\n' "${C_B}=== Secure Boot ===${C_0}"
  echo ""
  sb="$(secureboot_byte SecureBoot || echo "?")"
  setup="$(secureboot_byte SetupMode || echo "?")"
  if [[ "$sb" == "1" ]]; then
    sb_text="enabled"
  else
    sb_text="disabled ($sb)"
  fi
  if [[ "$setup" == "0" ]]; then
    setup_text="off"
  else
    setup_text="on ($setup)"
  fi
  printf "  %-26s %s\n" "SecureBoot:" "$sb_text"
  printf "  %-26s %s\n" "SetupMode:" "$setup_text"
  if [[ -f "$unsigned" ]]; then
    printf "  %-26s %s\n" "fwupdx64.efi:" "$unsigned"
  else
    printf "  %-26s %s\n" "fwupdx64.efi:" "${C_Y}absent${C_0}"
  fi
  if [[ -f "$signed" ]]; then
    # Judged on the listing, not on the return code: sbverify --list exits 0
    # on an unsigned binary.
    if command -v sbverify >/dev/null 2>&1 \
      && LC_ALL=C sbverify --list "$signed" 2>/dev/null | grep -qi "^signature"; then
      printf "  %-26s %s\n" "Signed copy:" "${C_G}present and signed${C_0}"
    else
      printf "  %-26s %s\n" "Signed copy:" "${C_Y}present, no readable signature${C_0}"
    fi
  else
    printf "  %-26s %s\n" "Signed copy:" "${C_Y}absent${C_0}"
  fi

  echo ""
  printf '%s\n' "${C_B}=== fwupd configuration ===${C_0}"
  echo ""
  if [[ -f "$conf" ]]; then
    option="$(capsule_option "$conf")"
    printf "  %-26s %s\n" "File:" "$conf"
    printf "  %-26s %s\n" "DisableShimForSecureBoot:" "${option:-not set}"
  else
    printf "  %-26s %s\n" "File:" "${C_Y}$conf is absent${C_0}"
  fi

  echo ""
  printf '%s\n' "${C_B}=== Last preflight ===${C_0}"
  echo ""
  if [[ -r "$state" ]]; then
    ts="$(state_value "$state" timestamp || echo 0)"
    result="$(state_value "$state" result || echo unknown)"
    cred="$(state_value "$state" credential || echo unknown)"
    [[ "$ts" =~ ^[0-9]+$ ]] || ts=0
    age=$(($(date +%s) - ts))
    printf "  %-26s %s\n" "File:" "$state"
    printf "  %-26s %s\n" "Taken:" "$(state_value "$state" timestamp_iso || echo unknown)"
    printf "  %-26s %s\n" "Age:" "$((age / 60)) minutes"
    printf "  %-26s %s\n" "Result:" "$result"
    printf "  %-26s %s\n" "Container:" "$(state_value "$state" device || echo unknown)"
    printf "  %-26s %s\n" "TPM-free credential:" "$cred"
    printf "  %-26s %s\n" "Clevis binding:" "$(state_value "$state" clevis || echo unknown)"
    echo ""
    if [[ "$result" == "pass" && $age -le $STATE_MAX_AGE ]]; then
      echo "  flash accepts this attestation."
    elif [[ "$result" == "pass" ]]; then
      echo "  Too old for flash, which wants one under $((STATE_MAX_AGE / 60)) minutes."
    else
      echo "  flash refuses this one: the preflight reported hard failures."
    fi
  else
    printf "  %-26s %s\n" "File:" "${C_Y}none at $state${C_0}"
    echo ""
    echo "  No preflight has been recorded here. flash refuses without one."
    echo "  Run: ./bios-update.sh preflight"
  fi
  echo ""
}

main() {
  parse_arguments "$@"

  case "$SUBCOMMAND" in
    preflight | check)
      check_root
      do_preflight
      ;;
    check-cab | cab)
      check_root
      do_check_cab
      ;;
    sign)
      check_root
      do_sign
      ;;
    noshim)
      check_root
      do_noshim
      ;;
    flash)
      check_root
      do_flash
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
