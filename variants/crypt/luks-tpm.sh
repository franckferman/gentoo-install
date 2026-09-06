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
# a second slot it is a rebuild. And the sealing is exercised before it is
# reported: `clevis luks list` shows the token exactly the same way whether the
# TPM honours it or refuses it, so the only verdict is to make the TPM do the
# work and check what it hands back against the keyslot.
#
# This variant runs in two halves, and the reason is worth stating.
#
#   step 30  creates the container, proves the recovery passphrase opens it,
#            and opens it. Nothing here needs anything the live medium does
#            not have: cryptsetup, and that is all.
#   step 75  seals a second slot to the TPM, from inside the target.
#
# It was one half until a test run on install-amd64-minimal.iso — the medium
# the Gentoo handbook tells everyone to boot — stopped at step 30 because that
# ISO ships no clevis, no jose and no tpm2-tools, and cannot install them: it
# carries no ebuild repository. The refusal even said so, and said it was the
# target that needed them. A variant unusable on the standard medium is a
# variant that does not work.
#
# So the binding happens where clevis is already going to be installed — step
# 70 puts it in the target for the initramfs — and with the very binaries that
# have to release the key at every boot afterwards. That makes the proof
# stronger, not weaker: the version that seals is the version that unseals.
# The PCRs bound here (0, 2, 3, 6) measure the firmware and its option ROMs,
# never the running system, so a value sealed from inside the chroot is the
# value the installed system finds at boot.
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
  # Raised by the seal, about the target — never about the live medium, which
  # is not asked to have any of this.
  err "the target has no clevis, and the sealing cannot happen without it"
  err "       clevis luks bind is what seals the key into the TPM; there is"
  err "       no substitute this module can fall back on"
  err "       app-crypt/clevis is not in the official Gentoo repository, which"
  err "       an install run found the hard way: GURU carries it, keyworded"
  err "       ~amd64, so both of these are needed in the target"
  err "         eselect repository enable guru && emaint sync -r guru"
  err "         echo '*/*::guru ~amd64' >> /etc/portage/package.accept_keywords/guru"
  err "         emerge --ask app-crypt/clevis"
  err "       nothing is lost meanwhile: the container is built and the"
  err "       recovery passphrase opens it, proved, so the machine boots and"
  err "       asks for it at every boot"
  err "       once clevis is in the target:  ./gentoo-install.sh --steps 50,75"
}

_lt_refuse_no_tpm2_tools() {
  err "the target has clevis but not the tpm2 pin's helpers"
  err "       clevis-encrypt-tpm2 shells out to tpm2_createprimary, tpm2_create,"
  err "       tpm2_load and tpm2_unseal; without them the binding fails at the"
  err "       moment it edits the LUKS header, which is the worst moment"
  err "       in the target:  emerge --ask app-crypt/tpm2-tools"
}

_lt_refuse_no_tpm() {
  err "no TPM 2.0 device on this machine"
  err "       looked for /dev/tpmrm0, /dev/tpm0 and /sys/class/tpm/tpm0"
  err "       asked here, before anything is destroyed, because the machine"
  err "       that seals and the machine that installs are the same one"
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

  # The chip, and only the chip. clevis, jose and the tpm2 helpers are asked
  # for in step 75, of the target, because that is where they run — the live
  # medium is never required to carry them.
  if ! crypt_tpm_present; then
    _lt_refuse_no_tpm
    return 1
  fi

  # Said before anything is destroyed, because it is knowable now and because
  # its answer changes what the operator gets. It is a warning and not a
  # refusal: this variant's container is a LUKS2 container with a proved
  # recovery passphrase whether or not a slot is ever sealed, and an operator
  # who enables the overlay between step 30 and step 75 gets both.
  warn "app-crypt/clevis is not in the official Gentoo repository"
  warn "       the sealing in step 75 needs it in the target, from GURU, where"
  warn "       it is also unstable-keyworded — so it takes two steps there:"
  warn "         eselect repository enable guru && emaint sync -r guru"
  warn "         echo '*/*::guru ~amd64' >> /etc/portage/package.accept_keywords/guru"
  warn "       without it this run ends with a working encrypted machine that"
  warn "       asks for the recovery passphrase at every boot, and says so"

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
  log "  when      the container is built here, in step 30; the slot above is"
  log "            sealed in step 75, inside the target, with the clevis that"
  log "            has to release it at every boot afterwards"
  warn "the TPM releasing the key today is not a promise about tomorrow"
  warn "       a BIOS update changes PCR 0 and the sealing stops matching"
  warn "       that is not a fault; the machine asks for the recovery"
  warn "       passphrase and boots, and the binding is made again afterwards"
  if crypt_is_luks "$dev"; then
    crypt_show_existing_header "$dev"
  fi
}

_lt_recorded_tpm_slot() {
  # The slot the journal says clevis owns, or nothing. A returned value, so
  # stdout. Read rather than assumed: it is the only thing on this medium that
  # knows whether a sealing ever happened, and on which slot.
  local slots entry
  declare -F state_get >/dev/null 2>&1 || return 0
  slots="$(state_get 'crypt.slots' 2>/dev/null || true)"
  for entry in $slots; do
    if [[ "$entry" == *:tpm2 ]]; then
      printf '%s\n' "${entry%%:*}"
      return 0
    fi
  done
  return 0
}

crypt_variant_apply() {
  local dev="$CRYPT_DEVICE"
  local recovery_pass=""
  local record="${CFG[crypt_primary_slot]}:recovery-passphrase"

  if [[ "$_LT_PROVISIONED" == "yes" ]]; then
    skip "${dev}: already provisioned, nothing rebuilt"
    # What the journal already says about the TPM slot, and nothing invented.
    #
    # This asserted crypt_tpm_slot outright, and it was wrong in both
    # directions. On a machine where step 75 never succeeded — no TPM in the
    # target, clevis absent, a sealing the chip refused, all of which this
    # project has hit — a --resume wrote into the journal that the TPM opens
    # this container. And where the sealing did succeed, clevis may have taken
    # another slot: it picks the first free one when the one asked for is busy,
    # as crypt_variant_seal says a few lines down while reading the real slot
    # back. So the resume replaced a true record with the configured number.
    #
    # Step 75 writes the tpm2 entry when it has actually sealed something, on
    # every pass including a re-run. Nothing here has to guess it.
    local recorded
    recorded="$(_lt_recorded_tpm_slot)"
    # shellcheck disable=SC2034  # read by steps/30_crypt.sh after apply()
    CRYPT_RECORD="${record}${recorded:+ ${recorded}:tpm2}"
    return 0
  fi

  # Read before anything is destroyed, and mandatory: apply() must not be able
  # to reach luksFormat without the second way in already in hand.
  crypt_read_passphrase recovery_pass "recovery passphrase for ${dev}" \
    crypt_recovery_pass_file GI_CRYPT_RECOVERY yes || return 1
  crypt_check_passphrase_strength "$recovery_pass" "recovery passphrase" || return 1

  crypt_secret_file _LT_KEY_RECOVERY recovery || return 1
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

  # The key stays: step 75 needs it to prove to the header that it may write
  # a second slot. It is a mode-600 file on a tmpfs, registered for the trap,
  # and the run removes it on every exit path — including the ones where the
  # sealing never happens.
  crypt_hold_key "$_LT_KEY_RECOVERY"

  log "the TPM slot comes next, in step 75, inside the target"
  log "       clevis lives there, not on this medium, and the version that"
  log "       seals should be the version that unseals at boot"

  # shellcheck disable=SC2034  # read by steps/30_crypt.sh after apply()

  CRYPT_RECORD="$record"
}

crypt_variant_verify() {
  local dev="$CRYPT_DEVICE"

  if [[ "$_LT_PROVISIONED" == "yes" ]]; then
    skip "${dev}: left as it was; this run proved no credential against it"
    skip "       tpm-reseal is the tool for re-exercising an existing sealing"
    return 0
  fi

  # apply() proved the recovery passphrase against the container it had just
  # made with it, and recorded that. It is the only credential that exists at
  # this point, and saying more here — before the TPM has released anything —
  # would be the kind of verdict this project was written against.
  crypt_require_ways_in 1 \
    "a container with no proved credential is a container nobody opens" || return 1

  warn "one way in so far: slot ${CFG[crypt_primary_slot]}, the recovery passphrase"
  warn "       step 75 seals slot ${CFG[crypt_tpm_slot]} to the TPM and proves it"
  warn "       by making the chip release the key; until then this machine"
  warn "       asks for the passphrase at every boot, and boots"
  return 0
}

# --------------------------------------------------------------------------- #
#  Step 75 — the sealing, inside the target                                   #
# --------------------------------------------------------------------------- #
_LT_SEAL_KEY=""

_lt_seal_key() {
  # A key file that opens the container, left in _LT_SEAL_KEY.
  #
  # Held from step 30 in an ordinary run; asked for again when this step runs
  # on its own — after a resume, or deliberately, to seal a machine installed
  # earlier. Either way it is proved against the header before clevis is given
  # it: binding with a key that opens nothing writes a slot nobody can reach.
  #
  # A global and not stdout, for the reason lib/crypt.sh gives at length in
  # crypt_secret_file(): a secret file created inside $( ) is registered for
  # the trap inside that subshell, and stays on disk when it ends.
  # Args: $1 = device.
  local dev="$1" pass=""
  _LT_SEAL_KEY=""

  if _LT_SEAL_KEY="$(crypt_held_key)"; then
    log "recovery key: the one step 30 proved, still held on the tmpfs"
  else
    log "no key held from step 30; asking for the recovery passphrase again"
    crypt_read_passphrase pass "recovery passphrase for ${dev}" \
      crypt_recovery_pass_file GI_CRYPT_RECOVERY no || return 1
    crypt_secret_file _LT_SEAL_KEY recovery || return 1
    crypt_write_secret "$_LT_SEAL_KEY" "$pass" || return 1
  fi

  if ! crypt_test_key_file "$dev" "$_LT_SEAL_KEY" "${CFG[crypt_primary_slot]}"; then
    err "that passphrase does not open slot ${CFG[crypt_primary_slot]} of ${dev}"
    err "       clevis needs a key that already opens the container before it"
    err "       may write another slot into the header"
    err "       nothing was changed; the container is exactly as it was"
    return 1
  fi
  crypt_record_way_in "${CFG[crypt_primary_slot]}" "recovery, typed when the TPM refuses"
  return 0
}

_lt_seal_requires() {
  # The tools, asked of the side that will run them. Everything here is about
  # the target: the live medium is never required to carry any of it.
  crypt_clevis_have clevis || {
    _lt_refuse_no_clevis
    return 1
  }
  if ! crypt_clevis_have tpm2_createprimary && ! crypt_clevis_have tpm2_create; then
    _lt_refuse_no_tpm2_tools
    return 1
  fi
  if ! crypt_clevis_have jose; then
    warn "jose is not in the target; clevis needs it to build its JWE"
    warn "       in the target: emerge --ask app-crypt/jose"
  fi
  # The chip is the machine's, not the target's, and /dev is bound in — so the
  # question is the same on both sides, and asking it here gives the better
  # message.
  if ! crypt_tpm_present; then
    _lt_refuse_no_tpm
    return 1
  fi
}

crypt_variant_seal() {
  # Bind a keyslot to the TPM and prove the chip honours it. Called by step 75
  # with a target attached and CRYPT_CLEVIS_IN_TARGET set, so every clevis
  # command below runs inside that target.
  local dev slot="${CFG[crypt_tpm_slot]}" bound=""

  # The device is read after crypt_require_device, not in the declaration
  # above it: that is what fills CRYPT_DEVICE from the journal, and a local
  # initialised on the same line as the declaration is initialised first. In a
  # run where step 30 had already set it this went unnoticed; step 75 on its
  # own asked for "the recovery passphrase for " and refused it against slot 0
  # of nothing.
  crypt_require_device || return 1
  dev="$CRYPT_DEVICE"
  _lt_seal_requires || return 1

  # Already bound? Then this is a re-run, and the honest thing is to prove the
  # binding that exists rather than write a second one beside it.
  if bound="$(crypt_clevis_slot "$dev")"; then
    skip "${dev} already carries a clevis binding on slot ${bound}"
    skip "       proving that one instead of writing another"
    slot="$bound"
  else
    _lt_seal_key "$dev" || return 1

    crypt_key_for_target "$_LT_SEAL_KEY" || return 1

    log "sealing a key into the TPM, slot ${slot}, policy $(crypt_pcr_policy)"
    if ! crypt_clevis_bind "$dev" "$CRYPT_KEY_IN_TARGET" "$slot"; then
      err "clevis could not bind ${dev} to the TPM"
      err "       the container exists and the recovery passphrase opens it,"
      err "       proved a moment ago, so this machine boots — it will ask"
      err "       to retry by hand, once the cause is understood, from inside"
      err "       the target:"
      err "         clevis luks bind -k FILE -s ${slot} -d ${dev} tpm2 '$(crypt_pcr_policy)'"
      return 1
    fi

    # Read back rather than assumed: clevis picks the first free slot when the
    # one asked for is taken, and verifying the wrong slot passes for the
    # wrong reason.
    if bound="$(crypt_clevis_slot "$dev")" && [[ "$bound" != "$slot" ]]; then
      warn "clevis reports keyslot ${bound}, not ${slot}; verifying ${bound}"
      slot="$bound"
    fi
  fi

  if ! crypt_clevis_capture clevis luks list -d "$dev" | grep -q tpm2; then
    if [[ "$DRY_RUN" == "yes" ]]; then
      skip "dry-run: nothing was bound, so there is no token to read back"
      return 0
    fi
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
    err "       slot ${CFG[crypt_primary_slot]} was proved, so it does boot"
    return 1
  fi
  crypt_record_way_in "$slot" "the TPM releases it while the firmware is unchanged"

  crypt_require_ways_in 2 \
    "a container that only the TPM opens is one BIOS update from a rebuild" || return 1

  # shellcheck disable=SC2034  # read by steps/75_seal.sh after the hook
  CRYPT_RECORD="${CFG[crypt_primary_slot]}:recovery-passphrase ${slot}:tpm2"

  crypt_wipe_secrets
  _LT_SEAL_KEY=""
  return 0
}
