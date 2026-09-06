#!/usr/bin/env bash
#
# gentoo-install — step 20: partition and format the target disk (DESTRUCTIVE)
# ----------------------------------------------------------------------------
# The one step in this installer that cannot be undone, so it is the one that
# says the most before it acts. In order: validate the settings, take an
# inventory of the disks, pick the target, refuse it if it is removable, in
# use, or carrying the running system, compute the layout as a table of real
# sizes and print it, print the disk's identity and everything currently on
# it, and only then ask for the device path to be typed out.
#
# Three gates, and they are not the same gate three times. wipe_disk is a
# tri-state a careful operator can answer up front; the typed confirmation is
# a proof and no flag lifts it (DESIGN.md §12); _disk_assert_target() is a
# check the code runs on itself before every sgdisk, wipefs and mkfs, so a
# mistake in this file stops here rather than on a disk.
#
# Usage:  source steps/20_disk.sh   (needs lib/core.sh, config, state, ui, disk)
#
set -euo pipefail

if [[ -n "${_GI_STEP20_LOADED:-}" ]]; then
  return 0
fi
_GI_STEP20_LOADED=1

# --------------------------------------------------------------------------- #
#  Idempotence                                                                #
# --------------------------------------------------------------------------- #
_step20_already_provisioned() {
  # Read, compare, and say which of the three happened (DESIGN.md §9). The
  # question is not "did we run before" — the journal answers that — but "is
  # the tree this plan describes standing right now", which is the only thing
  # the steps after this one care about.
  # Args: $1 = plan text.
  local plan="$1" mount dev root target current

  root="$(disk_plan_meta "$plan" mountpoint)"
  mountpoint -q -- "$root" 2>/dev/null || return 1

  while IFS=$'\t' read -r _ mount dev _; do
    target="${root%/}${mount}"
    if [[ "$mount" == "/" ]]; then
      target="$root"
    fi
    [[ -b "$dev" ]] || return 1
    mountpoint -q -- "$target" 2>/dev/null || return 1
    current="$(findmnt -no SOURCE --target "$target" 2>/dev/null || true)"
    [[ "$(readlink -f -- "$current" 2>/dev/null || true)" == "$(readlink -f -- "$dev" 2>/dev/null || true)" ]] || return 1
  done < <(_disk_mount_order "$plan")
  return 0
}

# --------------------------------------------------------------------------- #
#  Hand-over to the later steps                                               #
# --------------------------------------------------------------------------- #
_step20_uuid() {
  # Args: $1 = device. Prints its UUID on stdout, or nothing at all. Never
  # fails: an unreadable UUID costs the run a fallback, not the install.
  local dev="${1:-}"
  [[ -n "$dev" && -b "$dev" ]] || return 0
  command -v blkid >/dev/null 2>&1 || return 0
  blkid -s UUID -o value -- "$dev" 2>/dev/null || true
}

_step20_record_crypt_device() {
  # The partition a LUKS container belongs on: the physical volume under LVM,
  # otherwise the partition holding /. Journalled as soon as the partitions
  # exist, and before anything is formatted, because the message that stops an
  # encrypted run names it.
  #
  # Step 30 reads it as disk.crypt_device and refused with "No device to
  # encrypt" until this existed — which is how the encrypted path turned out
  # never to have run end to end.
  # Args: $1 = plan text.
  local plan="$1" dev=""
  if [[ "$(disk_plan_meta "$plan" lvm)" == "yes" ]]; then
    dev="$(disk_plan_rows "$plan" part | awk -F'\t' '$5 == "lvm" { print $6; exit }')"
  else
    dev="$(disk_plan_device_for "$plan" /)"
  fi
  if [[ -n "$dev" ]]; then
    state_set disk.crypt_device "$dev"
  fi
}

_step20_crypt_order_ok() {
  # True when this step may go on to create filesystems.
  #
  # The disk layer notices an open container and builds on it — disk_pv_device()
  # says so — but nothing creates one before this point, and the step registry
  # runs 20 before 30. So an encrypted install needs the container opened
  # between partitioning and formatting, and that sequence does not exist yet.
  # Until it does, refusing is the honest answer: a run that asked for
  # encryption and silently produced a plain disk is the one failure this
  # project must never ship.
  # Args: $1 = plan text. Returns 1 to stop the step.
  local plan="$1" want mapper
  want="${CFG[crypt]:-none}"
  [[ "$want" != "none" ]] || return 0

  mapper="/dev/mapper/${CFG[crypt_name]:-${CFG[disk_crypt_name]:-gentoo}}"
  if [[ -b "$mapper" ]]; then
    log "container ${mapper} is open; filesystems go inside it"
    return 0
  fi

  err "crypt = ${want}, and no container is open yet"
  err "       step 20 would now format $(disk_plan_device_for "$plan" /) directly, and step 30"
  err "       would put a LUKS header over the filesystem it had just made"
  err "       the partitions and the journal are written, so nothing is lost:"
  err "         cryptsetup luksFormat $(state_get disk.crypt_device 2>/dev/null || printf '<container>')"
  err "         cryptsetup open <container> ${CFG[crypt_name]:-gentoo}"
  err "         ./gentoo-install.sh --steps 20 --restart   # filesystems, on the mapper"
  err "       or install without encryption:  --crypt none"
  return 1
}

_step20_record() {
  # What steps 30, 50, 80 and 90 need, and nothing they do not. The journal
  # records what was done, never with what: no passphrase, no key.
  # Args: $1 = plan text.
  local plan="$1" root esp path

  root="$(disk_plan_meta "$plan" mountpoint)"
  esp="$(disk_plan_device_for "$plan" "${CFG[disk_esp_mount]}")"

  local root_dev uuid
  root_dev="$(disk_plan_device_for "$plan" /)"

  # The names are the contract with the later steps, and they were wrong.
  # This wrote disk.root, disk.vg, disk.esp and disk.filesystem — names no
  # consumer reads — while step 70 asked for disk.root_uuid and disk.root_device
  # and step 80 for disk.esp_device. Every one of them fell through to its empty
  # default, and step 70 refused with "nothing says where the root filesystem is"
  # on an install whose disk had just been partitioned correctly.
  state_set disk.device "$(disk_plan_meta "$plan" device)"
  state_set disk.layout "$(disk_plan_meta "$plan" layout)"
  state_set disk.lvm "$(disk_plan_meta "$plan" lvm)"
  state_set disk.vg_name "$(disk_plan_meta "$plan" vg)"
  state_set disk.mountpoint "$root"
  state_set disk.root_fstype "${CFG[disk_filesystem]}"
  state_set disk.esp_device "${esp}"
  state_set disk.esp_mount "${CFG[disk_esp_mount]}"
  state_set disk.root_device "$root_dev"

  # A UUID survives the disk moving from sda to nvme0n1, and that reorder is
  # exactly what the reboot after an install can bring. Step 70 prefers it and
  # falls back to the device name, so a missing UUID degrades rather than fails.
  uuid="$(_step20_uuid "$root_dev")"
  [[ -z "$uuid" ]] || state_set disk.root_uuid "$uuid"
  uuid="$(_step20_uuid "$esp")"
  [[ -z "$uuid" ]] || state_set disk.esp_uuid "$uuid"

  # Again here, so that the already-provisioned path journals it too.
  _step20_record_crypt_device "$plan"

  # A /boot of its own, when the layout gives it one. The GRUB variant asks for
  # this before deciding whether it needs cryptodisk: with /boot outside the
  # container the kernel is reachable without unlocking anything, and turning
  # cryptodisk on anyway only adds a second passphrase prompt at every boot.
  state_set disk.boot_device "$(disk_plan_device_for "$plan" /boot)"

  # The logical volume carrying /, so that step 70 composes
  # root=/dev/mapper/<vg>-<lv> from what step 20 created. Without it the kernel
  # command line falls back to the name "root", which is right until someone
  # asks for a layout that calls it anything else.
  if [[ "$(disk_plan_meta "$plan" lvm)" == "yes" ]]; then
    state_set disk.root_lv "$(disk_plan_name_for "$plan" /)"
  fi

  # The plan and the fstab records go to a file rather than into the journal:
  # they are tables, and a key=value journal is not where a table belongs.
  path="${CFG[state_dir]}/disk-plan.tsv"
  if [[ "$DRY_RUN" == "yes" ]]; then
    log "dry-run: would write the plan to ${path}"
    return 0
  fi
  write_file "$path" 0600 <<<"$plan" || return 1
  disk_fstab_records "$plan" >"${CFG[state_dir]}/disk-fstab.tsv" 2>/dev/null || true
  chmod 0600 -- "${CFG[state_dir]}/disk-fstab.tsv" 2>/dev/null || true
}

# --------------------------------------------------------------------------- #
#  The step                                                                   #
# --------------------------------------------------------------------------- #
step_20_disk() {
  local name plan

  disk_init_defaults
  disk_validate_config || return "$EXIT_FAILURE"

  if ! require_cmds lsblk findmnt; then
    err "       step 20 cannot even look at the disks without them"
    err "       they come with sys-apps/util-linux, which is on every live image"
    err "       example:  --steps 10"
    return "$EXIT_FAILURE"
  fi

  disk_show_inventory

  if ! name="$(disk_resolve_target)"; then
    return "$EXIT_FAILURE"
  fi
  if ! disk_guard "$name"; then
    return "$EXIT_FAILURE"
  fi

  # The plan is computed before anything is asked, because the question the
  # operator is being asked is "does this plan look right", and a question
  # that cannot show its answer is a question worth refusing.
  if ! plan="$(disk_plan "$name" "${CFG[disk_layout]}")"; then
    return "$EXIT_FAILURE"
  fi
  if ! disk_require_tools "$plan"; then
    return "$EXIT_FAILURE"
  fi

  if _step20_already_provisioned "$plan"; then
    skip "/dev/${name} is already partitioned, formatted and mounted as planned"
    disk_show_result "$plan"
    # shellcheck disable=SC2034  # lib/disk.sh reads it in _disk_assert_target
    DISK_CONFIRMED_TARGET="/dev/${name}"
    _step20_record "$plan" || return "$EXIT_FAILURE"
    return "$EXIT_SUCCESS"
  fi

  disk_show_plan "$plan"

  # Gate one: the reversible question, answerable up front by an operator who
  # already knows (wipe_disk = yes) or refused up front by one who does not
  # want this run to touch a disk at all (wipe_disk = no).
  if ! ask_tri wipe_disk "Erase /dev/${name} and lay this plan down?" "no"; then
    err "Disk untouched."
    err "       step 20 is the destructive one; nothing after it can run without it"
    err "       set wipe_disk = yes to stop being asked"
    err "       example:  --steps 20 --skip-steps 20"
    return "$EXIT_FAILURE"
  fi

  # Gate two: the proof. --yes and --force do not lift it.
  if ! disk_confirm_destroy "$name" "$plan"; then
    err "Disk untouched."
    return "$EXIT_FAILURE"
  fi

  # Gate three is inside every function below: _disk_assert_target().
  disk_release "$name" || return "$EXIT_FAILURE"
  disk_wipe "$name" || return "$EXIT_FAILURE"
  disk_partition "$name" "$plan" || return "$EXIT_FAILURE"
  _step20_record_crypt_device "$plan"

  if [[ "$(disk_plan_meta "$plan" lvm)" == "yes" ]]; then
    disk_create_volumes "$plan" || return "$EXIT_FAILURE"
  fi

  # A filesystem must not go where a LUKS container is about to go. Step 30 owns
  # the container and runs after this step, so formatting here would make an
  # ext4 that step 30 then overwrites with a LUKS header — and, when step 30
  # fails for any reason, would leave an unencrypted machine on a run that asked
  # for encryption. That is worse than stopping, so this stops.
  if ! _step20_crypt_order_ok "$plan"; then
    return "$EXIT_FAILURE"
  fi

  disk_format "$plan" || return "$EXIT_FAILURE"
  disk_mount_tree "$plan" || return "$EXIT_FAILURE"
  disk_verify "$plan" || return "$EXIT_FAILURE"
  disk_show_result "$plan"
  _step20_record "$plan" || return "$EXIT_FAILURE"

  ok "step 20: /dev/${name} provisioned and mounted under $(disk_plan_meta "$plan" mountpoint)"
  return "$EXIT_SUCCESS"
}
