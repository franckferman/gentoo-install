#!/usr/bin/env bash
#
# gentoo-install — crypt variant: luks-keyfile-gpg
# ----------------------------------------------------------------------------
# LUKS2 opened by a long random key that never exists in the clear on disk. The
# key is drawn, piped straight into a GPG envelope, and the envelope is what
# lands on the EFI system partition. Two secrets, not one: the passphrase you
# type opens the file, and the file opens the disk.
#
# This is the shape the internal installer uses, and the reason for it is the
# TPM: a key held in a file can be handed to clevis and sealed, while a key
# that only exists in someone's head cannot. On its own it buys something
# else — the same passphrase can open a fleet whose disks all carry different
# keys, and a key can be escrowed without escrowing a passphrase.
#
# The envelope sits on an unencrypted FAT partition and that is not a mistake:
# without the passphrase it is inert. Losing it, however, destroys the only
# copy of that keyslot's secret, so it is backed up off the machine or it is
# not backed up at all.
#
# Usage:  crypt = luks-keyfile-gpg     (sourced by lib/crypt.sh)
#
set -euo pipefail

_KG_KEY_RAW=""      # the LUKS key, unwrapped, on the tmpfs
_KG_KEY_FROM_ESP="" # the same key, unwrapped again from the deployed file
_KG_KEY_RECOVERY="" # the recovery passphrase
_KG_WRAPPED=""      # the envelope, before it is installed
_KG_PROVISIONED="no"

_kg_key_path() {
  printf '%s/%s\n' "${CFG[crypt_key_dir]%/}" "${CFG[crypt_key_name]}"
}

crypt_variant_describe() {
  printf '%s\n' "LUKS2 opened by a GPG-wrapped key file on the ESP"
}

crypt_variant_boot_note() {
  printf '%s\n' "the initramfs unwraps the key file and asks for its passphrase"
}

crypt_variant_requires() {
  printf '%s\n' cryptsetup
  printf '%s\n' gpg
}

crypt_variant_check() {
  local dir="${CFG[crypt_key_dir]%/}" pass_dir

  crypt_require_device || return 1

  if [[ ! -d "$dir" ]]; then
    if [[ "$DRY_RUN" == "yes" ]]; then
      log "dry-run: ${dir} does not exist here; the plan continues anyway"
    else
      err "crypt_key_dir does not exist: ${dir}"
      err "       it is where the wrapped key file is installed, and it has to"
      err "       be mounted before this step runs — normally the ESP, which"
      err "       step 20 formats and mounts"
      err "       example:  crypt_key_dir = /mnt/gentoo/boot/efi"
      return 1
    fi
  fi

  # A passphrase kept beside the file it opens is not a passphrase. This is a
  # real habit, not a hypothetical one, and it costs nothing to refuse.
  if [[ -n "${CFG[crypt_pass_file]}" ]]; then
    pass_dir="$(dirname -- "${CFG[crypt_pass_file]}")"
    if [[ "$(readlink -f -- "$pass_dir" 2>/dev/null || printf '%s' "$pass_dir")" == "$(readlink -f -- "$dir" 2>/dev/null || printf '%s' "$dir")" ]]; then
      err "crypt_pass_file sits in crypt_key_dir: ${dir}"
      err "       the envelope and the passphrase that opens it would travel"
      err "       together, which is the same as shipping neither"
      err "       put the passphrase file anywhere else, or better, on a tmpfs"
      err "       example:  crypt_pass_file = /run/gentoo-install-pass"
      return 1
    fi
  fi

  if crypt_already_provisioned "$CRYPT_DEVICE" "luks-keyfile-gpg"; then
    _KG_PROVISIONED="yes"
  fi
  return 0
}

crypt_variant_show() {
  local dev="$CRYPT_DEVICE" key
  key="$(_kg_key_path)"

  if [[ "$_KG_PROVISIONED" == "yes" ]]; then
    skip "${dev} already carries the container this run would build"
    skip "       UUID $(crypt_luks_uuid "$dev")"
    skip "       --restart forgets the journal and builds it again"
    return 0
  fi

  log "$(printf '  device    %s' "$dev")"
  log "$(printf '  container LUKS2 %s, %s bits, %s' \
    "${CFG[crypt_cipher]}" "${CFG[crypt_key_size]}" "${CFG[crypt_pbkdf]}")"
  log "$(printf '  key file  %s' "$key")"
  log "$(printf '  slot %-3s  the wrapped key: 4096 random bytes, base64, in a' \
    "${CFG[crypt_primary_slot]}")"
  log "            symmetric GPG envelope — the key itself is never written"
  log "            anywhere in the clear, it goes from the random source into"
  log "            gpg and no further"
  if [[ "${CFG[crypt_recovery]}" == "yes" ]]; then
    log "$(printf '  slot %-3s  recovery passphrase, independent of the key file' \
      "${CFG[crypt_recovery_slot]}")"
  else
    warn "no recovery keyslot (crypt_recovery = no)"
    warn "       the key file would be the only way in, and it lives on the"
    warn "       machine's own ESP: if that disk dies, it dies with it"
    warn "       crypt_recovery = yes adds a passphrase in slot ${CFG[crypt_recovery_slot]}"
  fi
  warn "${key} is on an unencrypted partition and readable by anyone"
  warn "       that is by design: without the passphrase it is inert"
  warn "       it is also the only copy of what opens slot ${CFG[crypt_primary_slot]} — copy it"
  warn "       off this machine before the machine leaves your hands"
  if crypt_is_luks "$dev"; then
    crypt_show_existing_header "$dev"
  fi
}

crypt_variant_apply() {
  local dev="$CRYPT_DEVICE"
  local master_pass="" recovery_pass="" key installed_ok="no"
  local record="${CFG[crypt_primary_slot]}:gpg-keyfile"
  key="$(_kg_key_path)"

  if [[ "$_KG_PROVISIONED" == "yes" ]]; then
    skip "${dev}: already provisioned, nothing rebuilt"
    # shellcheck disable=SC2034  # read by steps/30_crypt.sh after apply()
    CRYPT_RECORD="$record"
    return 0
  fi

  crypt_read_passphrase master_pass "passphrase that wraps the key file" \
    crypt_pass_file GI_CRYPT_PASSPHRASE yes || return 1
  crypt_check_passphrase_strength "$master_pass" "master passphrase" || return 1

  if [[ "${CFG[crypt_recovery]}" == "yes" ]]; then
    crypt_read_passphrase recovery_pass "recovery passphrase for ${dev}" \
      crypt_recovery_pass_file GI_CRYPT_RECOVERY yes || return 1
    crypt_check_passphrase_strength "$recovery_pass" "recovery passphrase" || return 1
    if [[ "$recovery_pass" == "$master_pass" ]]; then
      err "The recovery passphrase is the same as the master passphrase"
      err "       one secret protecting both slots is one way in, not two"
      return 1
    fi
  fi

  # Everything below happens on the tmpfs, mode 600, and is wiped by the trap
  # whichever way this run ends.
  _KG_WRAPPED="$(crypt_secret_file wrapped)" || return 1
  _KG_KEY_RAW="$(crypt_secret_file rawkey)" || return 1

  log "drawing the LUKS key and wrapping it"
  crypt_gpg_wrap "$_KG_WRAPPED" "$master_pass" || return 1

  # Unwrapped once, here, so that luksFormat and every later test use exactly
  # the bytes the envelope yields. GPG decryption is deterministic, which is
  # the whole reason this scheme works.
  crypt_gpg_unwrap "$_KG_WRAPPED" "$_KG_KEY_RAW" "$master_pass" || return 1

  if [[ -n "$recovery_pass" ]]; then
    _KG_KEY_RECOVERY="$(crypt_secret_file recovery)" || return 1
    crypt_write_secret "$_KG_KEY_RECOVERY" "$recovery_pass" || return 1
  fi

  crypt_confirm_format "$dev" || return 1

  log "creating the LUKS2 container on ${dev}"
  if ! crypt_luks_format "$dev" "$_KG_KEY_RAW" "${CFG[crypt_primary_slot]}"; then
    err "luksFormat failed on ${dev}"
    return 1
  fi

  if [[ -n "$_KG_KEY_RECOVERY" ]]; then
    log "adding the recovery passphrase in slot ${CFG[crypt_recovery_slot]}"
    if ! crypt_add_key "$dev" "$_KG_KEY_RAW" "$_KG_KEY_RECOVERY" \
      "${CFG[crypt_recovery_slot]}"; then
      err "could not add the recovery passphrase to ${dev}"
      err "       the container exists and the key file opens it"
      return 1
    fi
    record+=" ${CFG[crypt_recovery_slot]}:recovery-passphrase"
  fi

  if ! crypt_open "$dev" "${CFG[crypt_name]}" "$_KG_KEY_RAW"; then
    err "the container was created but would not open as ${CFG[crypt_name]}"
    return 1
  fi

  _kg_install_key "$_KG_WRAPPED" "$key" && installed_ok="yes"
  if [[ "$installed_ok" != "yes" ]]; then
    err "the container exists but its key file is not on ${CFG[crypt_key_dir]}"
    err "       nothing would open it at boot; install it by hand before"
    err "       rebooting, or rerun this step"
    return 1
  fi

  # The proof that matters is about the deployed file, not the one on the
  # tmpfs: they are meant to be the same bytes, and "meant to" is not a check.
  if [[ "$DRY_RUN" != "yes" ]]; then
    _KG_KEY_FROM_ESP="$(crypt_secret_file esprawkey)" || return 1
    crypt_gpg_unwrap "$key" "$_KG_KEY_FROM_ESP" "$master_pass" || return 1
  fi

  # shellcheck disable=SC2034  # read by steps/30_crypt.sh after apply()

  CRYPT_RECORD="$record"
}

_kg_install_key() {
  # Args: $1 = source (the envelope on the tmpfs), $2 = destination.
  # Mode 0600 is asked for and will not be honoured on FAT, which is what the
  # ESP is. Said once, here, rather than pretended.
  local src="$1" dst="$2" dir="${2%/*}"

  if [[ -e "$dst" ]] && ! cmp -s -- "$src" "$dst" 2>/dev/null; then
    if ! resolve_conflict "$dst" "wrapped key file"; then
      err "${dst} holds a different key file and was left alone"
      err "       it belongs to another container; this one would not open"
      return 1
    fi
  fi

  run_cmd mkdir -p -- "$dir" || return 1
  run_cmd install -m 0600 -- "$src" "$dst" || return 1
  ok "wrapped key file installed: ${dst}"
  log "       a FAT filesystem keeps no permission bits; the envelope is what"
  log "       protects it, not the mode"
  return 0
}

crypt_variant_verify() {
  local dev="$CRYPT_DEVICE" want=1 key
  key="$(_kg_key_path)"

  if [[ "$_KG_PROVISIONED" == "yes" ]]; then
    skip "${dev}: left as it was; this run proved no credential against it"
    skip "       the proof was made when the container was created"
    return 0
  fi

  if [[ "$DRY_RUN" == "yes" ]]; then
    log "dry-run: would prove the deployed key file and the recovery passphrase"
    return 0
  fi

  if [[ ! -s "$key" ]]; then
    err "${key} is missing or empty after the install"
    return 1
  fi

  # The key that came back out of the file on the ESP, not the one that went
  # in. --disable-external-tokens, as everywhere: a token answering in place
  # of this file would turn a broken deployment into a green light.
  if ! crypt_test_key_file "$dev" "$_KG_KEY_FROM_ESP" "${CFG[crypt_primary_slot]}"; then
    err "the key file on ${key} does not open slot ${CFG[crypt_primary_slot]}"
    err "       it decrypted, so the passphrase is right; the key inside it"
    err "       belongs to another container"
    return 1
  fi
  crypt_record_way_in "${CFG[crypt_primary_slot]}" "the wrapped key file, ${key}"

  if [[ -n "$_KG_KEY_RECOVERY" ]]; then
    if ! crypt_test_key_file "$dev" "$_KG_KEY_RECOVERY" "${CFG[crypt_recovery_slot]}"; then
      err "the recovery passphrase does not open slot ${CFG[crypt_recovery_slot]}"
      return 1
    fi
    crypt_record_way_in "${CFG[crypt_recovery_slot]}" "recovery, kept off the machine"
    want=2
  fi

  crypt_require_ways_in "$want" \
    "a container whose only key file lives on its own disk dies with that disk" || return 1

  crypt_wipe_secrets
  _KG_KEY_RAW=""
  _KG_KEY_FROM_ESP=""
  _KG_KEY_RECOVERY=""
  _KG_WRAPPED=""

  if ((want == 1)); then
    warn "this container has a single way in, because crypt_recovery = no"
    warn "       back ${key} up off this machine now; nothing else opens it"
  fi
  return 0
}
