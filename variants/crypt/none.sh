#!/usr/bin/env bash
#
# gentoo-install — crypt variant: none
# ----------------------------------------------------------------------------
# No encryption. The variant exists so that the step still runs, still prints,
# and still records what was decided: a step that disappears when a feature is
# off leaves the operator wondering whether it was skipped or forgotten. This
# one says, in as many words, that the disk will be readable by whoever ends up
# holding it — and then does nothing at all, which is the whole point.
#
# Usage:  crypt = none        (sourced by lib/crypt.sh, never executed)
#
set -euo pipefail

crypt_variant_describe() {
  printf '%s\n' "no encryption at all"
}

crypt_variant_boot_note() {
  printf '%s\n' "nothing is asked at boot, and nothing protects the disk"
}

crypt_variant_requires() {
  # Nothing. That is the one advantage this variant has.
  return 0
}

crypt_variant_check() {
  # A device is not required — there is nothing to encrypt — but if one is
  # known, its current state is worth reporting before the plan is printed.
  if crypt_resolve_device >/dev/null 2>&1; then
    CRYPT_DEVICE="$(crypt_resolve_device)"
  else
    CRYPT_DEVICE=""
  fi
  return 0
}

crypt_variant_show() {
  # Rendering only, on stderr, changes nothing.
  warn "encryption is OFF (crypt = none)"
  warn "       anyone who takes this disk out of the machine reads everything"
  warn "       on it: no passphrase, no key, no TPM stands in the way"
  warn "       a stolen laptop is a data breach, not an inconvenience"
  warn "       crypt = luks-passphrase is the default and asks for a"
  warn "       passphrase at every boot; it needs no hardware at all"

  if [[ -n "$CRYPT_DEVICE" ]] && crypt_is_luks "$CRYPT_DEVICE"; then
    warn "${CRYPT_DEVICE} already carries a LUKS header"
    warn "       this variant leaves it exactly as it is: it removes nothing"
    warn "       and opens nothing, so the later steps will not find a"
    warn "       filesystem where they expect one"
    warn "       crypt = luks-passphrase reuses that device properly"
  fi
}

crypt_variant_apply() {
  # Acts on nothing and leaves an empty record. The engine half of §7 with no
  # engine in it.
  log "no encryption to set up"
  # shellcheck disable=SC2034  # read by steps/30_crypt.sh after apply()
  CRYPT_RECORD=""
}

crypt_variant_verify() {
  # There is no credential to exercise, so there is nothing to prove. Saying
  # so is not a formality: every other variant ends with a proof, and an
  # operator comparing two runs must see why this one does not.
  skip "nothing to verify: this machine has no encrypted container"
  if [[ -n "$CRYPT_DEVICE" ]] && crypt_is_luks "$CRYPT_DEVICE"; then
    warn "${CRYPT_DEVICE} still holds the LUKS header it had before this run"
    warn "       gentoo-install did not touch it and cannot open it"
  fi
  return 0
}
