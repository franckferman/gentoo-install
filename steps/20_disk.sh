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
_step20_record() {
  # What steps 30, 50, 80 and 90 need, and nothing they do not. The journal
  # records what was done, never with what: no passphrase, no key.
  # Args: $1 = plan text.
  local plan="$1" root esp path

  root="$(disk_plan_meta "$plan" mountpoint)"
  esp="$(disk_plan_device_for "$plan" "${CFG[disk_esp_mount]}")"

  state_set disk.device "$(disk_plan_meta "$plan" device)"
  state_set disk.layout "$(disk_plan_meta "$plan" layout)"
  state_set disk.lvm "$(disk_plan_meta "$plan" lvm)"
  state_set disk.vg "$(disk_plan_meta "$plan" vg)"
  state_set disk.mountpoint "$root"
  state_set disk.filesystem "${CFG[disk_filesystem]}"
  state_set disk.esp "${esp}"
  state_set disk.esp_mount "${CFG[disk_esp_mount]}"
  state_set disk.root "$(disk_plan_device_for "$plan" /)"

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

  if [[ "$(disk_plan_meta "$plan" lvm)" == "yes" ]]; then
    disk_create_volumes "$plan" || return "$EXIT_FAILURE"
  fi

  disk_format "$plan" || return "$EXIT_FAILURE"
  disk_mount_tree "$plan" || return "$EXIT_FAILURE"
  disk_verify "$plan" || return "$EXIT_FAILURE"
  disk_show_result "$plan"
  _step20_record "$plan" || return "$EXIT_FAILURE"

  ok "step 20: /dev/${name} provisioned and mounted under $(disk_plan_meta "$plan" mountpoint)"
  return "$EXIT_SUCCESS"
}
