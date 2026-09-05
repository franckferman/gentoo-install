#!/usr/bin/env bash
#
# gentoo-install — PCR inspection: which register moved, and does it matter
# ----------------------------------------------------------------------------
# Reads the TPM platform configuration registers, says which ones changed since
# a snapshot, and whether the clevis policy is sealed on any of them. That last
# part is the whole answer: a register outside the policy can move as much as
# it likes without breaking automatic unlocking.
#
# It never writes to the TPM. The only thing it writes is a snapshot file, and
# only when asked for one.
#
# Usage:  ./tpm-pcr.sh <command> [options]   (--help for the list)
#
set -euo pipefail

readonly EXIT_SUCCESS=0
readonly EXIT_FAILURE=1
readonly EXIT_USAGE=2

# Configuration
SUBCOMMAND="show"
BANK="sha256"                          # --bank   : sha256 is the only bank the policy reads
TAG="manual"                           # --tag    : names the snapshot file
SNAP_DIR="/var/lib/gentoo-install/pcr" # --dir    : where snapshots are kept
SINCE=""                               # --since  : shortcut for compare TAG current
DEVICE=""                              # --device : container whose binding is read
ROOT_PREFIX=""                         # --root   : installed tree, when run from a LiveCD
JSON="false"                           # --json   : machine output, for show and compare

# Words left after the subcommand: PCR numbers for show and explain, snapshot
# names for compare. They are read before the options, so a word placed after
# an option still ends on "Unknown option" instead of being taken for a value.
ARGS=()

# --dir has to win over --root, and the two are indistinguishable once
# SNAP_DIR holds a path: the prefix applies to the default, never to a path
# the operator typed.
SNAP_DIR_GIVEN="false"

TPM_DIR="/sys/class/tpm/tpm0"
EVENT_LOG="/sys/kernel/security/tpm0/binary_bios_measurements"
PCR_POLICY='{"pcr_bank":"sha256","pcr_ids":"0,2,3,6"}'
POLICY_IDS="0,2,3,6"

# A SHA-256 PCR extended with nothing but EV_SEPARATOR ends on this value. It
# is the signature of a register in which no option ROM, no add-in card and no
# vendor event was ever measured, so sealing against it binds nothing.
EMPTY_PCR="3D458CFE55CC03EA1F443F1562BEEC8DF51C75E14A9FCF9A7234A13F198E7969"

# Set once by detect_source: sysfs, tpm2-tools or none. At script level because
# every reader needs it, and a subshell would work it out twenty-four times.
PCR_SOURCE="none"

ERR_LOG="/tmp/gentoo-install-tpm-pcr.log"

QUIET="${GI_QUIET:-false}"

# The two lists do_compare builds. At script level rather than local to it,
# because compare_json reads them and a value that crosses a function boundary
# by dynamic scoping is a value nobody can find a year later.
CHANGED=()
POLICY_CHANGED=()

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
Usage: ./tpm-pcr.sh [COMMAND] [OPTIONS]

================================================================================
gentoo-install - PCR inspection
Says which PCR moved, and whether that is why clevis no longer unseals
================================================================================

WHEN TO USE IT:
    A machine that used to unlock on its own asks for its passphrase again,
    and nobody can say what changed. This reads the PCR, tells which ones
    moved since a snapshot, and whether the policy clevis is bound to looks
    at them. That last part is the whole answer: a PCR outside the policy can
    move as much as it likes without breaking anything.

    It runs on the machine, in its chroot, or from a LiveCD, root or not.

WHAT IT NEVER DOES:
    It never writes to the TPM. There is no tpm2_pcrextend and no tpm2_clear
    in this file, and no clevis bind either. The only thing it writes is a
    snapshot under /var/lib/gentoo-install/pcr, and only when asked for one.

COMMANDS:
    show [N...]         Values now, with role and policy mark (default)
    snapshot            Freeze the current state in a dated file
    list                Stored snapshots: tag, date, BIOS version
    compare A [B]       Two snapshots, or one against now, with a verdict
    explain [N]         What each PCR measures, and what it holds here
    policy              The policy clevis really has, against the expected one

OPTIONS:
    -h, --help          Show this help
    -q, --quiet         Essential output only
        --bank NAME     PCR bank to read. Default: sha256, the policy's own
        --tag NAME      Names the snapshot file. Default: manual
        --dir DIR       Where snapshots live. Default: /var/lib/gentoo-install/pcr
        --since TAG     compare shortcut: that tag against the state now
        --device DEV    LUKS container. Detected from vg1 when omitted
        --root DIR      Root of the installed system, for a run from a LiveCD
        --json          Machine-readable output, for show and compare

WHERE THE VALUES COME FROM:
    /sys/class/tpm/tpm0/pcr-sha256/N, one file per register, world-readable.
    That is the normal source, not a fallback: tpm2-tools and clevis live in
    the installed system, and a diagnostic has to stay possible from a LiveCD
    where neither is there. tpm2_pcrread is used if it happens to be present,
    and nothing depends on it.

WHY PCR 4 IS NOT IN THE LIST:
    PCR 4 measures the boot file, and bootx64.efi is rewritten at every kernel
    build. Binding it would break automatic unlocking after every update, which
    is a worse trade than the coverage it buys.

WHEN A PCR CARRIES NOTHING:
    A SHA-256 register extended with nothing but the EV_SEPARATOR event ends on
    3D458CFE...7969. On the reference machine PCR 2, 3 and 6 all carry it: no
    option ROM, no add-in card, no vendor event was ever measured. Those three
    add nothing to the sealing, so the policy 0,2,3,6 rests on PCR 0 alone, and
    a BIOS update is the only thing that can break it. show, explain and policy
    say so.

ROOT:
    Only snapshot needs it, to write under /var/lib/gentoo-install. The
    registers themselves are world-readable, and a diagnostic that demands root
    is a diagnostic nobody runs from the shell they already have.

EXAMPLES:
    ./tpm-pcr.sh
        The twenty-four values, their role, and which ones the policy seals.

    ./tpm-pcr.sh snapshot --tag pre-flash
        Freezes the state before a BIOS update. Take it before, or the question
        "which PCR moved" has no answer afterwards.

    ./tpm-pcr.sh compare pre-flash
        That snapshot against the state now, with the verdict.

    ./tpm-pcr.sh explain 0
        What PCR 0 measures, what it holds here, and what changes it.

    ./tpm-pcr.sh policy --device /dev/nvme0n1p2
        What clevis is really bound to, against the expected 0,2,3,6.

HELP_EOF
}

parse_arguments() {
  if [[ $# -gt 0 ]] && [[ "$1" != -* ]]; then
    SUBCOMMAND="$1"
    shift
  fi

  while [[ $# -gt 0 ]] && [[ "$1" != -* ]]; do
    ARGS+=("$1")
    shift
  done

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
      --json)
        JSON="true"
        shift
        ;;
      --bank)
        [[ $# -ge 2 ]] || {
          err "--bank requires a name, e.g. sha256"
          exit "$EXIT_USAGE"
        }
        [[ "$2" =~ ^[a-z0-9]+$ ]] || {
          err "Invalid --bank: $2"
          exit "$EXIT_USAGE"
        }
        BANK="$2"
        shift 2
        ;;
      --tag)
        [[ $# -ge 2 ]] || {
          err "--tag requires a name, e.g. pre-flash"
          exit "$EXIT_USAGE"
        }
        [[ "$2" =~ ^[A-Za-z0-9._-]+$ ]] || {
          err "Invalid --tag: $2 (letters, digits, dash)"
          exit "$EXIT_USAGE"
        }
        TAG="$2"
        shift 2
        ;;
      --dir)
        [[ $# -ge 2 ]] || {
          err "--dir requires a directory"
          exit "$EXIT_USAGE"
        }
        SNAP_DIR="${2%/}"
        SNAP_DIR_GIVEN="true"
        shift 2
        ;;
      --since)
        [[ $# -ge 2 ]] || {
          err "--since requires a tag, e.g. pre-flash"
          exit "$EXIT_USAGE"
        }
        SINCE="$2"
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

  # --root names a tree mounted elsewhere, so that machine's snapshots are
  # under it too. A --dir typed by hand is already where the operator means.
  if [[ -n "$ROOT_PREFIX" && "$SNAP_DIR_GIVEN" == "false" ]]; then
    SNAP_DIR="${ROOT_PREFIX}${SNAP_DIR}"
  fi

  # --since is compare, with the current state as the second term
  if [[ -n "$SINCE" ]]; then
    SUBCOMMAND="compare"
    ARGS=("$SINCE" "current")
  fi

  if [[ "$BANK" != "sha256" ]]; then
    warn "Bank $BANK: the clevis policy of this project only reads sha256"
  fi
}

check_root() {
  if [[ $EUID -ne 0 ]]; then
    die "Need root access. Run: sudo -i"
  fi
}

normalize_device() {
  local input="${1:-}"
  input="${input%/}"
  input="${input#/dev/}"
  echo "$input"
}

################################################################################
# Reading the registers
################################################################################

check_tpm() {
  if [[ ! -d "$TPM_DIR" ]]; then
    err "No TPM here: $TPM_DIR does not exist"
    err "  Either this machine has no TPM, or its driver is not loaded"
    err "  compare, list and explain still work on stored snapshots"
    return 1
  fi
  return 0
}

detect_source() {
  # sysfs first and, on the reference machine, only. tpm2-tools is absent
  # from a LiveCD and from a fresh stage, while the kernel exposes the same
  # values with nothing to install and without root.
  local bank_dir="$TPM_DIR/pcr-$BANK" b have=""

  if [[ -d "$bank_dir" ]]; then
    PCR_SOURCE="sysfs"
    return 0
  fi

  for b in "$TPM_DIR"/pcr-*; do
    if [[ -d "$b" ]]; then
      have="$have ${b##*/pcr-}"
    fi
  done
  if [[ -n "$have" ]]; then
    warn "Bank $BANK is not exposed by this TPM. Banks present:$have"
  fi

  if command -v tpm2_pcrread >/dev/null 2>&1 && tpm2_pcrread "$BANK" >/dev/null 2>&1; then
    PCR_SOURCE="tpm2-tools"
    log "Reading through tpm2_pcrread, $bank_dir does not exist"
    return 0
  fi

  PCR_SOURCE="none"
  err "No readable source for bank $BANK"
  err "  Looked at $bank_dir, then at tpm2_pcrread"
  err "  tpm2-tools is app-crypt/tpm2-tools, in the installed system"
  return 1
}

read_pcr() {
  local n="$1" f v=""

  case "$PCR_SOURCE" in
    sysfs)
      f="$TPM_DIR/pcr-$BANK/$n"
      [[ -r "$f" ]] || return 1
      v="$(tr -d ' \r\n' <"$f")"
      ;;
    tpm2-tools)
      # awk on the index column, not grep: a digest can contain the
      # number being looked for anywhere in its own text.
      v="$(tpm2_pcrread "$BANK:$n" 2>>"$ERR_LOG" \
        | awk -v n="$n" '$1 == n && $2 == ":" {print $3}' || true)"
      v="${v#0x}"
      ;;
    *)
      return 1
      ;;
  esac

  [[ -n "$v" ]] || return 1
  echo "${v^^}"
}

is_empty_pcr() {
  [[ "${1:-}" == "$EMPTY_PCR" ]]
}

in_policy() {
  local n="$1" id
  local -a ids=()

  IFS=',' read -r -a ids <<<"$POLICY_IDS"
  for id in "${ids[@]}"; do
    if [[ "$id" == "$n" ]]; then
      return 0
    fi
  done
  return 1
}

pcr_role() {
  case "$1" in
    0) echo "UEFI firmware code, the BIOS itself" ;;
    1) echo "UEFI firmware settings and host configuration" ;;
    2) echo "Option ROM code carried by add-in cards" ;;
    3) echo "Option ROM configuration and data" ;;
    4) echo "Boot loader and boot attempts, bootx64.efi" ;;
    5) echo "Boot manager configuration and GPT partition table" ;;
    6) echo "Platform events: sleep, wake, vendor specific" ;;
    7) echo "Secure Boot state: PK, KEK, db, dbx" ;;
    8) echo "Kernel command line, as measured by the boot loader" ;;
    9) echo "Files the boot loader read: kernel, initramfs" ;;
    10) echo "IMA measurement log" ;;
    11) echo "Unified kernel image phases, systemd-stub" ;;
    12) echo "Kernel command line and credentials, systemd" ;;
    13) echo "System extensions, systemd" ;;
    14) echo "MOK certificates, enrolled through shim" ;;
    15) echo "Userspace: systemd-cryptsetup, measured file systems" ;;
    16) echo "Debug, resettable, never sound to seal against" ;;
    17) echo "DRTM: dynamic root of trust, set by the CPU" ;;
    18) echo "DRTM: trusted OS start-up code" ;;
    19) echo "DRTM: trusted OS" ;;
    20) echo "DRTM: trusted OS" ;;
    21) echo "DRTM: trusted OS" ;;
    22) echo "DRTM: reserved for the trusted OS" ;;
    23) echo "Application support, resettable by the OS" ;;
    *) echo "outside the 0 to 23 range" ;;
  esac
}

pcr_mover() {
  case "$1" in
    0) echo "A BIOS update. This is the one that breaks the sealing." ;;
    1) echo "A change made in the firmware setup screens." ;;
    2 | 3) echo "An added or removed card carrying an option ROM." ;;
    4) echo "Every kernel build, since bootx64.efi is rewritten." ;;
    5) echo "Repartitioning the disk." ;;
    6) echo "Vendor events. Often nothing at all on a laptop." ;;
    7) echo "Turning Secure Boot on or off, or enrolling keys." ;;
    *) echo "" ;;
  esac
}

################################################################################
# What names the machine
################################################################################

machine_id() {
  # The DMI serial number is what names the machine outside this script: the
  # inventory, the password manager entry, the certificate. Unlike
  # key-backup.sh this one never invents a random name on failure: a snapshot
  # is named by its tag and its timestamp, and compare has to be able to tell
  # "unknown" apart from a machine that really answered.
  local id=""
  if command -v dmidecode >/dev/null 2>&1; then
    id="$(dmidecode -s system-serial-number 2>/dev/null | head -n 1 | tr -d ' ' || true)"
  fi
  case "$id" in
    "" | None | "NotSpecified" | "ToBeFilledByO.E.M." | "SystemSerialNumber") id="" ;;
  esac
  if [[ -z "$id" && -r /sys/class/dmi/id/product_serial ]]; then
    # dmidecode is not in the stage, but the kernel exposes the same value
    id="$(tr -d ' \n' </sys/class/dmi/id/product_serial 2>/dev/null || true)"
    case "$id" in
      "" | None | "NotSpecified" | "ToBeFilledByO.E.M." | "SystemSerialNumber") id="" ;;
    esac
  fi

  [[ -n "$id" ]] || id="unknown"
  echo "$id"
}

dmi_value() {
  local f="/sys/class/dmi/id/$1" v=""

  if [[ -r "$f" ]]; then
    v="$(tr -d '\r\n' <"$f" || true)"
  fi
  [[ -n "$v" ]] || v="unknown"
  echo "$v"
}

secureboot_state() {
  # The EFI variable carries four attribute bytes then the flag, so the last
  # byte is the answer. bootctl is not on a LiveCD, od is.
  local f v=""

  for f in /sys/firmware/efi/efivars/SecureBoot-*; do
    if [[ -r "$f" ]]; then
      v="$(od -An -t u1 "$f" 2>/dev/null | awk '{print $NF}' | tail -n 1 || true)"
      break
    fi
  done

  case "$v" in
    1) echo "enabled" ;;
    0) echo "disabled" ;;
    *) echo "unknown" ;;
  esac
}

event_log_state() {
  if [[ -r "$EVENT_LOG" ]]; then
    echo "readable"
  elif [[ -e "$EVENT_LOG" ]]; then
    echo "present, root only"
  else
    echo "absent"
  fi
}

resolve_device() {
  local dev pv name

  command -v cryptsetup >/dev/null 2>&1 || {
    err "cryptsetup is not here, cannot look at a container"
    return 1
  }

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

  # vgs, not pvs: pvs takes physical volumes as arguments, not a group name
  pv="$(vgs --noheadings -o pv_name vg1 2>/dev/null | tr -d ' ' | head -n 1 || true)"
  if [[ -n "$pv" && "$pv" == /dev/mapper/* ]]; then
    name="$(basename "$pv")"
    dev="$(cryptsetup status "$name" 2>/dev/null | awk '/device:/ {print $2}' || true)"
    if [[ -n "$dev" ]] && cryptsetup isLuks "$dev" 2>/dev/null; then
      log "Container from the vg1 volume group: $dev"
      echo "$dev"
      return 0
    fi
  fi

  err "Cannot tell which container to read. Name it with --device"
  return 1
}

container_uuid() {
  local dev uuid=""

  dev="$(resolve_device 2>/dev/null)" || {
    echo "unknown"
    return 0
  }
  uuid="$(cryptsetup luksUUID "$dev" 2>>"$ERR_LOG" || true)"
  [[ -n "$uuid" ]] || uuid="unknown"
  echo "$uuid"
}

################################################################################
# Snapshots
################################################################################

live_field() {
  case "$1" in
    tag) echo "current" ;;
    date) date -Is ;;
    host) echo "${HOSTNAME:-unknown}" ;;
    machine) machine_id ;;
    kernel) uname -r ;;
    bios_version) dmi_value bios_version ;;
    bios_date) dmi_value bios_date ;;
    secureboot) secureboot_state ;;
    bank) echo "$BANK" ;;
    source) echo "$PCR_SOURCE" ;;
    eventlog) event_log_state ;;
    luks_uuid) container_uuid ;;
    policy) echo "$PCR_POLICY" ;;
    *) echo "unknown" ;;
  esac
}

current_snapshot_text() {
  local n v k

  echo "# gentoo-install PCR snapshot, written by tpm-pcr.sh"
  # The tag is what --tag gave. live_field answers "current" for it instead,
  # which is what compare needs when its term is the machine and not a file.
  echo "tag=$TAG"
  for k in date host machine kernel bios_version bios_date secureboot \
    bank source eventlog luks_uuid policy; do
    echo "$k=$(live_field "$k")"
  done
  for n in {0..23}; do
    v="$(read_pcr "$n")" || v=""
    if [[ -n "$v" ]]; then
      echo "pcr.$n=$v"
    fi
  done
}

snap_field() {
  # "current" is not a file: it is the machine as it stands, so every reader
  # below works the same way on a stored snapshot and on the live state.
  local file="$1" key="$2" v=""

  if [[ "$file" == "current" ]]; then
    live_field "$key"
    return 0
  fi

  v="$(grep -m 1 "^$key=" "$file" 2>/dev/null | cut -d= -f2- || true)"
  [[ -n "$v" ]] || v="unknown"
  echo "$v"
}

snap_pcr() {
  local file="$1" n="$2" v=""

  if [[ "$file" == "current" ]]; then
    read_pcr "$n" || return 1
    return 0
  fi

  v="$(grep -m 1 "^pcr\.$n=" "$file" 2>/dev/null | cut -d= -f2- || true)"
  [[ -n "$v" ]] || return 1
  echo "$v"
}

resolve_snapshot() {
  local name="$1" f newest=""

  if [[ "$name" == "current" ]]; then
    echo "current"
    return 0
  fi

  if [[ -f "$name" ]]; then
    [[ -r "$name" ]] || {
      err "Snapshot not readable: $name"
      return 1
    }
    echo "$name"
    return 0
  fi

  if [[ -f "$SNAP_DIR/$name" ]]; then
    echo "$SNAP_DIR/$name"
    return 0
  fi

  # The glob comes back sorted and the file name carries a sortable stamp,
  # so the last match is the most recent snapshot of that tag.
  for f in "$SNAP_DIR/$name"-*.txt; do
    if [[ -f "$f" ]]; then
      newest="$f"
    fi
  done

  if [[ -n "$newest" ]]; then
    echo "$newest"
    return 0
  fi

  err "No snapshot named $name"
  err "  Looked at $name, $SNAP_DIR/$name, then $SNAP_DIR/$name-*.txt"
  err "  ./tpm-pcr.sh list shows what is stored"
  return 1
}

check_snapshot() {
  local file="$1"

  [[ "$file" == "current" ]] && return 0
  if ! grep -q '^pcr\.' "$file" 2>/dev/null; then
    err "Not a snapshot, or truncated: $file"
    err "  A snapshot holds pcr.0= lines. This one holds none."
    return 1
  fi
  return 0
}

################################################################################
# What the policy is worth
################################################################################

policy_entropy_note() {
  # The point of the whole tool. A policy register that carries nothing seals
  # nothing, and saying it out loud is what was missing while the August 2026
  # incident was being investigated.
  local n v
  local -a ids=() empties=() carriers=()

  IFS=',' read -r -a ids <<<"$POLICY_IDS"
  for n in "${ids[@]}"; do
    v="$(read_pcr "$n")" || v=""
    if [[ -z "$v" ]]; then
      continue
    fi
    if is_empty_pcr "$v"; then
      empties+=("$n")
    else
      carriers+=("$n")
    fi
  done

  if [[ ${#empties[@]} -eq 0 ]]; then
    echo "  Every register of the policy carries a measurement."
    return 0
  fi

  echo "  Policy registers that carry nothing: ${empties[*]}"
  echo "  They hold the value of a register extended with EV_SEPARATOR alone:"
  echo "  no option ROM, no add-in card, no vendor event was ever measured."
  if [[ ${#carriers[@]} -eq 1 ]]; then
    echo "  The sealing therefore rests on PCR ${carriers[0]} alone."
    echo "  A BIOS update is the only thing that can break it, and nothing"
    echo "  else in the policy would notice a change."
  elif [[ ${#carriers[@]} -eq 0 ]]; then
    echo "  No register of the policy carries anything. The sealing binds the"
    echo "  key to nothing that identifies this firmware."
  else
    echo "  The sealing rests on PCR ${carriers[*]}, and on nothing else."
  fi
  return 0
}

policy_coverage_note() {
  echo "  Sealed     : $POLICY_IDS"
  echo "  Not sealed :"
  echo "    PCR 4  bootx64.efi. Left out on purpose: it is rewritten at every"
  echo "           kernel build, and binding it would break unlocking after"
  echo "           every update."
  echo "    PCR 7  Secure Boot state. Turning Secure Boot off would not stop"
  echo "           the TPM from releasing the key. Known, written down, and"
  echo "           left to the operator to arbitrate."
  return 0
}

bound_policy_ids() {
  # Named id_list, not ids: shellcheck follows sourced files across this
  # project and a `local -a ids=()` elsewhere makes a plain `ids` read as an
  # array here. Renaming is the fix; an exemption would only hide it.
  local bound="$1" id_list=""

  id_list="$(printf '%s' "$bound" | grep -o '"pcr_ids":"[^"]*"' | head -n 1 | cut -d'"' -f4 || true)"
  [[ -n "$id_list" ]] || return 1
  echo "$id_list"
}

join_list() {
  local out="" x

  for x in "$@"; do
    if [[ -n "$out" ]]; then
      out="$out,"
    fi
    out="$out$x"
  done
  echo "$out"
}

################################################################################
# Commands
################################################################################

do_show() {
  local n v mark
  local -a wanted=() empty_hits=()

  check_tpm || exit "$EXIT_FAILURE"
  detect_source || exit "$EXIT_FAILURE"

  if [[ ${#ARGS[@]} -gt 0 ]]; then
    for n in "${ARGS[@]}"; do
      [[ "$n" =~ ^[0-9]+$ ]] && [[ "$n" -le 23 ]] || {
        err "Not a PCR number: $n (0 to 23)"
        exit "$EXIT_USAGE"
      }
      wanted+=("$n")
    done
  else
    for n in {0..23}; do
      wanted+=("$n")
    done
  fi

  if [[ "$JSON" == "true" ]]; then
    show_json "${wanted[@]}"
    return 0
  fi

  echo ""
  printf '%s\n' "${C_B}=== PCR values, bank $BANK ===${C_0}"
  echo ""
  printf "  %-3s %-7s %s\n" "PCR" "Policy" "Value"
  for n in "${wanted[@]}"; do
    v="$(read_pcr "$n")" || v=""
    if [[ -z "$v" ]]; then
      printf "  %-3s %-7s %s\n" "$n" "-" "not exposed by this TPM"
      continue
    fi
    mark="-"
    if in_policy "$n"; then
      mark="sealed"
    fi
    printf "  %-3s %-7s %s\n" "$n" "$mark" "$v"
    if is_empty_pcr "$v" && ! in_policy "$n"; then
      empty_hits+=("$n")
    fi
  done

  echo ""
  printf "  %-12s %s\n" "Source:" "$PCR_SOURCE, $TPM_DIR/pcr-$BANK"
  printf "  %-12s %s\n" "Policy:" "$POLICY_IDS, the list this project binds"
  printf "  %-12s %s\n" "Event log:" "$(event_log_state)"
  echo ""
  if [[ ${#empty_hits[@]} -gt 0 ]]; then
    echo "  Outside the policy, PCR ${empty_hits[*]} carry nothing either."
  fi
  policy_entropy_note
  echo ""
  echo "  ./tpm-pcr.sh policy reads what clevis is really bound to."
  echo "  ./tpm-pcr.sh explain N says what a register measures."
  echo ""
}

show_json() {
  local n v sep="" inpol empty

  printf '{"bank":"%s","source":"%s","policy_ids":"%s","pcrs":{' \
    "$BANK" "$PCR_SOURCE" "$POLICY_IDS"
  for n in "$@"; do
    v="$(read_pcr "$n")" || v=""
    inpol="false"
    empty="false"
    in_policy "$n" && inpol="true"
    is_empty_pcr "$v" && empty="true"
    printf '%s"%s":{"value":"%s","in_policy":%s,"empty":%s}' \
      "$sep" "$n" "$v" "$inpol" "$empty"
    sep=","
  done
  printf '}}\n'
  return 0
}

do_snapshot() {
  local file stamp

  check_tpm || exit "$EXIT_FAILURE"
  detect_source || exit "$EXIT_FAILURE"

  if [[ ! -d "$SNAP_DIR" ]]; then
    mkdir -p "$SNAP_DIR" || {
      err "Cannot create $SNAP_DIR"
      err "  Point --dir at a directory this account can write"
      exit "$EXIT_FAILURE"
    }
    chmod 700 "$SNAP_DIR" 2>/dev/null || true
  fi
  [[ -w "$SNAP_DIR" ]] || {
    err "Not writable: $SNAP_DIR"
    err "  Point --dir at a directory this account can write"
    exit "$EXIT_FAILURE"
  }

  stamp="$(date +%Y%m%d-%H%M%S)"
  file="$SNAP_DIR/$TAG-$stamp.txt"

  # umask inside the subshell: the record names the machine, its firmware and
  # its LUKS UUID, and 600 keeps that out of reach of the rest of the box.
  if ! (
    umask 077
    current_snapshot_text >"$file"
  ); then
    die "Could not write $file"
  fi
  chmod 600 "$file" 2>/dev/null || true

  if verbose_enough; then
    echo ""
    printf '%s\n' "${C_G}==================================================${C_0}"
    printf '%s\n' "${C_G}  Snapshot taken${C_0}"
    printf '%s\n' "${C_G}==================================================${C_0}"
    echo ""
    echo "  $file"
    echo ""
    echo "  Compare the machine against it later with:"
    echo "    ./tpm-pcr.sh compare $TAG"
    echo ""
  else
    ok "Snapshot written: $file"
  fi
}

do_list() {
  local f count=0 tag date bios machine

  if [[ ! -d "$SNAP_DIR" ]]; then
    err "No snapshot directory: $SNAP_DIR"
    err "  Take one with: ./tpm-pcr.sh snapshot --tag pre-flash"
    exit "$EXIT_FAILURE"
  fi

  echo ""
  printf '%s\n' "${C_B}=== Snapshots in $SNAP_DIR ===${C_0}"
  echo ""
  printf "  %-12s %-17s %-14s %s\n" "Tag" "Date" "BIOS" "File"
  for f in "$SNAP_DIR"/*.txt; do
    if [[ ! -f "$f" ]]; then
      continue
    fi
    count=$((count + 1))
    if ! grep -q '^pcr\.' "$f" 2>/dev/null; then
      printf "  %-12s %-17s %-14s %s\n" "?" "?" "?" "$(basename "$f") (truncated)"
      continue
    fi
    tag="$(snap_field "$f" tag)"
    date="$(snap_field "$f" date)"
    bios="$(snap_field "$f" bios_version)"
    machine="$(snap_field "$f" machine)"
    printf "  %-12s %-17s %-14s %s\n" \
      "${tag:0:12}" "${date:0:10} ${date:11:5}" "${bios:0:14}" "$(basename "$f")"
    if [[ "$machine" != "unknown" ]]; then
      printf "  %-12s %s\n" "" "machine $machine"
    fi
  done
  echo ""
  if [[ $count -eq 0 ]]; then
    echo "  Nothing stored yet."
    echo "  Take one with: ./tpm-pcr.sh snapshot --tag pre-flash"
  else
    echo "  $count snapshot(s). Compare two of them with:"
    echo "    ./tpm-pcr.sh compare <tag> <tag>"
  fi
  echo ""
}

do_compare() {
  local a b n va vb va_bios vb_bios k x y
  local -a missing=()

  CHANGED=()
  POLICY_CHANGED=()

  if [[ ${#ARGS[@]} -lt 1 ]]; then
    err "compare needs at least one snapshot"
    err "  ./tpm-pcr.sh compare pre-flash            that tag against now"
    err "  ./tpm-pcr.sh compare pre-flash post-flash two stored snapshots"
    exit "$EXIT_USAGE"
  fi

  a="$(resolve_snapshot "${ARGS[0]}")" || exit "$EXIT_FAILURE"
  b="$(resolve_snapshot "${ARGS[1]:-current}")" || exit "$EXIT_FAILURE"
  check_snapshot "$a" || exit "$EXIT_FAILURE"
  check_snapshot "$b" || exit "$EXIT_FAILURE"

  if [[ "$a" == "current" || "$b" == "current" ]]; then
    check_tpm || exit "$EXIT_FAILURE"
    detect_source || exit "$EXIT_FAILURE"
  fi

  # Two machines cannot be compared: the values would differ for a reason
  # that has nothing to do with what happened to either of them.
  x="$(snap_field "$a" machine)"
  y="$(snap_field "$b" machine)"
  if [[ "$x" != "unknown" && "$y" != "unknown" && "$x" != "$y" ]]; then
    err "Those snapshots come from two machines: $x and $y"
    err "  Comparing them would answer nothing. Refusing."
    exit "$EXIT_FAILURE"
  fi
  x="$(snap_field "$a" luks_uuid)"
  y="$(snap_field "$b" luks_uuid)"
  if [[ "$x" != "unknown" && "$y" != "unknown" && "$x" != "$y" ]]; then
    err "Those snapshots hold two different LUKS UUID:"
    err "  $x"
    err "  $y"
    err "  That is another container, so another machine. Refusing."
    exit "$EXIT_FAILURE"
  fi

  for n in {0..23}; do
    va="$(snap_pcr "$a" "$n")" || va=""
    vb="$(snap_pcr "$b" "$n")" || vb=""
    if [[ -z "$va" || -z "$vb" ]]; then
      if [[ -n "$va$vb" ]]; then
        missing+=("$n")
      fi
      continue
    fi
    if [[ "$va" != "$vb" ]]; then
      CHANGED+=("$n")
      if in_policy "$n"; then
        POLICY_CHANGED+=("$n")
      fi
    fi
  done

  if [[ "$JSON" == "true" ]]; then
    compare_json "$a" "$b" || exit "$EXIT_FAILURE"
    return 0
  fi

  echo ""
  printf '%s\n' "${C_B}=== Compared ===${C_0}"
  echo ""
  printf "  %-4s %s\n" "A:" "$a"
  printf "  %-4s %s\n" "B:" "$b"
  printf "  %-4s %s\n" "" "$(snap_field "$a" date) -> $(snap_field "$b" date)"

  echo ""
  for k in bios_version bios_date kernel secureboot; do
    x="$(snap_field "$a" "$k")"
    y="$(snap_field "$b" "$k")"
    if [[ "$x" != "$y" ]]; then
      printf "  %-14s %s -> %s\n" "$k" "$x" "$y"
    fi
  done

  echo ""
  if [[ ${#CHANGED[@]} -eq 0 ]]; then
    echo "  No register moved."
  else
    echo "  Registers that moved: ${CHANGED[*]}"
    echo ""
    for n in "${CHANGED[@]}"; do
      if in_policy "$n"; then
        printf "  PCR %-2s %-7s %s\n" "$n" "sealed" "$(pcr_role "$n")"
      else
        printf "  PCR %-2s %-7s %s\n" "$n" "-" "$(pcr_role "$n")"
      fi
      printf "    A  %s\n" "$(snap_pcr "$a" "$n")"
      printf "    B  %s\n" "$(snap_pcr "$b" "$n")"
    done
  fi

  if [[ ${#missing[@]} -gt 0 ]]; then
    echo ""
    echo "  Recorded on one side only, not compared: ${missing[*]}"
  fi

  echo ""
  printf '%s\n' "${C_B}=== Verdict ===${C_0}"
  echo ""
  va_bios="$(snap_field "$a" bios_version)"
  vb_bios="$(snap_field "$b" bios_version)"

  if [[ ${#POLICY_CHANGED[@]} -gt 0 ]]; then
    echo "  Yes, this explains it."
    echo ""
    echo "  PCR ${POLICY_CHANGED[*]} moved, and the policy $POLICY_IDS seals that."
    echo "  The TPM will not release what it sealed against the old values, and"
    echo "  what it sealed cannot be recovered. A new secret has to be sealed"
    echo "  against the firmware as it stands now."
    if [[ "$va_bios" != "$vb_bios" ]]; then
      echo ""
      echo "  The BIOS went from $va_bios to $vb_bios, which is the direct cause."
    fi
    echo ""
    echo "    ./tpm-reseal.sh reseal"
  elif [[ ${#CHANGED[@]} -gt 0 ]]; then
    echo "  No."
    echo ""
    echo "  PCR ${CHANGED[*]} moved, but the policy $POLICY_IDS does not look there."
    echo "  If clevis still fails, the cause is elsewhere: the TPM locked out"
    echo "  after too many attempts, a token removed or damaged, or the wrong"
    echo "  keyslot. Resealing would hide the real cause, not fix it."
    echo ""
    echo "    ./luks-check.sh tpm"
  else
    echo "  Nothing moved at all. This is not a policy invalidation."
    echo "  If the machine still asks for its passphrase, suspect the TPM"
    echo "  dictionary lockout, or a token that is no longer there."
    echo ""
    echo "    ./luks-check.sh tpm"
  fi

  for n in "${CHANGED[@]}"; do
    if [[ "$n" == "4" ]]; then
      echo ""
      echo "  PCR 4 moved. It measures the boot file, and bootx64.efi is"
      echo "  rewritten at every kernel build. It is not in the policy, on"
      echo "  purpose: binding it would break unlocking after every update."
    fi
    if [[ "$n" == "7" ]]; then
      echo ""
      echo "  PCR 7 moved: the Secure Boot state changed. Put it back where"
      echo "  it was. Turning Secure Boot off to work around a PCR change is"
      echo "  the one thing not to do."
    fi
  done
  echo ""
}

compare_json() {
  local a="$1" b="$2" verdict="unchanged"

  if [[ ${#POLICY_CHANGED[@]} -gt 0 ]]; then
    verdict="policy-broken"
  elif [[ ${#CHANGED[@]} -gt 0 ]]; then
    verdict="outside-policy"
  fi

  printf '{"a":"%s","b":"%s","policy_ids":"%s",' "$a" "$b" "$POLICY_IDS"
  printf '"changed":[%s],"policy_changed":[%s],"verdict":"%s"}\n' \
    "$(join_list ${CHANGED[@]+"${CHANGED[@]}"})" \
    "$(join_list ${POLICY_CHANGED[@]+"${POLICY_CHANGED[@]}"})" \
    "$verdict"
  return 0
}

do_explain() {
  local n v mover
  local -a wanted=()

  if [[ ${#ARGS[@]} -gt 0 ]]; then
    for n in "${ARGS[@]}"; do
      [[ "$n" =~ ^[0-9]+$ ]] && [[ "$n" -le 23 ]] || {
        err "Not a PCR number: $n (0 to 23)"
        exit "$EXIT_USAGE"
      }
      wanted+=("$n")
    done
  else
    for n in {0..23}; do
      wanted+=("$n")
    done
  fi

  # explain still works with no TPM: what a register measures does not depend
  # on the machine. Only the Value and State lines do.
  if check_tpm 2>/dev/null; then
    detect_source >/dev/null 2>&1 || true
  fi

  for n in "${wanted[@]}"; do
    v="$(read_pcr "$n")" || v=""
    echo ""
    printf '%s\n' "${C_B}=== PCR $n ===${C_0}"
    printf "  %-10s %s\n" "Measures:" "$(pcr_role "$n")"
    if in_policy "$n"; then
      printf "  %-10s %s\n" "Policy:" "sealed, the policy is $POLICY_IDS"
    else
      printf "  %-10s %s\n" "Policy:" "not sealed by $POLICY_IDS"
    fi
    if [[ -z "$v" ]]; then
      printf "  %-10s %s\n" "Value:" "not readable here"
    else
      printf "  %-10s %s\n" "Value:" "$v"
      if [[ "$v" =~ ^0+$ ]]; then
        printf "  %-10s %s\n" "State:" "still at its reset value, never extended"
      elif [[ "$v" =~ ^F+$ ]]; then
        printf "  %-10s %s\n" "State:" "all ones: not implemented, or locality locked"
      elif is_empty_pcr "$v"; then
        printf "  %-10s %s\n" "State:" "nothing but EV_SEPARATOR was measured"
        if in_policy "$n"; then
          echo "             This register is in the policy and carries nothing:"
          echo "             it adds no entropy to the sealing."
        fi
      else
        printf "  %-10s %s\n" "State:" "extended, carries a measurement"
      fi
    fi
    mover="$(pcr_mover "$n")"
    if [[ -n "$mover" ]]; then
      printf "  %-10s %s\n" "Changes:" "$mover"
    fi
  done

  echo ""
  printf '%s\n' "${C_B}=== The policy of this project ===${C_0}"
  echo ""
  policy_coverage_note
  echo ""
  if [[ "$PCR_SOURCE" != "none" ]]; then
    policy_entropy_note
    echo ""
  fi
  echo "  The event log says which measurement extended a register, not just"
  echo "  that its value changed:"
  echo "    $EVENT_LOG"
  echo "    $(event_log_state)"
  echo ""
  echo "  Reading it takes tpm2_eventlog, from app-crypt/tpm2-tools. This"
  echo "  script does not parse it: the format is binary TCG, and a bash"
  echo "  parser for it would be a second source of truth to keep correct."
  echo ""
}

do_policy() {
  local dev bound id_list

  echo ""
  printf '%s\n' "${C_B}=== Clevis policy ===${C_0}"
  echo ""
  printf "  %-10s %s\n" "Expected:" "$PCR_POLICY"

  if ! command -v clevis >/dev/null 2>&1; then
    echo ""
    warn "clevis is not installed here, cannot read what is really bound"
    warn "  clevis lives in the installed system, not on the LiveCD"
    warn "  Run this on the machine itself, or from inside its chroot"
    echo ""
    echo "  What holds regardless, from the expected policy:"
    echo ""
    policy_coverage_note
  else
    : >"$ERR_LOG"
    chmod 600 "$ERR_LOG" 2>/dev/null || true

    dev="$(resolve_device)" || exit "$EXIT_FAILURE"
    printf "  %-10s %s\n" "Container:" "$dev"
    bound="$(clevis luks list -d "$dev" 2>>"$ERR_LOG" || true)"
    echo ""

    if [[ -z "$bound" ]]; then
      printf "  %-10s %s\n" "Bound:" "${C_Y}nothing${C_0}"
      echo ""
      echo "  No token on $dev: the machine asks for its passphrase at every"
      echo "  boot. ./tpm-reseal.sh puts the binding back."
      sed 's/^/    /' "$ERR_LOG" >&2 2>/dev/null || true
    else
      printf "  %-10s %s\n" "Bound:" "${C_G}present${C_0}"
      printf '%s\n' "$bound" | sed 's/^/    /'
      echo ""
      if id_list="$(bound_policy_ids "$bound")"; then
        if [[ "$id_list" == "$POLICY_IDS" ]]; then
          printf "  %-10s %s\n" "Bound to:" "$id_list, as expected"
        else
          printf "  %-10s %s\n" "Bound to:" "$id_list"
          warn "The bound list is $id_list, the project expects $POLICY_IDS"
          warn "  This machine was sealed with another list. What follows"
          warn "  is read against the list it really has."
          POLICY_IDS="$id_list"
        fi
      else
        warn "No pcr_ids in that token: it seals against no register at all"
      fi
      echo ""
      policy_coverage_note
    fi
  fi

  if check_tpm 2>/dev/null && detect_source >/dev/null 2>&1; then
    echo ""
    policy_entropy_note
  fi
  echo ""
}

# check_root guards snapshot alone. The registers are world-readable in sysfs,
# and a diagnostic that demands root is a diagnostic nobody runs from the shell
# they already have. snapshot writes under /var/lib/gentoo-install, which does
# need it.
main() {
  parse_arguments "$@"

  case "$SUBCOMMAND" in
    show | values)
      do_show
      ;;
    snapshot)
      check_root
      do_snapshot
      ;;
    list)
      do_list
      ;;
    compare | diff)
      do_compare
      ;;
    explain)
      do_explain
      ;;
    policy)
      do_policy
      ;;
    *)
      err "Unknown command: $SUBCOMMAND"
      err "Use --help for usage information"
      exit "$EXIT_USAGE"
      ;;
  esac
}

main "$@"
