#!/usr/bin/env bash
#
# gentoo-install — step 30: encryption
# ----------------------------------------------------------------------------
# Picks one of the variants under variants/crypt/ and runs it. The step itself
# knows nothing about LUKS, TPMs or GPG: it validates, loads, plans, confirms,
# applies, and then refuses to declare the machine finished until the variant
# has proved, by exercising them, that there is more than one way back into the
# container. "none" is a variant like the others and says so out loud — a step
# that vanishes when encryption is off leaves the operator guessing.
#
# Usage:  ./gentoo-install.sh --steps 30    (see --help)
#
set -euo pipefail

if [[ -n "${_GI_STEP30_LOADED:-}" ]]; then
  return 0
fi
_GI_STEP30_LOADED=1

# The libraries this step needs. Each one is a no-op when it is already
# loaded, so sourcing them here costs nothing under the entry point and makes
# the step usable on its own — which is how it gets tested.
_gi_step30_self="$(readlink -f -- "${BASH_SOURCE[0]}")"
_gi_step30_root="${_gi_step30_self%/*}"
_gi_step30_root="${_gi_step30_root%/*}"
_gi_step30_lib="${GI_LIB_DIR:-${_gi_step30_root}/lib}"
for _gi_step30_dep in core config state ui crypt; do
  if [[ ! -r "${_gi_step30_lib}/${_gi_step30_dep}.sh" ]]; then
    printf 'gentoo-install: step 30 needs %s/%s.sh\n' \
      "$_gi_step30_lib" "$_gi_step30_dep" >&2
    return 1
  fi
done
unset _gi_step30_dep
# shellcheck source-path=SCRIPTDIR/..
# shellcheck source=lib/core.sh
source "${_gi_step30_lib}/core.sh"
# shellcheck source=lib/config.sh
source "${_gi_step30_lib}/config.sh"
# shellcheck source=lib/state.sh
source "${_gi_step30_lib}/state.sh"
# shellcheck source=lib/ui.sh
source "${_gi_step30_lib}/ui.sh"
# shellcheck source=lib/crypt.sh
source "${_gi_step30_lib}/crypt.sh"
unset _gi_step30_self _gi_step30_root _gi_step30_lib

# --------------------------------------------------------------------------- #
#  Rendering                                                                  #
# --------------------------------------------------------------------------- #
show_crypt_plan() {
  # Prints and changes nothing (DESIGN.md §7). Everything on stderr.
  local variant="$1"
  log "encryption plan"
  log "$(printf '  variant   %-18s %s' "$variant" "$(crypt_variant_describe)")"
  log "$(printf '  at boot   %s' "$(crypt_variant_boot_note)")"
  crypt_variant_show
}

show_crypt_result() {
  # The last word of the step, and the only one an operator will remember.
  local variant="$1"
  if [[ "$variant" == "none" ]]; then
    return 0
  fi
  crypt_show_ways_in
  warn "write the recovery credential down somewhere that is not this machine"
  warn "       a passphrase kept on the disk it opens is not a passphrase"
}

# --------------------------------------------------------------------------- #
#  The step                                                                   #
# --------------------------------------------------------------------------- #
step_30_crypt() {
  local variant

  # Idempotent: set_default never overwrites a flag or a configuration file,
  # so calling this again when the entry point already did is free.
  crypt_config_defaults
  crypt_validate_config

  variant="${CFG[crypt]}"

  if ! crypt_load_variant "$variant"; then
    return "$EXIT_FAILURE"
  fi

  # Stage 2 of DESIGN.md §5: the value is legal, is it available here? A
  # variant that needs a tool this machine does not have says which tool and
  # what to do about it, rather than dying on a command not found halfway
  # through editing a LUKS header.
  if ! crypt_require_variant_cmds; then
    err "       ${variant} cannot run here without them"
    err "       crypt = luks-passphrase needs cryptsetup and nothing else"
    return "$EXIT_FAILURE"
  fi

  if ! crypt_variant_check; then
    return "$EXIT_FAILURE"
  fi

  show_crypt_plan "$variant"

  # Nothing to confirm when nothing changes; the variant's own apply() asks
  # for the typed proof before it destroys anything.
  if [[ "$DRY_RUN" != "yes" ]] && ! confirm "Apply the ${variant} encryption plan?" "yes"; then
    skip "step 30: nothing done"
    return "$EXIT_SUCCESS"
  fi

  crypt_forget_ways_in

  # apply() acts and leaves its record in CRYPT_RECORD. It is called plainly,
  # never as "$(crypt_variant_apply)": a command substitution is a subshell,
  # and the secret files apply() registers for the trap would be forgotten the
  # moment it returned — the same trap lib/core.sh documents for its writers.
  CRYPT_RECORD=""
  if ! crypt_variant_apply; then
    err "step 30: ${variant} could not be applied"
    return "$EXIT_FAILURE"
  fi

  # verify() is the part no flag lifts. --force lifts confirmations, it does
  # not lift proofs: a machine is not finished until a way back into it has
  # been exercised, here, now.
  if ! crypt_variant_verify; then
    err "step 30: ${variant} was applied but could not be proved"
    err "       do not reboot into this container yet"
    return "$EXIT_FAILURE"
  fi

  show_crypt_result "$variant"

  # shellcheck disable=SC2086  # the record is a deliberate word list
  crypt_state_record "$variant" "${CRYPT_DEVICE:-}" ${CRYPT_RECORD}
  return "$EXIT_SUCCESS"
}
