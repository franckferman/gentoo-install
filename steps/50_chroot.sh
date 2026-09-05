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

if [[ -z "${_GI_CHROOT_LOADED:-}" ]]; then
  # Sourcing a library is not a side effect: the file still defines everything
  # and runs nothing. It lets this step be sourced on its own, by a test or by
  # an operator, without depending on the order the entry point happens to use.
  _gi_step50_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
  # shellcheck source=lib/chroot.sh
  source "${_gi_step50_dir}/../lib/chroot.sh"
  unset _gi_step50_dir
fi

# --------------------------------------------------------------------------- #
#  The step                                                                   #
# --------------------------------------------------------------------------- #
step_50_chroot() {
  local target release

  target="$(chroot_target)"
  log "chroot target: ${target}"

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
