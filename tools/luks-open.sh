#!/usr/bin/env bash
#
# gentoo-install — unlock an encrypted machine from a LiveCD and mount its tree
# ----------------------------------------------------------------------------
# Unlocks the LUKS container, activates the volume group and mounts the system
# in the order the layout requires, so that rescue-chroot.sh can enter it. It
# writes nothing to the machine and adds no keyslot; 'close' undoes only what
# this script itself opened and mounted, which is recorded under /run. It
# carries its own helpers and sources no library: a rescue tool that cannot be
# copied alone onto a USB stick is useless exactly when it is needed.
#
# Usage:  ./luks-open.sh <command> [options]   (--help for the list)
#
set -euo pipefail

readonly EXIT_SUCCESS=0
readonly EXIT_FAILURE=1
readonly EXIT_USAGE=2

# Configuration
SUBCOMMAND="open"
FORCE="false"
DEVICE=""            # --device : bypasses detection
KEY_PATH=""          # --key    : GPG-wrapped key, otherwise taken from the ESP
TARGET="/mnt/rescue" # --target : where the tree is mounted
MAPPER_NAME="gentoo" # --name   : device-mapper name, dracut expects 'gentoo'
VG_NAME="vg1"        # --vg     : volume group inside the container
LUKS_DIRECT="false"  # --luks-pass : the passphrase is a LUKS one, no GPG step
PASSPHRASE=""        # never exposed on the command line internally
PASSPHRASE_SOURCE="none"
PASSPHRASE_STDIN="false"
MAX_TRIES=3

EFI_PROBE="/tmp/gentoo-install-rescue-efi"
ERR_LOG="/tmp/gentoo-install-luks-open.log"

# /run is a tmpfs, so this copy never reaches a block of any disk. /tmp is a
# directory of the root filesystem on a Gentoo OpenRC system, where rm -f frees
# the inode and leaves the content readable in the free space.
RECOVERED_KEY="/run/gentoo-install-rescue-key.gpg"

# Cleanup state, used by the failure trap
OPENED_CONTAINER=""

# Records what this run opened and what it mounted, one per line:
#   line 1  the device-mapper name, if we opened the container
#   line 2  the mountpoint, if we mounted the tree there
# What is not recorded belongs to someone else, an install run or a tree
# mounted by hand, and close never takes it down. /run is a tmpfs, so the
# record lasts exactly as long as the rescue session it describes.
OWN_STAMP="/run/gentoo-install-luks-open.own"
OWN_MAPPER=""
OWN_TARGET=""

load_ownership() {
  OWN_MAPPER=""
  OWN_TARGET=""
  [[ -s "$OWN_STAMP" ]] || return 0
  OWN_MAPPER="$(sed -n '1p' "$OWN_STAMP" 2>/dev/null)"
  OWN_TARGET="$(sed -n '2p' "$OWN_STAMP" 2>/dev/null)"
  return 0
}

save_ownership() {
  printf '%s\n%s\n' "$OWN_MAPPER" "$OWN_TARGET" >"$OWN_STAMP" 2>/dev/null || true
  chmod 600 "$OWN_STAMP" 2>/dev/null || true
}

QUIET="${GI_QUIET:-false}"

# Colours only when the stream that carries them is a terminal, and never when
# NO_COLOR is set. That stream is stderr: every coloured byte the helpers write
# goes there, so that `| tee` keeps its colour.
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
Usage: ./luks-open.sh [COMMAND] [OPTIONS]

Opens an encrypted machine from a LiveCD and mounts its tree, to repair it.

WHEN TO USE IT:
    The machine no longer boots, or boots into something unusable, and you need
    to get at its filesystem. Boot the LiveCD, run this, then rescue-chroot.sh
    to work inside the system.

    It needs the passphrase and the key file. The key file normally sits on the
    machine's own EFI partition, and is picked up from there without being
    asked for.

WHAT IT DOES:
    Unlocks the container, activates the volume group, mounts the tree under
    /mnt/rescue in the order the layout requires. It writes nothing to the
    machine and adds no keyslot.

COMMANDS:
    open                Unlock and mount (default)
    close               Undo what open did: unmount, deactivate, close
    status              What is open and mounted, change nothing

OPTIONS:
    -h, --help          Show this help
    -q, --quiet         Essential output only
        --device DEV    LUKS container (nvme0n1p2 or /dev/nvme0n1p2)
        --target DIR    Where to mount the tree (default: /mnt/rescue)
        --name NAME     Device-mapper name (default: gentoo)
        --vg NAME       Volume group inside the container (default: vg1)
        --key FILE      GPG-wrapped key. Recovered from the EFI partition when
                        omitted, which is where the installer leaves it
        --luks-pass     The passphrase is a LUKS passphrase, used directly.
                        For a container whose keyslot was added by hand
        --force         Skip every confirmation (non-interactive)

PASSPHRASE:
        (nothing)               Asked, not echoed, q cancels
        GI_PASSPHRASE           Environment variable
        --passphrase-file FILE  First line of a file, keep it mode 600
        --passphrase-stdin      Read from stdin
        --passphrase PASS       Literal value, visible in `ps`

WHERE THE KEY COMES FROM:
    The EFI partition of the machine being rescued, which is the first vfat
    partition of the disk carrying the container. It is mounted read-only, the
    key is copied to /run, a tmpfs, and it is unmounted again. The machine's
    own partition is never written to.

WHAT CLOSE UNDOES:
    Only what this script did. An open run records the mapper it created and
    the mountpoint it filled, under /run; close reads that record back. A tree
    mounted by an install run or by hand is named and kept, and a container
    opened by someone else is left open. A volume group carrying the running
    root is refused outright: this tool closes a machine opened from a LiveCD,
    not the one it runs on.

EXAMPLES:
    ./luks-open.sh
        Finds the container, asks for the passphrase, mounts on /mnt/rescue.

    ./luks-open.sh --device nvme0n1p2 --target /mnt/gentoo
        Names both explicitly.

    ./luks-open.sh status
        What is already open. Changes nothing.

    ./luks-open.sh close
        Undoes everything, in the right order.

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
      --luks-pass)
        LUKS_DIRECT="true"
        shift
        ;;
      --device)
        [[ $# -ge 2 ]] || die "--device requires a value"
        DEVICE="$2"
        shift 2
        ;;
      --target)
        [[ $# -ge 2 ]] || die "--target requires a value"
        TARGET="${2%/}"
        shift 2
        ;;
      --name)
        [[ $# -ge 2 ]] || die "--name requires a value"
        MAPPER_NAME="$2"
        shift 2
        ;;
      --vg)
        [[ $# -ge 2 ]] || die "--vg requires a value"
        VG_NAME="$2"
        shift 2
        ;;
      --key)
        [[ $# -ge 2 ]] || die "--key requires a value"
        KEY_PATH="$2"
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
}

check_root() {
  if [[ $EUID -ne 0 ]]; then
    err "Need root access. Run: sudo -i"
    exit "$EXIT_FAILURE"
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
# Devices
################################################################################

normalize_device() {
  local input="${1:-}"
  input="${input%/}"
  input="${input#/dev/}"
  echo "$input"
}

is_luks() { cryptsetup isLuks "$1" 2>/dev/null; }

open_mapper_of() {
  # Name of the open mapper backed by this container, empty if none.
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
  return 1
}

detect_container() {
  # Internal LUKS partitions only. A removable disk may hold a LUKS container
  # of its own, and rescuing a machine is precisely when opening the wrong one
  # would waste the most time.
  local part dev disk tran found=()

  for part in $(lsblk -lno NAME,TYPE 2>/dev/null | awk '$2 == "part" { print $1 }'); do
    dev="/dev/$part"
    is_luks "$dev" || continue
    disk="$(lsblk -dno PKNAME "$dev" 2>/dev/null | head -n 1 | tr -d ' ')"
    tran="$(lsblk -dno TRAN "/dev/${disk:-$part}" 2>/dev/null | tr -d ' ')"
    if [[ "$tran" == "usb" ]]; then
      skip "  $dev: skipped, USB transport"
      continue
    fi
    log "  $dev: LUKS on an internal disk"
    found+=("$dev")
  done

  if [[ ${#found[@]} -eq 1 ]]; then
    echo "${found[0]}"
    return 0
  fi
  if [[ ${#found[@]} -gt 1 ]]; then
    warn "Several internal LUKS containers: ${found[*]}"
    warn "Name the right one with --device"
  else
    warn "No internal LUKS container found"
  fi
  return 1
}

resolve_device() {
  local dev

  if [[ -n "$DEVICE" ]]; then
    dev="/dev/$(normalize_device "$DEVICE")"
    [[ -b "$dev" ]] || {
      err "Device not found: $dev"
      return 1
    }
    is_luks "$dev" || {
      err "$dev is not a LUKS container"
      return 1
    }
    echo "$dev"
    return 0
  fi

  log "Looking for the machine's container"
  detect_container
}

efi_partition_of() {
  # The vfat partition of the disk carrying the container, which is the only
  # place the installer leaves the key.
  local dev="$1" disk part
  disk="$(lsblk -dno PKNAME "$dev" 2>/dev/null | head -n 1 | tr -d ' ')"
  [[ -n "$disk" ]] || return 1

  for part in $(lsblk -lno NAME,TYPE "/dev/$disk" 2>/dev/null | awk '$2 == "part" { print $1 }'); do
    if [[ "$(blkid -s TYPE -o value "/dev/$part" 2>/dev/null)" == "vfat" ]]; then
      echo "/dev/$part"
      return 0
    fi
  done
  return 1
}

################################################################################
# Key material
################################################################################

recover_key_from_efi() {
  # Read-only mount, copy out, unmount. The machine's own partition is never
  # written to: it may be the only intact thing left on it.
  local dev="$1" efi

  if ! efi="$(efi_partition_of "$dev")"; then
    err "No vfat partition on the disk carrying $dev"
    return 1
  fi
  log "EFI partition: $efi"

  mkdir -p "$EFI_PROBE"
  if ! mount -o ro "$efi" "$EFI_PROBE" 2>>"$ERR_LOG"; then
    err "Cannot mount $efi read-only"
    rmdir "$EFI_PROBE" 2>/dev/null || true
    return 1
  fi

  local found_key="" candidate
  for candidate in luks-key.gpg luks-master-key.gpg; do
    if [[ -s "$EFI_PROBE/$candidate" ]]; then
      install -m 600 "$EFI_PROBE/$candidate" "$RECOVERED_KEY"
      found_key="$candidate"
      break
    fi
  done

  umount "$EFI_PROBE" 2>/dev/null || umount -l "$EFI_PROBE" 2>/dev/null || true
  rmdir "$EFI_PROBE" 2>/dev/null || true

  if [[ -z "$found_key" ]]; then
    err "No key file on $efi"
    err "  Looked for: luks-key.gpg, luks-master-key.gpg"
    err "  Restore one from wherever it was backed up, then pass --key FILE"
    return 1
  fi

  ok "Key recovered from the EFI partition ($found_key)"
  echo "$RECOVERED_KEY"
  return 0
}

resolve_key() {
  local dev="$1"
  if [[ -n "$KEY_PATH" ]]; then
    [[ -f "$KEY_PATH" ]] || {
      err "Key not found: $KEY_PATH"
      return 1
    }
    echo "$KEY_PATH"
    return 0
  fi
  recover_key_from_efi "$dev"
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
    echo "" >&2
    echo "    GI_PASSPHRASE=\"\$PW\" ./luks-open.sh --force" >&2
    echo "    ./luks-open.sh --force --passphrase-file FILE" >&2
    echo "" >&2
    return 1
  fi

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
# Unlock
################################################################################

cleanup_on_failure() {
  # Never leave a half-open container behind
  if [[ -n "$OPENED_CONTAINER" ]]; then
    warn "Cleaning up: closing $OPENED_CONTAINER"
    # Only the tree this run mounted. A target that was already mounted
    # when open started belongs to someone else, failure or not.
    [[ "$OWN_TARGET" == "$TARGET" ]] && umount -R "$TARGET" 2>/dev/null || true
    vgchange -an "$VG_NAME" >/dev/null 2>&1 || true
    cryptsetup luksClose "$OPENED_CONTAINER" 2>/dev/null || true
    OPENED_CONTAINER=""
    OWN_MAPPER=""
    OWN_TARGET=""
    rm -f "$OWN_STAMP" 2>/dev/null || true
  fi
}

open_container() {
  local dev="$1" key="${2:-}"
  local status=()

  : >"$ERR_LOG"
  chmod 600 "$ERR_LOG" 2>/dev/null || true

  if [[ "$LUKS_DIRECT" == "true" ]]; then
    log "Opening with the passphrase used directly as a LUKS passphrase"
    # Through stdin, never through argv. Not a here-string: bash implements
    # <<< as a pipe, and cryptsetup cannot use a pipe as a named key file
    # (/dev/fd/3) -- it fails with "keyfile max size exceeded". A here-string
    # also appends a newline, which would land in the key material and match
    # no keyslot. printf '%s' emits none.
    # --disable-external-tokens: a LUKS2 token is tried before the material
    # supplied here, so a working TPM opens the container whatever was
    # typed. This branch exists to answer "does this passphrase open it",
    # and that answer has to come from the passphrase.
    set +e
    printf '%s' "$PASSPHRASE" \
      | cryptsetup luksOpen --disable-external-tokens "$dev" "$MAPPER_NAME" \
        --key-file - 2>>"$ERR_LOG"
    status=("${PIPESTATUS[1]}")
    set -e
    if [[ "${status[0]}" -ne 0 ]]; then
      err "cryptsetup refused the passphrase"
      sed 's/^/    /' "$ERR_LOG" >&2 2>/dev/null || true
      return 1
    fi
    OPENED_CONTAINER="$MAPPER_NAME"
    ok "Container open: /dev/mapper/$MAPPER_NAME"
    return 0
  fi

  log "Opening with the GPG-wrapped key"
  if [[ -z "${GPG_TTY:-}" ]]; then
    GPG_TTY="$(tty 2>/dev/null || echo /dev/tty)"
    export GPG_TTY
  fi

  # The decrypted key goes straight into cryptsetup through the pipe, and
  # never touches the disk.
  # --disable-external-tokens for the same reason as the branch above: the
  # failure message below reads "it probably belongs to another machine", and
  # a TPM answering in the key's place turns that verdict into a guess. No
  # opening path is lost: this tool always demands a key or a passphrase.
  set +e
  gpg --quiet --batch --pinentry-mode loopback --passphrase-fd 3 \
    --decrypt "$key" 3<<<"$PASSPHRASE" 2>>"$ERR_LOG" \
    | cryptsetup luksOpen --disable-external-tokens "$dev" "$MAPPER_NAME" \
      --key-file - 2>>"$ERR_LOG"
  status=("${PIPESTATUS[@]}")
  set -e

  # Two distinct failures, worth telling apart when a machine is down
  if [[ "${status[0]}" -ne 0 ]]; then
    err "GPG could not decrypt $key"
    err "  Wrong passphrase, or the key file is damaged"
    sed 's/^/    /' "$ERR_LOG" >&2 2>/dev/null || true
    return 1
  fi
  if [[ "${status[1]}" -ne 0 ]]; then
    err "cryptsetup refused the key on $dev"
    err "  The key decrypted fine but matches no keyslot here"
    err "  It probably belongs to another machine"
    sed 's/^/    /' "$ERR_LOG" >&2 2>/dev/null || true
    return 1
  fi

  OPENED_CONTAINER="$MAPPER_NAME"
  ok "Container open: /dev/mapper/$MAPPER_NAME"
  return 0
}

################################################################################
# Mounting
################################################################################

mount_if_needed() {
  # mount on an already mounted point does not fail: it stacks, and the stack
  # hides every submount underneath.
  local source="$1" target="$2"

  if mountpoint -q "$target" 2>/dev/null; then
    skip "  $target already mounted"
    return 0
  fi
  [[ -b "$source" ]] || {
    skip "  $source does not exist, skipped"
    return 0
  }

  mkdir -p "$target"
  log "  $target <- $source"
  mount "$source" "$target" 2>>"$ERR_LOG" || {
    err "  mount failed: $source"
    return 1
  }
}

mount_tree() {
  local dev="$1"

  log "Activating the volume group $VG_NAME"
  vgchange -ay "$VG_NAME" >/dev/null 2>&1 || true
  command -v udevadm >/dev/null 2>&1 && udevadm settle --timeout=10 2>/dev/null || true

  if ! vgs "$VG_NAME" >/dev/null 2>&1; then
    err "Volume group $VG_NAME not found inside the container"
    err "  Name the right one with --vg, 'vgs' lists what is there"
    return 1
  fi

  mkdir -p "$TARGET"
  mount_if_needed "/dev/$VG_NAME/root" "$TARGET" || return 1

  # Order matters: usr and var before their own submounts, and boot before
  # boot/efi. Volumes the layout does not carry are skipped in silence.
  mkdir -p "$TARGET"/{home,boot,boot/efi,usr,var,opt}
  mount_if_needed "/dev/$VG_NAME/home" "$TARGET/home"
  mount_if_needed "/dev/$VG_NAME/apps" "$TARGET/apps"
  mount_if_needed "/dev/$VG_NAME/usr" "$TARGET/usr"
  mkdir -p "$TARGET/usr/portage"
  mount_if_needed "/dev/$VG_NAME/var" "$TARGET/var"
  mkdir -p "$TARGET/var/log"
  mount_if_needed "/dev/$VG_NAME/portage" "$TARGET/usr/portage"
  mount_if_needed "/dev/$VG_NAME/log" "$TARGET/var/log"
  mount_if_needed "/dev/$VG_NAME/opt" "$TARGET/opt"

  local efi
  if efi="$(efi_partition_of "$dev")"; then
    mount_if_needed "$efi" "$TARGET/boot/efi"
  else
    warn "  no EFI partition found, $TARGET/boot/efi left empty"
  fi

  ok "Tree mounted on $TARGET"
  return 0
}

################################################################################
# Commands
################################################################################

do_open() {
  local dev key existing

  dev="$(resolve_device)" || exit "$EXIT_FAILURE"
  ok "Container: $dev ($(lsblk -dno SIZE "$dev" 2>/dev/null | tr -d ' '))"

  if existing="$(open_mapper_of "$dev")"; then
    skip "Already open as /dev/mapper/$existing, reusing it"
    MAPPER_NAME="$existing"
  else
    if [[ -b "/dev/mapper/$MAPPER_NAME" ]]; then
      err "Mapper name already taken by another device: $MAPPER_NAME"
      err "Use --name, or close it first"
      exit "$EXIT_FAILURE"
    fi

    key=""
    if [[ "$LUKS_DIRECT" != "true" ]]; then
      key="$(resolve_key "$dev")" || exit "$EXIT_FAILURE"
    fi

    resolve_passphrase || exit "$EXIT_FAILURE"

    trap cleanup_on_failure ERR INT TERM
    open_container "$dev" "$key" || exit "$EXIT_FAILURE"

    # From here the mapper is ours. The stamp is what a later run of close
    # reads to know that, since the two commands are two processes.
    OWN_MAPPER="$MAPPER_NAME"
    save_ownership
  fi

  # Recorded before the mounting starts: a tree already mounted here is not
  # ours, and a mount that fails halfway still has to be undone.
  if ! mountpoint -q "$TARGET" 2>/dev/null; then
    OWN_TARGET="$TARGET"
    save_ownership
  fi

  if ! mount_tree "$dev"; then
    cleanup_on_failure
    exit "$EXIT_FAILURE"
  fi

  trap - ERR INT TERM
  OPENED_CONTAINER=""

  # The recovered key is a copy of a file that is not a secret on its own,
  # but it has no reason to outlive the rescue either.
  [[ -f "$RECOVERED_KEY" ]] && log "Recovered key kept at $RECOVERED_KEY for the session"

  if verbose_enough; then
    echo ""
    echo "${C_G}==================================================${C_0}"
    echo "${C_G}  Machine open${C_0}"
    echo "${C_G}==================================================${C_0}"
    echo ""
    echo "  Container : /dev/mapper/$MAPPER_NAME"
    echo "  Tree      : $TARGET"
    echo ""
    findmnt -rno TARGET,SOURCE "$TARGET" --submounts 2>/dev/null | sed 's/^/  /'
    echo ""
    echo "  To work inside the system:"
    echo "      ./rescue-chroot.sh --target $TARGET"
    echo ""
    echo "  When done:"
    echo "      ./luks-open.sh close --target $TARGET"
    echo ""
  else
    ok "Open on $TARGET, container /dev/mapper/$MAPPER_NAME"
  fi
}

do_close() {
  local acted=false left=0 mounted="false" own_tree="false" own_mapper="false" source=""

  # A group that carries the running root is never this tool's to deactivate.
  # vgchange -an there takes down every logical volume that happens to be
  # idle at that instant, on a machine that is working.
  if [[ "$(findmnt -no SOURCE / 2>/dev/null || true)" == "/dev/mapper/${VG_NAME}-"* ]]; then
    err "$VG_NAME carries the running root: refusing to deactivate it"
    err "  This tool closes a machine opened from a LiveCD, not the one"
    err "  it runs on. Name the right group with --vg"
    return 1
  fi

  mountpoint -q "$TARGET" 2>/dev/null && mounted="true"
  [[ "$OWN_TARGET" == "$TARGET" ]] && own_tree="true"
  [[ "$OWN_MAPPER" == "$MAPPER_NAME" ]] && own_mapper="true"

  # Named before anything moves. umount -R takes the submounts with it, and
  # only the operator knows whether an install run is standing on one of them.
  if [[ "$mounted" == "true" ]]; then
    source="$(findmnt -no SOURCE "$TARGET" 2>/dev/null || true)"
    echo "" >&2
    warn "About to unmount $TARGET and everything under it:"
    findmnt -rno TARGET,SOURCE "$TARGET" --submounts 2>/dev/null | sed 's/^/    /' >&2
    echo "" >&2
  fi

  # The record written by open is the only claim of ownership there is. The
  # defaults of this script, mapper 'gentoo' and group 'vg1', are the names a
  # machine installed by this project uses, so acting without that record is
  # acting blind.
  if [[ "$mounted" == "true" && "$own_tree" != "true" ]]; then
    warn "$TARGET was not mounted by this script"
    warn "  Mounted from: ${source:-unknown}"
    warn "  An install in progress, or a tree mounted by hand, is the"
    warn "  usual reason. Unmounting cuts whatever is working in there."
    if ! confirm "Unmount it anyway?" "N"; then
      log "Cancelled, nothing changed"
      return 0
    fi
  fi

  if [[ "$mounted" == "true" ]]; then
    if umount -R "$TARGET" 2>/dev/null; then
      ok "Unmounted $TARGET"
      acted=true
    else
      warn "$TARGET is busy, retrying lazily"
      if umount -Rl "$TARGET" 2>/dev/null; then
        acted=true
      else
        err "Failed to unmount $TARGET"
      fi
    fi
  else
    skip "$TARGET is not mounted"
  fi

  # The group lives inside the container. A container this script did not
  # open belongs to whoever did, and so does everything under it.
  if [[ "$own_mapper" != "true" ]]; then
    if [[ -b "/dev/mapper/$MAPPER_NAME" ]]; then
      warn "/dev/mapper/$MAPPER_NAME was not opened by this script, left open"
      warn "  $VG_NAME is left active for the same reason"
      warn "  Close it by hand if it is yours: cryptsetup luksClose $MAPPER_NAME"
    fi
    if [[ "$own_tree" == "true" ]]; then
      OWN_TARGET=""
      save_ownership
    fi
    rm -f "$RECOVERED_KEY"
    if [[ "$acted" == "true" ]]; then
      ok "Closed"
    else
      skip "Nothing to do"
    fi
    return 0
  fi

  if vgs "$VG_NAME" >/dev/null 2>&1; then
    log "Deactivating $VG_NAME"
    if vgchange -an "$VG_NAME" >/dev/null 2>&1; then
      acted=true
    else
      warn "vgchange -an failed"
    fi
  fi

  if [[ -b "/dev/mapper/$MAPPER_NAME" ]]; then
    log "Closing $MAPPER_NAME"
    if cryptsetup luksClose "$MAPPER_NAME" 2>/dev/null; then
      ok "Closed $MAPPER_NAME"
      acted=true
    else
      if dmsetup remove "$MAPPER_NAME" 2>/dev/null; then
        acted=true
      else
        err "Could not close $MAPPER_NAME"
      fi
    fi
  fi

  rm -f "$RECOVERED_KEY"

  # Reporting on the final state, not on what was attempted
  vgs "$VG_NAME" >/dev/null 2>&1 && {
    err "$VG_NAME still active"
    left=$((left + 1))
  }
  [[ -b "/dev/mapper/$MAPPER_NAME" ]] && {
    err "$MAPPER_NAME still open"
    left=$((left + 1))
  }

  if [[ $left -gt 0 ]]; then
    echo "" >&2
    err "Close incomplete: $left item(s) still held"
    echo "  What still holds a volume open:  dmsetup info -c -o name,open" >&2
    echo "  A shell whose cwd is under $TARGET is the usual culprit." >&2
    return 1
  fi

  OWN_MAPPER=""
  OWN_TARGET=""
  rm -f "$OWN_STAMP"

  if [[ "$acted" == "true" ]]; then
    ok "Closed"
  else
    skip "Nothing to do"
  fi
  return 0
}

do_status() {
  echo ""
  echo "${C_B}=== Rescue status ===${C_0}"
  echo ""

  local dev
  if dev="$(resolve_device 2>/dev/null)"; then
    printf "  %-22s %s\n" "Container:" "$dev"
    local m
    if m="$(open_mapper_of "$dev")"; then
      printf "  %-22s %s /dev/mapper/%s\n" "Open as:" "${C_G}yes${C_0}" "$m"
    else
      printf "  %-22s %s\n" "Open as:" "${C_Y}closed${C_0}"
    fi
  else
    printf "  %-22s %s\n" "Container:" "${C_Y}not found${C_0}"
  fi

  if [[ "$OWN_MAPPER" == "$MAPPER_NAME" || "$OWN_TARGET" == "$TARGET" ]]; then
    printf "  %-22s %s\n" "Opened here:" "${C_G}yes, close undoes it${C_0}"
  else
    printf "  %-22s %s\n" "Opened here:" "${C_Y}no, close leaves it alone${C_0}"
  fi

  if vgs "$VG_NAME" >/dev/null 2>&1; then
    printf "  %-22s %s %s volumes\n" "Volume group ($VG_NAME):" "${C_G}active${C_0}" \
      "$(lvs --noheadings -o lv_name "$VG_NAME" 2>/dev/null | wc -l)"
  else
    printf "  %-22s %s\n" "Volume group ($VG_NAME):" "${C_Y}inactive${C_0}"
  fi

  if mountpoint -q "$TARGET" 2>/dev/null; then
    printf "  %-22s %s\n" "Tree ($TARGET):" "${C_G}mounted${C_0}"
    echo ""
    findmnt -rno TARGET,SOURCE "$TARGET" --submounts 2>/dev/null | sed 's/^/    /'
  else
    printf "  %-22s %s\n" "Tree ($TARGET):" "${C_Y}not mounted${C_0}"
  fi
  echo ""
}

main() {
  parse_arguments "$@"
  load_ownership

  case "$SUBCOMMAND" in
    open)
      check_root
      do_open
      ;;
    close | umount)
      check_root
      do_close
      ;;
    status)
      check_root
      do_status
      ;;
    *)
      err "Unknown command: $SUBCOMMAND"
      err "       Use --help for usage information"
      exit "$EXIT_USAGE"
      ;;
  esac
}

main "$@"
