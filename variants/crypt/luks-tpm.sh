#!/usr/bin/env bash
#
# gentoo-install — crypt variant: luks-tpm
# ----------------------------------------------------------------------------
# LUKS2 sealed to the TPM with clevis: the machine unlocks itself as long as
# the firmware measures the same as it did on the day of the sealing.
#
# Two things are not negotiable here, and both were paid for on real machines.
# A recovery passphrase goes into its own keyslot, always — a TPM that stops
# releasing the key after a BIOS update is a documented incident, and without
# a second slot it is a rebuild. And the sealing is exercised before this step
# reports success: `clevis luks list` shows the token exactly the same way
# whether the TPM honours it or refuses it, so the only verdict is to make the
# TPM do the work and check what it hands back against the keyslot.
#
# Usage:  crypt = luks-tpm             (sourced by lib/crypt.sh)
#
set -euo pipefail

_LT_KEY_RECOVERY=""
_LT_PROVISIONED="no"

crypt_variant_describe() {
  printf '%s\n' "LUKS2 unlocked by the TPM, recovery passphrase in another slot"
}

crypt_variant_boot_note() {
  printf '%s\n' "nothing is asked while the firmware is unchanged; the recovery passphrase otherwise"
}

crypt_variant_requires() {
  # clevis and the TPM stack are diagnosed in check(), one message per cause,
  # rather than lumped into a list of missing binaries.
  printf '%s\n' cryptsetup
}

_lt_refuse_no_clevis() {
  err "clevis is not installed, and luks-tpm cannot work without it"
  err "       clevis luks bind is what seals the key into the TPM; there is"
  err "       no substitute this module can fall back on"
  err "       it has to be installed where the binding happens — in the target"
  err "       system or its chroot, not on the live medium that is running now"
  err "       Gentoo:        emerge --ask app-crypt/clevis app-crypt/tpm2-tools"
  err "       Debian/Ubuntu: apt install clevis clevis-luks clevis-tpm2"
  err "       no TPM, or none you want to depend on:  crypt = luks-passphrase"
}

_lt_refuse_no_tpm2_tools() {
  err "clevis is here but the tpm2 pin's helpers are not"
  err "       clevis-encrypt-tpm2 shells out to tpm2_createprimary, tpm2_create,"
  err "       tpm2_load and tpm2_unseal; without them the binding fails at the"
  err "       moment it edits the LUKS header, which is the worst moment"
  err "       Gentoo:        emerge --ask app-crypt/tpm2-tools"
  err "       Debian/Ubuntu: apt install tpm2-tools"
}

_lt_refuse_no_tpm() {
  err "no TPM 2.0 device on this machine"
  err "       looked for /dev/tpmrm0, /dev/tpm0 and /sys/class/tpm/tpm0"
  err "       in a chroot, the resource manager device has to be bound in"
  err "       before clevis can talk to the chip"
  err "       the firmware setup may also have the TPM switched off"
  err "       crypt = luks-passphrase needs no hardware at all"
}

_lt_refuse_no_recovery() {
  err "crypt_recovery = no, and luks-tpm will not run that way"
  err "       the TPM is the only thing releasing the key, and it stops doing"
  err "       so on a BIOS update, a firmware setting, a moved disk — none of"
  err "       which is a fault, all of which are ordinary"
  err "       a machine sealed with no second keyslot is a machine one flash"
  err "       away from a rebuild; the recovery passphrase is the condition"
  err "       for this variant to exist, not an option on it"
  err "       crypt_recovery = yes, or crypt = luks-passphrase"
}

crypt_variant_check() {
  crypt_require_device || return 1

  if [[ "${CFG[crypt_recovery]}" != "yes" ]]; then
    _lt_refuse_no_recovery
    return 1
  fi

  if ! have clevis; then
    _lt_refuse_no_clevis
    return 1
  fi
  if ! have tpm2_createprimary && ! have tpm2_create; then
    _lt_refuse_no_tpm2_tools
    return 1
  fi
  if ! have jose; then
    warn "jose is not in PATH; clevis needs it to build its JWE"
    warn "       Gentoo: emerge --ask app-crypt/jose"
  fi
  if ! crypt_tpm_present; then
    _lt_refuse_no_tpm
    return 1
  fi

  if crypt_already_provisioned "$CRYPT_DEVICE" "luks-tpm"; then
    _LT_PROVISIONED="yes"
  fi
  return 0
}

crypt_variant_show() {
  local dev="$CRYPT_DEVICE"

  if [[ "$_LT_PROVISIONED" == "yes" ]]; then
    skip "${dev} already carries the container this run would build"
    skip "       UUID $(crypt_luks_uuid "$dev")"
    skip "       --restart forgets the journal and builds it again"
    return 0
  fi

  log "$(printf '  device    %s' "$dev")"
  log "$(printf '  container LUKS2 %s, %s bits, %s' \
    "${CFG[crypt_cipher]}" "${CFG[crypt_key_size]}" "${CFG[crypt_pbkdf]}")"
  log "$(printf '  slot %-3s  recovery passphrase — the human way in, never' \
    "${CFG[crypt_primary_slot]}")"
  log "            touched by clevis, so a reseal can never remove it"
  log "$(printf '  slot %-3s  a key clevis draws for itself and seals to the TPM' \
    "${CFG[crypt_tpm_slot]}")"
  log "            it is not a copy of the passphrase: the two slots hold two"
  log "            different secrets, protected in two different ways"
  crypt_pcr_rationale
  warn "the TPM releasing the key today is not a promise about tomorrow"
  warn "       a BIOS update changes PCR 0 and the sealing stops matching"
  warn "       that is not a fault; the machine asks for the recovery"
  warn "       passphrase and boots, and the binding is made again afterwards"
  if crypt_is_luks "$dev"; then
    crypt_show_existing_header "$dev"
  fi
}

crypt_variant_apply() {
  local dev="$CRYPT_DEVICE"
  local recovery_pass=""
  local record="${CFG[crypt_primary_slot]}:recovery-passphrase"

  if [[ "$_LT_PROVISIONED" == "yes" ]]; then
    skip "${dev}: already provisioned, nothing rebuilt"
    # shellcheck disable=SC2034  # read by steps/30_crypt.sh after apply()
    CRYPT_RECORD="${record} ${CFG[crypt_tpm_slot]}:tpm2"
    return 0
  fi

  # Read before anything is destroyed, and mandatory: apply() must not be able
  # to reach luksFormat without the second way in already in hand.
  crypt_read_passphrase recovery_pass "recovery passphrase for ${dev}" \
    crypt_recovery_pass_file GI_CRYPT_RECOVERY yes || return 1
  crypt_check_passphrase_strength "$recovery_pass" "recovery passphrase" || return 1

  _LT_KEY_RECOVERY="$(crypt_secret_file recovery)" || return 1
  crypt_write_secret "$_LT_KEY_RECOVERY" "$recovery_pass" || return 1

  crypt_confirm_format "$dev" || return 1

  log "creating the LUKS2 container on ${dev}"
  if ! crypt_luks_format "$dev" "$_LT_KEY_RECOVERY" "${CFG[crypt_primary_slot]}"; then
    err "luksFormat failed on ${dev}"
    return 1
  fi

  # Proved before the TPM is involved at all. If the sealing then fails, the
  # machine is not stranded: it boots, it just asks for the passphrase.
  if ! crypt_test_key_file "$dev" "$_LT_KEY_RECOVERY" "${CFG[crypt_primary_slot]}"; then
    err "the recovery passphrase does not open the container just made with it"
    err "       nothing is sealed to the TPM; the container has no proved way in"
    return 1
  fi
  crypt_record_way_in "${CFG[crypt_primary_slot]}" "recovery, typed when the TPM refuses"

  if ! crypt_open "$dev" "${CFG[crypt_name]}" "$_LT_KEY_RECOVERY"; then
    err "the container was created but would not open as ${CFG[crypt_name]}"
    return 1
  fi

  log "sealing a key into the TPM, slot ${CFG[crypt_tpm_slot]}, policy $(crypt_pcr_policy)"
  if ! crypt_clevis_bind "$dev" "$_LT_KEY_RECOVERY" "${CFG[crypt_tpm_slot]}"; then
    err "clevis could not bind ${dev} to the TPM"
    err "       the container exists and the recovery passphrase opens it,"
    err "       proved a moment ago, so this machine boots — it will ask"
    err "       to retry by hand, once the cause is understood:"
    err "         clevis luks bind -k FILE -s ${CFG[crypt_tpm_slot]} -d ${dev} tpm2 '$(crypt_pcr_policy)'"
    return 1
  fi

  # shellcheck disable=SC2034  # read by steps/30_crypt.sh after apply()

  CRYPT_RECORD="${record} ${CFG[crypt_tpm_slot]}:tpm2"
}

crypt_variant_verify() {
  local dev="$CRYPT_DEVICE" slot="${CFG[crypt_tpm_slot]}" real

  if [[ "$_LT_PROVISIONED" == "yes" ]]; then
    skip "${dev}: left as it was; this run proved no credential against it"
    skip "       tpm-reseal is the tool for re-exercising an existing sealing"
    return 0
  fi

  # Which slot clevis really owns, read from its own listing rather than
  # assumed: a container bound elsewhere would otherwise be verified on the
  # wrong slot and pass for the wrong reason.
  if real="$(crypt_clevis_slot "$dev")" && [[ "$real" != "$slot" ]]; then
    warn "clevis reports keyslot ${real}, not ${slot}; verifying ${real}"
    slot="$real"
  fi

  if ! clevis luks list -d "$dev" 2>/dev/null | grep -q tpm2; then
    err "no tpm2 token on ${dev} after binding"
    err "       the machine will ask for the recovery passphrase at every boot"
    return 1
  fi
  log "a tpm2 token is present — which proves a token exists, and nothing more"

  log "asking the TPM to release what was just sealed"
  if ! crypt_clevis_verify_seal "$dev" "$slot"; then
    err "the binding was created, but the TPM does not honour it"
    err "       do not hand this machine over as unlocking on its own: it"
    err "       will ask for the recovery passphrase at the next boot"
    err "       slot ${CFG[crypt_primary_slot]} was proved above, so it does boot"
    return 1
  fi
  crypt_record_way_in "$slot" "the TPM releases it while the firmware is unchanged"

  crypt_require_ways_in 2 \
    "a container that only the TPM opens is one BIOS update from a rebuild" || return 1

  crypt_wipe_secrets
  _LT_KEY_RECOVERY=""
  return 0
}
