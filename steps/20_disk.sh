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
#  The hand-over to step 30                                                   #
# --------------------------------------------------------------------------- #
_step20_awaiting_container() {
  # True when this step has done all it can and step 30 must continue.
  #
  # An encrypted install needs the container to exist before any filesystem
  # does: the LUKS header lives in the partition, and a filesystem written there
  # first is a filesystem the header overwrites. disk_pv_device() already says
  # the disk layer "notices that a container is already open and builds on it",
  # so the missing piece was never the knowledge — it was the moment. Step 20
  # partitions and hands over; step 30 opens the container and calls the rest of
  # the provisioning on the mapper.
  #
  # Before this existed, an encrypted run formatted the partition, step 30 then
  # failed on the missing disk.crypt_device, and the run carried on to install
  # an unencrypted system onto a disk whose operator had asked for encryption.
  # Args: $1 = plan text. Returns 0 when step 30 takes over.
  local plan="$1" want mapper
  want="${CFG[crypt]:-none}"
  [[ "$want" != "none" ]] || return 1

  mapper="/dev/mapper/${CFG[crypt_name]:-gentoo}"
  if [[ -b "$mapper" ]]; then
    log "container ${mapper} is already open; filesystems go inside it"
    return 1
  fi
  return 0
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

  # Asked here rather than in disk_guard, because the plan is what says whether
  # a volume group will be made at all: disk_lvm defaults to auto, and auto
  # means "whatever the layout says".
  if ! disk_guard_vg_name "/dev/${name}" "$plan"; then
    return "$EXIT_FAILURE"
  fi

  if _step20_already_provisioned "$plan"; then
    skip "/dev/${name} is already partitioned, formatted and mounted as planned"
    disk_show_result "$plan"
    # shellcheck disable=SC2034  # lib/disk.sh reads it in _disk_assert_target
    DISK_CONFIRMED_TARGET="/dev/${name}"
    disk_record_plan_facts "$plan" || return "$EXIT_FAILURE"
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
  disk_record_crypt_device "$plan"

  # The handover. Everything below writes a filesystem, and with encryption
  # asked for there is nowhere to write one yet: the volume group would go on
  # the raw partition and the root filesystem into the bytes the LUKS header is
  # about to occupy. Step 30 opens the container and finishes from there.
  if _step20_awaiting_container "$plan"; then
    disk_record_plan_facts "$plan" || return "$EXIT_FAILURE"
    ok "step 20: /dev/${name} partitioned; step 30 creates the container and"
    log "         the filesystems go inside it"
    return "$EXIT_SUCCESS"
  fi

  if [[ "$(disk_plan_meta "$plan" lvm)" == "yes" ]]; then
    disk_create_volumes "$plan" || return "$EXIT_FAILURE"
  fi

  disk_format "$plan" || return "$EXIT_FAILURE"
  disk_mount_tree "$plan" || return "$EXIT_FAILURE"
  disk_verify "$plan" || return "$EXIT_FAILURE"
  disk_show_result "$plan"
  disk_record_plan_facts "$plan" || return "$EXIT_FAILURE"

  ok "step 20: /dev/${name} provisioned and mounted under $(disk_plan_meta "$plan" mountpoint)"
  return "$EXIT_SUCCESS"
}
