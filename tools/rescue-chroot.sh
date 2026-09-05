#!/usr/bin/env bash
#
# gentoo-install — enter a machine that is already open and mounted
# ----------------------------------------------------------------------------
# Binds /dev, /sys, /proc and /run into a tree that luks-open.sh has already
# mounted, then chroots into it to repair the system. It mounts no storage and
# assumes nothing about the layout: opening belongs to luks-open.sh. On the way
# out it names the processes still holding the tree, because those are what
# make a later teardown fail with nothing pointing at the cause. It carries its
# own helpers and sources no library, so it can be copied out on its own.
#
# Usage:  ./rescue-chroot.sh <command> [options]   (--help for the list)
#
set -euo pipefail

readonly EXIT_SUCCESS=0
readonly EXIT_FAILURE=1
readonly EXIT_USAGE=2

# Configuration
SUBCOMMAND="enter"
FORCE="false"
TARGET="/mnt/rescue"                 # --target : tree opened by luks-open.sh
WORKDIR="/tmp/gentoo-install-rescue" # where the init script lands, inside the target

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
Usage: ./rescue-chroot.sh [COMMAND] [OPTIONS]

Binds the virtual filesystems and enters a machine already opened.

WHEN TO USE IT:
    After luks-open.sh has unlocked a machine and mounted its tree. This puts
    you inside that system, with its own commands, to repair whatever broke:
    reinstall a package, fix a configuration, rebuild the kernel, reset a
    password.

    It is the rescue counterpart of the installer's own chroot step, which does
    the same during an install. This one makes no assumption about the layout
    and mounts no storage: opening belongs to luks-open.sh.

COMMANDS:
    enter               Bind and enter (default)
    prepare             Bind without entering
    exit                Undo the bindings, naming whatever still holds them
    status              What is mounted and bound, change nothing

OPTIONS:
    -h, --help          Show this help
    -q, --quiet         Essential output only
        --target DIR    Root of the opened system (default: /mnt/rescue)
        --force         Skip every confirmation (non-interactive)

ON THE WAY OUT:
    'exit' does more than unmount. A process started inside the chroot keeps
    its root there and holds the volumes open, which makes a later teardown
    fail with nothing pointing at the cause. gpg-agent is the usual one: gpg
    daemonises it whenever it asks for a passphrase at the console.

    So this command looks for holders with fuser, names them, and offers to
    stop them. It never kills anything without saying which process and why.

EXAMPLES:
    ./luks-open.sh                    # first, unlock and mount
    ./rescue-chroot.sh                # then, work inside

    ./rescue-chroot.sh exit           # bindings undone, holders named
    ./luks-open.sh close              # then close the storage

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
      --target)
        [[ $# -ge 2 ]] || die "--target requires a value"
        TARGET="${2%/}"
        shift 2
        ;;
      *)
        err "Unknown option: $1"
        err "       Use --help for usage information"
        exit "$EXIT_USAGE"
        ;;
    esac
  done
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
# Checks
################################################################################

verify_target() {
  if ! mountpoint -q "$TARGET" 2>/dev/null; then
    err "$TARGET is not mounted"
    err "  Open the machine first:  ./luks-open.sh --target $TARGET"
    return 1
  fi

  # About to exec a shell in there: its absence gives a cryptic chroot error
  if [[ ! -x "$TARGET/bin/bash" ]]; then
    err "No usable $TARGET/bin/bash: chroot would fail"
    err "  The root volume is mounted but the system looks incomplete"
    return 1
  fi

  if [[ ! -d "$TARGET/usr/bin" ]]; then
    err "$TARGET/usr looks empty: is the usr volume mounted?"
    err "  ./luks-open.sh status --target $TARGET"
    return 1
  fi

  if [[ -f "$TARGET/etc/gentoo-release" ]]; then
    log "System: $(cat "$TARGET/etc/gentoo-release" 2>/dev/null)"
  else
    warn "No /etc/gentoo-release: this may not be a Gentoo system"
  fi

  return 0
}

################################################################################
# Bindings
################################################################################

bind_if_needed() {
  local source="$1" target="$2" kind="${3:-rbind}"

  # mount on an already mounted point does not fail: it stacks, and the stack
  # hides every submount underneath
  if mountpoint -q "$target" 2>/dev/null; then
    skip "  $target already bound"
    return 0
  fi

  mkdir -p "$target"
  log "  $target <- $source"
  case "$kind" in
    rbind)
      mount --rbind "$source" "$target"
      mount --make-rslave "$target"
      ;;
    bind) mount --rbind "$source" "$target" ;;
    proc) mount -t proc /proc "$target" ;;
  esac
}

setup_bindings() {
  log "Binding the virtual filesystems"
  bind_if_needed /dev "$TARGET/dev" rbind
  bind_if_needed /sys "$TARGET/sys" rbind
  bind_if_needed /proc "$TARGET/proc" proc

  # /run matters more here than during an install: a rescue often runs
  # commands that expect a runtime directory, and the target's own /run is
  # empty on a system that never booted.
  bind_if_needed /run "$TARGET/run" rbind

  # Resolution, so emerge and friends can reach the network if there is one.
  # Saved and restored on the way out: the file belongs to the machine.
  if [[ -e /etc/resolv.conf ]]; then
    if [[ -e "$TARGET/etc/resolv.conf" && ! -e "$TARGET/etc/resolv.conf.rescue-orig" ]]; then
      cp -a "$TARGET/etc/resolv.conf" "$TARGET/etc/resolv.conf.rescue-orig"
    fi
    cp -L /etc/resolv.conf "$TARGET/etc/resolv.conf" 2>/dev/null || true
    log "  resolv.conf copied in, original kept as resolv.conf.rescue-orig"
  fi

  ok "Virtual filesystems ready"
}

write_init() {
  local init="$TARGET$WORKDIR/.rescue_init.sh"
  local rc="$TARGET$WORKDIR/.rescue_bashrc"

  mkdir -p "$TARGET$WORKDIR"

  # The prompt has to come from an rcfile, not from an export: exec /bin/bash
  # starts a fresh interactive shell, which rebuilds PS1 from its rc files and
  # discards whatever the parent exported.
  # Quoted heredoc: an unquoted one would eat the backslash in \$.
  cat >"$rc" <<'RC_EOF'
[[ -f /etc/bash/bashrc ]] && source /etc/bash/bashrc
[[ -f /etc/profile ]] && source /etc/profile
PS1='\[\033[1;33m\](rescue)\[\033[0m\] \w \$ '
RC_EOF

  cat >"$init" <<EOF
#!/bin/bash
# Entry point run by chroot(1). Not a tool: it prepares the environment, then
# replaces itself with the interactive shell.

if [[ -n "\${GI_RESCUE:-}" ]]; then
    echo "Already inside the rescue chroot. Type 'exit' to leave." >&2
    exit 1
fi
export GI_RESCUE=1

source /etc/profile 2>/dev/null || true
command -v env-update >/dev/null 2>&1 && env-update &>/dev/null || true

echo ""
echo -e "\033[1;33m======================================\033[0m"
echo -e "\033[1;33m  RESCUE CHROOT                      \033[0m"
echo -e "\033[1;33m  You are inside the repaired machine\033[0m"
echo -e "\033[1;33m  Everything below writes to its disk \033[0m"
echo -e "\033[1;33m======================================\033[0m"
echo ""
echo -e "  System : \$(cat /etc/gentoo-release 2>/dev/null || echo unknown)"
echo -e "  Kernel : \$(readlink -f /usr/src/linux 2>/dev/null || echo none)"
echo ""
echo "  Useful here:"
echo "    passwd                      reset the root password"
echo "    emerge --info               check the package environment"
echo "    dmesg | tail                what the last boot said"
echo "    clevis luks list -d DEV     is the TPM sealing still there"
echo ""
echo "    exit                        leave, then ./rescue-chroot.sh exit"
echo ""

exec /bin/bash --rcfile $WORKDIR/.rescue_bashrc -i
EOF

  chmod +x "$init"
  log "  wrote $WORKDIR/.rescue_init.sh and .rescue_bashrc"
}

################################################################################
# Leaving
################################################################################

holders_of() {
  # fuser is the tool that works here. A scan of /proc/PID/root finds nothing
  # once a lazy unmount has happened: the kernel then shows "/" instead of the
  # chroot path, which is exactly when the holder matters most.
  local target="$1" out=""
  command -v fuser >/dev/null 2>&1 || return 1
  # -M makes fuser refuse an argument that is not a mountpoint. Without it the
  # question asked becomes "who uses the filesystem holding this path", which
  # on a LiveCD is the live root: 560 PIDs measured here, PID 1 among them.
  out="$(fuser -M -m "$target" 2>/dev/null | tr -s ' ' '\n' | grep -E '^[0-9]+$' || true)"
  [[ -n "$out" ]] || return 1
  echo "$out"
  return 0
}

report_holders() {
  # The caller passes the list it already has. What is shown and what is
  # killed have to be the same list: fuser run twice answers differently, and
  # it is the second answer that would reach kill.
  local pids="${1:-}" p
  if [[ -z "$pids" ]]; then
    if ! pids="$(holders_of "$TARGET")"; then
      skip "  nothing holds $TARGET"
      return 1
    fi
  fi

  echo "" >&2
  warn "Processes still holding $TARGET:"
  for p in $pids; do
    [[ -d "/proc/$p" ]] || continue
    printf "    PID %-7s %s\n" "$p" \
      "$(tr '\0' ' ' <"/proc/$p/cmdline" 2>/dev/null | cut -c1-55)" >&2
  done
  echo "" >&2
  echo "  A process started inside the chroot keeps its root there. Until it" >&2
  echo "  stops, the volumes cannot be closed and luks-open.sh close will" >&2
  echo "  report the container as still open." >&2
  echo "" >&2
  return 0
}

stop_holders() {
  local pids="${1:-}" p left=0

  [[ -n "$pids" ]] || pids="$(holders_of "$TARGET")" || return 0

  for p in $pids; do
    [[ -d "/proc/$p" ]] || continue
    # $$ is this script, $PPID the shell it was started from, 1 the init of
    # the rescue system. None of the three is a chroot leftover, and killing
    # any of them ends the repair instead of ending the chroot.
    [[ "$p" == "$$" || "$p" == "$PPID" || "$p" == "1" ]] && continue
    log "  stopping PID $p"
    kill "$p" 2>/dev/null || true
  done
  sleep 2

  pids="$(holders_of "$TARGET")" || return 0
  for p in $pids; do
    [[ -d "/proc/$p" ]] || continue
    [[ "$p" == "$$" || "$p" == "$PPID" || "$p" == "1" ]] && continue
    warn "  PID $p did not stop, sending KILL"
    kill -9 "$p" 2>/dev/null || true
    left=$((left + 1))
  done
  sleep 1
  return 0
}

unbind_all() {
  local acted=false mp

  log "Unbinding the virtual filesystems"

  # Restore the machine's own resolver before anything is detached
  if [[ -e "$TARGET/etc/resolv.conf.rescue-orig" ]]; then
    mv -f "$TARGET/etc/resolv.conf.rescue-orig" "$TARGET/etc/resolv.conf"
    log "  resolv.conf restored"
  fi

  # Reverse order of creation, deepest first
  for mp in "$TARGET/proc" "$TARGET/run" "$TARGET/sys" "$TARGET/dev"; do
    if mountpoint -q "$mp" 2>/dev/null; then
      if umount -R "$mp" 2>/dev/null; then
        log "  unbound $mp"
        acted=true
      elif umount -Rl "$mp" 2>/dev/null; then
        warn "  $mp was busy, unbound lazily"
        acted=true
      else
        err "  could not unbind $mp"
      fi
    else
      skip "  $mp not bound"
    fi
  done

  rm -rf "${TARGET:?}${WORKDIR:?}" 2>/dev/null || true

  if [[ "$acted" == "true" ]]; then
    ok "Virtual filesystems released"
  else
    skip "Nothing was bound"
  fi
}

################################################################################
# Commands
################################################################################

do_prepare() {
  verify_target || exit "$EXIT_FAILURE"
  setup_bindings
  write_init
}

do_enter() {
  do_prepare

  echo "" >&2
  if verbose_enough; then
    echo "${C_Y}You are about to enter the rescued system.${C_0}" >&2
    echo "To enter it by hand instead, from another terminal:" >&2
    echo "    chroot $TARGET $WORKDIR/.rescue_init.sh" >&2
    echo "" >&2
  fi

  if ! confirm "Enter now?" "Y"; then
    log "Not entering. Prepared and ready:"
    log "  chroot $TARGET $WORKDIR/.rescue_init.sh"
    log "  ./rescue-chroot.sh exit    (when done)"
    return 0
  fi

  log "Entering"
  chroot "$TARGET" "$WORKDIR/.rescue_init.sh" || warn "Chroot exited with a non-zero status"
  ok "Chroot exited"

  echo "" >&2
  log "The bindings are still in place. When you are done:"
  log "  ./rescue-chroot.sh exit"
}

do_exit() {
  local pids=""

  # The recommended sequence prints './luks-open.sh close' first, so this
  # command is often run on a target that is no longer mounted. There is
  # nothing to hold then, and asking would be asking about the live root.
  if ! mountpoint -q "$TARGET" 2>/dev/null; then
    warn "$TARGET is not a mountpoint: the storage is already closed"
    warn "  Not looking for holders here: the answer would name the"
    warn "  processes of the rescue system itself"
    unbind_all
    return 0
  fi

  if pids="$(holders_of "$TARGET")"; then
    report_holders "$pids"
    # Default N, not Y. The yes branch sends kill, then kill -9, to every
    # PID printed above: a list nobody read is not a list anybody agreed to.
    if confirm "Stop these processes?" "N"; then
      stop_holders "$pids"
      report_holders || ok "All holders stopped"
    else
      warn "Left running: the storage will not close until they stop"
    fi
  else
    skip "  nothing holds $TARGET"
  fi

  unbind_all

  echo "" >&2
  log "The storage is still open. To close it:"
  log "  ./luks-open.sh close --target $TARGET"
}

do_status() {
  echo ""
  echo "${C_B}=== Rescue chroot status ===${C_0}"
  echo ""

  local label
  label="Target ($TARGET)"
  if mountpoint -q "$TARGET" 2>/dev/null; then
    printf "  %-26s %s <- %s\n" "$label:" "${C_G}mounted${C_0}" \
      "$(findmnt -no SOURCE "$TARGET")"
  else
    printf "  %-26s %s\n" "$label:" "${C_Y}not mounted${C_0}"
  fi

  if [[ -f "$TARGET/etc/gentoo-release" ]]; then
    printf "  %-26s %s %s\n" "System:" "${C_G}present${C_0}" \
      "$(cat "$TARGET/etc/gentoo-release")"
  else
    printf "  %-26s %s\n" "System:" "${C_Y}absent${C_0}"
  fi

  echo ""
  echo "${C_B}=== Bindings ===${C_0}"
  echo ""
  local mp
  for mp in dev sys proc run; do
    if mountpoint -q "$TARGET/$mp" 2>/dev/null; then
      printf "  %-26s %s\n" "/$mp:" "${C_G}bound${C_0}"
    else
      printf "  %-26s %s\n" "/$mp:" "${C_Y}not bound${C_0}"
    fi
  done

  report_holders || {
    echo ""
    echo "  No process holds $TARGET."
    echo ""
  }
}

main() {
  parse_arguments "$@"

  case "$SUBCOMMAND" in
    enter)
      check_root
      do_enter
      ;;
    prepare)
      check_root
      do_prepare
      echo "" >&2
      ok "Ready. Enter with: chroot $TARGET $WORKDIR/.rescue_init.sh"
      ;;
    exit | umount | unbind)
      check_root
      do_exit
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
