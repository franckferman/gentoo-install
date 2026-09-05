#!/usr/bin/env bash
#
# gentoo-install — disk: detection, refusals, proportional layouts, provisioning
# ----------------------------------------------------------------------------
# Everything that touches a block device lives here. The module is built around
# one idea: a layout is a proportion, not a table of gigabytes. `root:50` is a
# number that works on the machine it was written for and destroys the plan on
# a 64 GiB laptop or a 4 TiB server, so a layout declares percentages with soft
# minima and maxima, and disk_plan() turns them into a table of real sizes that
# is printed before anything is written.
#
# The second idea is that detection refuses by default. A removable disk, a
# disk with a mounted filesystem and the disk carrying the running system are
# each refused, and each refusal has its own switch — never one blanket
# --force, which is how an operator lifts three guards while meaning to lift
# one. The erase confirmation is a typed device path (DESIGN.md §12) and no
# flag lifts it.
#
# Engine and rendering are separate (DESIGN.md §7): disk_plan() returns a
# record set on stdout and says nothing, disk_show_plan() prints and changes
# nothing, disk_apply_plan() acts. Every destructive command goes through
# run_cmd(), so --dry-run is complete by construction, and through
# _disk_assert_target(), so it can only ever land on the confirmed disk.
#
# Nothing here runs at source time. Call disk_init_defaults() once — right
# after config_init_defaults() if the disk settings are to be readable from a
# configuration file, and step_20_disk() calls it too so the module works on
# its own.
#
# Usage:  source lib/disk.sh   (needs lib/core.sh, lib/config.sh, lib/ui.sh)
#
set -euo pipefail

if [[ -n "${_GI_DISK_LOADED:-}" ]]; then
  return 0
fi
_GI_DISK_LOADED=1

# --------------------------------------------------------------------------- #
#  Constants                                                                  #
# --------------------------------------------------------------------------- #
# GPT keeps a primary header at the start and a backup at the end. sgdisk
# aligns the first partition on 1 MiB; 2 MiB of reserve covers both ends with
# room to spare, and being one mebibyte pessimistic costs nothing.
readonly DISK_GPT_RESERVE_MIB=2

# LVM allocates in extents of 4 MiB by default and the physical volume header
# eats about one. Sizes are rounded down to a multiple of the extent so that
# lvcreate never rounds a volume up past the free space.
readonly DISK_LVM_EXTENT_MIB=4
readonly DISK_LVM_OVERHEAD_MIB=8

# Floors. A volume shrunk below these is not a small volume, it is a broken
# one: a Gentoo root has to hold a stage3, a portage tree and a kernel build.
readonly DISK_FLOOR_ROOT_MIB=3072
readonly DISK_FLOOR_OTHER_MIB=512

# The mountpoint that means "not a mountpoint".
readonly DISK_SWAP_MOUNT="swap"

# Set by disk_confirm_destroy(). Every destructive helper checks the device it
# was handed against this before running, so a caller that computed a path
# wrongly stops here instead of on the disk.
DISK_CONFIRMED_TARGET=""

# --------------------------------------------------------------------------- #
#  Settings                                                                   #
# --------------------------------------------------------------------------- #
disk_init_defaults() {
  # Declared here rather than in lib/config.sh so this module stays one file.
  # set_default never overwrites an explicit value, so calling it twice, or
  # after parse_args, is harmless.
  #
  # Safe by default: nothing is auto-selected that a careful operator would
  # not have selected by hand.
  set_default disk ""                # empty: detect, then ask
  set_default disk_layout "desktop"  # minimal|server|desktop|custom
  set_default disk_filesystem "ext4" # ext4|xfs|btrfs|f2fs
  set_default disk_lvm "auto"        # auto|yes|no — auto follows the layout
  set_default disk_vg "vg0"
  set_default disk_root "/mnt/gentoo"
  set_default disk_swap "auto" # auto|none|<size>

  # 512 MiB is the number everybody copies and the first thing that fills up.
  # A Gentoo kernel plus a genkernel initramfs is 60–120 MiB per generation,
  # microcode and a bootloader add a few more, and this installer mounts the
  # ESP at /boot so the kernels live on it. 512 MiB holds three or four
  # generations before `make install` fails halfway; 1 GiB holds a dozen and
  # costs half a gibibyte on the smallest disk worth installing on.
  set_default disk_esp_size "1024" # MiB
  set_default disk_esp_mount "/boot"

  # Conservative by default: each of these lifts one refusal and one only.
  set_default disk_allow_removable "no" # yes: a USB stick becomes a target
  set_default disk_allow_mounted "no"   # yes: mounted filesystems get unmounted
  set_default disk_allow_system "no"    # yes: the disk you booted from is fair game
  set_default disk_allow_loop "no"      # yes: loop devices are listed (the test suite)

  # custom layout input
  set_default disk_volumes ""      # "name:mount:size:fs;..."
  set_default disk_volumes_file "" # a file of the same records, one per line

  # Consumed, never created, by this module: step 30 owns LUKS. When a mapper
  # of this name is open, the volume group is built on it instead of the raw
  # partition.
  set_default disk_crypt_name "gentoo"
}

# --------------------------------------------------------------------------- #
#  Validation — stage 1 (DESIGN.md §5): the value must be spellable           #
# --------------------------------------------------------------------------- #
disk_validate_filesystem() {
  # Args: $1 = value, $2 = the flag that sets it (for the example line).
  validate_enum "filesystem" "$1" "${2:---filesystem}" \
    "ext4:the boring answer, and the one every rescue disk can repair" \
    "xfs:fast on large files, cannot be shrunk, needs sys-fs/xfsprogs" \
    "btrfs:snapshots and checksums, needs sys-fs/btrfs-progs" \
    "f2fs:log-structured, for flash without a controller, needs sys-fs/f2fs-tools"
}

disk_validate_layout() {
  validate_enum "disk layout" "$1" "${2:---layout}" \
    "minimal:one root partition, no LVM, nothing you did not ask for" \
    "server:LVM, /var and /var/log split off, free extents kept in the group" \
    "desktop:LVM, /home takes what is left" \
    "custom:the volumes named by disk_volumes or disk_volumes_file"
}

disk_validate_lvm() {
  validate_enum "LVM mode" "$1" "${2:---lvm}" \
    "auto:whatever the layout declares" \
    "yes:one volume group, whatever the layout declares" \
    "no:plain partitions, whatever the layout declares"
}

disk_validate_config() {
  # Every disk setting checked in one place, in milliseconds, before a single
  # sector is read. Called at the top of step 20; a future --filesystem flag
  # calls disk_validate_filesystem() directly at parse time.
  local esp

  disk_validate_layout "${CFG[disk_layout]}" "--disk-layout"
  disk_validate_filesystem "${CFG[disk_filesystem]}" "--filesystem"
  disk_validate_lvm "${CFG[disk_lvm]}" "--lvm"

  if ! esp="$(disk_parse_size "${CFG[disk_esp_size]}" "disk_esp_size")"; then
    return 1
  fi
  if ((esp < 256)); then
    die_usage "disk_esp_size is too small: ${CFG[disk_esp_size]}" \
      "an ESP under 256 MiB cannot hold one kernel and its initramfs" \
      "512 MiB is the usual answer and the usual thing to run out of" \
      "example:  disk_esp_size = 1024"
  fi

  case "${CFG[disk_esp_mount]}" in
    /boot | /efi | /boot/efi) ;;
    *)
      die_usage "Unknown ESP mountpoint: ${CFG[disk_esp_mount]}" \
        "/boot      the ESP holds the kernels; nothing to run out of twice" \
        "/efi       systemd-boot's own convention, kernels under /boot on root" \
        "/boot/efi  the GRUB convention, kernels under /boot on root" \
        "example:  disk_esp_mount = /boot"
      ;;
  esac

  case "${CFG[disk_swap]}" in
    auto | none | no | "") ;;
    *)
      disk_parse_size "${CFG[disk_swap]}" "disk_swap" >/dev/null || return 1
      ;;
  esac

  if [[ ! "${CFG[disk_vg]}" =~ ^[a-zA-Z0-9+_.][a-zA-Z0-9+_.-]*$ ]]; then
    die_usage "Invalid volume group name: ${CFG[disk_vg]}" \
      "LVM accepts letters, digits and + _ . -, and will not start with -" \
      "example:  disk_vg = vg0"
  fi
  return 0
}

# --------------------------------------------------------------------------- #
#  Sizes                                                                      #
# --------------------------------------------------------------------------- #
disk_parse_size() {
  # A size in mebibytes on stdout (a returned value). Binary units only: a
  # disk vendor's "500 GB" and a kernel's "500 GiB" differ by 7%, and a plan
  # that silently mixes them overflows on the last volume.
  # Args: $1 = spec, $2 = what it is, for the error message.
  local spec="$1" what="${2:-size}" number unit
  if [[ ! "$spec" =~ ^([0-9]+)([KkMmGgTt]?)(i?[Bb]?)$ ]]; then
    die_usage "Invalid ${what}: ${spec}" \
      "expected a whole number and a binary unit: K, M, G or T" \
      "a bare number is read as mebibytes" \
      "example:  ${what} = 8G"
  fi
  number="${BASH_REMATCH[1]}"
  unit="${BASH_REMATCH[2]}"
  case "${unit,,}" in
    k) printf '%s\n' "$((number / 1024))" ;;
    "" | m) printf '%s\n' "$number" ;;
    g) printf '%s\n' "$((number * 1024))" ;;
    t) printf '%s\n' "$((number * 1024 * 1024))" ;;
  esac
}

disk_human_size() {
  # Mebibytes to something a human reads, one decimal. A returned value.
  local mib="${1:-0}"
  if ((mib >= 1048576)); then
    printf '%d.%01d TiB\n' "$((mib / 1048576))" "$(((mib % 1048576) * 10 / 1048576))"
  elif ((mib >= 1024)); then
    printf '%d.%01d GiB\n' "$((mib / 1024))" "$(((mib % 1024) * 10 / 1024))"
  else
    printf '%d MiB\n' "$mib"
  fi
}

_disk_round_extent() {
  # Down to a whole LVM extent. Rounding up is what makes the last lvcreate
  # fail on a volume group that was exactly full.
  local mib="$1"
  printf '%s\n' "$((mib - mib % DISK_LVM_EXTENT_MIB))"
}

# --------------------------------------------------------------------------- #
#  Block device facts                                                         #
# --------------------------------------------------------------------------- #
disk_normalize() {
  # /dev/sda, /dev/sda/, sda -> sda. A returned value.
  local input="${1:-}"
  input="${input%/}"
  input="${input#/dev/}"
  printf '%s\n' "$input"
}

disk_device() { printf '/dev/%s\n' "$(disk_normalize "${1:-}")"; }

disk_is_whole() {
  # True for a whole disk, false for a partition, an LV or nothing at all. A
  # loop device is a whole device too, but it is a file pretending to be one,
  # so it counts only when disk_allow_loop says it should — which is how the
  # test suite drives this module without going near a disk.
  local name kind
  name="$(disk_normalize "${1:-}")"
  [[ -n "$name" && -b "/dev/${name}" ]] || return 1
  kind="$(lsblk -dno TYPE "/dev/${name}" 2>/dev/null || true)"
  case "$kind" in
    disk) return 0 ;;
    loop) [[ "${CFG[disk_allow_loop]:-no}" == "yes" ]] ;;
    *) return 1 ;;
  esac
}

disk_size_bytes() { lsblk -bdno SIZE "/dev/$(disk_normalize "$1")" 2>/dev/null || printf '0\n'; }

disk_size_mib() {
  local bytes
  bytes="$(disk_size_bytes "$1")"
  printf '%s\n' "$((bytes / 1048576))"
}

_disk_field() {
  # One lsblk column of a whole disk, trimmed, empty rather than absent.
  local name="$1" column="$2" value
  value="$(lsblk -dno "$column" "/dev/$(disk_normalize "$name")" 2>/dev/null || true)"
  value="${value#"${value%%[![:space:]]*}"}"
  printf '%s\n' "${value%"${value##*[![:space:]]}"}"
}

disk_model() { _disk_field "$1" MODEL; }
disk_serial() { _disk_field "$1" SERIAL; }
disk_tran() { _disk_field "$1" TRAN; }
disk_rotational() { _disk_field "$1" ROTA; }

disk_serial_or_unknown() {
  local serial
  serial="$(disk_serial "$1")"
  printf '%s\n' "${serial:-<none reported>}"
}

disk_partition_device() {
  # nvme0n1 + 1 -> /dev/nvme0n1p1, sda + 1 -> /dev/sda1, loop0 + 1 ->
  # /dev/loop0p1. The rule is the kernel's: a name ending in a digit takes a
  # 'p' so that nvme0n11 cannot be read as nvme0n1 partition 1.
  local name index="$2"
  name="$(disk_normalize "$1")"
  if [[ "$name" =~ [0-9]$ ]]; then
    printf '/dev/%sp%s\n' "$name" "$index"
  else
    printf '/dev/%s%s\n' "$name" "$index"
  fi
}

disk_list() {
  # Whole disks worth offering, one kernel name per line. loop, sr, zram and
  # ram are images and readers, not install targets; disk_allow_loop lifts the
  # first so the test suite can drive this module against a file.
  local pattern='^(loop|sr|zram|ram|fd)'
  if [[ "${CFG[disk_allow_loop]:-no}" == "yes" ]]; then
    pattern='^(sr|zram|ram|fd)'
  fi
  lsblk -dno NAME,TYPE 2>/dev/null \
    | awk '$2 == "disk" || $2 == "loop" { print $1 }' \
    | grep -Ev "$pattern" || true
}

disk_mountpoints() {
  # Every mountpoint under a disk, one per line, deepest last.
  lsblk -lno MOUNTPOINT "/dev/$(disk_normalize "$1")" 2>/dev/null \
    | sed '/^[[:space:]]*$/d' || true
}

_disk_holding_disks() {
  # Every whole disk underneath a device, one name per line. `lsblk -s` walks
  # the tree upwards, so an LVM volume on a LUKS container on a partition
  # resolves all the way down to the disk. It is -nslo NAME and not
  # -nso PKNAME on purpose: in inverse mode lsblk prints each row's PKNAME
  # against the wrong row, which silently answers "no disk" for exactly the
  # encrypted-LVM root this has to recognise.
  # Args: $1 = any block device.
  lsblk -nslo NAME,TYPE "$1" 2>/dev/null | awk '$2 == "disk" { print $1 }' || true
}

_disk_system_disks() {
  # The disks the running system sits on, resolved from the mount table rather
  # than guessed from a name.
  local mount source
  for mount in / /boot /boot/efi /efi /usr /var /run/initramfs/live; do
    source="$(findmnt -no SOURCE --target "$mount" 2>/dev/null || true)"
    [[ -n "$source" ]] || continue
    [[ -b "$source" ]] || continue
    _disk_holding_disks "$source"
  done | sed '/^[[:space:]]*$/d' | sort -u
}

disk_carries_system() {
  local name
  name="$(disk_normalize "$1")"
  _disk_system_disks | grep -qx -- "$name"
}

disk_is_removable() {
  # TRAN=usb is the signal that holds: an external enclosure happily reports
  # RM=0, and an internal card reader reports RM=1.
  local name
  name="$(disk_normalize "$1")"
  [[ "$(disk_tran "$name")" == "usb" ]] && return 0
  [[ "$(_disk_field "$name" RM)" == "1" ]] && return 0
  [[ "$(_disk_field "$name" HOTPLUG)" == "1" ]] && return 0
  return 1
}

disk_classify() {
  # system | mounted | removable | internal, in order of severity. A returned
  # value.
  local name
  name="$(disk_normalize "$1")"
  if disk_carries_system "$name"; then
    printf 'system\n'
  elif [[ -n "$(disk_mountpoints "$name")" ]]; then
    printf 'mounted\n'
  elif disk_is_removable "$name"; then
    printf 'removable\n'
  else
    printf 'internal\n'
  fi
}

disk_inventory() {
  # TSV on stdout: name, size, transport, rotational, class, model. A returned
  # value, so a caller can filter it; disk_show_inventory() renders it.
  local name
  while IFS= read -r name; do
    [[ -n "$name" ]] || continue
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$name" \
      "$(disk_human_size "$(disk_size_mib "$name")")" \
      "$(disk_tran "$name" | sed 's/^$/-/')" \
      "$([[ "$(disk_rotational "$name")" == "1" ]] && printf 'hdd' || printf 'ssd')" \
      "$(disk_classify "$name")" \
      "$(disk_model "$name" | cut -c1-28)"
  done < <(disk_list)
}

disk_show_inventory() {
  # Prints, changes nothing. On stderr: it is diagnostics, not a value.
  local name size tran rota class model
  log "disks on this machine:"
  log "$(printf '       %-12s %-10s %-6s %-5s %-10s %s' \
    NAME SIZE TRAN TYPE ROLE MODEL)"
  while IFS=$'\t' read -r name size tran rota class model; do
    log "$(printf '       %-12s %-10s %-6s %-5s %-10s %s' \
      "$name" "$size" "$tran" "$rota" "$class" "$model")"
  done < <(disk_inventory)
}

# --------------------------------------------------------------------------- #
#  Refusals                                                                   #
# --------------------------------------------------------------------------- #
disk_guard() {
  # Three refusals, three switches. --force lifts none of them: it lifts
  # confirmations, not proofs (DESIGN.md §12), and each of these exists
  # because somebody once lost the wrong disk to it.
  # Args: $1 = disk name. Returns 0 when the disk may be used.
  local name class mp
  name="$(disk_normalize "$1")"

  if ! disk_is_whole "$name"; then
    err "Not a whole disk: /dev/${name}"
    err "       gentoo-install partitions disks, so it wants sda, not sda1"
    err "       --list-disks shows what this machine has"
    err "       example:  disk = /dev/nvme0n1"
    return 1
  fi

  class="$(disk_classify "$name")"

  if [[ "$class" == "system" && "${CFG[disk_allow_system]:-no}" != "yes" ]]; then
    err "/dev/${name} carries the running system — refused"
    err "       it holds one of: $(_disk_mounts_line "$name")"
    err "       erasing it takes the installer down with it, mid-write"
    err "       disk_allow_system = yes lifts this, and nothing else does"
    err "       example:  --disk /dev/nvme0n1"
    return 1
  fi

  if disk_is_removable "$name" && [[ "${CFG[disk_allow_removable]:-no}" != "yes" ]]; then
    err "/dev/${name} is removable (transport: $(disk_tran "$name" | sed 's/^$/unknown/')) — refused"
    err "       this is what stops an install landing on the USB stick it booted from"
    err "       disk_allow_removable = yes lifts this refusal alone"
    err "       example:  --config removable.conf, holding disk_allow_removable = yes"
    return 1
  fi

  if [[ -n "$(disk_mountpoints "$name")" && "${CFG[disk_allow_mounted]:-no}" != "yes" ]]; then
    err "/dev/${name} has mounted filesystems — refused"
    while IFS= read -r mp; do
      [[ -n "$mp" ]] || continue
      err "       mounted: ${mp}"
    done < <(disk_mountpoints "$name")
    err "       something is using this disk right now; unmount it, or"
    err "       disk_allow_mounted = yes to let gentoo-install unmount it first"
    err "       example:  umount $(disk_mountpoints "$name" | head -n 1)"
    return 1
  fi

  if [[ -n "$(disk_mountpoints "$name")" ]]; then
    warn "/dev/${name} has mounted filesystems; they will be unmounted (disk_allow_mounted=yes)"
  fi
  return 0
}

_disk_mounts_line() {
  disk_mountpoints "$1" | paste -sd, - || true
}

# --------------------------------------------------------------------------- #
#  Target selection                                                           #
# --------------------------------------------------------------------------- #
disk_resolve_target() {
  # The disk name on stdout (a returned value). Explicit setting first, then a
  # single internal candidate offered for confirmation, then a menu. Never a
  # silent guess between several disks: picking the first of two is how an
  # installer erases the wrong one without ever having lied.
  local wanted="${CFG[disk]:-}" name choice
  local -a candidates=()

  if [[ -n "$wanted" ]]; then
    name="$(disk_normalize "$wanted")"
    if [[ ! -b "/dev/${name}" ]]; then
      err "No such block device: ${wanted}"
      err "       --list-disks shows what this machine has"
      err "       example:  --disk /dev/nvme0n1"
      return 1
    fi
    printf '%s\n' "$name"
    return 0
  fi

  while IFS= read -r name; do
    [[ -n "$name" ]] || continue
    [[ "$(disk_classify "$name")" == "internal" ]] || continue
    candidates+=("$name")
  done < <(disk_list)

  if ((${#candidates[@]} == 0)); then
    err "No installable disk found"
    err "       every disk here is removable, mounted, or carries the running system"
    err "       name one explicitly, or lift the matching refusal"
    err "       example:  --disk /dev/nvme0n1"
    return 1
  fi

  if ((${#candidates[@]} == 1)); then
    name="${candidates[0]}"
    log "one internal disk found: /dev/${name} ($(disk_human_size "$(disk_size_mib "$name")"), $(disk_model "$name"))"
    if confirm "Install onto /dev/${name}?" "no"; then
      printf '%s\n' "$name"
      return 0
    fi
    err "Disk not confirmed; nothing done."
    err "       name the one you meant instead"
    err "       example:  --disk /dev/sdb"
    return 1
  fi

  local -a entries=()
  for name in "${candidates[@]}"; do
    entries+=("$(printf '/dev/%-10s %10s  %s' "$name" \
      "$(disk_human_size "$(disk_size_mib "$name")")" "$(disk_model "$name")")")
  done
  if ! choice="$(menu "Several internal disks — which one?" "${entries[@]}")"; then
    return 1
  fi
  choice="${choice#/dev/}"
  printf '%s\n' "${choice%% *}"
}

# --------------------------------------------------------------------------- #
#  Layouts                                                                    #
# --------------------------------------------------------------------------- #
disk_layout_dir() {
  # variants/layout, resolved from this file rather than from the caller's
  # working directory. A returned value.
  local dir="${GI_VARIANTS_DIR:-}" self
  if [[ -z "$dir" ]]; then
    self="$(readlink -f -- "${BASH_SOURCE[0]}")"
    dir="${self%/lib/*}/variants"
  fi
  printf '%s\n' "${dir}/layout"
}

disk_load_layout() {
  # Source variants/layout/<name>.sh and print what layout_<name> returns.
  # The records it prints are the whole contract between a variant and this
  # file, and they are documented in every variant's header.
  local name="$1" file fn
  file="$(disk_layout_dir)/${name}.sh"
  fn="layout_${name}"

  if [[ ! -r "$file" ]]; then
    err "No such layout: ${name}"
    err "       expected ${file}"
    err "       minimal | server | desktop | custom ship with the installer"
    err "       example:  disk_layout = desktop"
    return 1
  fi
  # shellcheck source=/dev/null
  source "$file"
  if ! declare -F "$fn" >/dev/null 2>&1; then
    err "Layout ${name} does not define ${fn}()"
    err "       ${file} must define it and print its records on stdout"
    err "       example:  disk_layout = desktop"
    return 1
  fi
  "$fn"
}

_disk_swap_auto_mib() {
  # Args: $1 = the space the volumes will share, in MiB.
  # Enough to hibernate is not the goal here; enough to survive a linker
  # running out of memory during a kernel build is. RAM, clamped to a sane
  # band, and never more than a tenth of the disk — a 2 GiB swap on a 20 GiB
  # disk is already a tenth of the install gone.
  local pool="$1" mem_kib mem_mib swap cap
  mem_kib="$(awk '/^MemTotal:/ { print $2; exit }' /proc/meminfo 2>/dev/null || true)"
  mem_mib=$((${mem_kib:-2097152} / 1024))

  swap="$mem_mib"
  ((swap >= 2048)) || swap=2048
  ((swap <= 8192)) || swap=8192

  cap=$((pool / 10))
  ((swap <= cap)) || swap="$cap"

  if ((pool < 4096)); then
    printf '0\n'
    return 0
  fi
  ((swap >= 256)) || swap=256
  _disk_round_extent "$swap"
}

_disk_floor() {
  # The size below which a volume stops being a volume.
  if [[ "$1" == "/" ]]; then
    printf '%s\n' "$DISK_FLOOR_ROOT_MIB"
  else
    printf '%s\n' "$DISK_FLOOR_OTHER_MIB"
  fi
}

# shellcheck disable=SC2034  # the arrays below are filled here, read by disk_plan
_disk_parse_records() {
  # Fill the parallel arrays from a layout's records. Kept apart from disk_plan
  # so a malformed record is reported with its line and nothing is computed on
  # top of it.
  # Args: $1 = layout name, $2.. = the raw lines.
  local layout="$1"
  shift
  local line body name mount spec fs kind pct mn mx key value

  _DISK_LVM="no"
  _DISK_ABOUT=""
  _DISK_N=()
  _DISK_M=()
  _DISK_K=()
  _DISK_P=()
  _DISK_MIN=()
  _DISK_MAX=()
  _DISK_F=()

  for line in "$@"; do
    body="${line#"${line%%[![:space:]]*}"}"
    body="${body%"${body##*[![:space:]]}"}"
    [[ -n "$body" ]] || continue

    if [[ "${body:0:1}" == "#" ]]; then
      value="${body#\#}"
      value="${value#"${value%%[![:space:]]*}"}"
      [[ "$value" == *:* ]] || continue
      key="${value%%:*}"
      value="${value#*:}"
      value="${value#"${value%%[![:space:]]*}"}"
      case "$key" in
        lvm) _DISK_LVM="$value" ;;
        about) _DISK_ABOUT="$value" ;;
      esac
      continue
    fi

    IFS=':' read -r name mount spec fs <<<"$body"
    if [[ -z "$name" || -z "$mount" || -z "$spec" ]]; then
      err "Malformed volume record in layout ${layout}: ${body}"
      err "       a record reads name:mountpoint:size:filesystem"
      err "       example:  home:/home:rest:@fs@"
      return 1
    fi
    if [[ ! "$name" =~ ^[a-z][a-z0-9_]*$ ]]; then
      err "Invalid volume name in layout ${layout}: ${name}"
      err "       lowercase letters, digits and underscores; it becomes an LV name"
      err "       example:  varlog:/var/log:10%:@fs@"
      return 1
    fi
    if [[ "$mount" != "$DISK_SWAP_MOUNT" && "${mount:0:1}" != "/" ]]; then
      err "Invalid mountpoint in layout ${layout}: ${mount}"
      err "       an absolute path, or the word swap"
      err "       example:  var:/var:30%:@fs@"
      return 1
    fi

    kind="abs"
    pct=0
    mn=0
    mx=0
    case "$spec" in
      rest)
        kind="rest"
        ;;
      auto)
        kind="auto"
        ;;
      *%*)
        kind="pct"
        IFS='/' read -r pct mn mx <<<"$spec"
        pct="${pct%\%}"
        if [[ ! "$pct" =~ ^[0-9]+$ ]] || ((pct < 1 || pct > 100)); then
          err "Invalid percentage in layout ${layout}: ${spec}"
          err "       a whole number of percent between 1 and 100"
          err "       optionally followed by /min/max: 25%/8G/80G"
          err "       example:  root:/:25%/8G/80G:@fs@"
          return 1
        fi
        if [[ -n "${mn:-}" ]]; then mn="$(disk_parse_size "$mn" "minimum of ${name}")" || return 1; else mn=0; fi
        if [[ -n "${mx:-}" ]]; then mx="$(disk_parse_size "$mx" "maximum of ${name}")" || return 1; else mx=0; fi
        if ((mx > 0 && mn > mx)); then
          err "Layout ${layout}: ${name} has a minimum above its maximum (${mn} > ${mx} MiB)"
          err "       min comes before max: 25%/8G/80G"
          err "       example:  root:/:25%/8G/80G:@fs@"
          return 1
        fi
        ;;
      *)
        pct=0
        mn="$(disk_parse_size "$spec" "size of ${name}")" || return 1
        ;;
    esac

    if [[ "$mount" == "$DISK_SWAP_MOUNT" ]]; then
      fs="swap"
    elif [[ -z "${fs:-}" || "$fs" == "@fs@" ]]; then
      fs="${CFG[disk_filesystem]}"
    fi

    _DISK_N+=("$name")
    _DISK_M+=("$mount")
    _DISK_K+=("$kind")
    _DISK_P+=("$pct")
    _DISK_MIN+=("$mn")
    _DISK_MAX+=("$mx")
    _DISK_F+=("$fs")
  done

  if ((${#_DISK_N[@]} == 0)); then
    err "Layout ${layout} declares no volume"
    err "       at least a root volume is needed"
    err "       example:  root:/:rest:@fs@"
    return 1
  fi
  return 0
}

disk_plan() {
  # The engine (DESIGN.md §7): a record set on stdout, nothing said, nothing
  # touched. Six tab-separated columns:
  #
  #   meta  <key>  <value>  0     -     -
  #   esp   <name> <mount>  <mib> vfat  <device>
  #   part  <name> <mount>  <mib> <fs>  <device>
  #   lv    <name> <mount>  <mib> <fs>  <device>
  #   free  -      -        <mib> -     -
  #
  # Args: $1 = disk name, $2 = layout name.
  local name="$1" layout="$2"
  local -a raw=()
  local total esp pool avail lvm vg swap_total=0 sum=0 rest_index=-1
  local i mib floor sur head take fs dev part_index=1 raw_text
  local -a size=()

  # Command substitution, not `mapfile < <(...)`: mapfile reports on itself,
  # not on the process it read from, so a layout that refused to produce a
  # record set would go unnoticed and the plan would be computed on nothing.
  raw_text="$(disk_load_layout "$layout")" || return 1
  mapfile -t raw <<<"$raw_text"
  _disk_parse_records "$layout" "${raw[@]}" || return 1

  lvm="${_DISK_LVM}"
  case "${CFG[disk_lvm]:-auto}" in
    yes) lvm="yes" ;;
    no) lvm="no" ;;
  esac
  vg="${CFG[disk_vg]}"

  total="$(disk_size_mib "$name")"
  esp="$(disk_parse_size "${CFG[disk_esp_size]}" "disk_esp_size")" || return 1

  pool=$((total - esp - DISK_GPT_RESERVE_MIB))
  if [[ "$lvm" == "yes" ]]; then
    pool=$((pool - DISK_LVM_OVERHEAD_MIB))
  fi
  if ((pool < DISK_FLOOR_ROOT_MIB)); then
    err "/dev/${name} is too small for layout ${layout}"
    err "       $(disk_human_size "$total") total, $(disk_human_size "$esp") of it ESP"
    err "       that leaves $(disk_human_size "$((pool > 0 ? pool : 0))") for the system, and a Gentoo root needs $(disk_human_size "$DISK_FLOOR_ROOT_MIB")"
    err "       a smaller ESP buys some of it back"
    err "       example:  disk_esp_size = 512"
    return 1
  fi

  # Swap is a fixed claim, taken before the percentages so that a percentage
  # always means the same thing: a share of what the filesystems will divide.
  avail="$pool"
  for ((i = 0; i < ${#_DISK_N[@]}; i++)); do
    size[i]=0
    [[ "${_DISK_M[i]}" == "$DISK_SWAP_MOUNT" ]] || continue
    case "${CFG[disk_swap]:-auto}" in
      none | no | "") mib=0 ;;
      auto)
        if [[ "${_DISK_K[i]}" == "auto" ]]; then
          mib="$(_disk_swap_auto_mib "$pool")"
        else
          mib="${_DISK_MIN[i]}"
        fi
        ;;
      *) mib="$(disk_parse_size "${CFG[disk_swap]}" "disk_swap")" || return 1 ;;
    esac
    size[i]="$mib"
    swap_total=$((swap_total + mib))
  done
  avail=$((avail - swap_total))

  # Percentages of what is left, then the soft clamps, then the hard floor.
  for ((i = 0; i < ${#_DISK_N[@]}; i++)); do
    [[ "${_DISK_M[i]}" != "$DISK_SWAP_MOUNT" ]] || continue
    case "${_DISK_K[i]}" in
      rest)
        if ((rest_index >= 0)); then
          err "Layout ${layout} claims 'rest' twice: ${_DISK_N[rest_index]} and ${_DISK_N[i]}"
          err "       only one volume can take what is left over"
          err "       example:  home:/home:rest:@fs@"
          return 1
        fi
        rest_index="$i"
        continue
        ;;
      pct)
        mib=$((avail * _DISK_P[i] / 100))
        if ((_DISK_MIN[i] > 0 && mib < _DISK_MIN[i])); then mib="${_DISK_MIN[i]}"; fi
        if ((_DISK_MAX[i] > 0 && mib > _DISK_MAX[i])); then mib="${_DISK_MAX[i]}"; fi
        ;;
      auto | abs)
        mib="${_DISK_MIN[i]}"
        ;;
      *)
        err "internal: unknown size kind ${_DISK_K[i]} for ${_DISK_N[i]}"
        return 1
        ;;
    esac
    floor="$(_disk_floor "${_DISK_M[i]}")"
    ((mib >= floor)) || mib="$floor"
    size[i]="$(_disk_round_extent "$mib")"
    sum=$((sum + size[i]))
  done

  # Fitting. A minimum is a preference, not a promise: on a disk too small to
  # honour them all, every volume gives back the same proportion of what it
  # holds above its floor, so the shape of the layout survives even when its
  # numbers cannot. Below the floors the layout genuinely does not fit, and
  # that is said rather than worked around.
  local rest_floor=0
  if ((rest_index >= 0)); then
    rest_floor="$(_disk_floor "${_DISK_M[rest_index]}")"
  fi
  if ((sum + rest_floor > avail)); then
    sur=$((sum + rest_floor - avail))
    head=0
    for ((i = 0; i < ${#_DISK_N[@]}; i++)); do
      [[ "${_DISK_M[i]}" != "$DISK_SWAP_MOUNT" ]] || continue
      ((i != rest_index)) || continue
      head=$((head + size[i] - $(_disk_floor "${_DISK_M[i]}")))
    done
    if ((head < sur)); then
      err "Layout ${layout} does not fit on /dev/${name}"
      err "       $(disk_human_size "$avail") to share out after the ESP and swap"
      err "       the ${#_DISK_N[@]} volumes need $(disk_human_size "$((sum + rest_floor))") even shrunk to their floors"
      err "       a layout with fewer volumes fits: minimal is one root and nothing else"
      err "       example:  --layout minimal"
      return 1
    fi
    for ((i = 0; i < ${#_DISK_N[@]}; i++)); do
      [[ "${_DISK_M[i]}" != "$DISK_SWAP_MOUNT" ]] || continue
      ((i != rest_index)) || continue
      floor="$(_disk_floor "${_DISK_M[i]}")"
      take=$(((size[i] - floor) * sur / head))
      size[i]="$(_disk_round_extent "$((size[i] - take))")"
    done
    sum=0
    for ((i = 0; i < ${#_DISK_N[@]}; i++)); do
      [[ "${_DISK_M[i]}" != "$DISK_SWAP_MOUNT" ]] || continue
      ((i != rest_index)) || continue
      sum=$((sum + size[i]))
    done
  fi

  # The volume taking what is left takes it exactly: on LVM the last lvcreate
  # asks for 100%FREE and on plain partitions sgdisk gets 0:0, so rounding it
  # down to an extent would only invent megabytes nobody can reach.
  if ((rest_index >= 0)); then
    size[rest_index]=$((avail - sum))
    sum=$((sum + size[rest_index]))
  fi

  # ------------------------------------------------------------------- #
  printf 'meta\tdevice\t/dev/%s\t0\t-\t-\n' "$name"
  printf 'meta\tlayout\t%s\t0\t-\t-\n' "$layout"
  printf 'meta\tabout\t%s\t0\t-\t-\n' "${_DISK_ABOUT:-no description}"
  printf 'meta\tlvm\t%s\t0\t-\t-\n' "$lvm"
  printf 'meta\tvg\t%s\t0\t-\t-\n' "$vg"
  printf 'meta\tmountpoint\t%s\t0\t-\t-\n' "${CFG[disk_root]}"
  printf 'meta\ttotal\t%s\t%s\t-\t-\n' "$(disk_human_size "$total")" "$total"
  printf 'meta\tpool\t%s\t%s\t-\t-\n' "$(disk_human_size "$pool")" "$pool"

  printf 'esp\tesp\t%s\t%s\tvfat\t%s\n' \
    "${CFG[disk_esp_mount]}" "$esp" "$(disk_partition_device "$name" 1)"
  part_index=2

  if [[ "$lvm" == "yes" ]]; then
    printf 'part\tsystem\t-\t%s\tlvm\t%s\n' \
      "$((total - esp - DISK_GPT_RESERVE_MIB))" "$(disk_partition_device "$name" 2)"
  fi

  # Swap first, then the sized volumes, then the one taking what is left: on
  # LVM that lets the last lvcreate use every free extent, and on plain
  # partitions it puts the open-ended partition at the end of the disk where
  # sgdisk's 0:0 belongs.
  local pass
  for pass in swap fixed rest; do
    for ((i = 0; i < ${#_DISK_N[@]}; i++)); do
      case "$pass" in
        swap) [[ "${_DISK_M[i]}" == "$DISK_SWAP_MOUNT" ]] || continue ;;
        fixed)
          [[ "${_DISK_M[i]}" != "$DISK_SWAP_MOUNT" ]] || continue
          ((i != rest_index)) || continue
          ;;
        rest) ((i == rest_index)) || continue ;;
      esac
      ((size[i] > 0)) || continue
      fs="${_DISK_F[i]}"
      if [[ "$lvm" == "yes" ]]; then
        dev="/dev/${vg}/${_DISK_N[i]}"
        printf 'lv\t%s\t%s\t%s\t%s\t%s\n' "${_DISK_N[i]}" "${_DISK_M[i]}" "${size[i]}" "$fs" "$dev"
      else
        dev="$(disk_partition_device "$name" "$part_index")"
        printf 'part\t%s\t%s\t%s\t%s\t%s\n' "${_DISK_N[i]}" "${_DISK_M[i]}" "${size[i]}" "$fs" "$dev"
        part_index=$((part_index + 1))
      fi
    done
  done

  if ((avail - sum > 0)); then
    printf 'free\t-\t-\t%s\t-\t-\n' "$((avail - sum))"
  fi
}

# --------------------------------------------------------------------------- #
#  Plan accessors                                                             #
# --------------------------------------------------------------------------- #
disk_plan_meta() {
  # Args: $1 = plan text, $2 = key. A returned value.
  awk -F'\t' -v k="$2" '$1 == "meta" && $2 == k { print $3; exit }' <<<"$1"
}

disk_plan_rows() {
  # Args: $1 = plan text, $2 = kind (esp|part|lv|free) or "volume" for the
  # three that carry a filesystem. A returned value.
  local want="$2"
  if [[ "$want" == "volume" ]]; then
    awk -F'\t' '$1 == "esp" || $1 == "part" || $1 == "lv" { print }' <<<"$1"
  else
    awk -F'\t' -v k="$want" '$1 == k { print }' <<<"$1"
  fi
}

disk_plan_device_for() {
  # The device backing a mountpoint. A returned value.
  awk -F'\t' -v m="$2" '($1 == "esp" || $1 == "part" || $1 == "lv") && $3 == m { print $6; exit }' <<<"$1"
}

# --------------------------------------------------------------------------- #
#  Rendering                                                                  #
# --------------------------------------------------------------------------- #
disk_show_plan() {
  # Prints, changes nothing. This is the screen the operator reads before
  # typing the device name, so it says what will exist and what will be lost,
  # in the units the disk is sold in and the units the kernel uses.
  # Args: $1 = plan text.
  local plan="$1"
  local kind name mount mib fs dev total lvm vg
  total="$(awk -F'\t' '$1 == "meta" && $2 == "total" { print $4; exit }' <<<"$plan")"
  lvm="$(disk_plan_meta "$plan" lvm)"
  vg="$(disk_plan_meta "$plan" vg)"

  log "layout $(disk_plan_meta "$plan" layout) on $(disk_plan_meta "$plan" device) — $(disk_human_size "$total")"
  log "       $(disk_plan_meta "$plan" about)"
  if [[ "$lvm" == "yes" ]]; then
    log "       LVM: volume group ${vg} on the second partition"
  else
    log "       no LVM: plain GPT partitions"
  fi
  log "       mounted under $(disk_plan_meta "$plan" mountpoint)"
  log "$(printf '       %-6s %-10s %-12s %10s %7s  %-6s %s' \
    KIND NAME MOUNT SIZE SHARE FS DEVICE)"

  while IFS=$'\t' read -r kind name mount mib fs dev; do
    case "$kind" in
      meta) continue ;;
      free)
        if [[ "$lvm" == "yes" ]]; then
          dev="kept free in ${vg} for lvextend and snapshots"
        else
          dev="unpartitioned"
        fi
        log "$(printf '       %-6s %-10s %-12s %10s %6s%%  %-6s %s' \
          "free" "-" "-" "$(disk_human_size "$mib")" \
          "$(_disk_share "$mib" "$total")" "-" "$dev")"
        continue
        ;;
    esac
    [[ "$fs" != "lvm" ]] || continue
    log "$(printf '       %-6s %-10s %-12s %10s %6s%%  %-6s %s' \
      "$kind" "$name" "$mount" "$(disk_human_size "$mib")" \
      "$(_disk_share "$mib" "$total")" "$fs" "$dev")"
  done <<<"$plan"
}

_disk_share() {
  # A percentage of the whole disk with one decimal, so a 1 GiB ESP on a 2 TiB
  # disk reads as 0.0% instead of vanishing into an integer zero that could
  # equally mean "nothing".
  local part="$1" whole="$2" tenths
  ((whole > 0)) || {
    printf '0.0\n'
    return 0
  }
  tenths=$((part * 1000 / whole))
  printf '%d.%d\n' "$((tenths / 10))" "$((tenths % 10))"
}

disk_show_target() {
  # What the disk is and what is on it, immediately before the typed
  # confirmation. Model, size and serial identify it; lsblk -f says what is
  # about to stop existing.
  # Args: $1 = disk name.
  local name="$1" line
  log "the disk about to be erased:"
  log "       device   /dev/${name}"
  log "       model    $(disk_model "$name")"
  log "       size     $(disk_human_size "$(disk_size_mib "$name")") ($(disk_size_bytes "$name") bytes)"
  log "       serial   $(disk_serial_or_unknown "$name")"
  log "       bus      $(disk_tran "$name" | sed 's/^$/unknown/'), $([[ "$(disk_rotational "$name")" == "1" ]] && printf 'rotational' || printf 'solid state')"
  log "       role     $(disk_classify "$name")"
  log "       what is on it now (lsblk -f):"
  while IFS= read -r line; do
    log "       | ${line}"
  done < <(lsblk -f -o NAME,FSTYPE,LABEL,UUID,FSAVAIL,MOUNTPOINTS "/dev/${name}" 2>/dev/null || printf 'lsblk reported nothing\n')
}

# --------------------------------------------------------------------------- #
#  Confirmation — a proof, not a question                                     #
# --------------------------------------------------------------------------- #
disk_confirm_destroy() {
  # Shows the disk, then asks for its path to be typed. --force and --yes do
  # not lift this and never will (DESIGN.md §12): there is no reflex answer to
  # "type /dev/nvme0n1", which is the whole reason it is not a y/n.
  # Args: $1 = disk name, $2 = plan text.
  local name="$1" plan="$2" count

  disk_show_target "$name"
  count="$(lsblk -lno NAME "/dev/${name}" 2>/dev/null | tail -n +2 | wc -l)"
  if ((count > 0)); then
    warn "${count} existing partition(s)/volume(s) on /dev/${name} will be destroyed."
  fi
  warn "Every byte on /dev/${name} will be overwritten. There is no undo."
  log "what replaces it:"
  disk_show_plan "$plan"

  if [[ "$DRY_RUN" == "yes" ]]; then
    skip "dry run: the typed confirmation for /dev/${name} is not asked for"
    DISK_CONFIRMED_TARGET="/dev/${name}"
    return 0
  fi

  if ! confirm_typed "This erases /dev/${name} completely." "/dev/${name}"; then
    return 1
  fi
  DISK_CONFIRMED_TARGET="/dev/${name}"
  return 0
}

_disk_assert_target() {
  # The last thing between a computed path and sgdisk. Called at the top of
  # every function that writes: a caller that built the wrong path stops here,
  # not on somebody's disk.
  # Args: $1 = the device about to be written to.
  local device="$1" parent
  if [[ -z "$DISK_CONFIRMED_TARGET" ]]; then
    err "internal: refusing to write to ${device} before a disk was confirmed"
    return 1
  fi
  if [[ "$device" == "$DISK_CONFIRMED_TARGET" ]]; then
    return 0
  fi
  # A partition or a logical volume of the confirmed disk is fair game; a
  # device that does not descend from it is not.
  if [[ "$DRY_RUN" == "yes" ]]; then
    return 0
  fi
  parent="$(_disk_holding_disks "$device" | head -n 1)"
  if [[ -n "$parent" && "/dev/${parent}" == "$DISK_CONFIRMED_TARGET" ]]; then
    return 0
  fi
  err "internal: ${device} is not on the confirmed disk ${DISK_CONFIRMED_TARGET}"
  err "       refusing to write to it"
  return 1
}

# --------------------------------------------------------------------------- #
#  Tools                                                                      #
# --------------------------------------------------------------------------- #
disk_require_tools() {
  # Stage 2 of validation (DESIGN.md §5): the value is legal, but is the tool
  # that implements it on this machine? Every missing one is named at once.
  # Args: $1 = plan text.
  local plan="$1" fs lvm
  local -a needed=(lsblk sgdisk wipefs partprobe blkid findmnt mountpoint)
  lvm="$(disk_plan_meta "$plan" lvm)"

  if [[ "$lvm" == "yes" ]]; then
    needed+=(pvcreate vgcreate lvcreate vgchange lvs vgs)
  fi
  while IFS= read -r fs; do
    [[ -n "$fs" && "$fs" != "lvm" ]] || continue
    case "$fs" in
      swap) needed+=(mkswap swapon) ;;
      *) needed+=("mkfs.${fs}") ;;
    esac
  done < <(disk_plan_rows "$plan" volume | awk -F'\t' '{ print $5 }' | sort -u)

  if ! require_cmds "${needed[@]}"; then
    err "       on a Gentoo live image: sys-fs/lvm2 sys-apps/gptfdisk sys-fs/dosfstools"
    err "       xfs needs sys-fs/xfsprogs, btrfs sys-fs/btrfs-progs, f2fs sys-fs/f2fs-tools"
    err "       example:  --filesystem ext4"
    return 1
  fi
  return 0
}

# --------------------------------------------------------------------------- #
#  Release, wipe, partition                                                   #
# --------------------------------------------------------------------------- #
disk_release() {
  # Free every holder so that sgdisk cannot fail on a busy device and leave
  # the disk half-erased. The stack comes down from the top: mounts, then
  # swap, then LVM, then any device-mapper node underneath it. Closing a
  # container while a volume group still sits on it always fails, and nothing
  # would retry it afterwards.
  # Args: $1 = disk name.
  local name="$1" device="/dev/$1"
  local mp dev holder vg left
  local -a seen=()

  _disk_assert_target "$device" || return 1
  log "releasing holders on ${device}"

  while IFS= read -r mp; do
    [[ -n "$mp" ]] || continue
    run_quiet umount -R -- "$mp" || run_quiet umount -l -- "$mp" \
      || warn "could not unmount ${mp}"
  done < <(disk_mountpoints "$name" | awk '{ print length, $0 }' | sort -rn | cut -d' ' -f2-)

  while IFS= read -r dev; do
    [[ -n "$dev" ]] || continue
    run_quiet swapoff "$dev" || warn "swapoff failed: ${dev}"
  done < <(lsblk -lnpo NAME,FSTYPE "$device" 2>/dev/null | awk '$2 == "swap" { print $1 }')

  # The volume group cannot be found through its physical volume when the PV
  # is a mapper node: matching PVs against the disk resolves nothing on an
  # encrypted stack. The LVM children of the subtree are the reliable way in.
  while IFS= read -r holder; do
    [[ -n "$holder" ]] || continue
    vg="$(lvs --noheadings -o vg_name "/dev/mapper/${holder}" 2>/dev/null | tr -d ' ' | head -n 1 || true)"
    [[ -n "$vg" ]] || continue
    if [[ " ${seen[*]-} " == *" ${vg} "* ]]; then continue; fi
    seen+=("$vg")
    run_quiet vgchange -an "$vg" || warn "vgchange -an ${vg} failed"
  done < <(lsblk -lno NAME,TYPE "$device" 2>/dev/null | awk '$2 == "lvm" { print $1 }')

  local pass
  for pass in lvm crypt; do
    while IFS= read -r holder; do
      [[ -n "$holder" ]] || continue
      run_quiet cryptsetup luksClose "$holder" \
        || run_quiet dmsetup remove "$holder" \
        || warn "could not close mapper ${holder}"
    done < <(lsblk -lno NAME,TYPE "$device" 2>/dev/null | awk -v t="$pass" '$2 == t { print $1 }')
  done

  run_quiet sync
  _disk_settle

  if [[ "$DRY_RUN" == "yes" ]]; then
    return 0
  fi
  left="$(lsblk -lno NAME,TYPE "$device" 2>/dev/null | awk '$2 == "crypt" || $2 == "lvm" { print $1 }' | paste -sd, - || true)"
  if [[ -n "$left" ]]; then
    err "Still open on ${device}: ${left}"
    err "       sgdisk would fail on a busy device and leave the disk half-erased"
    err "       close them by hand and run step 20 again"
    err "       example:  cryptsetup luksClose ${left%%,*}"
    return 1
  fi
  return 0
}

_disk_settle() {
  # Give udev and the kernel time to publish or withdraw the partition nodes.
  if [[ "$DRY_RUN" == "yes" ]]; then
    return 0
  fi
  if have udevadm; then
    udevadm settle --timeout=15 >/dev/null 2>&1 || true
  fi
}

disk_wipe() {
  # Signatures first, then both GPT headers. wipefs alone leaves the backup
  # header at the end of the disk, and a stale backup header is what makes a
  # freshly partitioned disk come back with yesterday's table.
  # Args: $1 = disk name.
  local name="$1" device="/dev/$1" part
  _disk_assert_target "$device" || return 1

  log "erasing ${device}"
  while IFS= read -r part; do
    [[ -n "$part" ]] || continue
    _disk_assert_target "$part" || return 1
    run_quiet wipefs -a -- "$part" || true
  done < <(lsblk -lnpo NAME,TYPE "$device" 2>/dev/null | awk '$2 == "part" { print $1 }')

  run_quiet wipefs -a -- "$device" || true
  run_quiet sgdisk --zap-all -- "$device" || warn "sgdisk --zap-all reported an error"
  run_cmd sgdisk --clear -- "$device" >/dev/null || {
    err "could not write a fresh GPT to ${device}"
    return 1
  }
  run_quiet partprobe -- "$device" || true
  _disk_settle
  ok "${device}: GPT table created"
}

_disk_type_code() {
  # GPT type codes. The discoverable-partitions codes for / and /home let a
  # systemd-boot system mount them without an fstab entry; everything else is
  # a plain Linux filesystem, because a wrong specific code is worse than a
  # right generic one.
  case "$1" in
    "$DISK_SWAP_MOUNT") printf '8200\n' ;;
    /) printf '8304\n' ;;
    /home) printf '8302\n' ;;
    *) printf '8300\n' ;;
  esac
}

disk_partition() {
  # GPT, ESP first, then either one LVM partition or the layout's volumes as
  # plain partitions. Sizes are relative: sgdisk picks the aligned start
  # itself, so there is no sector arithmetic here to get wrong, and the last
  # partition takes 0:0 — whatever the disk actually holds.
  # Args: $1 = disk name, $2 = plan text.
  local name="$1" plan="$2" device="/dev/$1"
  local -a argv=()
  local kind vname mount mib fs dev index=1 lvm

  _disk_assert_target "$device" || return 1
  lvm="$(disk_plan_meta "$plan" lvm)"

  argv+=(-n "1:0:+$(disk_plan_rows "$plan" esp | awk -F'\t' '{ print $4 }')M"
  -t 1:EF00 -c 1:"EFI System")
  index=2

  if [[ "$lvm" == "yes" ]]; then
    argv+=(-n 2:0:0 -t 2:8E00 -c 2:"Linux LVM")
  else
    local -a rows=()
    mapfile -t rows < <(disk_plan_rows "$plan" part)
    local last=$((${#rows[@]} - 1)) i
    for i in "${!rows[@]}"; do
      IFS=$'\t' read -r kind vname mount mib fs dev <<<"${rows[i]}"
      if ((i == last)); then
        argv+=(-n "${index}:0:0")
      else
        argv+=(-n "${index}:0:+${mib}M")
      fi
      argv+=(-t "${index}:$(_disk_type_code "$mount")" -c "${index}:${vname}")
      index=$((index + 1))
    done
  fi

  log "creating the partition table on ${device}"
  if ! run_cmd sgdisk "${argv[@]}" -- "$device" >/dev/null; then
    err "sgdisk failed on ${device}"
    err "       the disk may be busy, or the table may be larger than the disk"
    err "       sgdisk -p ${device} shows what is there now"
    err "       example:  --steps 20"
    return 1
  fi
  run_quiet partprobe -- "$device" || true
  _disk_settle

  if [[ "$DRY_RUN" == "yes" ]]; then
    return 0
  fi
  local expected
  expected="$(disk_partition_device "$name" 1)"
  if [[ ! -b "$expected" ]]; then
    err "Partitions did not appear on ${device}"
    err "       expected ${expected} after partprobe and udevadm settle"
    err "       something else is holding the disk open"
    err "       example:  lsof +D /dev; dmsetup info -c"
    return 1
  fi
  ok "${device}: $((index - 1)) partition(s) created"
}

# --------------------------------------------------------------------------- #
#  LVM                                                                        #
# --------------------------------------------------------------------------- #
disk_pv_device() {
  # Where the volume group goes. Step 30 owns LUKS; this module only notices
  # that a container of the configured name is already open and builds on it
  # instead of on the raw partition.
  # Args: $1 = plan text. A returned value.
  local plan="$1" mapper part
  part="$(disk_plan_rows "$plan" part | awk -F'\t' '$5 == "lvm" { print $6; exit }')"
  mapper="/dev/mapper/${CFG[disk_crypt_name]:-gentoo}"
  if [[ -b "$mapper" ]]; then
    printf '%s\n' "$mapper"
  else
    printf '%s\n' "$part"
  fi
}

disk_create_volumes() {
  # Physical volume, volume group, then the logical volumes in plan order.
  # The volume that takes what is left is created last with 100%FREE, so the
  # rounding of every extent above it lands inside it instead of failing it.
  # Args: $1 = plan text.
  local plan="$1" pv vg
  local kind name mount mib fs dev
  local -a rows=()

  vg="$(disk_plan_meta "$plan" vg)"
  pv="$(disk_pv_device "$plan")"
  if [[ -z "$pv" ]]; then
    err "internal: the plan declares LVM but names no physical volume"
    return 1
  fi
  _disk_assert_target "$pv" || return 1

  log "creating the physical volume on ${pv}"
  if ! run_quiet pvcreate -ff -y -- "$pv"; then
    err "pvcreate failed on ${pv}"
    err "       something still holds it; step 20 releases holders before this"
    err "       example:  vgchange -an ${vg}"
    return 1
  fi
  if ! run_quiet vgcreate -- "$vg" "$pv"; then
    err "vgcreate ${vg} failed on ${pv}"
    err "       a volume group of that name may already exist"
    err "       vgs lists them; vgremove ${vg} removes one"
    err "       example:  disk_vg = vg1"
    return 1
  fi
  ok "volume group ${vg} created on ${pv}"

  mapfile -t rows < <(disk_plan_rows "$plan" lv)
  local last=$((${#rows[@]} - 1)) i has_free
  has_free="$(disk_plan_rows "$plan" free | wc -l)"

  for i in "${!rows[@]}"; do
    IFS=$'\t' read -r kind name mount mib fs dev <<<"${rows[i]}"
    if ((i == last)) && ((has_free == 0)); then
      log "  lvcreate ${vg}/${name} — every remaining extent"
      if ! run_quiet lvcreate --yes -l 100%FREE -n "$name" "$vg"; then
        err "lvcreate failed for ${vg}/${name}"
        return 1
      fi
    else
      log "  lvcreate ${vg}/${name} — $(disk_human_size "$mib")"
      if ! run_quiet lvcreate --yes -L "${mib}m" -n "$name" "$vg"; then
        err "lvcreate failed for ${vg}/${name} ($(disk_human_size "$mib"))"
        err "       the group holds $(vgs --noheadings --nosuffix --units m -o vg_free "$vg" 2>/dev/null | tr -d ' ' || printf '?')  MiB free"
        err "       the plan was computed against the disk, not the group"
        err "       example:  --layout minimal"
        return 1
      fi
    fi
  done
  run_quiet vgchange --available y "$vg" || true
  _disk_settle
  ok "${#rows[@]} logical volume(s) in ${vg}"
}

# --------------------------------------------------------------------------- #
#  Filesystems                                                                #
# --------------------------------------------------------------------------- #
_disk_label() {
  # Filesystem labels have different limits and a too-long one is a hard
  # error on xfs and a silent truncation on ext4. Cut it here, once.
  local name="$1" fs="$2" limit=16
  case "$fs" in
    vfat) limit=11 ;;
    xfs) limit=12 ;;
    ext4 | ext3 | ext2) limit=16 ;;
    *) limit=32 ;;
  esac
  if [[ "$fs" == "vfat" ]]; then
    name="${name^^}"
  fi
  printf '%s\n' "${name:0:limit}"
}

_disk_mkfs() {
  # One filesystem. Args: $1 = device, $2 = fs, $3 = volume name, $4 = mount.
  local dev="$1" fs="$2" name="$3" mount="$4" label
  _disk_assert_target "$dev" || return 1
  label="$(_disk_label "$name" "$fs")"

  case "$fs" in
    swap)
      log "  mkswap ${dev}"
      run_quiet mkswap -L "$(_disk_label "$name" ext4)" -- "$dev" || {
        err "mkswap failed on ${dev}"
        return 1
      }
      return 0
      ;;
    vfat)
      log "  mkfs.vfat -F 32 ${dev}"
      run_quiet mkfs.vfat -F 32 -n "$label" -- "$dev" || {
        err "mkfs.vfat failed on ${dev}"
        return 1
      }
      return 0
      ;;
    ext4 | ext3 | ext2)
      # The 5% reserve exists so that a full filesystem still leaves root a way
      # to log in and clean up. That argument is about the root filesystem; on
      # /home or /var/log it is a few gibibytes of nothing.
      local -a opts=(-q -F -L "$label")
      if [[ "$mount" != "/" ]]; then
        opts+=(-m 1)
      fi
      log "  mkfs.${fs} ${dev} (${mount})"
      run_quiet "mkfs.${fs}" "${opts[@]}" -- "$dev" || {
        err "mkfs.${fs} failed on ${dev}"
        return 1
      }
      return 0
      ;;
    xfs)
      log "  mkfs.xfs ${dev} (${mount})"
      run_quiet mkfs.xfs -q -f -L "$label" -- "$dev" || {
        err "mkfs.xfs failed on ${dev}"
        return 1
      }
      return 0
      ;;
    btrfs)
      log "  mkfs.btrfs ${dev} (${mount})"
      run_quiet mkfs.btrfs -q -f -L "$label" -- "$dev" || {
        err "mkfs.btrfs failed on ${dev}"
        return 1
      }
      return 0
      ;;
    f2fs)
      log "  mkfs.f2fs ${dev} (${mount})"
      run_quiet mkfs.f2fs -q -f -l "$label" "$dev" || {
        err "mkfs.f2fs failed on ${dev}"
        return 1
      }
      return 0
      ;;
    *)
      err "internal: no mkfs known for ${fs}"
      return 1
      ;;
  esac
}

disk_format() {
  # Every volume in the plan, in plan order. Args: $1 = plan text.
  local plan="$1" kind name mount mib fs dev count=0
  log "creating filesystems"
  while IFS=$'\t' read -r kind name mount mib fs dev; do
    [[ -n "$fs" && "$fs" != "lvm" ]] || continue
    _disk_mkfs "$dev" "$fs" "$name" "$mount" || return 1
    count=$((count + 1))
  done < <(disk_plan_rows "$plan" volume)
  ok "${count} filesystem(s) created"
}

# --------------------------------------------------------------------------- #
#  Mounting                                                                   #
# --------------------------------------------------------------------------- #
_disk_mount_order() {
  # Mountpoints shallowest first, so /var exists before /var/log is mounted on
  # it. Sorting the strings alone puts /var/log before /var-something and is
  # right by accident; sorting on depth first is right on purpose.
  # Args: $1 = plan text.
  awk -F'\t' '
    ($1 == "esp" || $1 == "part" || $1 == "lv") && $3 != "-" && $3 != "swap" {
      d = gsub("/", "/", $3)
      print d "\t" $3 "\t" $6 "\t" $5
    }' <<<"$1" | sort -k1,1n -k2,2
}

disk_mount_tree() {
  # Mount the target tree, idempotently: a mountpoint that already carries the
  # right device is reported, not mounted twice.
  # Args: $1 = plan text.
  local plan="$1" root mount dev fs current
  root="$(disk_plan_meta "$plan" mountpoint)"

  log "mounting the target tree under ${root}"
  run_cmd mkdir -p -- "$root" || return 1

  while IFS=$'\t' read -r _ mount dev fs; do
    [[ -n "$mount" ]] || continue
    local target="${root%/}${mount}"
    if [[ "$mount" == "/" ]]; then
      target="$root"
    fi
    run_cmd mkdir -p -- "$target" || return 1
    if [[ "$DRY_RUN" != "yes" ]] && mountpoint -q -- "$target" 2>/dev/null; then
      current="$(findmnt -no SOURCE --target "$target" 2>/dev/null || true)"
      if [[ "$(readlink -f -- "$current" 2>/dev/null || true)" == "$(readlink -f -- "$dev" 2>/dev/null || true)" ]]; then
        skip "  ${target} already carries ${dev}"
        continue
      fi
      err "${target} is already mounted, from ${current}"
      err "       gentoo-install will not stack a mount on top of somebody else's"
      err "       unmount it and run step 20 again"
      err "       example:  umount ${target}"
      return 1
    fi
    log "  ${target} <- ${dev} (${fs})"
    if ! run_cmd mount -- "$dev" "$target"; then
      err "could not mount ${dev} on ${target}"
      return 1
    fi
    track_mount "$target"
  done < <(_disk_mount_order "$plan")

  local swap_dev
  while IFS=$'\t' read -r _ _ _ _ _ swap_dev; do
    [[ -n "$swap_dev" ]] || continue
    if [[ "$DRY_RUN" != "yes" ]] && swapon --show=NAME --noheadings 2>/dev/null \
      | grep -qx -- "$(readlink -f -- "$swap_dev" 2>/dev/null || printf '%s' "$swap_dev")"; then
      skip "  swap already active on ${swap_dev}"
      continue
    fi
    log "  swapon ${swap_dev}"
    run_cmd swapon -- "$swap_dev" || warn "swapon ${swap_dev} failed; carrying on without swap"
  done < <(disk_plan_rows "$plan" volume | awk -F'\t' '$5 == "swap"')

  ok "target tree mounted under ${root}"
}

disk_teardown() {
  # Undo a mounted tree so the disk can be provisioned again. Reports on the
  # final state, not on what was attempted: a lazy unmount followed by two
  # failures is not a successful teardown.
  # Args: $1 = plan text.
  local plan="$1" root vg dev left=0
  root="$(disk_plan_meta "$plan" mountpoint)"
  vg="$(disk_plan_meta "$plan" vg)"

  if mountpoint -q -- "$root" 2>/dev/null; then
    if run_quiet umount -R -- "$root"; then
      ok "unmounted ${root}"
    else
      warn "${root} is busy; unmounting lazily"
      run_quiet umount -Rl -- "$root" || err "could not unmount ${root}"
    fi
  else
    skip "${root} is not mounted"
  fi

  while IFS=$'\t' read -r _ _ _ _ _ dev; do
    [[ -n "$dev" ]] || continue
    run_quiet swapoff -- "$dev" || true
  done < <(disk_plan_rows "$plan" volume | awk -F'\t' '$5 == "swap"')

  if [[ "$(disk_plan_meta "$plan" lvm)" == "yes" ]] && vgs "$vg" >/dev/null 2>&1; then
    run_quiet vgchange -an "$vg" || warn "vgchange -an ${vg} failed"
  fi

  if mountpoint -q -- "$root" 2>/dev/null; then
    err "${root} is still mounted"
    left=$((left + 1))
  fi
  if [[ "$(disk_plan_meta "$plan" lvm)" == "yes" ]] \
    && vgs "$vg" -o vg_attr --noheadings 2>/dev/null | grep -q 'a'; then
    warn "volume group ${vg} is still active"
  fi
  ((left == 0)) || return 1
  return 0
}

# --------------------------------------------------------------------------- #
#  Verification and hand-over                                                 #
# --------------------------------------------------------------------------- #
disk_verify() {
  # Nothing is claimed that has not been checked. Args: $1 = plan text.
  local plan="$1" root mount dev fs problems=0 seen
  root="$(disk_plan_meta "$plan" mountpoint)"

  if [[ "$DRY_RUN" == "yes" ]]; then
    skip "dry run: nothing to verify"
    return 0
  fi

  while IFS=$'\t' read -r _ mount dev fs; do
    local target="${root%/}${mount}"
    if [[ "$mount" == "/" ]]; then
      target="$root"
    fi
    if [[ ! -b "$dev" ]]; then
      err "missing device: ${dev}"
      problems=$((problems + 1))
      continue
    fi
    if ! mountpoint -q -- "$target" 2>/dev/null; then
      err "not mounted: ${target}"
      problems=$((problems + 1))
      continue
    fi
    seen="$(lsblk -no FSTYPE "$dev" 2>/dev/null | head -n 1 | tr -d ' ')"
    if [[ -n "$seen" && "$seen" != "$fs" ]]; then
      err "${dev} carries ${seen}, the plan says ${fs}"
      problems=$((problems + 1))
    fi
  done < <(_disk_mount_order "$plan")

  if ((problems > 0)); then
    err "disk verification failed: ${problems} problem(s)"
    err "       findmnt -R ${root} shows the tree as it is"
    err "       lsblk -f $(disk_plan_meta "$plan" device) shows the disk"
    err "       example:  --steps 20 --restart"
    return 1
  fi
  ok "disk verification passed"
}

disk_fstab_records() {
  # What step 90 needs to write an fstab, on stdout (a returned value):
  # spec, mountpoint, type, options, dump, pass — already in mount order, and
  # by UUID, because a device name is not stable across a reboot.
  # Args: $1 = plan text.
  local plan="$1" mount dev fs uuid opts dump pass
  while IFS=$'\t' read -r _ mount dev fs; do
    uuid="$(blkid -s UUID -o value -- "$dev" 2>/dev/null || true)"
    case "$fs" in
      vfat) opts="defaults,umask=0077,shortname=winnt" ;;
      btrfs) opts="defaults,compress=zstd:3,noatime" ;;
      xfs) opts="defaults,noatime" ;;
      *) opts="defaults,noatime" ;;
    esac
    dump=0
    pass=2
    if [[ "$mount" == "/" ]]; then pass=1; fi
    if [[ "$fs" == "vfat" ]]; then pass=2; fi
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
      "${uuid:+UUID=}${uuid:-$dev}" "$mount" "$fs" "$opts" "$dump" "$pass"
  done < <(_disk_mount_order "$plan")

  local swap_dev
  while IFS=$'\t' read -r _ _ _ _ _ swap_dev; do
    [[ -n "$swap_dev" ]] || continue
    uuid="$(blkid -s UUID -o value -- "$swap_dev" 2>/dev/null || true)"
    printf '%s\tnone\tswap\tsw\t0\t0\n' "${uuid:+UUID=}${uuid:-$swap_dev}"
  done < <(disk_plan_rows "$plan" volume | awk -F'\t' '$5 == "swap"')
}

disk_show_result() {
  # The disk as it now is, straight from lsblk, so the operator compares it
  # with the plan they approved rather than with a claim this file makes.
  # Args: $1 = plan text.
  local plan="$1" line root
  root="$(disk_plan_meta "$plan" mountpoint)"
  log "$(disk_plan_meta "$plan" device) after provisioning (lsblk -f):"
  while IFS= read -r line; do
    log "       | ${line}"
  done < <(lsblk -f -o NAME,FSTYPE,LABEL,SIZE,MOUNTPOINTS "$(disk_plan_meta "$plan" device)" 2>/dev/null || true)
  log "target tree (findmnt):"
  while IFS= read -r line; do
    log "       | ${line}"
  done < <(findmnt -R -o TARGET,SOURCE,FSTYPE,SIZE "$root" 2>/dev/null || true)
}
