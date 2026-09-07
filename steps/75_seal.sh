#!/usr/bin/env bash
#
# gentoo-install — step 75: the sealing
# ----------------------------------------------------------------------------
# What the encryption variant still owes the target, done inside the target.
#
# Only one variant owes anything today, and the reason it does is worth having
# in the file rather than in a commit message. luks-tpm seals a keyslot with
# clevis, and clevis is not on the Gentoo minimal ISO — no jose, no tpm2-tools
# either, and no way to add them there: that medium carries no ebuild
# repository. Sealing from the live medium therefore refused on the one medium
# the handbook tells everyone to boot, which a test run established by hitting
# exactly that wall.
#
# Step 70 already installs clevis into the target, because the initramfs needs
# it to unlock at boot. So this step runs afterwards and binds from inside,
# with the very binaries that will have to release the key at every boot: the
# version that seals is the version that unseals, which is a stronger proof
# than the live medium could ever give.
#
# What the number buys, beyond ordering:
#
#   --skip-steps 75      install now, seal later, deliberately.
#   --steps 50,75        seal a target that is already installed — after a
#                        BIOS update, or a run that stopped before this point.
#
# A variant with nothing to seal says so and the step succeeds: a step that
# vanishes when it has no work leaves the operator guessing (DESIGN.md §4).
#
# Usage:  ./gentoo-install.sh --steps 75    (see --help)
#
set -euo pipefail

if [[ -n "${_GI_STEP75_LOADED:-}" ]]; then
  return 0
fi
_GI_STEP75_LOADED=1

_gi_step75_self="$(readlink -f -- "${BASH_SOURCE[0]}")"
_gi_step75_root="${_gi_step75_self%/*}"
_gi_step75_root="${_gi_step75_root%/*}"
_gi_step75_lib="${GI_LIB_DIR:-${_gi_step75_root}/lib}"
for _gi_step75_dep in core config state ui crypt chroot; do
  if [[ ! -r "${_gi_step75_lib}/${_gi_step75_dep}.sh" ]]; then
    printf 'gentoo-install: step 75 needs %s/%s.sh\n' \
      "$_gi_step75_lib" "$_gi_step75_dep" >&2
    return 1
  fi
done
unset _gi_step75_dep
# shellcheck source-path=SCRIPTDIR/..
# shellcheck source=lib/core.sh
source "${_gi_step75_lib}/core.sh"
# shellcheck source=lib/config.sh
source "${_gi_step75_lib}/config.sh"
# shellcheck source=lib/state.sh
source "${_gi_step75_lib}/state.sh"
# shellcheck source=lib/ui.sh
source "${_gi_step75_lib}/ui.sh"
# shellcheck source=lib/crypt.sh
source "${_gi_step75_lib}/crypt.sh"
# shellcheck source=lib/chroot.sh
source "${_gi_step75_lib}/chroot.sh"
unset _gi_step75_self _gi_step75_root _gi_step75_lib

# --------------------------------------------------------------------------- #
#  The target this runs in                                                    #
# --------------------------------------------------------------------------- #
_step75_target_ready() {
  # The tree, and the device nodes inside it. Both are step 50's work, and a
  # missing one gives a different message because it has a different fix.
  local root="$1"

  if [[ ! -d "$root" ]]; then
    err "Target root does not exist: ${root}"
    err "       step 50 mounts it; the sealing happens inside it"
    err "       example:  ./gentoo-install.sh --steps 50,75"
    return 1
  fi

  chroot_attach "$root" || return 1

  if [[ "$DRY_RUN" == "yes" ]]; then
    return 0
  fi

  # clevis talks to the chip through a device node, so /dev has to be bound in.
  # Without this the failure arrives inside clevis, as a tpm2 error about a
  # missing TCTI, which names nothing an operator can act on.
  if ! chroot_run_quiet test -c /dev/tpmrm0 && ! chroot_run_quiet test -c /dev/tpm0; then
    err "No TPM device inside ${root}"
    err "       the chip is reached through /dev/tpmrm0, and /dev has to be"
    err "       bound into the target for anything in there to see it"
    err "       step 50 mounts the pseudo-filesystems; this step needs them"
    err "       example:  ./gentoo-install.sh --steps 50,75"
    return 1
  fi
  return 0
}

# --------------------------------------------------------------------------- #
#  The step                                                                   #
# --------------------------------------------------------------------------- #
step_75_seal() {
  local variant root

  crypt_config_defaults

  # The journal, not the settings. This step can be reached on its own —
  # --steps 75 is exactly what an operator runs after fixing a TPM — and a run
  # launched without the configuration file has only defaults, which say
  # luks-passphrase. Sealing a luks-tpm machine then loaded the passphrase
  # variant, found it defines no crypt_variant_seal, and returned success with
  # "luks-passphrase has nothing to seal in the target": the TPM was never
  # sealed, the step reported done, and the machine asked for the recovery
  # passphrase at every boot for ever after.
  variant="$(target_fact crypt crypt.variant "none")"

  if [[ "$variant" == "none" ]]; then
    skip "crypt = none: there is no container to seal"
    return "$EXIT_SUCCESS"
  fi

  if ! crypt_load_variant "$variant"; then
    return "$EXIT_FAILURE"
  fi

  if ! declare -F crypt_variant_seal >/dev/null 2>&1; then
    skip "${variant} has nothing to seal in the target"
    skip "       $(crypt_variant_boot_note)"
    return "$EXIT_SUCCESS"
  fi

  root="$(chroot_target)"
  _step75_target_ready "$root" || return "$EXIT_FAILURE"

  # From here on every clevis command runs inside the target.
  CRYPT_CLEVIS_IN_TARGET="yes"

  # Armed in this shell and not in a subshell, for the reason lib/crypt.sh
  # spells out in crypt_secret_file(): the trap this installs calls cleanup(),
  # which unmounts the target.
  crypt_arm_secret_trap

  CRYPT_RECORD=""
  if ! crypt_variant_seal; then
    err "step 75: ${variant} could not be sealed"
    err "       the container and its recovery passphrase are untouched"
    err "       the machine boots and asks for that passphrase"
    return "$EXIT_FAILURE"
  fi

  crypt_show_ways_in

  if [[ -n "$CRYPT_RECORD" ]]; then
    # shellcheck disable=SC2086  # the record is a deliberate word list
    crypt_state_record "$variant" "${CRYPT_DEVICE:-}" ${CRYPT_RECORD}
  fi
  return "$EXIT_SUCCESS"
}
