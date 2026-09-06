#!/usr/bin/env bash
#
# gentoo-install — step 90: system configuration inside the target tree
# ----------------------------------------------------------------------------
# Timezone, locales, console keymap, hostname, /etc/hosts, fstab, the root
# password, the groups and the accounts this machine is to have, the privilege
# each account is granted, an optional lock on root, a network service that
# matches the init system, an optional hardened sshd, and the services those
# choices imply.
#
# Three rules hold everywhere in this file. Every mount in fstab is named by
# UUID, never by /dev/sdX, because the kernel is free to renumber disks between
# boots. And fstab is written, then handed to findmnt --verify, then rolled
# back if findmnt objects: a broken fstab is a machine that does not boot, and
# it is the one file here with a checker good enough to catch that beforehand.
# And root is never locked until another account has been shown to escalate and
# to be able to log in: that proof is a proof, so --force does not lift it.
#
# The target tree is never "/". Step 90 configures the system being installed,
# not the one running the installer, and it refuses to confuse the two.
#
# Usage:  sourced by gentoo-install.sh, which calls step_90_system()
#
set -euo pipefail

if [[ -n "${_GI_STEP_90_LOADED:-}" ]]; then
  return 0
fi
_GI_STEP_90_LOADED=1

# The entry point sources the libraries before this file, so these guards never
# fire in production. They exist so that shellcheck and a standalone source of
# this file both see the same definitions the runner does.
_gi_step90_lib="${GI_LIB_DIR:-${BASH_SOURCE[0]%/*}/../lib}"
if [[ -z "${_GI_CORE_LOADED:-}" ]]; then
  # shellcheck source=lib/core.sh
  source "${_gi_step90_lib}/core.sh"
fi
if [[ -z "${_GI_CONFIG_LOADED:-}" ]]; then
  # shellcheck source=lib/config.sh
  source "${_gi_step90_lib}/config.sh"
fi
if [[ -z "${_GI_STATE_LOADED:-}" ]]; then
  # shellcheck source=lib/state.sh
  source "${_gi_step90_lib}/state.sh"
fi
if [[ -z "${_GI_UI_LOADED:-}" ]]; then
  # shellcheck source=lib/ui.sh
  source "${_gi_step90_lib}/ui.sh"
fi
unset _gi_step90_lib

# Set by _sys_fstab_validate so that the reason findmnt refused survives the
# >/dev/null 2>&1 that write_validated runs its validator under.
_SYS_FSTAB_DIAG=""

# Counted, so the step can report "6 of 11 parts changed something".
_SYS_CHANGED=0
_SYS_TODO_N=0

# --------------------------------------------------------------------------- #
#  Reading the configuration                                                  #
# --------------------------------------------------------------------------- #
_sys_cfg_first() {
  # First non-empty value among a list of CFG keys. Prints on stdout.
  local key
  for key in "$@"; do
    if [[ -n "${CFG[$key]:-}" ]]; then
      printf '%s\n' "${CFG[$key]}"
      return 0
    fi
  done
  return 1
}

_sys_cfg() {
  # Args: $1 = fallback, $2.. = candidate CFG keys.
  local fallback="$1"
  shift
  _sys_cfg_first "$@" 2>/dev/null || printf '%s\n' "$fallback"
}

_sys_root() {
  # Where the target system is mounted. GI_ROOT exists so that this step can be
  # exercised against a throwaway tree without a flag that only tests would use.
  local root
  root="$(_sys_cfg "${GI_ROOT:-/mnt/gentoo}" root chroot_dir target_root)"
  root="${root%/}"
  printf '%s\n' "${root:-/}"
}

_sys_init() {
  printf '%s\n' "${CFG[init]:-openrc}"
}

_sys_target_has() {
  # Args: $1 = root, $2 = absolute path inside the target.
  [[ -x "${1}${2}" ]]
}

_sys_todo() {
  # One thing the operator still has to do by hand. Recorded in the journal so
  # that step 95 can list them even after a --resume, and echoed as a warning
  # so that an operator watching this run sees it immediately.
  _SYS_TODO_N=$((_SYS_TODO_N + 1))
  warn "to do by hand: $*"
  [[ -n "${STATE_FILE:-}" ]] || return 0
  state_set "system.todo.${_SYS_TODO_N}" "$*" || true
}

_sys_record() {
  # Args: $1 = key suffix, $2 = value. Never a secret: state.sh refuses those,
  # and nothing here ever offers one.
  [[ -n "${STATE_FILE:-}" ]] || return 0
  state_set "system.${1}" "$2" || true
}

_sys_note_change() {
  if [[ "$WRITE_RESULT" == "written" ]]; then
    _SYS_CHANGED=$((_SYS_CHANGED + 1))
  fi
}

_sys_in_chroot() {
  # Args: $1 = root, $2.. = argv. Never runs against "/", which step_90_system
  # has already refused, and never in --dry-run, which run_cmd handles.
  local root="$1"
  shift
  run_cmd chroot "$root" "$@"
}

# --------------------------------------------------------------------------- #
#  fstab — the engine half: it returns a record and says nothing (§7)          #
# --------------------------------------------------------------------------- #
_sys_uuid_of() {
  # Filesystem UUID of a device. Works on /dev/mapper/* too, which is what a
  # LUKS-backed root looks like once step 30 has opened it: the UUID belongs to
  # the filesystem inside the container, so it is stable across reboots.
  local dev="$1" uuid
  uuid="$(blkid -s UUID -o value -- "$dev" 2>/dev/null || true)"
  [[ -n "$uuid" ]] || return 1
  printf '%s\n' "$uuid"
}

_sys_fstab_options() {
  # Args: $1 = fstype, $2 = target inside the target system, $3 = live options.
  # Curated, not copied: findmnt reports the kernel's effective option list,
  # which is thirty entries long and mostly defaults. What must survive is the
  # handful that change where or how the filesystem is mounted.
  local fstype="$1" target="$2" live="$3" subvol=""

  case "$fstype" in
    vfat | fat | msdos)
      # An ESP holds the bootloader and, on an encrypted machine, sometimes a
      # key file. Nothing but root has any business reading it.
      case "$target" in
        /boot | /efi | /boot/efi)
          printf 'defaults,noatime,fmask=0077,dmask=0077\n'
          ;;
        *) printf 'defaults,noatime\n' ;;
      esac
      ;;
    btrfs)
      # Losing subvol= here boots the wrong subvolume, silently.
      subvol="$(printf '%s' "$live" | tr ',' '\n' \
        | grep -m1 -E '^subvol(id)?=' || true)"
      printf 'defaults,noatime%s\n' "${subvol:+,${subvol}}"
      ;;
    ext2 | ext3 | ext4 | xfs | f2fs)
      printf 'defaults,noatime\n'
      ;;
    *)
      printf 'defaults\n'
      ;;
  esac
}

_sys_fstab_pass() {
  # Args: $1 = fstype, $2 = target. The sixth field: fsck order at boot.
  local fstype="$1" target="$2"
  if [[ "$target" == "/" ]]; then
    printf '1\n'
    return 0
  fi
  case "$fstype" in
    ext2 | ext3 | ext4 | vfat | fat | msdos | f2fs) printf '2\n' ;;
    *) printf '0\n' ;; # btrfs and xfs check themselves; nothing else is checked
  esac
}

_sys_fstab_render() {
  # Print the fstab this machine's partitions call for. Reads the kernel's own
  # mount table, which is the only description of what step 20 actually built
  # that cannot have drifted from it. Returns 1 when nothing is mounted at the
  # target: that means step 20 or step 50 has not run.
  # Args: $1 = root.
  local root="$1"
  local target source fstype live uuid opts pass rows=0 swap_seen=0
  local disk_base="" swap_dev swap_type parent

  if ! have findmnt; then
    err "findmnt is not installed, so the mounted layout cannot be read"
    err "       it comes with sys-apps/util-linux, which the install medium has"
    return 1
  fi

  disk_base="$(_sys_cfg "" disk target_disk device)"
  disk_base="${disk_base##*/}"

  {
    printf '# /etc/fstab — generated by gentoo-install\n'
    printf '#\n'
    printf '# Every filesystem is named by UUID. A kernel is free to call the same\n'
    printf '# disk /dev/sda on one boot and /dev/sdb on the next, and an fstab that\n'
    printf '# says /dev/sda then mounts something else or nothing at all.\n'
    printf '#\n'
    printf '# Regenerate with:  gentoo-install.sh --steps 90\n'
    printf '#\n'
    printf '# %-42s %-14s %-8s %-34s %s %s\n' \
      '<device>' '<mountpoint>' '<type>' '<options>' 'dump' 'pass'
  }

  # findmnt --raw separates columns with a single space, not a tab, and escapes
  # any space inside a path as \x20 — which is precisely what makes splitting
  # on space safe here. Reading with IFS=$'\t' put the whole line into $target:
  # the /boot line then failed with an empty source, and the root line was
  # dropped in silence by the leading-slash test below, so a generated fstab
  # had no root filesystem in it at all.
  while IFS=' ' read -r target source fstype live; do
    [[ -n "$target" ]] || continue
    # findmnt escapes spaces and tabs in paths as \x20 / \011; undo that here
    # so the comparison below sees the real path.
    target="${target//\\x20/ }"

    # /mnt/gentoo -> /, /mnt/gentoo/boot -> /boot.
    if [[ "$target" == "$root" ]]; then
      target="/"
    else
      target="${target#"$root"}"
    fi
    [[ "${target:0:1}" == "/" ]] || continue

    # Only a filesystem the installed machine will mount from a block device
    # belongs in its fstab. Step 50 binds /proc, /sys, /dev and /run into the
    # target so the chroot works, and findmnt --real still reports devtmpfs
    # among them; none of that is the new system's business. The test is on the
    # source being a block device rather than on a list of type names, so a
    # block device that genuinely has no UUID still raises the error below.
    [[ -b "$source" ]] || continue

    if ! uuid="$(_sys_uuid_of "$source")"; then
      err "no UUID for ${source} (mounted at ${target})"
      err "       every fstab line this project writes is a UUID, and there is"
      err "       no UUID to write for this one"
      err "       blkid -p ${source}"
      return 1
    fi

    opts="$(_sys_fstab_options "$fstype" "$target" "$live")"
    pass="$(_sys_fstab_pass "$fstype" "$target")"
    printf 'UUID=%-37s %-14s %-8s %-34s %s %s\n' \
      "$uuid" "$target" "$fstype" "$opts" 0 "$pass"
    rows=$((rows + 1))
  done < <(findmnt --real -nr -o TARGET,SOURCE,FSTYPE,OPTIONS -R -- "$root" 2>/dev/null \
    | sort -k1,1)

  if ((rows == 0)); then
    err "nothing is mounted under ${root}"
    err "       fstab is generated from the layout step 20 built and step 50"
    err "       mounted, so there is nothing to describe yet"
    err "       findmnt -R ${root}"
    return 1
  fi

  # Swap: active swap that belongs to the target disk, or a swap file inside
  # the target tree. Anything else is the live medium's and is not ours to
  # write into the installed system's fstab.
  if [[ -r /proc/swaps ]]; then
    while read -r swap_dev swap_type _; do
      [[ "${swap_dev:0:1}" == "/" ]] || continue
      case "$swap_type" in
        partition)
          parent="$(lsblk -no PKNAME -- "$swap_dev" 2>/dev/null | head -n 1 || true)"
          [[ -n "$disk_base" && "$parent" == "$disk_base" ]] || continue
          uuid="$(_sys_uuid_of "$swap_dev")" || continue
          if ((swap_seen == 0)); then
            printf '\n'
            swap_seen=1
          fi
          printf 'UUID=%-37s %-14s %-8s %-34s %s %s\n' \
            "$uuid" "none" "swap" "sw" 0 0
          ;;
        file)
          [[ "$swap_dev" == "${root}/"* ]] || continue
          if ((swap_seen == 0)); then
            printf '\n'
            swap_seen=1
          fi
          # A swap file has no UUID of its own: it is named by its path inside
          # the installed system, which is the one exception to the UUID rule.
          printf '%-42s %-14s %-8s %-34s %s %s\n' \
            "${swap_dev#"$root"}" "none" "swap" "sw" 0 0
          ;;
      esac
    done < <(tail -n +2 /proc/swaps 2>/dev/null || true)
  fi

  return 0
}

# --------------------------------------------------------------------------- #
#  fstab — the checker                                                        #
# --------------------------------------------------------------------------- #
_sys_fstab_shape_check() {
  # The fallback when findmnt is absent: six fields, a source this project is
  # willing to write, an absolute target. Weaker than findmnt --verify and it
  # says so; better than writing an unread file.
  local file="$1" lineno=0 bad=0 line
  local f1 f2 f3 f4 f5 f6 extra
  _SYS_FSTAB_DIAG=""
  while IFS= read -r line; do
    lineno=$((lineno + 1))
    [[ -n "${line//[[:space:]]/}" ]] || continue
    [[ "${line#"${line%%[![:space:]]*}"}" != '#'* ]] || continue
    # shellcheck disable=SC2086  # deliberate word splitting: fstab is columns
    set -- $line
    # shellcheck disable=SC2034  # f4 is the options column: captured so the
    # mapping stays readable, deliberately not validated here.
    f1="${1:-}" f2="${2:-}" f3="${3:-}" f4="${4:-}" f5="${5:-}" f6="${6:-}" extra="${7:-}"
    if [[ -z "$f6" || -n "$extra" ]]; then
      _SYS_FSTAB_DIAG+="line ${lineno}: expected exactly six fields"$'\n'
      bad=1
      continue
    fi
    if [[ "$f1" != UUID=* && "${f1:0:1}" != "/" ]]; then
      _SYS_FSTAB_DIAG+="line ${lineno}: source '${f1}' is neither UUID= nor an absolute path"$'\n'
      bad=1
    fi
    if [[ "${f2:0:1}" != "/" && "$f2" != "none" ]]; then
      _SYS_FSTAB_DIAG+="line ${lineno}: target '${f2}' is not absolute"$'\n'
      bad=1
    fi
    if [[ -z "$f3" ]]; then
      _SYS_FSTAB_DIAG+="line ${lineno}: no filesystem type"$'\n'
      bad=1
    fi
    if [[ ! "$f5" =~ ^[0-9]+$ || ! "$f6" =~ ^[0-9]+$ ]]; then
      _SYS_FSTAB_DIAG+="line ${lineno}: dump and pass must be numbers, got '${f5}' '${f6}'"$'\n'
      bad=1
    fi
  done <"$file"
  return "$bad"
}

_sys_fstab_validate() {
  # The validator write_validated hands the freshly written file to. It runs
  # under >/dev/null 2>&1, so what findmnt said is kept in _SYS_FSTAB_DIAG for
  # the caller to print.
  # Args: $1 = fstab path, $2 = root.
  local file="$1" root="$2" tmp rc=0

  if ! have findmnt; then
    warn "findmnt is absent: fstab gets the shape check, not findmnt --verify"
    _sys_fstab_shape_check "$file"
    return $?
  fi

  # The fstab describes the machine after it boots, where / is /. findmnt is
  # being asked about it now, where / is still the live medium and the target
  # tree hangs off ${root}. Re-anchoring the paths is what makes the answer
  # mean something: "does every UUID resolve, and does every mountpoint exist".
  tmp="$(make_temp)"
  awk -v r="$root" '
    /^[[:space:]]*(#|$)/ { print; next }
    NF >= 2 {
      if ($2 == "/")            { $2 = r "/" }
      else if ($2 ~ /^\//)      { $2 = r $2 }
      if ($1 ~ /^\//)           { $1 = r $1 }
      print
      next
    }
    { print }
  ' "$file" >"$tmp"

  _SYS_FSTAB_DIAG="$(LC_ALL=C findmnt --verify --tab-file "$tmp" 2>&1)" || rc=$?
  return "$rc"
}

_sys_fstab_check_against_plan() {
  # The mount table says what is mounted; the plan says what step 20 built.
  # When they disagree, the fstab is written from the first and the bootloader
  # is installed against the second, and nobody says a word.
  #
  # That is not hypothetical. A target reattached by hand had its ESP mounted at
  # /boot/efi while the plan said /boot: step 90 wrote /boot/efi into the fstab,
  # step 80 asked grub-install for /boot, and grub answered "/boot doesn't look
  # like an EFI partition" — a message about the ESP, produced by a
  # disagreement two steps earlier.
  #
  # A warning and not a refusal: what is mounted is what the machine has, and an
  # operator who mounted less than the plan describes may have meant to.
  # Args: $1 = the rendered fstab body.
  local body="$1" plan mount kind name dev fs absent=""

  declare -F disk_saved_plan >/dev/null 2>&1 || return 0
  plan="$(disk_saved_plan)" || return 0

  while IFS=$'\t' read -r kind name mount _ fs dev; do
    [[ -n "$mount" && "$mount" == /* ]] || continue
    [[ "$fs" != "swap" && "$fs" != "lvm" ]] || continue
    if ! awk -v m="$mount" '$1 !~ /^#/ && $2 == m { found = 1 } END { exit !found }' \
      <<<"$body"; then
      absent+="  ${mount} (${kind} ${name}, ${dev})"$'\n'
    fi
  done < <(disk_plan_rows "$plan" volume)

  [[ -n "$absent" ]] || return 0

  warn "the fstab does not carry every mountpoint the disk plan describes:"
  printf '%s' "$absent" | while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    warn "     ${line}"
  done
  warn "       the fstab is written from what is mounted now, and the bootloader"
  warn "       is installed against the plan — a machine built from both would"
  warn "       look for its kernel somewhere its fstab never mounts"
  warn "       mount what is missing and run this step again, or --restart if"
  warn "       the plan is the stale one"
}

_sys_fstab() {
  # Args: $1 = root.
  local root="$1"
  # Split: in one local, ${root} expands empty and this would name the
  # HOST /etc/fstab instead of the target one (SC2318).
  local fstab="${root}/etc/fstab" body line

  log "fstab: reading the layout from the kernel's mount table"
  if ! body="$(_sys_fstab_render "$root")"; then
    return 1
  fi

  _sys_fstab_check_against_plan "$body"

  if [[ "$DRY_RUN" == "yes" ]]; then
    log "dry-run: ${fstab} would be:"
    printf '%s\n' "$body" | sed 's/^/       | /' >&2
    log "dry-run: then validated with findmnt --verify"
    return 0
  fi

  if write_validated "$fstab" _sys_fstab_validate "$fstab" "$root" <<<"$body"; then
    _sys_note_change
    _sys_record fstab "${WRITE_RESULT}"
    return 0
  fi

  err "fstab was rejected and the previous content has been put back."
  err "       findmnt --verify said:"
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    err "       ${line}"
  done <<<"$_SYS_FSTAB_DIAG"
  err "       nothing was left half-written: an fstab that does not verify is a"
  err "       machine that stops in the initramfs, and that is not recoverable"
  err "       from the installed system"
  err "       findmnt -R ${root}"
  _sys_record fstab "rejected"
  return 1
}

# --------------------------------------------------------------------------- #
#  Timezone                                                                   #
# --------------------------------------------------------------------------- #
_sys_timezone() {
  local root="$1" tz
  tz="$(_sys_cfg "UTC" timezone tz)"

  if [[ ! -e "${root}/usr/share/zoneinfo/${tz}" && "$DRY_RUN" != "yes" ]]; then
    err "Unknown timezone: ${tz}"
    err "       it must name a file under ${root}/usr/share/zoneinfo"
    err "       example:  Europe/Paris, America/New_York, UTC"
    err "       ls ${root}/usr/share/zoneinfo"
    return 1
  fi

  # A relative symlink, so it means the same thing inside the chroot, inside
  # the installed system and from here.
  run_cmd ln -sfn "../usr/share/zoneinfo/${tz}" "${root}/etc/localtime" || return 1
  write_file "${root}/etc/timezone" <<<"$tz" || return 1
  _sys_note_change
  _sys_record timezone "$tz"
}

# --------------------------------------------------------------------------- #
#  Locales                                                                    #
# --------------------------------------------------------------------------- #
_sys_locale_lines() {
  # One "<locale> <charmap>" per line. CFG[locale] is a comma-separated list
  # of full entries; CFG[locale] names the one that becomes LANG.
  local primary="$1" extra entry
  extra="$(_sys_cfg "" locales)"
  printf 'C.UTF-8 UTF-8\n'
  printf '%s %s\n' "$primary" "${primary##*.}"
  if [[ -n "$extra" ]]; then
    while IFS= read -r entry; do
      entry="${entry#"${entry%%[![:space:]]*}"}"
      entry="${entry%"${entry##*[![:space:]]}"}"
      [[ -n "$entry" ]] || continue
      if [[ "$entry" != *" "* ]]; then
        entry="${entry} ${entry##*.}"
      fi
      printf '%s\n' "$entry"
    done < <(printf '%s' "$extra" | tr ',' '\n')
  fi
}

_sys_locales() {
  local root="$1" locale eselect_name
  locale="$(_sys_cfg "en_US.UTF-8" locale lang)"

  write_block "${root}/etc/locale.gen" "locales" <<EOF
$(_sys_locale_lines "$locale" | sort -u)
EOF
  _sys_note_change

  if ! _sys_target_has "$root" /usr/sbin/locale-gen \
    && ! _sys_target_has "$root" /usr/bin/locale-gen; then
    if [[ "$DRY_RUN" != "yes" ]]; then
      warn "locale-gen is not in the target tree; locales were listed, not built"
      _sys_todo "chroot ${root} /bin/bash -lc 'locale-gen && eselect locale set ${locale}'"
      return 0
    fi
  fi

  _sys_in_chroot "$root" locale-gen || {
    err "locale-gen failed inside ${root}"
    err "       every entry in /etc/locale.gen must name a locale glibc knows"
    err "       chroot ${root} /bin/bash -lc 'locale-gen'"
    return 1
  }

  # eselect wants the name as `locale -a` prints it: en_US.utf8, not
  # en_US.UTF-8. It is the same locale spelled the way the tool spells it.
  eselect_name="${locale//UTF-8/utf8}"
  eselect_name="${eselect_name//utf-8/utf8}"
  if _sys_in_chroot "$root" eselect locale set "$eselect_name"; then
    ok "locale: LANG set to ${eselect_name} through eselect"
  else
    warn "eselect locale refused '${eselect_name}'; writing /etc/env.d/02locale instead"
    write_block "${root}/etc/env.d/02locale" "locale" <<EOF
LANG="${locale}"
LC_COLLATE="C.UTF-8"
EOF
    _sys_note_change
  fi
  _sys_in_chroot "$root" env-update || true
  _sys_record locale "$locale"
}

# --------------------------------------------------------------------------- #
#  Console keymap                                                             #
# --------------------------------------------------------------------------- #
_sys_keymap() {
  local root="$1" keymap init found
  keymap="$(_sys_cfg "us" keymap keyboard)"
  init="$(_sys_init)"

  if [[ -d "${root}/usr/share/keymaps" ]]; then
    found="$(find "${root}/usr/share/keymaps" -name "${keymap}.map.gz" -print -quit 2>/dev/null || true)"
    if [[ -z "$found" ]]; then
      warn "keymap '${keymap}' was not found under ${root}/usr/share/keymaps"
      warn "       the console falls back to us at boot, which is survivable but"
      warn "       surprising when the root password has a non-ASCII character"
      warn "       find ${root}/usr/share/keymaps -name '*.map.gz' | sed 's#.*/##;s#\\.map\\.gz##'"
    fi
  fi

  if [[ "$init" == "systemd" ]]; then
    write_block "${root}/etc/vconsole.conf" "keymap" <<EOF
KEYMAP="${keymap}"
EOF
  else
    write_block "${root}/etc/conf.d/keymaps" "keymap" <<EOF
keymap="${keymap}"
EOF
  fi
  _sys_note_change
  _sys_record keymap "$keymap"
}

# --------------------------------------------------------------------------- #
#  Hostname and /etc/hosts                                                    #
# --------------------------------------------------------------------------- #
_sys_hostname() {
  local root="$1" host domain fqdn init
  host="$(_sys_cfg "gentoo" hostname host)"
  domain="$(_sys_cfg "" domain domainname)"
  init="$(_sys_init)"

  if [[ ! "$host" =~ ^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?$ ]]; then
    err "Invalid hostname: ${host}"
    err "       letters, digits and hyphens; no leading or trailing hyphen"
    err "       the domain goes in its own setting, not in the hostname"
    err "       example:  hostname = workstation"
    return 1
  fi

  fqdn="$host"
  [[ -z "$domain" ]] || fqdn="${host}.${domain}"

  write_file "${root}/etc/hostname" <<<"$host" || return 1
  _sys_note_change

  # OpenRC before 0.45 reads /etc/conf.d/hostname and ignores /etc/hostname.
  # Writing both costs one marked block and removes a version dependency.
  if [[ "$init" != "systemd" ]]; then
    write_block "${root}/etc/conf.d/hostname" "hostname" <<EOF
hostname="${host}"
EOF
    _sys_note_change
  fi

  # Only the line this project owns goes in the block. The stage3 already
  # carries the localhost entries, and replacing them would be this step
  # rewriting something it did not write.
  write_block "${root}/etc/hosts" "hosts" <<EOF
127.0.0.1   localhost
::1         localhost
127.0.1.1   ${fqdn} ${host}
EOF
  _sys_note_change
  _sys_record hostname "$fqdn"
}

# --------------------------------------------------------------------------- #
#  Root password                                                              #
# --------------------------------------------------------------------------- #
_sys_root_password() {
  # The value is read straight into chpasswd's stdin. It is never an argument,
  # never a log line, never a journal entry: argv shows up in ps, and the state
  # journal refuses a key that looks like a secret in the first place.
  local root="$1" secret="" tool

  if [[ "$DRY_RUN" == "yes" ]]; then
    log "dry-run: would ask for the root password and set it with chpasswd"
    return 0
  fi

  if ! tool="$(_sys_chpasswd_path "$root")"; then
    warn "chpasswd is not in the target tree; the root password was not set"
    _sys_todo "set the root password: chroot ${root} /bin/bash -lc 'passwd root'"
    return 0
  fi

  if ! prompt_secret secret "Root password for the new system"; then
    warn "no root password was set; the account stays as the stage3 left it (locked)"
    warn "       a locked root account is safe and unusable: nothing logs in as root"
    warn "       until a password is set or a key is installed"
    _sys_todo "set the root password: chroot ${root} /bin/bash -lc 'passwd root'"
    return 0
  fi

  if printf 'root:%s\n' "$secret" | chroot "$root" "$tool"; then
    secret=""
    ok "root password set"
    _sys_record root_auth "password"
    return 0
  fi

  secret=""
  err "chpasswd refused the root password"
  err "       chroot ${root} /bin/bash -lc 'passwd root'"
  return 1
}

# --------------------------------------------------------------------------- #
#  Accounts — the record format                                               #
# --------------------------------------------------------------------------- #
# One record per account, on the model of disk_volumes (lib/disk.sh):
#
#   accounts = "alice:wheel,audio,video:/bin/bash:sudo;bob::/bin/sh:none"
#
# The fields are name:groups:shell:privilege, ';' separates records, and an
# empty field takes the default — user_groups, user_shell and privilege, which
# are the settings that described the single account this step used to create.
# accounts_file holds the same records, one per line, '#' starts a comment.
#
# Everything is checked before anything is created. useradd refuses a whole
# account over one unknown group, and an account list that is half applied is
# harder to reason about than one that was refused outright.
#
# The privilege is per account and it is never a group rule. A
# '%wheel ALL=(ALL:ALL) ALL' line also hands root to an account that asked for
# 'none' and is in wheel for its ordinary memberships; what this step writes is
# what was asked for, account by account, and nothing else.

# Filled by _sys_accounts_load, read by the four parts below. Parallel arrays,
# indexed together, like lib/disk.sh does for the volume plan.
_SYS_ACC_NAME=()
_SYS_ACC_GROUPS=()
_SYS_ACC_SHELL=()
_SYS_ACC_PRIV=()
_SYS_GRP_NAME=()
_SYS_GRP_GID=()

# "" not read yet | ok | bad. The parse runs once per step and every part that
# needs it reads the same answer, so a malformed record is reported once.
_SYS_ACC_STATE=""

_sys_priv_check() {
  # Args: $1 = value, $2 = where it was written, for the message.
  local value="$1" where="$2"
  case "$value" in
    none | sudo | sudo-nopasswd | doas | doas-nopasswd) return 0 ;;
  esac
  err "Unknown privilege in ${where}: ${value}"
  err "       sudo            sudo, after the account types its own password"
  err "       sudo-nopasswd   sudo, with no password asked, ever"
  err "       doas            doas, after the account types its own password"
  err "       doas-nopasswd   doas, with no password asked, ever"
  err "       none            nothing escalates; root logs in on the console"
  err "       example:  accounts = \"alice:wheel:/bin/bash:sudo\""
  return 1
}

_sys_nopasswd_warning() {
  # A warning, not a refusal: it is a legitimate choice for a service account
  # or for a personal machine, and it is the operator's to make knowingly.
  local name="$1" tool="$2"
  warn "${name}: ${tool} with NOPASSWD — anything running as ${name} is root"
  warn "       no secret stands between the account and the machine. A bug in a"
  warn "       browser, a hostile dependency in a build script, one stray"
  warn "       post-install hook: each of them reaches root knowing nothing that"
  warn "       ${name} knows, because there is nothing to know."
  warn "       That is a full compromise of this machine, not a lost session."
  warn "       Plain '${tool}' asks for ${name}'s own password and costs one line"
  warn "       of typing per escalation."
  warn "       example:  accounts = \"${name}:wheel:/bin/bash:${tool}\""
}

# --------------------------------------------------------------------------- #
#  What the target tree says                                                  #
# --------------------------------------------------------------------------- #
# /etc/passwd, /etc/group and /etc/shadow are read directly rather than through
# `chroot ... id`. They are the same truth id consults, they are readable
# without a chroot — which is what lets this whole path be exercised against a
# throwaway tree — and reading them works in --dry-run.
_sys_tree_readable() {
  # A target worth asking questions about: not empty, not "/", and unpacked.
  local root="$1"
  [[ -n "$root" && "$root" != "/" && -d "${root}/etc" ]]
}

_sys_group_exists() {
  local root="$1" name="$2"
  [[ -r "${root}/etc/group" ]] || return 1
  grep -q "^${name}:" "${root}/etc/group" 2>/dev/null
}

_sys_group_gid() {
  local root="$1" name="$2"
  awk -F: -v g="$name" '$1 == g { print $3; exit }' "${root}/etc/group" 2>/dev/null
}

_sys_group_planned() {
  # A group this run is about to create counts as existing. The groups part
  # runs before the accounts part for exactly this reason.
  local name="$1" i
  for ((i = 0; i < ${#_SYS_GRP_NAME[@]}; i++)); do
    [[ "${_SYS_GRP_NAME[i]}" != "$name" ]] || return 0
  done
  return 1
}

_sys_account_exists() {
  local root="$1" name="$2"
  [[ -r "${root}/etc/passwd" ]] || return 1
  grep -q "^${name}:" "${root}/etc/passwd" 2>/dev/null
}

_sys_account_has_password() {
  # A usable hash starts with '$'. '!' is locked, '*' is disabled and an empty
  # field is no password at all: none of the three is a way in. Step 95 reads
  # the same file by the same rule.
  local root="$1" name="$2"
  [[ -r "${root}/etc/shadow" ]] || return 1
  awk -F: -v u="$name" '$1 == u && $2 ~ /^\$/ { found = 1 } END { exit !found }' \
    "${root}/etc/shadow" 2>/dev/null
}

_sys_account_has_key() {
  local root="$1" name="$2"
  local file="${root}/home/${name}/.ssh/authorized_keys"
  [[ -f "$file" ]] || return 1
  grep -qE '^[[:space:]]*(ssh-|ecdsa-|sk-|ssh_)' "$file" 2>/dev/null
}

_sys_root_is_locked() {
  local root="$1" hash
  [[ -r "${root}/etc/shadow" ]] || return 1
  hash="$(awk -F: '$1 == "root" { print $2; exit }' "${root}/etc/shadow" 2>/dev/null)"
  [[ "${hash:0:1}" == "!" ]]
}

_sys_account_in_group() {
  # Primary group counts: useradd puts the account's own GID in /etc/passwd and
  # never lists it among the members of the group line.
  local root="$1" name="$2" group="$3" line gid members pgid
  line="$(grep -m1 "^${group}:" "${root}/etc/group" 2>/dev/null)" || return 1
  gid="$(printf '%s' "$line" | cut -d: -f3)"
  members="$(printf '%s' "$line" | cut -d: -f4)"
  pgid="$(awk -F: -v u="$name" '$1 == u { print $4; exit }' \
    "${root}/etc/passwd" 2>/dev/null || true)"
  [[ -z "$pgid" || "$pgid" != "$gid" ]] || return 0
  printf '%s' ",${members}," | grep -qF ",${name},"
}

_sys_account_missing_groups() {
  # The wanted groups an existing account is not in yet, comma-separated. A
  # returned value, so stdout; empty means there is nothing to complete.
  local root="$1" name="$2" wanted="$3" group
  local -a missing=()
  group=""
  # `|| [[ -n "$group" ]]` because the last item carries no trailing newline:
  # read returns 1 on it, having assigned it, and a plain `while read` would
  # drop the last group of every list.
  while IFS= read -r group || [[ -n "$group" ]]; do
    [[ -n "$group" ]] || continue
    _sys_account_in_group "$root" "$name" "$group" || missing+=("$group")
  done < <(printf '%s' "$wanted" | tr ',' '\n')
  ((${#missing[@]} > 0)) || return 0
  printf '%s\n' "$(
    IFS=,
    printf '%s' "${missing[*]}"
  )"
}

# --------------------------------------------------------------------------- #
#  Parsing                                                                    #
# --------------------------------------------------------------------------- #
_sys_groups_parse() {
  # groups = "docker;media:1500" — a name, and a GID when one is needed.
  # Args: $1 = the spec.
  local spec="$1" record name gid extra
  _SYS_GRP_NAME=()
  _SYS_GRP_GID=()
  [[ -n "$spec" ]] || return 0

  while IFS= read -r record; do
    record="${record#"${record%%[![:space:]]*}"}"
    record="${record%"${record##*[![:space:]]}"}"
    [[ -n "$record" ]] || continue

    IFS=':' read -r name gid extra <<<"$record"
    if [[ -n "${extra:-}" ]]; then
      err "Malformed group record: ${record}"
      err "       a record reads name, or name:gid, and nothing more"
      err "       ';' separates one record from the next"
      err "       example:  groups = \"docker;media:1500\""
      return 1
    fi
    if [[ ! "$name" =~ ^[a-z_][a-z0-9_-]*$ ]] || ((${#name} > 32)); then
      err "Invalid group name: ${name}"
      err "       lowercase letters, digits, underscore and hyphen, at most 32"
      err "       characters, not starting with a digit or a hyphen"
      err "       example:  groups = \"docker;media:1500\""
      return 1
    fi
    if [[ -n "$gid" && ! "$gid" =~ ^[0-9]+$ ]]; then
      err "Invalid GID for group ${name}: ${gid}"
      err "       a whole number, or nothing at all to let groupadd choose"
      err "       example:  groups = \"media:1500\""
      return 1
    fi
    _SYS_GRP_NAME+=("$name")
    _SYS_GRP_GID+=("${gid:-}")
  done < <(printf '%s\n' "${spec//;/$'\n'}")
  return 0
}

_sys_accounts_records() {
  # Every record this configuration asks for, one per line. A returned value.
  # Three sources, and the first two are joined the way disk_volumes and
  # disk_volumes_file are: accounts, then accounts_file, then — only when
  # neither is set — the single-account settings this step started with.
  local spec file legacy line
  spec="$(_sys_cfg "" accounts)"
  file="$(_sys_cfg "" accounts_file)"
  legacy="$(_sys_cfg "" user username)"

  if [[ -z "$spec" && -z "$file" ]]; then
    [[ -n "$legacy" ]] || return 0
    printf '%s:%s:%s:%s\n' "$legacy" \
      "$(_sys_cfg "" user_groups)" \
      "$(_sys_cfg "" user_shell shell)" \
      "$(_sys_cfg "" privilege privilege_tool sudo_tool)"
    return 0
  fi

  if [[ -n "$legacy" ]]; then
    warn "both 'accounts' and 'user' are set; 'accounts' wins and 'user' is ignored"
    warn "       the two are not merged: joining two lists of accounts silently is"
    warn "       how a machine ends up with a login nobody wrote down"
    warn "       ${legacy} is not created unless it appears in 'accounts'"
    warn "       example:  accounts = \"${legacy}:wheel:/bin/bash:sudo;<the rest>\""
  fi

  if [[ -n "$spec" ]]; then
    # Split on ';' only. A record's own fields are separated by ':' and a shell
    # is an absolute path, so neither may be used here.
    printf '%s\n' "${spec//;/$'\n'}"
  fi

  if [[ -n "$file" ]]; then
    if [[ ! -r "$file" ]]; then
      err "Cannot read accounts_file: ${file}"
      err "       expected a readable file of name:groups:shell:privilege records"
      err "       one record per line, '#' starts a comment, blank lines ignored"
      err "       example:  accounts_file = /root/accounts.txt"
      return 1
    fi
    while IFS= read -r line || [[ -n "$line" ]]; do
      printf '%s\n' "$line"
    done <"$file"
  fi
  return 0
}

_sys_accounts_parse() {
  # Args: $1 = root, $2.. = the raw records. Fills the parallel arrays.
  local root="$1"
  shift
  local record name groups shell priv extra group i normalized
  local def_groups def_shell def_priv
  local -a keep=()

  def_groups="$(_sys_cfg "wheel,audio,video,usb,portage" user_groups)"
  def_shell="$(_sys_cfg "/bin/bash" user_shell shell)"
  def_priv="$(_sys_cfg "sudo" privilege privilege_tool sudo_tool)"

  _SYS_ACC_NAME=()
  _SYS_ACC_GROUPS=()
  _SYS_ACC_SHELL=()
  _SYS_ACC_PRIV=()

  for record in "$@"; do
    record="${record#"${record%%[![:space:]]*}"}"
    record="${record%"${record##*[![:space:]]}"}"
    [[ -n "$record" ]] || continue
    [[ "${record:0:1}" != "#" ]] || continue

    IFS=':' read -r name groups shell priv extra <<<"$record"
    if [[ -n "${extra:-}" ]]; then
      err "Malformed account record: ${record}"
      err "       a record reads name:groups:shell:privilege and has four fields"
      err "       an empty field takes the default; a missing one does too"
      err "       ';' separates one record from the next"
      err "       example:  accounts = \"alice:wheel,audio:/bin/bash:sudo\""
      return 1
    fi
    if [[ ! "$name" =~ ^[a-z_][a-z0-9_-]*$ ]] || ((${#name} > 32)); then
      err "Invalid account name: ${name:-<empty>}"
      err "       lowercase letters, digits, underscore and hyphen, at most 32"
      err "       characters, not starting with a digit or a hyphen"
      err "       the name is the first field of the record"
      err "       example:  accounts = \"alice:wheel:/bin/bash:sudo\""
      return 1
    fi
    for ((i = 0; i < ${#_SYS_ACC_NAME[@]}; i++)); do
      [[ "${_SYS_ACC_NAME[i]}" != "$name" ]] && continue
      err "Account ${name} is declared twice"
      err "       the second record would silently lose to the first"
      err "       keep one record per account, with all of its groups on it"
      err "       example:  accounts = \"${name}:wheel,audio,video:/bin/bash:sudo\""
      return 1
    done

    groups="${groups:-$def_groups}"
    shell="${shell:-$def_shell}"
    priv="${priv:-$def_priv}"

    _sys_priv_check "$priv" "the record for ${name}" || return 1

    if [[ "${shell:0:1}" != "/" ]]; then
      err "Invalid shell for ${name}: ${shell}"
      err "       an absolute path, as the installed system will see it"
      err "       example:  accounts = \"${name}::/bin/bash:${priv}\""
      return 1
    fi
    if _sys_tree_readable "$root" && [[ ! -e "${root}${shell}" ]]; then
      err "No such shell in the target: ${shell} (account ${name})"
      err "       the path is resolved inside ${root}, and nothing is there"
      err "       /bin/bash      the stage3 ships it"
      err "       /bin/sh        always present"
      err "       /sbin/nologin  for an account that must never log in"
      err "       cat ${root}/etc/shells   lists what the target offers"
      err "       example:  accounts = \"${name}::/bin/bash:${priv}\""
      return 1
    fi

    keep=()
    group=""
    # shellcheck disable=SC2020  # character-for-character is what is wanted:
    # ',' and ' ' each become a newline, which is how the list gets split.
    # The `|| [[ -n ... ]]` catches the last item, which has no newline after it.
    while IFS= read -r group || [[ -n "$group" ]]; do
      [[ -n "$group" ]] || continue
      if [[ ! "$group" =~ ^[a-z_][a-z0-9_-]*$ ]]; then
        err "Invalid group name for ${name}: ${group}"
        err "       lowercase letters, digits, underscore and hyphen"
        err "       the groups field is a comma-separated list"
        err "       example:  accounts = \"${name}:wheel,audio,video::${priv}\""
        return 1
      fi
      if _sys_tree_readable "$root" && [[ -r "${root}/etc/group" ]] \
        && ! _sys_group_exists "$root" "$group" && ! _sys_group_planned "$group"; then
        err "No such group in the target: ${group} (account ${name})"
        err "       useradd refuses the whole account over one unknown group, so"
        err "       this is refused here instead of half-applied there"
        err "       create it:  groups = \"${group}\""
        err "       or drop it: accounts = \"${name}:<the groups that exist>::${priv}\""
        err "       cut -d: -f1 ${root}/etc/group   lists what is there"
        return 1
      fi
      keep+=("$group")
    done < <(printf '%s' "$groups" | tr ', ' '\n\n')

    normalized="$(
      IFS=,
      printf '%s' "${keep[*]-}"
    )"

    _SYS_ACC_NAME+=("$name")
    _SYS_ACC_GROUPS+=("$normalized")
    _SYS_ACC_SHELL+=("$shell")
    _SYS_ACC_PRIV+=("$priv")
  done
  return 0
}

_sys_accounts_load() {
  # Parse once per step. Returns 0 when the arrays are usable.
  local root="$1" raw
  local -a records=()

  case "$_SYS_ACC_STATE" in
    ok) return 0 ;;
    bad) return 1 ;;
  esac
  _SYS_ACC_STATE="bad"

  if ! _sys_groups_parse "$(_sys_cfg "" groups)"; then
    return 1
  fi
  # Captured rather than piped, so that the failure of _sys_accounts_records
  # is the failure of this function: the right-hand side of a pipe and the
  # inside of a process substitution both lose their exit status here.
  if ! raw="$(_sys_accounts_records)"; then
    return 1
  fi
  # An empty list is not an error. It is a machine with root and nothing else,
  # and _sys_accounts says so in its own voice.
  mapfile -t records <<<"$raw"
  if ! _sys_accounts_parse "$root" ${records[@]+"${records[@]}"}; then
    return 1
  fi
  _SYS_ACC_STATE="ok"
  return 0
}

# --------------------------------------------------------------------------- #
#  Groups — created first, because useradd fails on an unknown one            #
# --------------------------------------------------------------------------- #
_sys_groups() {
  local root="$1" i name gid existing
  local -a argv=()

  _sys_accounts_load "$root" || return 1
  ((${#_SYS_GRP_NAME[@]} > 0)) || return 0

  if ! _sys_target_has "$root" /usr/sbin/groupadd \
    && ! _sys_target_has "$root" /usr/bin/groupadd && [[ "$DRY_RUN" != "yes" ]]; then
    warn "groupadd is not in the target tree; no group was created"
    for ((i = 0; i < ${#_SYS_GRP_NAME[@]}; i++)); do
      _sys_todo "create the group: chroot ${root} /bin/bash -lc 'groupadd ${_SYS_GRP_NAME[i]}'"
    done
    return 1
  fi

  for ((i = 0; i < ${#_SYS_GRP_NAME[@]}; i++)); do
    name="${_SYS_GRP_NAME[i]}"
    gid="${_SYS_GRP_GID[i]}"

    if _sys_group_exists "$root" "$name"; then
      existing="$(_sys_group_gid "$root" "$name")"
      if [[ -n "$gid" && "$existing" != "$gid" ]]; then
        warn "group ${name} already exists with GID ${existing}, not ${gid}"
        warn "       the GID is left alone: changing it orphans every file that"
        warn "       already carries the old one, and nothing here knows which"
        warn "       chroot ${root} /bin/bash -lc 'groupmod -g ${gid} ${name}'"
      else
        skip "group ${name} already exists in the target"
      fi
      continue
    fi

    argv=(groupadd)
    [[ -z "$gid" ]] || argv+=(-g "$gid")
    argv+=("$name")
    if ! _sys_in_chroot "$root" "${argv[@]}"; then
      err "groupadd refused to create ${name}"
      err "       chroot ${root} /bin/bash -lc '$(_cmdline "${argv[@]}")'"
      return 1
    fi
    ok "group ${name} created${gid:+ with GID ${gid}}"
    _SYS_CHANGED=$((_SYS_CHANGED + 1))
  done

  _sys_record groups "$(
    IFS=' '
    printf '%s' "${_SYS_GRP_NAME[*]}"
  )"
}

# --------------------------------------------------------------------------- #
#  The accounts                                                               #
# --------------------------------------------------------------------------- #
_sys_chpasswd_path() {
  # Where chpasswd lives inside the target, or nothing. A returned value.
  local root="$1" path
  for path in /usr/sbin/chpasswd /usr/bin/chpasswd /sbin/chpasswd /bin/chpasswd; do
    if _sys_target_has "$root" "$path"; then
      printf '%s\n' "$path"
      return 0
    fi
  done
  return 1
}

_sys_set_password() {
  # The value is read straight into chpasswd's stdin. It is never an argument,
  # never a log line, never a journal entry: argv shows up in ps, and the state
  # journal refuses a key that looks like a secret in the first place.
  # Args: $1 = root, $2 = account name.
  local root="$1" name="$2" secret="" tool

  if [[ "$DRY_RUN" == "yes" ]]; then
    log "dry-run: would ask for ${name}'s password and set it with chpasswd"
    return 0
  fi
  if _sys_account_has_password "$root" "$name"; then
    skip "account ${name} already has a password; not asking again"
    return 0
  fi
  if ! tool="$(_sys_chpasswd_path "$root")"; then
    warn "chpasswd is not in the target tree; ${name} has no password"
    _sys_todo "set ${name}'s password: chroot ${root} /bin/bash -lc 'passwd ${name}'"
    return 0
  fi
  if ! prompt_secret secret "Password for ${name}"; then
    warn "no password set for ${name}; the account cannot log in yet"
    _sys_todo "set ${name}'s password: chroot ${root} /bin/bash -lc 'passwd ${name}'"
    return 0
  fi
  if printf '%s:%s\n' "$name" "$secret" | chroot "$root" "$tool"; then
    secret=""
    ok "password set for ${name}"
    return 0
  fi
  secret=""
  err "chpasswd refused the password for ${name}"
  _sys_todo "set ${name}'s password: chroot ${root} /bin/bash -lc 'passwd ${name}'"
  return 1
}

_sys_account_one() {
  # Args: $1 = root, $2 = name, $3 = groups, $4 = shell, $5 = privilege.
  local root="$1" name="$2" groups="$3" shell="$4" priv="$5" missing
  local -a argv=()

  if _sys_account_exists "$root" "$name"; then
    skip "account ${name} already exists in the target"
    missing="$(_sys_account_missing_groups "$root" "$name" "$groups")"
    if [[ -n "$missing" ]]; then
      if _sys_in_chroot "$root" usermod -a -G "$missing" "$name"; then
        ok "account ${name}: added to ${missing}"
        _SYS_CHANGED=$((_SYS_CHANGED + 1))
      else
        err "usermod could not add ${name} to ${missing}"
        err "       chroot ${root} /bin/bash -lc 'usermod -a -G ${missing} ${name}'"
        return 1
      fi
    fi
  else
    argv=(useradd -m)
    [[ -z "$groups" ]] || argv+=(-G "$groups")
    argv+=(-s "$shell" "$name")
    if ! _sys_in_chroot "$root" "${argv[@]}"; then
      err "useradd refused to create ${name}"
      err "       groups: ${groups:-<none>}"
      err "       shell:  ${shell}"
      err "       chroot ${root} /bin/bash -lc '$(_cmdline "${argv[@]}")'"
      return 1
    fi
    ok "account ${name} created — groups ${groups:-<none>}, shell ${shell}, ${priv}"
    _SYS_CHANGED=$((_SYS_CHANGED + 1))
  fi

  case "$priv" in
    sudo-nopasswd) _sys_nopasswd_warning "$name" "sudo" ;;
    doas-nopasswd) _sys_nopasswd_warning "$name" "doas" ;;
  esac

  _sys_set_password "$root" "$name"
}

_sys_accounts() {
  local root="$1" i failed=0

  _sys_accounts_load "$root" || return 1

  if ((${#_SYS_ACC_NAME[@]} == 0)); then
    skip "no account configured; only root will exist on the new system"
    _sys_todo "create an account: chroot ${root} /bin/bash -lc 'useradd -m -G wheel <name> && passwd <name>'"
    return 0
  fi

  if ! _sys_target_has "$root" /usr/sbin/useradd \
    && ! _sys_target_has "$root" /usr/bin/useradd && [[ "$DRY_RUN" != "yes" ]]; then
    warn "useradd is not in the target tree; no account was created"
    for ((i = 0; i < ${#_SYS_ACC_NAME[@]}; i++)); do
      _sys_todo "create the account: chroot ${root} /bin/bash -lc 'useradd -m -G ${_SYS_ACC_GROUPS[i]} -s ${_SYS_ACC_SHELL[i]} ${_SYS_ACC_NAME[i]}'"
    done
    return 1
  fi

  for ((i = 0; i < ${#_SYS_ACC_NAME[@]}; i++)); do
    if ! _sys_account_one "$root" "${_SYS_ACC_NAME[i]}" "${_SYS_ACC_GROUPS[i]}" \
      "${_SYS_ACC_SHELL[i]}" "${_SYS_ACC_PRIV[i]}"; then
      failed=$((failed + 1))
    fi
  done

  _sys_record accounts "$(
    IFS=' '
    printf '%s' "${_SYS_ACC_NAME[*]}"
  )"
  # The first account keeps the key step 95 and the README already read.
  _sys_record user "${_SYS_ACC_NAME[0]}"
  _sys_record user_groups "${_SYS_ACC_GROUPS[0]}"

  ((failed == 0)) || return 1
  return 0
}

# --------------------------------------------------------------------------- #
#  sudo and doas — one rule per account, and both files are validated         #
# --------------------------------------------------------------------------- #
_sys_visudo_check() {
  # Args: $1 = root, $2 = path inside the target.
  local root="$1" path="$2"
  _sys_target_has "$root" /usr/sbin/visudo || return 0
  chroot "$root" /usr/sbin/visudo -c -f "$path" >/dev/null 2>&1
}

_sys_doas_check() {
  local root="$1"
  _sys_target_has "$root" /usr/bin/doas || return 0
  chroot "$root" /usr/bin/doas -C /etc/doas.conf >/dev/null 2>&1
}

_sys_privilege_summary() {
  # What step 95 reads to answer "is there a way to become root": the tool, not
  # the per-account detail, which goes in its own key next to it.
  local i any_sudo="no" any_doas="no"
  for ((i = 0; i < ${#_SYS_ACC_PRIV[@]}; i++)); do
    case "${_SYS_ACC_PRIV[i]}" in
      sudo | sudo-nopasswd) any_sudo="yes" ;;
      doas | doas-nopasswd) any_doas="yes" ;;
    esac
  done
  if [[ "$any_sudo" == "yes" ]]; then
    printf 'sudo\n'
  elif [[ "$any_doas" == "yes" ]]; then
    printf 'doas\n'
  else
    printf 'none\n'
  fi
}

_sys_privilege() {
  local root="$1" i name priv path detail=""
  local -a sudo_rules=() doas_rules=()

  if ! _sys_accounts_load "$root"; then
    skip "sudo/doas: the account list did not parse, so nothing is granted"
    return 0
  fi

  for ((i = 0; i < ${#_SYS_ACC_NAME[@]}; i++)); do
    name="${_SYS_ACC_NAME[i]}"
    priv="${_SYS_ACC_PRIV[i]}"
    detail+="${detail:+ }${name}:${priv}"
    case "$priv" in
      sudo) sudo_rules+=("${name} ALL=(ALL:ALL) ALL") ;;
      sudo-nopasswd) sudo_rules+=("${name} ALL=(ALL:ALL) NOPASSWD: ALL") ;;
      doas) doas_rules+=("permit persist ${name}") ;;
      doas-nopasswd) doas_rules+=("permit nopass ${name}") ;;
    esac
  done

  path="/etc/sudoers.d/10-gentoo-install"
  if ((${#sudo_rules[@]} > 0)); then
    # A drop-in, not an edit of /etc/sudoers: a rerun replaces its own file and
    # a hand edit of the main file survives untouched.
    if [[ "$DRY_RUN" != "yes" ]]; then
      run_cmd mkdir -p -- "${root}/etc/sudoers.d" || return 1
    fi
    if ! write_validated "${root}${path}" _sys_visudo_check "$root" "$path" <<EOF
# Written by gentoo-install. One rule per account, named explicitly.
#
# There is deliberately no '%wheel ALL=(ALL:ALL) ALL' line: a group rule would
# also hand root to an account that asked for privilege 'none' and is in wheel
# for its ordinary memberships, which is a grant nobody wrote down.
$(printf '%s\n' "${sudo_rules[@]}")
EOF
    then
      err "visudo refused ${path}; the previous content is back"
      err "       a sudoers file that does not parse is a machine nobody administers"
      return 1
    fi
    _sys_note_change
    run_cmd chmod 0440 -- "${root}${path}" || true
    if ! _sys_target_has "$root" /usr/sbin/visudo && [[ "$DRY_RUN" != "yes" ]]; then
      warn "sudo is not installed in the target, so the file was written unverified"
      _sys_todo "emerge app-admin/sudo, then: chroot ${root} visudo -c"
    fi
    ok "sudo: ${#sudo_rules[@]} account(s) may become root"
  elif [[ -f "${root}${path}" ]]; then
    # An earlier run granted sudo and this one does not. Leaving the file would
    # leave the grant, and idempotence that only ever adds is not idempotence.
    if ! write_validated "${root}${path}" _sys_visudo_check "$root" "$path" <<EOF
# Written by gentoo-install. No account asks for sudo, so this file grants
# nothing. Removing it changes nothing.
EOF
    then
      err "visudo refused ${path}; the previous content is back"
      return 1
    fi
    _sys_note_change
    run_cmd chmod 0440 -- "${root}${path}" || true
    ok "sudo: the drop-in grants nothing any more"
  else
    skip "sudo: no account asked for it"
  fi

  if ((${#doas_rules[@]} > 0)); then
    if ! write_validated "${root}/etc/doas.conf" _sys_doas_check "$root" <<EOF
# Written by gentoo-install. One rule per account.
# persist remembers the answer for five minutes, like sudo does.
$(printf '%s\n' "${doas_rules[@]}")
EOF
    then
      err "doas -C refused /etc/doas.conf; the previous content is back"
      return 1
    fi
    _sys_note_change
    run_cmd chmod 0400 -- "${root}/etc/doas.conf" || true
    if ! _sys_target_has "$root" /usr/bin/doas && [[ "$DRY_RUN" != "yes" ]]; then
      warn "doas is not installed in the target, so the file was written unverified"
      _sys_todo "emerge app-admin/doas, then: chroot ${root} doas -C /etc/doas.conf"
    fi
    ok "doas: ${#doas_rules[@]} account(s) may become root"
  else
    # /etc/doas.conf is not a drop-in and it is not ours outright, so an
    # unwanted grant there is named rather than rewritten.
    if [[ -f "${root}/etc/doas.conf" && "$DRY_RUN" != "yes" ]]; then
      warn "${root}/etc/doas.conf exists and no account asks for doas"
      warn "       it is not a drop-in and may be somebody's own file, so it is"
      warn "       left alone; read it before trusting root_lock"
    fi
    skip "doas: no account asked for it"
  fi

  if ((${#_SYS_ACC_NAME[@]} > 0)) && [[ "$(_sys_privilege_summary)" == "none" ]]; then
    _sys_todo "no account can become root; log in as root on the console instead"
  fi

  _sys_record privilege "$(_sys_privilege_summary)"
  _sys_record privilege_by_account "$detail"
}

# --------------------------------------------------------------------------- #
#  root_lock — the proof, and --force does not lift it (DESIGN.md §12)        #
# --------------------------------------------------------------------------- #
# Locking root without another way to become root gives a machine nobody can
# administer, and the only recourse is a LiveUSB. That is the accident this
# whole project is written against, so root_lock = yes is refused unless an
# account both escalates and can log in.
_sys_root_lock() {
  local root="$1" mode i name priv
  local -a escalating=() unusable=()

  mode="$(_sys_cfg "no" root_lock)"
  case "$mode" in
    yes | no) ;;
    *)
      err "Unknown root_lock: ${mode}"
      err "       yes  passwd -l root, once another account is shown to escalate"
      err "       no   root keeps whatever password it was given"
      err "       example:  root_lock = no"
      return 1
      ;;
  esac

  if [[ "$mode" != "yes" ]]; then
    skip "root is left as it is (root_lock = no)"
    return 0
  fi

  if ! _sys_accounts_load "$root"; then
    err "Refusing root_lock = yes: the account list above did not parse"
    err "       nothing can be shown to escalate, so nothing proves this machine"
    err "       would still be administrable with root locked"
    err "       fix the record the previous error names, then rerun"
    err "       ./gentoo-install.sh --steps 90"
    return 1
  fi

  for ((i = 0; i < ${#_SYS_ACC_NAME[@]}; i++)); do
    priv="${_SYS_ACC_PRIV[i]}"
    [[ "$priv" != "none" ]] || continue
    name="${_SYS_ACC_NAME[i]}"
    if [[ "$DRY_RUN" == "yes" ]]; then
      # Nothing has been created yet, so the credential half of the proof has
      # nothing to read. The half that comes from the configuration is checked
      # here; the other half is checked for real on the run that installs.
      escalating+=("$name")
      continue
    fi
    if _sys_account_has_password "$root" "$name"; then
      escalating+=("${name} (password)")
    elif _sys_account_has_key "$root" "$name"; then
      escalating+=("${name} (ssh key)")
    else
      unusable+=("$name")
    fi
  done

  if ((${#escalating[@]} == 0)); then
    err "Refusing root_lock = yes: no account could administer this machine"
    if ((${#unusable[@]} > 0)); then
      err "       ${unusable[*]} can become root, and cannot log in: no password"
      err "       and no authorized_keys with a key in it"
      err "       chroot ${root} /bin/bash -lc 'passwd ${unusable[0]}'"
    else
      err "       no account has a privilege other than 'none', so locking root"
      err "       leaves nothing on this machine that can become root"
      err "       accounts = \"alice:wheel:/bin/bash:sudo\""
      err "       then:  chroot ${root} /bin/bash -lc 'passwd alice'"
    fi
    err "       a locked root with no way up is recovered from a LiveUSB and a"
    err "       chroot, and from nowhere else"
    err "       --force does not lift this. --force lifts confirmations, never"
    err "       proofs (docs/DESIGN.md §12)"
    err "       or leave the machine as it is:  root_lock = no"
    _sys_record root_lock "refused"
    return 1
  fi

  if [[ "$DRY_RUN" == "yes" ]]; then
    log "dry-run: would run passwd -l root, once ${escalating[*]} is shown to"
    log "         have a password or an ssh key on the run that installs"
    return 0
  fi

  if _sys_root_is_locked "$root"; then
    skip "root is already locked; ${escalating[*]} is the way in"
    _sys_record root_lock "yes"
    return 0
  fi

  if ! _sys_target_has "$root" /usr/bin/passwd && ! _sys_target_has "$root" /bin/passwd; then
    warn "passwd is not in the target tree; root was not locked"
    _sys_todo "lock root: chroot ${root} /bin/bash -lc 'passwd -l root'"
    return 0
  fi

  if ! _sys_in_chroot "$root" passwd -l root; then
    err "passwd -l root failed inside ${root}"
    err "       chroot ${root} /bin/bash -lc 'passwd -l root'"
    return 1
  fi
  _SYS_CHANGED=$((_SYS_CHANGED + 1))
  ok "root locked; the way in is ${escalating[*]}"
  _sys_record root_lock "yes"
}

# --------------------------------------------------------------------------- #
#  Services                                                                   #
# --------------------------------------------------------------------------- #
_sys_service_exists() {
  # Args: $1 = root, $2 = service name.
  local root="$1" name="$2"
  if [[ "$(_sys_init)" == "systemd" ]]; then
    [[ -e "${root}/usr/lib/systemd/system/${name}.service" ||
      -e "${root}/lib/systemd/system/${name}.service" ||
      -e "${root}/etc/systemd/system/${name}.service" ]]
  else
    [[ -x "${root}/etc/init.d/${name}" ]]
  fi
}

_sys_enable_service() {
  # The single door every service enablement goes through, so that the init
  # system is decided in one place instead of at each call site.
  # Args: $1 = root, $2 = service, $3 = OpenRC runlevel (default default).
  local root="$1" name="$2" level="${3:-default}"

  if [[ "$DRY_RUN" != "yes" ]] && ! _sys_service_exists "$root" "$name"; then
    warn "service '${name}' is not installed in the target; not enabling it"
    if [[ "$(_sys_init)" == "systemd" ]]; then
      _sys_todo "install ${name}, then: systemctl --root=${root} enable ${name}"
    else
      _sys_todo "install ${name}, then: chroot ${root} rc-update add ${name} ${level}"
    fi
    return 1
  fi

  if [[ "$(_sys_init)" == "systemd" ]]; then
    # --root works without a chroot and without a running systemd: it only
    # creates the symlinks the unit's [Install] section describes.
    if run_quiet systemctl --root="$root" enable "$name"; then
      ok "service ${name}: enabled"
      return 0
    fi
    err "systemctl --root=${root} enable ${name} failed"
    return 1
  fi

  if _sys_in_chroot "$root" rc-update add "$name" "$level"; then
    ok "service ${name}: added to the ${level} runlevel"
    return 0
  fi
  err "rc-update add ${name} ${level} failed inside ${root}"
  return 1
}

_sys_extra_services() {
  # Extra services live in a data file, per DESIGN.md §10, so that adding one
  # is a line of data and not an edit to this function. The file is optional;
  # without it, only the services the choices above imply are enabled.
  #   data/services.tsv:  init <TAB> service <TAB> runlevel <TAB> why
  local root="$1" file init svc_init name level
  init="$(_sys_init)"
  file="${DATA_DIR:-${BASH_SOURCE[0]%/*}/../data}/services.tsv"
  [[ -r "$file" ]] || return 0
  while IFS=$'\t' read -r svc_init name level _; do
    [[ -n "$name" ]] || continue
    [[ "${svc_init:0:1}" != "#" ]] || continue
    [[ "$svc_init" == "$init" || "$svc_init" == "any" ]] || continue
    _sys_enable_service "$root" "$name" "${level:-default}" || true
  done <"$file"
}

# --------------------------------------------------------------------------- #
#  Network                                                                    #
# --------------------------------------------------------------------------- #
_sys_network() {
  local root="$1" want init
  init="$(_sys_init)"

  if [[ "$init" == "systemd" ]]; then
    want="$(_sys_cfg "systemd-networkd" network network_service)"
  else
    want="$(_sys_cfg "dhcpcd" network network_service)"
  fi

  case "$want" in
    dhcpcd | networkmanager | systemd-networkd | none) ;;
    NetworkManager) want="networkmanager" ;;
    *)
      err "Unknown network service: ${want}"
      err "       dhcpcd            a DHCP client and nothing else; works on both inits"
      err "       networkmanager    for a laptop, wifi and a desktop applet"
      err "       systemd-networkd  systemd only, configured by .network files"
      err "       none              configure the network by hand after the reboot"
      err "       example:  network = dhcpcd"
      return 1
      ;;
  esac

  if [[ "$want" == "systemd-networkd" && "$init" != "systemd" ]]; then
    err "network = systemd-networkd needs init = systemd"
    err "       this install uses ${init}, which has no systemd-networkd"
    err "       dhcpcd            the OpenRC equivalent, and the default here"
    err "       networkmanager    if wifi or a desktop applet is wanted"
    err "       example:  network = dhcpcd"
    return 1
  fi

  case "$want" in
    none)
      skip "no network service configured (network = none)"
      _sys_todo "the new system has no network client; configure one before rebooting"
      _sys_record network "none"
      return 0
      ;;
    systemd-networkd)
      write_file "${root}/etc/systemd/network/20-wired.network" <<'EOF'
# Any wired interface, addressed by DHCP. Narrow the [Match] section once the
# interface names on this machine are known: `networkctl list` prints them.
[Match]
Type=ether

[Network]
DHCP=yes
IPv6AcceptRA=yes
EOF
      _sys_note_change
      _sys_enable_service "$root" "systemd-networkd" || true
      _sys_enable_service "$root" "systemd-resolved" || true
      # systemd-resolved answers on 127.0.0.53 and nothing finds it without
      # this symlink; a system that resolves nothing looks like a dead network.
      run_cmd ln -sfn ../run/systemd/resolve/stub-resolv.conf \
        "${root}/etc/resolv.conf" || true
      ;;
    dhcpcd)
      _sys_enable_service "$root" "dhcpcd" || true
      ;;
    networkmanager)
      if [[ "$init" == "systemd" ]]; then
        _sys_enable_service "$root" "NetworkManager" || true
      else
        _sys_enable_service "$root" "NetworkManager" "default" || true
      fi
      ;;
  esac

  _sys_record network "$want"
}

# --------------------------------------------------------------------------- #
#  sshd — off by default, because turning it on opens a port                  #
# --------------------------------------------------------------------------- #
_sys_sshd_check() {
  # Args: $1 = root. sshd -t needs host keys, which a fresh stage3 has not
  # generated yet; without them the check would fail on a perfectly good file.
  local root="$1"
  _sys_target_has "$root" /usr/sbin/sshd || return 0
  compgen -G "${root}/etc/ssh/ssh_host_*_key" >/dev/null 2>&1 || return 0
  chroot "$root" /usr/sbin/sshd -t >/dev/null 2>&1
}

_sys_sshd() {
  local root="$1" key user home passwords="yes"
  # Split: same reason -- this would name the HOST sshd_config (SC2318).
  local config="${root}/etc/ssh/sshd_config"

  if ! cfg_yes ssh && ! cfg_yes sshd; then
    skip "sshd not enabled (conservative default: it opens a port on every boot)"
    _sys_record sshd "disabled"
    return 0
  fi

  key="$(_sys_cfg "" ssh_key ssh_authorized_key authorized_key)"
  user="$(_sys_cfg "" user username)"

  if [[ -n "$key" && -n "$user" ]]; then
    home="${root}/home/${user}"
    if [[ "$DRY_RUN" != "yes" ]]; then
      run_cmd mkdir -p -- "${home}/.ssh" || return 1
    fi
    if [[ -r "$key" ]]; then
      write_file "${home}/.ssh/authorized_keys" "0600" <"$key" || return 1
    else
      write_file "${home}/.ssh/authorized_keys" "0600" <<<"$key" || return 1
    fi
    _sys_note_change
    run_cmd chroot "$root" chown -R "${user}:${user}" "/home/${user}/.ssh" || true
    passwords="no"
  fi

  if [[ "$passwords" == "yes" ]]; then
    warn "sshd will accept passwords: no authorized key was supplied"
    warn "       a password-authenticated sshd on a public address is brute-forced"
    warn "       within the hour; supply a key with ssh_key = /path/to/id_ed25519.pub"
    warn "       and this step turns password authentication off by itself"
  fi

  # A drop-in, and an Include line at the very top of sshd_config so that it is
  # actually read. sshd takes the FIRST value it sees for most keywords, so an
  # Include appended at the end would be silently overridden by everything
  # above it — which is exactly how hardening ends up doing nothing.
  write_file "${root}/etc/ssh/sshd_config.d/10-gentoo-install.conf" <<EOF
# Hardening written by gentoo-install. Delete this file to go back to
# whatever /etc/ssh/sshd_config says on its own.
PermitRootLogin no
PasswordAuthentication ${passwords}
KbdInteractiveAuthentication no
PermitEmptyPasswords no
X11Forwarding no
AllowAgentForwarding no
MaxAuthTries 3
LoginGraceTime 30
ClientAliveInterval 300
ClientAliveCountMax 2
EOF
  _sys_note_change

  if [[ -f "$config" ]] \
    && ! grep -qE '^[[:space:]]*Include[[:space:]]+/etc/ssh/sshd_config\.d/' "$config" 2>/dev/null; then
    local merged
    merged="$(
      printf 'Include /etc/ssh/sshd_config.d/*.conf\n'
      cat -- "$config"
    )"
    if ! write_validated "$config" _sys_sshd_check "$root" <<<"$merged"; then
      err "sshd -t refused ${config}; the previous content is back"
      return 1
    fi
    _sys_note_change
  fi

  _sys_enable_service "$root" "sshd" || true
  _sys_record sshd "enabled"
  if [[ "$passwords" == "yes" ]]; then
    _sys_todo "install an ssh key and set PasswordAuthentication no in /etc/ssh/sshd_config.d/10-gentoo-install.conf"
  fi
}

# --------------------------------------------------------------------------- #
#  The step                                                                   #
# --------------------------------------------------------------------------- #
step_90_system() {
  local root part failed=0
  local -a parts=(
    timezone locales keymap hostname fstab
    root_password groups accounts privilege root_lock network sshd
  )

  root="$(_sys_root)"
  _SYS_CHANGED=0
  _SYS_TODO_N=0
  _SYS_ACC_STATE=""

  if [[ "$root" == "/" || -z "$root" ]]; then
    err "Refusing to configure / as the target system"
    err "       step 90 writes fstab, the root password and the enabled services"
    err "       of the system being installed — not of the one running the"
    err "       installer. Pointing it at / would rewrite this machine."
    err "       the target defaults to /mnt/gentoo; set it explicitly with"
    err "       root = /mnt/gentoo in the configuration file"
    return "$EXIT_FAILURE"
  fi

  if [[ ! -d "${root}/etc" || ! -d "${root}/usr" ]]; then
    err "${root} does not look like an unpacked Gentoo system"
    err "       expected ${root}/etc and ${root}/usr to exist"
    err "       step 40 unpacks the stage3 and step 50 mounts it; run those first"
    err "       ./gentoo-install.sh --steps 40,50"
    return "$EXIT_FAILURE"
  fi

  log "configuring ${root} (init: $(_sys_init))"

  for part in "${parts[@]}"; do
    if ! "_sys_${part}" "$root"; then
      err "system: ${part} failed"
      failed=$((failed + 1))
    fi
  done

  _sys_extra_services "$root" || true

  _sys_record changed "$_SYS_CHANGED"
  _sys_record todo_count "$_SYS_TODO_N"

  if ((failed > 0)); then
    err "system configuration: ${failed} of ${#parts[@]} part(s) failed"
    err "       each failure above names the command that reproduces it"
    err "       fix the cause, then: ./gentoo-install.sh --steps 90"
    return "$EXIT_FAILURE"
  fi

  ok "system configuration: ${#parts[@]} part(s), ${_SYS_CHANGED} file(s) written"
  if ((_SYS_TODO_N > 0)); then
    warn "${_SYS_TODO_N} thing(s) left to do by hand; step 95 lists them again"
  fi
  return "$EXIT_SUCCESS"
}
