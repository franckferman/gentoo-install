#!/usr/bin/env bash
#
# gentoo-install — step 50: mount the pseudo-filesystems and enter the chroot
# ----------------------------------------------------------------------------
# Turns the unpacked stage3 under the target root into something commands can
# run in: /proc, /sys, /dev (with pts and shm), /run and the EFI system
# partition mounted, /etc/resolv.conf copied in, and a proof that a command
# really does execute inside before any later step assumes it.
#
# The mounts stay up when this step returns: steps 60 to 90 all run inside
# them, and step 95 releases them. core.sh's EXIT trap releases them too, so an
# interrupted run does not leave the target half-mounted.
#
# Usage:  source steps/50_chroot.sh   (needs lib/core.sh and lib/chroot.sh)
#
set -euo pipefail

if [[ -z "${_GI_CHROOT_LOADED:-}" || -z "${_GI_DISK_LOADED:-}" || -z "${_GI_CRYPT_LOADED:-}" ]]; then
  # Sourcing a library is not a side effect: the file still defines everything
  # and runs nothing. It lets this step be sourced on its own, by a test or by
  # an operator, without depending on the order the entry point happens to use.
  #
  # disk and crypt are here for the reattachment below: this step is the one an
  # operator returns to, and returning means opening a container and mounting a
  # tree that another process left behind.
  _gi_step50_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
  # shellcheck source=lib/chroot.sh
  source "${_gi_step50_dir}/../lib/chroot.sh"
  # shellcheck source=lib/disk.sh
  source "${_gi_step50_dir}/../lib/disk.sh"
  # shellcheck source=lib/crypt.sh
  source "${_gi_step50_dir}/../lib/crypt.sh"
  unset _gi_step50_dir
fi

# --------------------------------------------------------------------------- #
#  Getting back to a target another process left behind                       #
# --------------------------------------------------------------------------- #
_step50_reattach() {
  # Mount the tree the recorded plan describes, when it is not mounted.
  #
  # Only step 20 ever mounted the target, and the run releases everything it
  # mounted when it ends. So the second invocation of this installer — a
  # --resume after an interruption, a --steps 70,80 to finish a job, the exact
  # sequence step 95 prints when it fails — arrived at an empty /mnt/gentoo and
  # went on to mount /proc and /dev over nothing. The way back in was to reach
  # for tools/luks-open.sh, which is a rescue tool, for the ordinary case of
  # picking up where the last run stopped.
  #
  # The plan step 20 wrote down is what makes this exact rather than a guess: it
  # names the devices, the mountpoints and the order. Nothing here formats
  # anything, and disk_mount_tree refuses to stack a mount on someone else's.
  local plan root device

  plan="$(disk_saved_plan)" || {
    # No plan means nothing partitioned this target; --root points at a tree
    # somebody else prepared, which is a supported way to use this.
    return 0
  }

  if disk_target_is_mounted "$plan"; then
    return 0
  fi

  root="$(disk_plan_meta "$plan" mountpoint)"
  device="$(disk_plan_meta "$plan" device)"
  log "${root} is not mounted; the plan step 20 recorded says what belongs there"

  # A plan naming the disk this machine booted from is a plan from another life
  # — a stale state directory, most often — and acting on it would activate a
  # volume group and mount a running system's filesystems under /mnt/gentoo.
  #
  # The predicate is disk_target_carries_this_system and deliberately not
  # disk_may_write_firmware_state, which answers a different question and
  # answers it the other way round: writing an NVRAM entry for the disk you
  # booted from is the normal case, and mounting that same disk's tree is the
  # one to refuse. The first version of this guard used it, and the test that
  # covered it stubbed the predicate — so the stub agreed with the mistake and
  # the test passed.
  if [[ -n "$device" ]] && disk_target_carries_this_system "$device"; then
    err "the recorded plan describes ${device}, which is this machine's own disk"
    err "       ${STATE_DIR:-/var/lib/gentoo-install} holds a plan from another install"
    err "       nothing was mounted; --restart forgets that plan"
    err "       example:  ./gentoo-install.sh --restart --steps 20"
    return 1
  fi

  # The journal decides here, not the settings — this step exists for the
  # second invocation, and the second invocation is the one launched without
  # the configuration file that named the container. target_fact's own comment
  # says why: a *default* loses to the record of what was done, because
  # config_init_defaults gives crypt a non-empty default (luks-passphrase) and
  # crypt_name a non-empty default (gentoo).
  #
  # Reading CFG here cost both directions. An install the operator asked NOT to
  # encrypt was reattached by trying to open a LUKS container on a partition
  # with no header, and step 50 failed with "the target could not be made
  # reachable" on a machine that needed no container at all. And an install
  # with crypt_name = vault was reopened as /dev/mapper/gentoo, which is not
  # the device the recorded plan names, so the mount failed and a mapping under
  # the wrong name was left behind on the way out.
  local variant
  variant="$(target_fact crypt crypt.variant "none")"
  if [[ "$variant" != "none" ]]; then
    local container name
    name="$(target_fact crypt_name crypt.name "gentoo")"
    if ! crypt_is_open "$name"; then
      container="$(target_fact crypt_device crypt.device "")"
      [[ -n "$container" ]] || container="$(target_fact "" disk.crypt_device "")"
      if [[ -z "$container" ]]; then
        err "crypt = ${variant} but no container is recorded"
        err "       step 20 writes disk.crypt_device and step 30 writes crypt.device"
        err "       name it yourself with crypt_device = /dev/nvme0n1p2"
        return 1
      fi
      crypt_open_for_resume "$container" "$name" || return 1
    fi
  fi

  disk_activate_volume_group "$plan" || return 1
  disk_mount_tree "$plan" || return 1
  return 0
}

# --------------------------------------------------------------------------- #
#  The step                                                                   #
# --------------------------------------------------------------------------- #
step_50_chroot() {
  local target release

  target="$(chroot_target)"
  log "chroot target: ${target}"

  if ! _step50_reattach; then
    err "step 50: the target could not be made reachable"
    err "       nothing is mounted and nothing was changed"
    return "$EXIT_FAILURE"
  fi

  if ! chroot_prepare "$target"; then
    err "step 50: the chroot could not be prepared"
    # Release whatever did mount before giving up, so the next attempt starts
    # from a known state instead of adopting half of the last one.
    chroot_cleanup || true
    return "$EXIT_FAILURE"
  fi

  # The proof. Everything after this step assumes a command can run inside the
  # target; finding out here costs one fork, finding out in step 70 costs the
  # three hours that led up to it.
  if ! chroot_run_quiet /bin/true; then
    err "step 50: ${target} is mounted but no command runs inside it"
    err "       a 32-bit or foreign-architecture stage3 on a 64-bit host looks like this"
    err "       check it by hand:  $(chroot_command_hint)"
    chroot_cleanup || true
    return "$EXIT_FAILURE"
  fi

  if release="$(chroot_capture cat /etc/gentoo-release)" && [[ -n "$release" ]]; then
    ok "chroot answers: ${release}"
  else
    # Not fatal: /etc/gentoo-release is absent from a target that is not Gentoo
    # yet, and --dry-run reads nothing at all.
    log "chroot answers, but /etc/gentoo-release says nothing yet"
  fi

  show_chroot_status

  state_set "chroot.target" "$target"
  state_set "chroot.mounts" "${#_GI_CHROOT_OWNED[@]}"
  if [[ -n "$_GI_CHROOT_ESP_DEVICE" ]]; then
    state_set "chroot.esp" "$_GI_CHROOT_ESP_DEVICE"
  fi

  log "the mounts stay up for steps 60-90; step 95 releases them"
  log "to look around by hand, from another terminal:"
  log "       $(chroot_command_hint)"

  return "$EXIT_SUCCESS"
}
