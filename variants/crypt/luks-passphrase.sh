#!/usr/bin/env bash
#
# gentoo-install — crypt variant: luks-passphrase
# ----------------------------------------------------------------------------
# LUKS2, and a passphrase typed at every boot. The default variant, because it
# is what most people want and because it depends on no hardware: no TPM, no
# key file, no second partition to keep in sync. If the machine boots, the
# passphrase opens it.
#
# It writes two keyslots, not one. The everyday passphrase lives in slot 0 and
# a recovery passphrase in slot 1, so that a mistyped-and-forgotten credential
# is an annoyance rather than a wiped disk. crypt_recovery = no drops the
# second slot and the run says, at that moment, what it is giving up.
#
# Usage:  crypt = luks-passphrase      (sourced by lib/crypt.sh)
#
set -euo pipefail

# Script-level, so verify() still sees what apply() made and the trap in
# lib/crypt.sh can wipe them whatever happens.
_LP_KEY_PRIMARY=""
_LP_KEY_RECOVERY=""
_LP_PROVISIONED="no"

crypt_variant_describe() {
  printf '%s\n' "LUKS2, passphrase typed at every boot"
}

crypt_variant_boot_note() {
  printf '%s\n' "the machine asks for a passphrase and waits for it"
}

crypt_variant_requires() {
  printf '%s\n' cryptsetup
}

crypt_variant_check() {
  crypt_require_device || return 1
  if crypt_already_provisioned "$CRYPT_DEVICE" "luks-passphrase"; then
    _LP_PROVISIONED="yes"
  fi
  return 0
}

crypt_variant_show() {
  local dev="$CRYPT_DEVICE"

  if [[ "$_LP_PROVISIONED" == "yes" ]]; then
    skip "${dev} already carries the container this run would build"
    skip "       UUID $(crypt_luks_uuid "$dev")"
    skip "       --restart forgets the journal and builds it again"
    skip "       crypt_wipe_luks = yes reformats it, destroying its keyslots"
    return 0
  fi

  log "$(printf '  device    %s' "$dev")"
  log "$(printf '  container LUKS2 %s, %s bits, %s' \
    "${CFG[crypt_cipher]}" "${CFG[crypt_key_size]}" "${CFG[crypt_pbkdf]}")"
  log "$(printf '  slot %-3s  passphrase typed at every boot' "${CFG[crypt_primary_slot]}")"
  if [[ "${CFG[crypt_recovery]}" == "yes" ]]; then
    log "$(printf '  slot %-3s  recovery passphrase, for the day the first one is gone' \
      "${CFG[crypt_recovery_slot]}")"
  else
    warn "no recovery keyslot (crypt_recovery = no)"
    warn "       one credential will stand between this machine and its data"
    warn "       forget it, mistype it at creation, or lose the note it is"
    warn "       written on, and the disk is unreadable — there is no reset"
    warn "       crypt_recovery = yes adds a second passphrase in slot ${CFG[crypt_recovery_slot]}"
  fi
  if crypt_is_luks "$dev"; then
    crypt_show_existing_header "$dev"
  fi
}

crypt_variant_apply() {
  local dev="$CRYPT_DEVICE"
  local boot_pass="" recovery_pass=""
  local record="${CFG[crypt_primary_slot]}:boot-passphrase"

  if [[ "$_LP_PROVISIONED" == "yes" ]]; then
    skip "${dev}: already provisioned, nothing rebuilt"
    # shellcheck disable=SC2034  # read by steps/30_crypt.sh after apply()
    CRYPT_RECORD="$record"
    return 0
  fi

  # Asked before anything is destroyed. An operator who changes their mind at
  # the passphrase prompt must find the disk exactly as they left it.
  crypt_read_passphrase boot_pass "boot passphrase for ${dev}" \
    crypt_pass_file GI_CRYPT_PASSPHRASE yes || return 1
  crypt_check_passphrase_strength "$boot_pass" "boot passphrase" || return 1

  if [[ "${CFG[crypt_recovery]}" == "yes" ]]; then
    crypt_read_passphrase recovery_pass "recovery passphrase for ${dev}" \
      crypt_recovery_pass_file GI_CRYPT_RECOVERY yes || return 1
    crypt_check_passphrase_strength "$recovery_pass" "recovery passphrase" || return 1
    if [[ "$recovery_pass" == "$boot_pass" ]]; then
      err "The recovery passphrase is the same as the boot passphrase"
      err "       two keyslots holding one secret is one way in, not two"
      err "       the point of the second slot is to survive losing the first"
      return 1
    fi
  fi

  _LP_KEY_PRIMARY="$(crypt_secret_file boot)" || return 1
  crypt_write_secret "$_LP_KEY_PRIMARY" "$boot_pass" || return 1
  if [[ -n "$recovery_pass" ]]; then
    _LP_KEY_RECOVERY="$(crypt_secret_file recovery)" || return 1
    crypt_write_secret "$_LP_KEY_RECOVERY" "$recovery_pass" || return 1
  fi

  crypt_confirm_format "$dev" || return 1

  log "creating the LUKS2 container on ${dev}"
  if ! crypt_luks_format "$dev" "$_LP_KEY_PRIMARY" "${CFG[crypt_primary_slot]}"; then
    err "luksFormat failed on ${dev}"
    return 1
  fi

  if [[ -n "$_LP_KEY_RECOVERY" ]]; then
    log "adding the recovery passphrase in slot ${CFG[crypt_recovery_slot]}"
    if ! crypt_add_key "$dev" "$_LP_KEY_PRIMARY" "$_LP_KEY_RECOVERY" \
      "${CFG[crypt_recovery_slot]}"; then
      err "could not add the recovery passphrase to ${dev}"
      err "       the container exists and the boot passphrase opens it"
      err "       it has one way in, which is one fewer than this variant promises"
      return 1
    fi
    record+=" ${CFG[crypt_recovery_slot]}:recovery-passphrase"
  fi

  if ! crypt_open "$dev" "${CFG[crypt_name]}" "$_LP_KEY_PRIMARY"; then
    err "the container was created but would not open as ${CFG[crypt_name]}"
    return 1
  fi

  # shellcheck disable=SC2034  # read by steps/30_crypt.sh after apply()

  CRYPT_RECORD="$record"
}

crypt_variant_verify() {
  local dev="$CRYPT_DEVICE" want=1

  if [[ "$_LP_PROVISIONED" == "yes" ]]; then
    # Nothing was built, so nothing new can be proved. Said plainly rather
    # than dressed up as a successful check.
    skip "${dev}: left as it was; this run proved no credential against it"
    skip "       the proof was made when the container was created"
    skip "       --restart rebuilds it and proves it again"
    return 0
  fi

  # The proofs. Each one goes through cryptsetup --test-passphrase with
  # --disable-external-tokens, which activates nothing and, more importantly,
  # keeps any LUKS2 token on this container from answering in place of the
  # file being tested.
  if ! crypt_test_key_file "$dev" "$_LP_KEY_PRIMARY" "${CFG[crypt_primary_slot]}"; then
    err "the boot passphrase does not open slot ${CFG[crypt_primary_slot]} on ${dev}"
    err "       the container was just created with it, so this should not happen"
    err "       do not reboot into it"
    return 1
  fi
  crypt_record_way_in "${CFG[crypt_primary_slot]}" "typed at every boot"

  if [[ -n "$_LP_KEY_RECOVERY" ]]; then
    if ! crypt_test_key_file "$dev" "$_LP_KEY_RECOVERY" "${CFG[crypt_recovery_slot]}"; then
      err "the recovery passphrase does not open slot ${CFG[crypt_recovery_slot]}"
      err "       a keyslot written and never read back is a keyslot whose"
      err "       state nobody knows, and this is the last moment the material"
      err "       to test it is still at hand"
      return 1
    fi
    crypt_record_way_in "${CFG[crypt_recovery_slot]}" "recovery, kept off the machine"
    want=2
  fi

  crypt_require_ways_in "$want" \
    "a LUKS container with no proved credential is a disk nobody can open" || return 1

  # The material has done its work; it does not outlive the step.
  crypt_wipe_secrets
  _LP_KEY_PRIMARY=""
  _LP_KEY_RECOVERY=""

  if ((want == 1)); then
    warn "this container has a single way in, because crypt_recovery = no"
    warn "       nothing else will open it: no key file, no TPM, no reset"
  fi
  return 0
}
