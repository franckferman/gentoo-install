#!/usr/bin/env bash
#
# gentoo-install — chroot: pseudo-filesystems, entry, exit, command execution
# ----------------------------------------------------------------------------
# Mounts what a chroot needs (/proc, /sys, /dev with its pts and shm children,
# /run and the EFI system partition), copies the resolver configuration in,
# runs commands inside, and releases exactly what this run mounted.
#
# The rule this module exists to enforce: ownership is recorded at the moment
# of the mount, never guessed afterwards. The internal installer this project
# grew out of unmounted the ESP unconditionally before entering the chroot, so
# /boot/efi was an empty directory inside, the boot step wrote into the target
# filesystem instead of the firmware partition, and the recovery path was gone
# without a single error message. A mount that was already there when we
# arrived is adopted, reported, and left exactly as it was found.
#
# Nothing here runs at source time.
#
# Usage:  source lib/chroot.sh   (needs lib/core.sh)
#
set -euo pipefail

if [[ -n "${_GI_CHROOT_LOADED:-}" ]]; then
  return 0
fi
_GI_CHROOT_LOADED=1

# --------------------------------------------------------------------------- #
#  Module state                                                               #
# --------------------------------------------------------------------------- #
# CHROOT_ROOT is the one piece of state the module carries, exactly as
# lib/state.sh carries STATE_FILE: chroot_attach() sets it, everything else
# refuses to act until it is set. The two ownership arrays are the whole point
# of the module — _GI_CHROOT_OWNED is what chroot_cleanup() may unmount, and
# _GI_CHROOT_ADOPTED is what it must not touch.
CHROOT_ROOT=""
_GI_CHROOT_OWNED=()
_GI_CHROOT_ADOPTED=()
_GI_CHROOT_ESP_DEVICE=""

# Where the ESP is mounted inside the target unless something says otherwise.
# /boot/efi is the layout the Gentoo handbook and GRUB both assume; a
# systemd-boot install that mounts the ESP on /boot sets chroot_esp_mountpoint
# through the configuration instead.
readonly CHROOT_ESP_MOUNTPOINT_DEFAULT="/boot/efi"

# The GUID every GPT EFI system partition carries. Checked before mounting, so
# that a mistyped device name is refused instead of being mounted on /boot/efi.
readonly CHROOT_ESP_PARTTYPE="c12a7328-f81f-11d2-ba4b-00a0c93ec93b"

# Run inside the chroot ahead of every command: a login shell would rebuild
# PATH from /etc/profile but would also print whatever the profile prints, and
# chroot_capture() needs a clean stdout. Sourcing it with output silenced gives
# the environment without the noise. `exec "$0" "$@"` then runs the caller's
# argv untouched — no quoting, no eval, no shell metacharacter surprises.
# shellcheck disable=SC2016  # single quotes are the point: this text is
# expanded by the shell inside the chroot, not by this one.
readonly _GI_CHROOT_PRELUDE='
export HOME="${HOME:-/root}"
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export TERM="${TERM:-dumb}"
if [ -r /etc/profile ]; then . /etc/profile >/dev/null 2>&1 || true; fi
exec "$0" "$@"'

# --------------------------------------------------------------------------- #
#  Target resolution                                                          #
# --------------------------------------------------------------------------- #
chroot_target() {
  # Where the installed system is mounted. A returned value, so stdout.
  #
  # GI_TARGET beats the configuration so that a test — or an operator poking at
  # a second system — can point the module somewhere else without touching CFG.
  if [[ -n "${GI_TARGET:-}" ]]; then
    printf '%s\n' "${GI_TARGET%/}"
    return 0
  fi
  # chroot_dir first, because it exists precisely to point the chroot somewhere
  # other than where the stage was unpacked; then root, which is what --root
  # sets and what steps 40 and 60 already use.
  #
  # This read CFG[target] until it was found by running an install: no such
  # setting is declared, so the lookup was always empty and every run chrooted
  # into /mnt/gentoo whatever --root said. Step 50 then failed with "Target root
  # does not exist" while step 60 was working on the real target three lines
  # further down.
  if declare -p CFG >/dev/null 2>&1; then
    local dir="${CFG[chroot_dir]:-}"
    [[ -n "$dir" ]] || dir="${CFG[root]:-}"
    if [[ -n "$dir" ]]; then
      printf '%s\n' "${dir%/}"
      return 0
    fi
  fi
  printf '%s\n' "/mnt/gentoo"
}

chroot_esp_mountpoint() {
  # Where the ESP belongs inside the target. A returned value, so stdout.
  if [[ -n "${GI_ESP_MOUNTPOINT:-}" ]]; then
    printf '%s\n' "$GI_ESP_MOUNTPOINT"
    return 0
  fi
  # The same source of truth steps 70 and 95 use: the operator's esp_mount when
  # they set one, otherwise where step 20 actually mounted the ESP, otherwise the
  # disk layer's own default. Reading CFG[esp_mount] alone fell through to
  # /boot/efi and mounted the ESP a second time there when step 20 had put it on
  # /boot — which surfaced as two fstab lines carrying the same UUID.
  local value=""
  if declare -F target_fact >/dev/null 2>&1; then
    value="$(target_fact esp_mount disk.esp_mount "")"
  fi
  if [[ -z "$value" ]] && declare -p CFG >/dev/null 2>&1; then
    value="${CFG[disk_esp_mount]:-}"
  fi
  printf '%s\n' "${value:-$CHROOT_ESP_MOUNTPOINT_DEFAULT}"
}

chroot_attach() {
  # Point the module at a target without touching anything. Args: $1 = root.
  local root="${1:-}"
  [[ -n "$root" ]] || root="$(chroot_target)"
  CHROOT_ROOT="${root%/}"
  if [[ -z "$CHROOT_ROOT" || "$CHROOT_ROOT" == "/" ]]; then
    err "Refusing to treat / as a chroot target"
    err "       every mount and every unmount below would land on the running system"
    err "       example:  --root /mnt/gentoo"
    return 1
  fi
}

_chroot_require_attached() {
  if [[ -z "$CHROOT_ROOT" ]]; then
    die "internal: chroot_attach() was never called"
  fi
}

# --------------------------------------------------------------------------- #
#  Readiness                                                                   #
# --------------------------------------------------------------------------- #
_chroot_is_mounted() {
  # True when $1 is itself a mountpoint. findmnt --mountpoint asks about that
  # exact directory; a bare `findmnt PATH` would also answer for a device.
  local path="$1"
  [[ -d "$path" ]] || return 1
  if have findmnt; then
    findmnt -rno TARGET --mountpoint "$path" >/dev/null 2>&1
  else
    mountpoint -q -- "$path" 2>/dev/null
  fi
}

chroot_verify_target() {
  # Everything that makes `chroot` fail with a one-word message, checked here
  # where the message can still name the step that fixes it.
  _chroot_require_attached
  local problems=0

  if [[ ! -d "$CHROOT_ROOT" ]]; then
    err "Target root does not exist: ${CHROOT_ROOT}"
    err "       step 20 partitions and mounts it, step 40 unpacks the stage3 into it"
    err "       example:  ./gentoo-install.sh --steps 20,40,50"
    return 1
  fi

  if ! _chroot_is_mounted "$CHROOT_ROOT"; then
    # Not fatal on its own: a test tree, or a target on the same filesystem,
    # is a legitimate thing to chroot into. It is worth saying out loud.
    warn "${CHROOT_ROOT} is not a mountpoint — is the target filesystem mounted?"
  fi

  if [[ ! -x "${CHROOT_ROOT}/bin/bash" ]]; then
    err "No usable /bin/bash under ${CHROOT_ROOT}"
    err "       chroot would fail with 'No such file or directory' and name nothing"
    err "       step 40 unpacks the stage3 that provides it"
    problems=$((problems + 1))
  fi

  if [[ ! -d "${CHROOT_ROOT}/usr/bin" ]]; then
    err "${CHROOT_ROOT}/usr looks empty"
    err "       a separate /usr filesystem that is not mounted looks exactly like this"
    problems=$((problems + 1))
  fi

  ((problems == 0)) || return 1
  return 0
}

# --------------------------------------------------------------------------- #
#  Mount primitives                                                           #
# --------------------------------------------------------------------------- #
_chroot_record_owned() {
  _GI_CHROOT_OWNED+=("$1")
  # core.sh unmounts tracked mounts from its EXIT trap, so an interrupted run
  # still releases them even if nothing calls chroot_cleanup().
  track_mount "$1"
}

_chroot_mount() {
  # The single door every mount in this module goes through, so that ownership
  # is recorded in exactly one place.
  # Args: $1 = kind (rbind|bind|fs), $2 = source, $3 = path inside the target,
  #       $4 = filesystem type (kind fs only), $5 = mount options (kind fs only).
  _chroot_require_attached
  local kind="$1" source="$2" rel="$3" fstype="${4:-}" options="${5:-}"
  local target="${CHROOT_ROOT}${rel}"

  if _chroot_is_mounted "$target"; then
    _GI_CHROOT_ADOPTED+=("$target")
    skip "chroot: ${rel} was already mounted — adopted, and this run will not unmount it"
    return 0
  fi

  if [[ "$kind" != "fs" && ! -e "$source" ]]; then
    warn "chroot: ${source} does not exist on this system; ${rel} left unmounted"
    return 0
  fi

  run_cmd mkdir -p -- "$target" || return 1

  case "$kind" in
    rbind)
      # --make-rslave, always. Without it a mount made later inside the chroot
      # propagates back out to the host, and `umount -R` on the way out can
      # take the host's own /dev with it.
      run_cmd mount --rbind -- "$source" "$target" || return 1
      run_cmd mount --make-rslave -- "$target" || warn "chroot: ${rel} could not be made rslave"
      ;;
    bind)
      run_cmd mount --bind -- "$source" "$target" || return 1
      run_cmd mount --make-slave -- "$target" || warn "chroot: ${rel} could not be made slave"
      ;;
    fs)
      if [[ -n "$options" ]]; then
        run_cmd mount -t "$fstype" -o "$options" -- "$source" "$target" || return 1
      else
        run_cmd mount -t "$fstype" -- "$source" "$target" || return 1
      fi
      ;;
    *)
      die "internal: _chroot_mount got an unknown kind: ${kind}"
      ;;
  esac

  _chroot_record_owned "$target"
  ok "chroot: mounted ${rel}"
}

chroot_mount_pseudo() {
  # /proc, /sys, /dev, /dev/pts, /dev/shm and /run, in the order the Gentoo
  # handbook gives, which is also the order they must be released in reverse.
  #
  # /dev/pts and /dev/shm normally arrive with the recursive bind of /dev and
  # are adopted rather than mounted again; the explicit entries below are for
  # the case where they did not, which is what a stage3 unpacked over a tmpfs
  # /dev looks like. A chroot without /dev/pts cannot open a terminal, and one
  # without a tmpfs on /dev/shm breaks every build that uses shared memory.
  _chroot_require_attached
  local failed=0

  _chroot_mount fs proc /proc proc || failed=$((failed + 1))
  _chroot_mount rbind /sys /sys || failed=$((failed + 1))
  _chroot_mount rbind /dev /dev || failed=$((failed + 1))
  _chroot_mount fs devpts /dev/pts devpts gid=5,mode=620 || failed=$((failed + 1))
  _chroot_mount fs tmpfs /dev/shm tmpfs nosuid,nodev,noexec,mode=1777 || failed=$((failed + 1))
  _chroot_mount bind /run /run || failed=$((failed + 1))

  if ((failed > 0)); then
    err "chroot: ${failed} pseudo-filesystem(s) could not be mounted"
    err "       nothing was left half-mounted: chroot_cleanup releases what did mount"
    return 1
  fi
  return 0
}

# --------------------------------------------------------------------------- #
#  The EFI system partition                                                   #
# --------------------------------------------------------------------------- #
_chroot_esp_from_config() {
  if [[ -n "${GI_ESP_DEVICE:-}" ]]; then
    printf '%s\n' "$GI_ESP_DEVICE"
    return 0
  fi
  if declare -p CFG >/dev/null 2>&1; then
    if [[ -n "${CFG[esp_device]:-}" ]]; then
      printf '%s\n' "${CFG[esp_device]}"
      return 0
    fi
    if [[ -n "${CFG[esp_device]:-}" ]]; then
      printf '%s\n' "${CFG[esp_device]}"
      return 0
    fi
  fi
  return 1
}

_chroot_esp_from_fstab() {
  # The target's own fstab is the most authoritative answer there is: it is
  # what the installed system will use, so mounting anything else here would
  # install the bootloader somewhere the machine never looks at.
  local mp="$1" fstab="${CHROOT_ROOT}/etc/fstab" spec
  [[ -r "$fstab" ]] || return 1
  spec="$(awk -v m="$mp" '!/^[[:space:]]*#/ && $2 == m { print $1; exit }' "$fstab")"
  [[ -n "$spec" ]] || return 1
  case "$spec" in
    UUID=* | LABEL=* | PARTUUID=* | PARTLABEL=*)
      have findfs || return 1
      findfs "$spec" 2>/dev/null
      ;;
    /dev/*)
      printf '%s\n' "$spec"
      ;;
    *)
      return 1
      ;;
  esac
}

_chroot_whole_disk() {
  # Walk up from a partition, a device-mapper node or an LVM volume to the disk
  # that carries it. lsblk -dno PKNAME one level at a time, because a root on
  # LVM on LUKS on a partition is three levels deep and a single call answers
  # for one of them only.
  local node="$1" parent="" i
  have lsblk || return 1
  for ((i = 0; i < 8; i++)); do
    parent="$(lsblk -dno PKNAME -- "$node" 2>/dev/null | head -n 1 | tr -d ' ')"
    [[ -n "$parent" ]] || break
    node="/dev/${parent}"
  done
  [[ -b "$node" ]] || return 1
  printf '%s\n' "$node"
}

_chroot_esp_from_topology() {
  # Last resort: the EFI system partition of the disk the target root lives on.
  # Derived, never guessed — "the first partition of the first disk" is how an
  # installer writes a bootloader onto somebody else's operating system.
  local root_src disk
  have findmnt || return 1
  root_src="$(findmnt -no SOURCE --target "$CHROOT_ROOT" 2>/dev/null | head -n 1)" || return 1
  [[ -n "$root_src" ]] || return 1
  disk="$(_chroot_whole_disk "$root_src")" || return 1
  lsblk -rno NAME,PARTTYPE -- "$disk" 2>/dev/null \
    | awk -v t="$CHROOT_ESP_PARTTYPE" 'tolower($2) == t { print "/dev/" $1; exit }' \
    | grep . || return 1
}

chroot_esp_device() {
  # The ESP this install should use, or 1 and nothing on stdout. A returned
  # value, so stdout; the three sources are announced on stderr.
  _chroot_require_attached
  local device="" mp
  mp="$(chroot_esp_mountpoint)"

  if device="$(_chroot_esp_from_config)"; then
    log "chroot: ESP ${device} (from the configuration)"
  elif device="$(_chroot_esp_from_fstab "$mp")" && [[ -n "$device" ]]; then
    log "chroot: ESP ${device} (from ${CHROOT_ROOT}/etc/fstab)"
  elif device="$(_chroot_esp_from_topology)" && [[ -n "$device" ]]; then
    log "chroot: ESP ${device} (the EFI system partition of the target's disk)"
  else
    return 1
  fi

  printf '%s\n' "$device"
}

chroot_mount_esp() {
  # Mounting the ESP is not optional housekeeping: step 80 writes the
  # bootloader there, and a chroot whose /boot/efi is an empty directory
  # accepts every one of those writes onto the root filesystem instead.
  #
  # Not fatal when there is no ESP to find — a BIOS install has none — but
  # loud, because on a UEFI machine this is the difference between a system
  # that boots and one that does not.
  _chroot_require_attached
  local device mp fstype

  mp="$(chroot_esp_mountpoint)"

  if _chroot_is_mounted "${CHROOT_ROOT}${mp}"; then
    _GI_CHROOT_ADOPTED+=("${CHROOT_ROOT}${mp}")
    skip "chroot: ${mp} was already mounted — adopted, and this run will not unmount it"
    return 0
  fi

  if ! device="$(chroot_esp_device)"; then
    warn "chroot: no EFI system partition found for ${CHROOT_ROOT}"
    warn "       ${mp} stays an empty directory, and the bootloader step will write into it"
    warn "       name it explicitly if this machine boots with UEFI:  esp_device = /dev/sda1"
    return 0
  fi

  if [[ ! -b "$device" ]]; then
    err "Not a block device: ${device}"
    err "       an ESP is a partition, so /dev/sda1 or /dev/nvme0n1p1"
    err "       example:  esp_device = /dev/nvme0n1p1"
    return 1
  fi

  if have blkid; then
    fstype="$(blkid -o value -s TYPE -- "$device" 2>/dev/null || true)"
    if [[ -n "$fstype" && "$fstype" != "vfat" ]]; then
      err "${device} holds a ${fstype} filesystem, not vfat"
      err "       an EFI system partition is FAT32; this is something else"
      err "       mounting it on ${mp} would hide the real one and lose the bootloader"
      return 1
    fi
  fi

  _chroot_mount fs "$device" "$mp" vfat || return 1
  _GI_CHROOT_ESP_DEVICE="$device"
  return 0
}

# --------------------------------------------------------------------------- #
#  Name resolution inside the chroot                                          #
# --------------------------------------------------------------------------- #
chroot_copy_resolv_conf() {
  # Portage inside the chroot has no network without this. It goes through
  # write_file so that --dry-run, --on-conflict and the "already up to date"
  # report all behave the same as everywhere else.
  #
  # cat, not cp: on a systemd host /etc/resolv.conf is a symlink into
  # /run/systemd/resolve, and copying the symlink gives the chroot a dangling
  # link that fails with a name-resolution error nobody connects to this.
  _chroot_require_attached
  local src="/etc/resolv.conf" dst="${CHROOT_ROOT}/etc/resolv.conf" body

  if [[ ! -r "$src" ]]; then
    warn "chroot: ${src} is not readable; the chroot will have no name resolution"
    return 0
  fi

  body="$(cat -- "$src" 2>/dev/null || true)"
  if [[ -z "${body//[[:space:]]/}" ]]; then
    warn "chroot: ${src} is empty; the chroot will have no name resolution"
    return 0
  fi

  run_cmd mkdir -p -- "${CHROOT_ROOT}/etc" || return 1
  write_file "$dst" 0644 <<EOF
${body}
EOF
}

# --------------------------------------------------------------------------- #
#  Prepare                                                                    #
# --------------------------------------------------------------------------- #
chroot_prepare() {
  # Everything a chroot needs, in one call, idempotent.
  # Args: $1 = target root (optional; the configuration answers otherwise).
  chroot_attach "${1:-}" || return 1
  chroot_verify_target || return 1
  chroot_mount_pseudo || return 1
  chroot_mount_esp || return 1
  chroot_copy_resolv_conf || return 1
  ok "chroot: ${CHROOT_ROOT} is ready (${#_GI_CHROOT_OWNED[@]} mount(s) owned by this run)"
}

# --------------------------------------------------------------------------- #
#  Running things inside                                                      #
# --------------------------------------------------------------------------- #
chroot_run() {
  # Run a command inside the chroot and report its exit code as our own.
  # Args: $@ = argv, executed directly — no shell, no quoting to get wrong.
  #   chroot_run emerge --info
  _chroot_require_attached
  (($# > 0)) || die "internal: chroot_run was given no command"
  run_cmd chroot "$CHROOT_ROOT" /bin/bash -c "$_GI_CHROOT_PRELUDE" "$@"
}

chroot_run_quiet() {
  # Same contract, with the command's own output discarded. For the checks
  # whose exit code is the whole answer.
  _chroot_require_attached
  (($# > 0)) || die "internal: chroot_run_quiet was given no command"
  run_quiet chroot "$CHROOT_ROOT" /bin/bash -c "$_GI_CHROOT_PRELUDE" "$@"
}

chroot_capture() {
  # Run a command inside the chroot and print its stdout — a returned value.
  # Deliberately not routed through run_cmd: a dry run has nothing mounted, so
  # there is nothing to read, and returning 1 lets the caller say "unknown"
  # rather than mistake an empty answer for a real one.
  _chroot_require_attached
  (($# > 0)) || die "internal: chroot_capture was given no command"
  if [[ "$DRY_RUN" == "yes" ]]; then
    log "dry-run: would read from the chroot: $(_cmdline "$@")"
    return 1
  fi
  chroot "$CHROOT_ROOT" /bin/bash -c "$_GI_CHROOT_PRELUDE" "$@" 2>/dev/null
}

chroot_enter() {
  # An interactive shell inside the chroot, for the operator who wants to look
  # around. The prompt comes from an rcfile and not from an exported PS1: an
  # interactive bash rebuilds PS1 from its rc files and throws away whatever
  # the parent exported, which is why every naive version of this ends up
  # showing the host's prompt in the one place where knowing which side you
  # are on actually matters.
  _chroot_require_attached
  local rc="${CHROOT_ROOT}/tmp/.gentoo-install-rc"

  if [[ "${NON_INTERACTIVE:-no}" == "yes" || ! -r /dev/tty ]]; then
    err "Cannot open an interactive chroot without a terminal"
    err "       chroot_run executes a single command instead"
    err "       example:  $(chroot_command_hint)"
    return 1
  fi

  if [[ "$DRY_RUN" == "yes" ]]; then
    log "dry-run: would enter ${CHROOT_ROOT}"
    return 0
  fi

  mkdir -p -- "${CHROOT_ROOT}/tmp" || return 1
  cat >"$rc" <<'EOF'
[[ -r /etc/bash/bashrc ]] && source /etc/bash/bashrc
[[ -r /etc/profile ]] && source /etc/profile
PS1='\[\033[1;31m\](chroot)\[\033[0m\] \w \$ '
EOF
  track_temp "$rc"

  warn "Entering ${CHROOT_ROOT}. Everything from here writes to the target."
  local rc_code=0
  chroot "$CHROOT_ROOT" /bin/bash --rcfile /tmp/.gentoo-install-rc -i || rc_code=$?
  log "chroot: left ${CHROOT_ROOT} (exit ${rc_code})"
  return "$rc_code"
}

chroot_command_hint() {
  # The command an operator can paste into another terminal. A returned value.
  _chroot_require_attached
  printf 'chroot %s /bin/bash -l\n' "$CHROOT_ROOT"
}

# --------------------------------------------------------------------------- #
#  Release                                                                    #
# --------------------------------------------------------------------------- #
chroot_cleanup() {
  # Unmount what this run mounted, deepest first, and nothing else. Idempotent:
  # calling it twice, or after core.sh's EXIT trap has already been through,
  # reports and returns 0.
  local i path failed=0 released=0

  if ((${#_GI_CHROOT_OWNED[@]} == 0)); then
    skip "chroot: this run mounted nothing, so there is nothing to unmount"
    return 0
  fi

  for ((i = ${#_GI_CHROOT_OWNED[@]} - 1; i >= 0; i--)); do
    path="${_GI_CHROOT_OWNED[i]}"
    if ! _chroot_is_mounted "$path"; then
      continue
    fi
    if umount -R -- "$path" 2>/dev/null; then
      released=$((released + 1))
    elif umount -Rl -- "$path" 2>/dev/null; then
      warn "chroot: ${path} was busy, unmounted lazily"
      released=$((released + 1))
    else
      err "chroot: could not unmount ${path}"
      err "       something still has it open:  fuser -vm ${path}"
      failed=$((failed + 1))
    fi
  done

  _GI_CHROOT_OWNED=()
  _GI_CHROOT_ESP_DEVICE=""

  if ((${#_GI_CHROOT_ADOPTED[@]} > 0)); then
    log "chroot: ${#_GI_CHROOT_ADOPTED[@]} mount(s) were already there and stay mounted"
  fi

  if ((failed > 0)); then
    err "chroot: ${failed} mount(s) still held; unmount them before rebooting"
    return 1
  fi

  ok "chroot: released ${released} mount(s)"
  return 0
}

# --------------------------------------------------------------------------- #
#  Records and rendering (DESIGN.md §7)                                       #
# --------------------------------------------------------------------------- #
chroot_mount_records() {
  # One record per line on stdout: path<TAB>owned|adopted<TAB>mounted|absent.
  # The engine half: it prints a value and changes nothing.
  local path state
  if ((${#_GI_CHROOT_OWNED[@]} > 0)); then
    for path in "${_GI_CHROOT_OWNED[@]}"; do
      state="absent"
      _chroot_is_mounted "$path" && state="mounted"
      printf '%s\towned\t%s\n' "$path" "$state"
    done
  fi
  if ((${#_GI_CHROOT_ADOPTED[@]} > 0)); then
    for path in "${_GI_CHROOT_ADOPTED[@]}"; do
      state="absent"
      _chroot_is_mounted "$path" && state="mounted"
      printf '%s\tadopted\t%s\n' "$path" "$state"
    done
  fi
}

show_chroot_status() {
  # The rendering half: it prints and changes nothing.
  local path owner state
  log "chroot: ${CHROOT_ROOT:-<not attached>}"
  if [[ -n "$_GI_CHROOT_ESP_DEVICE" ]]; then
    log "  ESP        ${_GI_CHROOT_ESP_DEVICE} on $(chroot_esp_mountpoint)"
  fi
  while IFS=$'\t' read -r path owner state; do
    [[ -n "$path" ]] || continue
    log "$(printf '  %-9s %-8s %s' "$owner" "$state" "$path")"
  done < <(chroot_mount_records)
}
