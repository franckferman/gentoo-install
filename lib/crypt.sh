#!/usr/bin/env bash
#
# gentoo-install — crypt: the primitives every encryption variant shares
# ----------------------------------------------------------------------------
# LUKS2 containers, keyslot bookkeeping, secrets on a tmpfs, and the one rule
# that shapes the whole module: a credential is never assumed to work, it is
# exercised. Every such test goes through cryptsetup --disable-external-tokens,
# because without that flag a machine whose TPM still answers will happily
# validate any passphrase you hand it — the token answers instead of the
# material under test, and a dead credential reads as a live one.
#
# Nothing here runs at source time. steps/30_crypt.sh calls
# crypt_config_defaults() and crypt_load_variant().
#
# Usage:  source lib/crypt.sh   (needs lib/core.sh, lib/config.sh, lib/ui.sh)
#
set -euo pipefail

if [[ -n "${_GI_CRYPT_LOADED:-}" ]]; then
  return 0
fi
_GI_CRYPT_LOADED=1

# --------------------------------------------------------------------------- #
#  Where the variants live                                                    #
# --------------------------------------------------------------------------- #
_gi_crypt_self="$(readlink -f -- "${BASH_SOURCE[0]}")"
_gi_crypt_lib="${_gi_crypt_self%/*}"
CRYPT_VARIANT_DIR="${GI_VARIANT_DIR:-${_gi_crypt_lib%/*}/variants/crypt}"
unset _gi_crypt_self _gi_crypt_lib

# --------------------------------------------------------------------------- #
#  Conventions                                                                #
# --------------------------------------------------------------------------- #
# The keyslot map is a convention, not an accident, and every variant states
# its own. Slot 0 is always a credential a human can produce: it is the slot
# nothing automatic ever writes to, so that removing an automatic unlock can
# never remove the last way in.
readonly CRYPT_SLOT_PRIMARY_DEFAULT=0
readonly CRYPT_SLOT_RECOVERY_DEFAULT=1
readonly CRYPT_SLOT_TPM_DEFAULT=2

# The PCR policy of the internal installer this module is drawn from, kept as
# the default because it is the one that has run on real machines. See
# crypt_pcr_rationale() for why 4 is not in it and why 7 is not either.
readonly CRYPT_PCRS_DEFAULT="0,2,3,6"

# --------------------------------------------------------------------------- #
#  Settings                                                                   #
# --------------------------------------------------------------------------- #
crypt_config_defaults() {
  # Declared with set_default, so a flag or a configuration file already parsed
  # wins (DESIGN.md §5). Call this from config_init_defaults() to make the keys
  # spellable in a .conf; steps/30_crypt.sh calls it again, harmlessly, so the
  # step also works when it is driven on its own.
  #
  # Safe by default: luks-passphrase. It is what most operators want, it needs
  # no hardware, and it degrades to "type your passphrase" rather than to "this
  # machine cannot be opened".

  set_default crypt "luks-passphrase" # none|luks-passphrase|luks-tpm|luks-keyfile-gpg
  set_default crypt_device ""         # block device to encrypt; step 20 fills it in
  set_default crypt_name "gentoo"     # /dev/mapper/<name> once opened

  # Container geometry. The internal installer's values, which are also the
  # cryptsetup defaults for LUKS2 except for the hash.
  set_default crypt_cipher "aes-xts-plain64"
  set_default crypt_key_size "512" # XTS uses two AES-256 keys, hence 2 x 256
  set_default crypt_hash "sha512"
  set_default crypt_pbkdf "argon2id"
  set_default crypt_pbkdf_iterations "" # empty: let cryptsetup benchmark
  set_default crypt_pbkdf_memory ""     # empty: let cryptsetup benchmark

  # Keyslots.
  set_default crypt_primary_slot "$CRYPT_SLOT_PRIMARY_DEFAULT"
  set_default crypt_recovery_slot "$CRYPT_SLOT_RECOVERY_DEFAULT"
  set_default crypt_tpm_slot "$CRYPT_SLOT_TPM_DEFAULT"

  # A second, independent way in. Conservative by default only in the sense
  # that it costs the operator one more prompt: switching it off leaves a
  # machine whose single credential, once lost, loses the disk with it.
  set_default crypt_recovery "yes" # yes|no — luks-tpm refuses no

  # Secrets never come from a flag: argv is world-readable through ps. These
  # name a file whose first line is the secret; the environment variables
  # GI_CRYPT_PASSPHRASE and GI_CRYPT_RECOVERY are the other unattended route.
  set_default crypt_pass_file ""          # the everyday credential
  set_default crypt_recovery_pass_file "" # the recovery credential

  # TPM sealing.
  set_default crypt_pcrs "$CRYPT_PCRS_DEFAULT"
  set_default crypt_pcr_bank "sha256"

  # GPG-wrapped key file, for the luks-keyfile-gpg variant.
  set_default crypt_key_dir "/boot/efi" # the ESP, mounted, unencrypted
  set_default crypt_key_name "luks-key.gpg"

  # Reformatting a container that already exists destroys every keyslot on it.
  set_default crypt_wipe_luks "ask" # ask|yes|no
}

crypt_variants() {
  # The catalogue is the directory: one file per variant, so adding one is
  # adding a file (DESIGN.md §10). A returned value, so stdout.
  local path name
  [[ -d "$CRYPT_VARIANT_DIR" ]] || return 0
  for path in "$CRYPT_VARIANT_DIR"/*.sh; do
    [[ -f "$path" ]] || continue
    name="${path##*/}"
    printf '%s\n' "${name%.sh}"
  done | sort
}

crypt_validate_early() {
  # Stage 1 of DESIGN.md §5, for a value no closed list can hold: cryptsetup
  # supports whatever the running kernel supports, and that differs between
  # machines. So the question is put to cryptsetup rather than to a table that
  # would be wrong somewhere.
  #
  # Only a cipher other than the default is checked. The measurement is what
  # costs: a valid cipher takes about two seconds because cryptsetup actually
  # benchmarks it, while an unknown one fails in twenty milliseconds. Paying two
  # seconds on every run to re-confirm the one cipher this project ships and
  # tests would be a poor trade; paying it once for a deliberate choice, before
  # step 20 wipes anything, is a good one.
  local cipher="${CFG[crypt_cipher]:-}" size="${CFG[crypt_key_size]:-512}"

  [[ -n "$cipher" ]] || return 0
  [[ "$cipher" != "aes-xts-plain64" ]] || return 0
  [[ "${CFG[crypt]:-none}" != "none" ]] || return 0
  have cryptsetup || return 0

  log "checking that this kernel offers ${cipher} at ${size} bits"
  if cryptsetup benchmark -c "$cipher" -s "$size" >/dev/null 2>&1; then
    ok "${cipher}/${size} is available here"
    return 0
  fi

  err "This kernel cannot do ${cipher} at ${size} bits"
  err "       cryptsetup was asked and refused. Either the name is wrong or the"
  err "       module is not built; the answer differs between kernels, which is"
  err "       why this is asked rather than looked up in a table."
  err "       what this machine offers:  cryptsetup benchmark"
  err "       the default, always built:  crypt_cipher = aes-xts-plain64"
  return 1
}

crypt_validate_pbkdf_params() {
  # --pbkdf-memory belongs to argon2. pbkdf2 has no memory parameter at all: it
  # is an iteration count and nothing else, and cryptsetup refuses the pair.
  # Caught here rather than inside luksFormat, which runs in step 30 — after
  # step 20 has wiped the disk for a combination that was never going to work.
  local pbkdf="${CFG[crypt_pbkdf]:-argon2id}"

  [[ "$pbkdf" == "pbkdf2" ]] || return 0
  [[ -n "${CFG[crypt_pbkdf_memory]:-}" ]] || return 0

  err "crypt_pbkdf = pbkdf2 takes no crypt_pbkdf_memory"
  err "       memory is an argon2 parameter; pbkdf2 is an iteration count and"
  err "       nothing else, and cryptsetup refuses the two together."
  err "       drop it:                    crypt_pbkdf_memory ="
  err "       or keep a memory-hard one:  crypt_pbkdf = argon2id"
  return 1
}

crypt_validate_config() {
  # Stage 1 of DESIGN.md §5: the value must be spellable. Ten milliseconds,
  # before a single sector is touched.
  local slot value

  validate_enum "encryption variant" "${CFG[crypt]}" "--crypt" \
    "none:no encryption at all; the disk is readable by whoever holds it" \
    "luks-passphrase:LUKS2, passphrase typed at every boot — the default" \
    "luks-tpm:LUKS2 unlocked by the TPM, recovery passphrase in another slot" \
    "luks-keyfile-gpg:LUKS2 opened by a GPG-wrapped key file on the ESP"

  validate_enum "recovery credential" "${CFG[crypt_recovery]}" "--crypt-recovery" \
    "yes:add a second, independent credential in its own keyslot" \
    "no:one credential only; losing it loses the disk"

  validate_enum "key derivation" "${CFG[crypt_pbkdf]}" "--crypt-pbkdf" \
    "argon2id:memory-hard, the LUKS2 default, the right answer on a PC" \
    "argon2i:memory-hard, side-channel variant" \
    "pbkdf2:cheap and old; only for a container a slow CPU must open"

  validate_enum "existing LUKS header policy" "${CFG[crypt_wipe_luks]}" "--crypt-wipe-luks" \
    "ask:decide when a container is actually found" \
    "yes:reformat it, destroying every keyslot it carries" \
    "no:refuse to touch a device that already holds a LUKS header"

  value="${CFG[crypt_key_size]}"
  if [[ ! "$value" =~ ^[0-9]+$ ]] || ((value < 128)); then
    die_usage "Invalid crypt_key_size: ${value}" \
      "a number of bits; XTS splits it in two, so 512 means AES-256" \
      "example:  crypt_key_size = 512"
  fi

  for slot in crypt_primary_slot crypt_recovery_slot crypt_tpm_slot; do
    value="${CFG[$slot]}"
    if [[ ! "$value" =~ ^[0-9]+$ ]] || ((value > 31)); then
      die_usage "Invalid ${slot}: ${value}" \
        "a LUKS2 keyslot number, 0 to 31" \
        "example:  ${slot} = 1"
    fi
  done

  if [[ "${CFG[crypt_tpm_slot]}" == "${CFG[crypt_primary_slot]}" ]]; then
    die_usage "crypt_tpm_slot and crypt_primary_slot name the same slot: ${CFG[crypt_tpm_slot]}" \
      "the slot the TPM owns is rewritten whenever the sealing is redone" \
      "putting the human credential there would destroy it on the first reseal" \
      "example:  crypt_tpm_slot = 2"
  fi

  crypt_validate_pcrs "${CFG[crypt_pcrs]}"
}

crypt_validate_pcrs() {
  local list="$1" n
  if [[ ! "$list" =~ ^[0-9]+(,[0-9]+)*$ ]]; then
    die_usage "Invalid PCR list: ${list}" \
      "comma-separated register numbers, no spaces" \
      "example:  crypt_pcrs = 0,2,3,6"
  fi
  for n in ${list//,/ }; do
    if ((10#$n > 23)); then
      die_usage "Invalid PCR number: ${n}" \
        "a TPM 2.0 platform has registers 0 to 23" \
        "example:  crypt_pcrs = 0,2,3,6"
    fi
  done
}

crypt_pcr_policy() {
  # The JSON clevis's tpm2 pin takes. A returned value, so stdout.
  printf '{"pcr_bank":"%s","pcr_ids":"%s"}\n' \
    "${CFG[crypt_pcr_bank]}" "${CFG[crypt_pcrs]}"
}

crypt_pcr_rationale() {
  # Why this list and not another one. Printed by the plan, because a policy
  # nobody can explain is a policy nobody can change safely.
  log "PCR policy ${CFG[crypt_pcrs]} on bank ${CFG[crypt_pcr_bank]}"
  log "       0  the firmware itself — a BIOS update changes it, and that is"
  log "          the one event that breaks sealing on real fleets"
  log "       2,3  option ROMs and their configuration — a card added or removed"
  log "       6  platform events"
  log "       4 is deliberately out: it measures the boot binary, which is"
  log "          rewritten at every kernel build. Binding it would break the"
  log "          automatic unlock after every single update."
  log "       7 is out too, and that one is a known hole: Secure Boot can be"
  log "          switched off without the TPM noticing. Add 7 to crypt_pcrs if"
  log "          your threat model needs it, and reseal whenever you touch the"
  log "          Secure Boot keys."
}

# --------------------------------------------------------------------------- #
#  Secrets on a tmpfs                                                         #
# --------------------------------------------------------------------------- #
_GI_CRYPT_SECRETS=()
_GI_CRYPT_TMPDIR=""
_GI_CRYPT_TRAPPED="no"

crypt_secure_tmpdir() {
  # Ask the filesystem, never assume. The two situations this module runs in
  # are opposites: on a booted machine /run is a tmpfs and /tmp sits on the
  # root filesystem, while inside an installation chroot the live medium's
  # /tmp is usually bound in and /run is the target's own directory, on disk.
  # Hardcoding either one is wrong half the time.
  # A returned value, so stdout.
  local dir fstype
  if [[ -n "$_GI_CRYPT_TMPDIR" ]]; then
    printf '%s\n' "$_GI_CRYPT_TMPDIR"
    return 0
  fi
  for dir in /run /dev/shm /tmp; do
    [[ -d "$dir" && -w "$dir" ]] || continue
    fstype=""
    if have findmnt; then
      fstype="$(findmnt -no FSTYPE --target "$dir" 2>/dev/null || true)"
    elif have stat; then
      fstype="$(stat -f -c %T -- "$dir" 2>/dev/null || true)"
    fi
    if [[ "$fstype" == "tmpfs" || "$fstype" == "ramfs" ]]; then
      _GI_CRYPT_TMPDIR="$dir"
      printf '%s\n' "$dir"
      return 0
    fi
  done

  # Said out loud rather than done quietly: a removed file is not an erased
  # one, and on a copy-on-write filesystem it is not even removed.
  warn "no tmpfs among /run, /dev/shm and /tmp"
  warn "       key material will touch a persistent filesystem while this runs"
  warn "       it is deleted afterwards, and deleted is not erased"
  _GI_CRYPT_TMPDIR="${TMPDIR:-/tmp}"
  printf '%s\n' "$_GI_CRYPT_TMPDIR"
}

_crypt_carry_status() { return "$1"; }

_crypt_exit_trap() {
  # The EXIT trap is a single slot, so this one replaces core's and calls it:
  # secrets go first, then the mounts come down. cleanup() reads $? to decide
  # whether to keep its backups, so the status is handed back to it intact.
  local rc=$?
  set +e
  crypt_wipe_secrets
  _crypt_carry_status "$rc"
  if declare -F cleanup >/dev/null 2>&1; then
    cleanup
  fi
  return "$rc"
}

crypt_arm_secret_trap() {
  # Idempotent, and installed the moment the first secret file is created
  # rather than at source time: a run that never reaches step 30 has no reason
  # to own the traps.
  [[ "$_GI_CRYPT_TRAPPED" == "no" ]] || return 0
  _GI_CRYPT_TRAPPED="yes"
  trap '_crypt_exit_trap' EXIT
  if declare -F handle_interrupt >/dev/null 2>&1; then
    trap 'crypt_wipe_secrets; handle_interrupt' INT TERM
  else
    trap 'crypt_wipe_secrets; exit 130' INT TERM
  fi
}

crypt_secret_file() {
  # A mode-600 file on the tmpfs, registered for the trap and for core's
  # cleanup(), so it goes away on every exit path including Ctrl-C.
  # Args: $1 = a short purpose, for the file name only. Prints the path.
  local purpose="${1:-secret}" dir path
  dir="$(crypt_secure_tmpdir)"
  path="$(umask 077 && mktemp "${dir}/gentoo-install-${purpose}.XXXXXXXX")" || {
    err "cannot create a temporary file under ${dir}"
    return 1
  }
  chmod 0600 -- "$path" 2>/dev/null || true
  _GI_CRYPT_SECRETS+=("$path")
  if declare -F track_temp >/dev/null 2>&1; then
    track_temp "$path"
  fi
  # The trap is NOT armed here, and that is the whole point of this comment.
  #
  # This function prints a path, so every caller runs it as "$(crypt_secret_file
  # ...)" — a command substitution, which is a subshell. `trap ... EXIT` executed
  # inside a subshell fires when that subshell ends, and _crypt_exit_trap calls
  # cleanup(), which unmounts every tracked mount. So arming here tore the target
  # tree down on the spot: every secret file created after step 30 mounted
  # anything left the machine unmounted a line later, and the next command failed
  # with "No such file or directory" about a path that existed the line before.
  #
  # The idempotence guard did not save it either: _GI_CRYPT_TRAPPED="yes" is set
  # in the subshell and never reaches the parent, so every call armed it afresh.
  #
  # crypt_arm_secret_trap() is called by the step instead, in the parent shell,
  # before any secret exists.
  printf '%s\n' "$path"
}

crypt_write_secret() {
  # Put a secret held in a variable into a file, without a trailing newline.
  # That last detail is not cosmetic: cryptsetup --key-file reads every byte
  # it is given and does not stop at a newline, while the boot-time prompt
  # hands it the typed line with the newline stripped. A file written with
  # `echo` would create a keyslot no human can ever open.
  # Args: $1 = path, $2 = the secret.
  local path="$1" secret="$2"
  (umask 077 && printf '%s' "$secret" >"$path") || {
    err "cannot write ${path}"
    return 1
  }
  chmod 0600 -- "$path" 2>/dev/null || true
}

crypt_wipe_secrets() {
  # Always succeeds: a failure here must not mask the status the run is
  # exiting with.
  local path
  if ((${#_GI_CRYPT_SECRETS[@]} > 0)); then
    for path in "${_GI_CRYPT_SECRETS[@]}"; do
      [[ -e "$path" ]] || continue
      # shred is theatre on a tmpfs and insurance everywhere else.
      if have shred; then
        shred -u -- "$path" 2>/dev/null || rm -f -- "$path" 2>/dev/null || true
      else
        rm -f -- "$path" 2>/dev/null || true
      fi
    done
  fi
  _GI_CRYPT_SECRETS=()
  return 0
}

# --------------------------------------------------------------------------- #
#  Reading a passphrase                                                       #
# --------------------------------------------------------------------------- #
crypt_read_passphrase() {
  # Three routes, none of them argv: ps is world-readable and shell history is
  # forever, so no flag in this project ever carries a secret.
  #   1. an environment variable   (/proc/PID/environ, root only)
  #   2. the first line of a file  (keep it mode 600)
  #   3. the terminal, not echoed
  # Args: $1 = variable to fill, $2 = what it is, $3 = CFG key naming a file,
  #       $4 = environment variable name, $5 = ask twice (yes|no, default yes).
  local varname="$1" label="$2" file_key="$3" env_name="$4" twice="${5:-yes}"
  local file mode value

  if [[ ! "$varname" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
    die "internal: crypt_read_passphrase() got an invalid variable name: ${varname}"
  fi

  value="${!env_name:-}"
  if [[ -n "$value" ]]; then
    log "${label}: taken from \$${env_name}"
    printf -v "$varname" '%s' "$value"
    return 0
  fi

  file="${CFG[$file_key]:-}"
  if [[ -n "$file" ]]; then
    if [[ ! -r "$file" ]]; then
      err "Cannot read ${file_key}: ${file}"
      err "       expected a readable file whose first line is the ${label}"
      err "       example:  ${file_key} = /run/secrets/luks-recovery"
      return 1
    fi
    mode="$(stat -c '%a' -- "$file" 2>/dev/null || printf '600')"
    if [[ "$mode" != "600" && "$mode" != "400" ]]; then
      warn "${file} is mode ${mode}; a file holding a passphrase belongs at 600"
    fi
    IFS= read -r value <"$file" || true
    if [[ -z "$value" ]]; then
      err "${file} holds nothing on its first line"
      err "       the ${label} is read from the first line, newline stripped"
      err "       example:  printf '%%s\\n' \"\$PW\" > ${file}"
      return 1
    fi
    log "${label}: taken from ${file}"
    printf -v "$varname" '%s' "$value"
    return 0
  fi

  if [[ "$NON_INTERACTIVE" == "yes" || ! -r /dev/tty ]]; then
    err "No ${label}, and no terminal to ask on"
    err "       ${env_name}=... is the unattended route"
    err "       ${file_key} = FILE reads it from the first line of a file"
    err "       a flag would put it in ps and in shell history, so there is none"
    return 1
  fi

  crypt_say_keymap
  prompt_secret "$varname" "$label" "$twice"
}

crypt_say_keymap() {
  # Said once, before the first passphrase is typed.
  #
  # The passphrase is typed here, on the console of a live image, and again at
  # every boot on the console of the installed machine. If those two consoles
  # disagree about the keyboard, the passphrase that was set is not the one the
  # operator meant to set, and the mismatch only shows at the next boot — by
  # which time the disk is encrypted with it. Loading a keymap is not this
  # installer's business, but saying which one is loaded costs nothing.
  local map=""

  [[ -z "${_CRYPT_KEYMAP_SAID:-}" ]] || return 0
  _CRYPT_KEYMAP_SAID=1

  if have localectl; then
    map="$(localectl status 2>/dev/null | sed -n 's/.*VC Keymap: *//p' | head -n 1)"
  fi
  if [[ -z "$map" && -r /etc/vconsole.conf ]]; then
    map="$(sed -n 's/^KEYMAP=//p' /etc/vconsole.conf | tr -d '"' | head -n 1)"
  fi
  if [[ -z "$map" && -r /etc/conf.d/keymaps ]]; then
    map="$(sed -n 's/^keymap=//p' /etc/conf.d/keymaps | tr -d '"' | head -n 1)"
  fi

  if [[ -n "$map" && "$map" != "us" ]]; then
    log "this console is on the ${map} keymap"
    log "       the machine you are installing will boot on its own default,"
    log "       usually us. Type a passphrase whose characters are in the same"
    log "       place on both, or set it from a file: crypt_pass_file = FILE"
  elif [[ -n "$map" ]]; then
    log "this console is on the ${map} keymap"
  else
    log "the console keymap could not be read; it is probably us"
    log "       if this keyboard is not us, the passphrase you type here and the"
    log "       one the installed machine asks for will not be the same"
  fi
  return 0
}

crypt_check_passphrase_strength() {
  # Says what is weak, refuses only what is unusable. An installer that
  # enforces a password policy is an installer people work around.
  local secret="$1" label="${2:-passphrase}"
  if ((${#secret} == 0)); then
    err "The ${label} is empty."
    return 1
  fi
  if ((${#secret} < 8)); then
    warn "the ${label} is ${#secret} characters; a disk stolen offline gives an"
    warn "       attacker unlimited time to guess it"
  fi
  case "$secret" in
    *[^[:print:]]*)
      warn "the ${label} contains a non-printable character"
      warn "       the boot prompt may not reproduce it — it often has no"
      warn "       keymap loaded and only knows US QWERTY"
      ;;
  esac
  return 0
}

# --------------------------------------------------------------------------- #
#  Reading a container                                                        #
# --------------------------------------------------------------------------- #
crypt_is_luks() {
  cryptsetup isLuks "$1" 2>/dev/null
}

crypt_luks_uuid() {
  cryptsetup luksUUID "$1" 2>/dev/null || true
}

crypt_luks_version() {
  cryptsetup luksDump "$1" 2>/dev/null | awk -F': *' '/^Version:/ { print $2; exit }'
}

crypt_used_slots() {
  # The keyslots that actually hold something, one per line on stdout. Read
  # from the header rather than assumed: a container provisioned elsewhere
  # does not have to match this project's conventions.
  cryptsetup luksDump "$1" 2>/dev/null | awk '
    /^Keyslots:/ { in_slots = 1; next }
    /^[^[:space:]]/ { in_slots = 0 }
    in_slots && /^[[:space:]]+[0-9]+:/ { sub(/:.*/, "", $1); print $1 }
  '
}

crypt_slot_in_use() {
  local dev="$1" want="$2" slot
  while IFS= read -r slot; do
    [[ "$slot" == "$want" ]] && return 0
  done < <(crypt_used_slots "$dev")
  return 1
}

crypt_tokens() {
  cryptsetup luksDump "$1" 2>/dev/null | sed -n '/^Tokens:/,/^Digests:/p'
}

# --------------------------------------------------------------------------- #
#  The proof                                                                  #
# --------------------------------------------------------------------------- #
crypt_test_key_file() {
  # The single door every credential check goes through.
  #
  # --test-passphrase activates nothing, so this is safe to run on a container
  # already in use. --disable-external-tokens is the part that carries the
  # meaning: a LUKS2 token plugin is consulted before the material handed on
  # the command line, so on a machine whose TPM still answers, this command
  # succeeds with *any* key file unless the flag is there. A credential that
  # no longer works then reads as working — which is exactly the state a
  # machine is in just before a BIOS update kills the sealing for good.
  #
  # Args: $1 = device, $2 = key file, $3 = keyslot (optional; "" means any).
  local dev="$1" keyfile="$2" slot="${3:-}"
  local -a args=(open --test-passphrase --disable-external-tokens)
  if [[ -n "$slot" ]]; then
    args+=(--key-slot "$slot")
  fi
  args+=(--key-file "$keyfile" "$dev")
  if [[ "$DRY_RUN" == "yes" ]]; then
    log "dry-run: would prove the credential against ${dev}${slot:+ slot ${slot}}"
    return 0
  fi
  cryptsetup "${args[@]}" 2>/dev/null
}

# The ways into the container that have been proved during this run, by
# exercising them. The doctrine of DESIGN.md §12 in one variable: nothing is
# erased and no machine is declared finished before another way in has been
# shown to work.
_GI_CRYPT_WAYS_IN=()

crypt_record_way_in() {
  # Args: $1 = slot, $2 = one line saying what a human does with it.
  _GI_CRYPT_WAYS_IN+=("$1|$2")
  ok "proved: slot $1 opens the container — $2"
}

crypt_forget_ways_in() {
  _GI_CRYPT_WAYS_IN=()
}

crypt_ways_in_count() {
  printf '%s\n' "${#_GI_CRYPT_WAYS_IN[@]}"
}

crypt_show_ways_in() {
  # Rendering only, changes nothing (DESIGN.md §7).
  local entry
  if ((${#_GI_CRYPT_WAYS_IN[@]} == 0)); then
    warn "no way into the container has been proved"
    return 0
  fi
  log "${#_GI_CRYPT_WAYS_IN[@]} independent way(s) into the container, each exercised just now:"
  for entry in "${_GI_CRYPT_WAYS_IN[@]}"; do
    log "$(printf '       slot %-3s %s' "${entry%%|*}" "${entry#*|}")"
  done
}

crypt_require_ways_in() {
  # Args: $1 = how many, $2 = what would be lost with fewer.
  local want="$1" why="$2"
  if ((${#_GI_CRYPT_WAYS_IN[@]} >= want)); then
    return 0
  fi
  err "Only ${#_GI_CRYPT_WAYS_IN[@]} way(s) into this container could be proved, ${want} required"
  err "       ${why}"
  err "       nothing was declared finished; the container is as it was left"
  return 1
}

# --------------------------------------------------------------------------- #
#  Writing a container                                                        #
# --------------------------------------------------------------------------- #
crypt_format_args() {
  # The luksFormat argv, minus the device and the key file. Printed one
  # argument per line so a caller can mapfile it — a returned value, stdout.
  printf '%s\n' --type luks2 --batch-mode
  printf '%s\n' --cipher "${CFG[crypt_cipher]}"
  printf '%s\n' --key-size "${CFG[crypt_key_size]}"
  printf '%s\n' --hash "${CFG[crypt_hash]}"
  printf '%s\n' --pbkdf "${CFG[crypt_pbkdf]}"
  if [[ -n "${CFG[crypt_pbkdf_iterations]}" ]]; then
    printf '%s\n' --pbkdf-force-iterations "${CFG[crypt_pbkdf_iterations]}"
  fi
  # argon2 only: pbkdf2 refuses this flag. The combination is already refused at
  # parse time; this keeps the argv right even for a caller driving this alone.
  if [[ -n "${CFG[crypt_pbkdf_memory]}" && "${CFG[crypt_pbkdf]}" != "pbkdf2" ]]; then
    printf '%s\n' --pbkdf-memory "${CFG[crypt_pbkdf_memory]}"
  fi
}

crypt_luks_format() {
  # Args: $1 = device, $2 = key file for the first credential, $3 = its slot.
  local dev="$1" keyfile="$2" slot="$3"
  local -a args=()
  mapfile -t args < <(crypt_format_args)
  args+=(--key-slot "$slot" --key-file "$keyfile")
  run_cmd cryptsetup luksFormat "${args[@]}" "$dev"
}

crypt_add_key() {
  # Args: $1 = device, $2 = key file that already opens it, $3 = new key file,
  #       $4 = slot for the new key.
  local dev="$1" have_key="$2" new_key="$3" slot="$4"
  local -a args=()
  mapfile -t args < <(crypt_format_args)
  # --batch-mode belongs to format; luksAddKey takes the same PBKDF options.
  args+=(--key-file "$have_key" --new-key-slot "$slot")
  run_cmd cryptsetup luksAddKey "${args[@]}" "$dev" "$new_key"
}

crypt_open() {
  # Args: $1 = device, $2 = mapper name, $3 = key file.
  local dev="$1" name="$2" keyfile="$3"
  if crypt_is_open "$name"; then
    skip "/dev/mapper/${name} is already open"
    return 0
  fi
  run_cmd cryptsetup open --disable-external-tokens --key-file "$keyfile" "$dev" "$name"
}

crypt_close() {
  local name="$1"
  if ! crypt_is_open "$name"; then
    skip "/dev/mapper/${name} is not open"
    return 0
  fi
  run_cmd cryptsetup close "$name"
}

crypt_is_open() {
  [[ -e "/dev/mapper/$1" ]] && cryptsetup status "$1" >/dev/null 2>&1
}

# --------------------------------------------------------------------------- #
#  GPG envelope                                                               #
# --------------------------------------------------------------------------- #
crypt_gpg_wrap() {
  # Draw a fresh LUKS key and put it straight into a GPG envelope. The key
  # never exists outside the pipe: it goes from the random source to gpg and
  # stops there. What lands on disk is already encrypted.
  # Args: $1 = output path, $2 = the passphrase that wraps it.
  local out="$1" passphrase="$2" rc=0

  if [[ "$DRY_RUN" == "yes" ]]; then
    log "dry-run: would draw a LUKS key and wrap it into ${out}"
    return 0
  fi

  # 4096 random bytes in base64, one long line: what the internal installer
  # writes, and comfortably more entropy than the cipher can use.
  (
    umask 077
    crypt_random_material \
      | gpg --quiet --batch --yes --pinentry-mode loopback \
        --passphrase-fd 3 --symmetric --cipher-algo aes256 --armor \
        3<<<"$passphrase" >"$out"
  ) || rc=$?

  if ((rc != 0)); then
    err "could not write the wrapped key file ${out}"
    return 1
  fi
  if [[ ! -s "$out" ]]; then
    err "the wrapped key file ${out} came out empty"
    return 1
  fi
  chmod 0600 -- "$out" 2>/dev/null || true
  return 0
}

crypt_random_material() {
  # Prints raw key material on stdout, and is the one function in this file
  # that does. Every caller pipes it directly into gpg; nothing logs it.
  if have openssl; then
    openssl rand -base64 4096 | tr -d '\n'
  else
    head -c 4096 /dev/urandom | base64 | tr -d '\n'
  fi
}

crypt_gpg_unwrap() {
  # Args: $1 = wrapped file, $2 = destination, $3 = passphrase.
  # The two failures are told apart because they mean different things: a
  # wrong passphrase is an operator error, a key that decrypts but opens
  # nothing is the key of another machine.
  local wrapped="$1" out="$2" passphrase="$3" rc=0

  if [[ "$DRY_RUN" == "yes" ]]; then
    log "dry-run: would unwrap ${wrapped}"
    return 0
  fi

  if [[ -z "${GPG_TTY:-}" ]]; then
    GPG_TTY="$(tty 2>/dev/null || printf '/dev/tty')"
    export GPG_TTY
  fi

  local diag
  diag="$(crypt_secret_file gpgdiag 2>/dev/null || printf '')"
  gpg --quiet --batch --pinentry-mode loopback --passphrase-fd 3 \
    --decrypt "$wrapped" 3<<<"$passphrase" >"$out" 2>"${diag:-/dev/null}" || rc=$?

  if ((rc != 0)); then
    err "GPG could not decrypt ${wrapped}"
    err "       wrong passphrase, or the file is damaged"
    # What gpg said, rather than a guess about it. Swallowing this cost an hour
    # once: the message named neither the passphrase nor the file, and the same
    # command run by hand succeeded.
    if [[ -n "$diag" && -s "$diag" ]]; then
      while IFS= read -r line; do
        err "       gpg: ${line}"
      done <"$diag"
    fi
    return 1
  fi
  if [[ ! -s "$out" ]]; then
    err "${wrapped} decrypted to nothing"
    return 1
  fi
  return 0
}

# --------------------------------------------------------------------------- #
#  TPM, through clevis                                                        #
# --------------------------------------------------------------------------- #
crypt_tpm_present() {
  [[ -c /dev/tpmrm0 || -c /dev/tpm0 || -d /sys/class/tpm/tpm0 ]]
}

crypt_clevis_slot() {
  # The slot clevis really owns, read from its own listing rather than
  # assumed. A container bound on another slot would otherwise keep its old
  # binding while a second one was created beside it.
  local dev="$1" slot
  have clevis || return 1
  slot="$(clevis luks list -d "$dev" 2>/dev/null | head -n 1 | cut -d: -f1 | tr -d ' ')"
  [[ "$slot" =~ ^[0-9]+$ ]] || return 1
  printf '%s\n' "$slot"
}

crypt_clevis_bind() {
  # Args: $1 = device, $2 = key file that already opens it, $3 = slot.
  # Note what -k is for: clevis draws a brand new key for the slot it creates,
  # and only uses this file to prove it may write to the header. The TPM slot
  # and the human slot therefore hold different secrets, and removing the key
  # file does not remove "a copy" of anything.
  local dev="$1" keyfile="$2" slot="$3" policy
  policy="$(crypt_pcr_policy)"
  run_cmd clevis luks bind -k "$keyfile" -s "$slot" -d "$dev" tpm2 "$policy"
}

crypt_clevis_verify_seal() {
  # A token in `clevis luks list` proves a token exists and nothing else: it
  # reads identically whether the TPM honours it or refuses it. The only proof
  # is to make the TPM do the work and check what comes back against the
  # keyslot — which is what this does, and what the internal tooling had to
  # learn the expensive way after a BIOS update.
  # Args: $1 = device, $2 = slot.
  local dev="$1" slot="$2" released rc=0

  if [[ "$DRY_RUN" == "yes" ]]; then
    log "dry-run: would ask the TPM to release the key it just sealed"
    return 0
  fi

  released="$(crypt_secret_file tpm-released)" || return 1

  # The released key is written to a file and never to a variable or a log:
  # it is the material that opens the disk.
  clevis luks pass -d "$dev" -s "$slot" >"$released" 2>/dev/null || rc=$?
  if ((rc != 0)); then
    err "the TPM refused to release the key it was just sealed with"
    err "       the binding exists, the sealing does not work"
    return 1
  fi
  if [[ ! -s "$released" ]]; then
    err "clevis released an empty key"
    return 1
  fi

  # --disable-external-tokens here too, and it is not decoration: without it
  # the clevis token plugin answers this very question on its own and the
  # test passes whatever the file holds. The internal tooling omits the flag
  # at exactly this point.
  if ! crypt_test_key_file "$dev" "$released" "$slot"; then
    err "the key the TPM released opens no keyslot ${slot}"
    return 1
  fi
  return 0
}

# --------------------------------------------------------------------------- #
#  Variants                                                                   #
# --------------------------------------------------------------------------- #
# A variant file defines these seven and nothing else. The first three are
# values (stdout), the last four act or render.
readonly CRYPT_VARIANT_HOOKS=(
  crypt_variant_describe
  crypt_variant_boot_note
  crypt_variant_requires
  crypt_variant_check
  crypt_variant_show
  crypt_variant_apply
  crypt_variant_verify
)

crypt_load_variant() {
  # Args: $1 = variant name.
  local name="$1" path hook
  local -a known=()

  mapfile -t known < <(crypt_variants)
  if ((${#known[@]} == 0)); then
    err "No encryption variant found under ${CRYPT_VARIANT_DIR}"
    err "       the directory is missing or empty"
    err "       set GI_VARIANT_DIR if the variants live elsewhere"
    return 1
  fi

  path="${CRYPT_VARIANT_DIR}/${name}.sh"
  if [[ ! -r "$path" ]]; then
    err "Unknown encryption variant: ${name}"
    err "       available: ${known[*]}"
    err "       example:  crypt = luks-passphrase"
    return 1
  fi

  # A stale hook from an earlier load would run silently in place of the one
  # this variant forgot to define.
  for hook in "${CRYPT_VARIANT_HOOKS[@]}"; do
    unset -f "$hook" 2>/dev/null || true
  done

  # shellcheck source=/dev/null
  source "$path"

  for hook in "${CRYPT_VARIANT_HOOKS[@]}"; do
    if ! declare -F "$hook" >/dev/null 2>&1; then
      err "Variant ${name} does not define ${hook}()"
      err "       every variant defines: ${CRYPT_VARIANT_HOOKS[*]}"
      err "       see variants/crypt/none.sh for the smallest complete one"
      return 1
    fi
  done

  log "encryption variant: ${name} — $(crypt_variant_describe)"
}

crypt_require_variant_cmds() {
  # Stage 2 of DESIGN.md §5: the value is legal, but is it available here?
  local -a needed=()
  mapfile -t needed < <(crypt_variant_requires)
  ((${#needed[@]} > 0)) || return 0
  require_cmds "${needed[@]}"
}

# --------------------------------------------------------------------------- #
#  Target device                                                              #
# --------------------------------------------------------------------------- #
crypt_family() {
  # The encryption choice in one vocabulary: none, passphrase, tpm or keyfile.
  #
  # Two spellings exist because two things name the same choice. Step 30's
  # catalogue is the directory variants/crypt, so the setting and the journal
  # read luks-passphrase; the kernel command line, the dracut module list and
  # the package list all speak of passphrase. Nothing wrong with either — but
  # step 70 compared the long spelling against the short one and fell to its
  # default arm, so "Unknown crypt variant: luks-passphrase" stopped every
  # encrypted install before an initramfs could be built. Step 95 had been
  # normalising all along, in a copy of its own; this is that copy, moved to
  # where both can reach it.
  # Args: $1 = any spelling. A returned value, so stdout.
  case "${1:-}" in
    "" | none | no) printf 'none\n' ;;
    luks-passphrase | passphrase) printf 'passphrase\n' ;;
    luks-tpm | tpm) printf 'tpm\n' ;;
    luks-keyfile-gpg | keyfile) printf 'keyfile\n' ;;
    *) printf '%s\n' "$1" ;;
  esac
}

crypt_resolve_device() {
  # The device to encrypt, from the setting or from what step 20 recorded.
  # A returned value, so stdout.
  local dev="${CFG[crypt_device]:-}"
  if [[ -z "$dev" ]] && declare -F state_get >/dev/null 2>&1; then
    dev="$(state_get 'disk.crypt_device' 2>/dev/null || true)"
  fi
  [[ -n "$dev" ]] || return 1
  printf '%s\n' "$dev"
}

crypt_check_device() {
  # Args: $1 = device. Stage 2 again: it is spelled right, is it here?
  local dev="$1"
  if [[ "$DRY_RUN" == "yes" && ! -b "$dev" ]]; then
    log "dry-run: ${dev} is not a block device here; the plan continues anyway"
    return 0
  fi
  if [[ ! -b "$dev" ]]; then
    err "Not a block device: ${dev}"
    err "       step 20 records the container's device; run it first, or name"
    err "       the device yourself"
    err "       example:  crypt_device = /dev/nvme0n1p2"
    return 1
  fi
  return 0
}

# The device the loaded variant works on. Filled by crypt_require_device(),
# which a variant calls from its check() when it needs one; the "none" variant
# does not, and the step therefore never has to know which variant it holds.
# shellcheck disable=SC2034  # read by variants/crypt/*.sh and by steps/30_crypt.sh
CRYPT_DEVICE=""

# What crypt_variant_apply() built, as "slot:role" words. It is a global and
# not a value printed on stdout, and the reason is the one lib/core.sh gives
# for its file writers: `record="$(crypt_variant_apply)"` would run apply in a
# subshell, and every secret file it registered — for the trap, for cleanup(),
# for verify() to test — would die with that subshell, unwiped and unreachable.
# shellcheck disable=SC2034  # written by variants/crypt/*.sh, read by steps/30_crypt.sh
CRYPT_RECORD=""

crypt_require_device() {
  local dev
  if ! dev="$(crypt_resolve_device)"; then
    err "No device to encrypt"
    err "       step 20 records the container's device in the state journal"
    err "       run it first, or name the device yourself"
    err "       example:  crypt_device = /dev/nvme0n1p2"
    return 1
  fi
  crypt_check_device "$dev" || return 1
  # shellcheck disable=SC2034  # read by the variant that asked for it
  CRYPT_DEVICE="$dev"
  return 0
}

# --------------------------------------------------------------------------- #
#  Idempotence and the typed proof                                            #
# --------------------------------------------------------------------------- #
crypt_already_provisioned() {
  # True when this run would rebuild exactly what is already on the device.
  # Read, compare, and say which of the three happened (DESIGN.md §9).
  # Args: $1 = device, $2 = variant name.
  local dev="$1" variant="$2" done_variant done_uuid uuid
  declare -F state_get >/dev/null 2>&1 || return 1
  crypt_is_luks "$dev" || return 1
  done_variant="$(state_get 'crypt.variant' 2>/dev/null || true)"
  done_uuid="$(state_get 'crypt.uuid' 2>/dev/null || true)"
  uuid="$(crypt_luks_uuid "$dev")"
  [[ -n "$done_uuid" && -n "$uuid" ]] || return 1
  [[ "$done_variant" == "$variant" && "$done_uuid" == "$uuid" ]]
}

crypt_show_existing_header() {
  # Rendering only. What is about to be destroyed, named.
  local dev="$1"
  local -a slots=()
  warn "${dev} already holds a LUKS header"
  warn "$(printf '       version   %s' "$(crypt_luks_version "$dev")")"
  warn "$(printf '       UUID      %s' "$(crypt_luks_uuid "$dev")")"
  mapfile -t slots < <(crypt_used_slots "$dev")
  if ((${#slots[@]} > 0)); then
    warn "$(printf '       keyslots  %s' "${slots[*]}")"
  fi
  warn "       reformatting destroys every one of them, and every byte the"
  warn "       container protects becomes unreadable — there is no undo"
}

crypt_confirm_format() {
  # An irreversible act, so the confirmation is a typed value and no flag
  # lifts it (DESIGN.md §12). --force lifts confirmations, not proofs.
  # Args: $1 = device.
  local dev="$1"
  if ! crypt_is_luks "$dev"; then
    if [[ "$FORCE" == "yes" ]]; then
      log "formatting ${dev} (--force)"
      return 0
    fi
    if ! confirm "Create a LUKS2 container on ${dev}? Everything on it is lost." "no"; then
      skip "${dev} left alone"
      return 1
    fi
    return 0
  fi

  crypt_show_existing_header "$dev"
  if ! ask_tri crypt_wipe_luks "Reformat the existing LUKS container on ${dev}?" "no"; then
    err "Refusing to reformat ${dev}"
    err "       it already holds a LUKS header with keyslots on it"
    err "       crypt_wipe_luks = yes reformats it, destroying them"
    err "       crypt_device = ... points this step at another device"
    return 1
  fi
  confirm_typed "About to destroy every keyslot on ${dev}." "$dev"
}

crypt_state_record() {
  # The journal says what was done, never with what: no passphrase, no key,
  # no slot secret. state_set refuses such a key outright, and so does this.
  # Args: $1 = variant, $2 = device, $3.. = "slot:role" pairs.
  local variant="$1" dev="$2"
  shift 2
  declare -F state_set >/dev/null 2>&1 || return 0
  state_set 'crypt.variant' "$variant"
  state_set 'crypt.device' "$dev"
  if [[ "$variant" != "none" ]]; then
    state_set 'crypt.uuid' "$(crypt_luks_uuid "$dev")"
    state_set 'crypt.name' "${CFG[crypt_name]}"
    if (($# > 0)); then
      state_set 'crypt.slots' "$*"
    fi
    # Where the initramfs will look for the key file, and on which filesystem.
    # The path, never the key: this says where the file is, not what is in it,
    # exactly as crypt.device says which container was made and not how to open
    # it. Step 70 reads both back by name, and without them a --resume rebuilds
    # an initramfs pointing at the default path rather than the one in use.
    if [[ "$variant" == *keyfile* ]]; then
      local key_uuid="${CFG[crypt_keyfile_uuid]:-}"
      state_set 'crypt.keyfile' "${CFG[crypt_keyfile]:-/luks-key.gpg}"
      if [[ -z "$key_uuid" ]] && declare -F state_get >/dev/null 2>&1; then
        key_uuid="$(state_get disk.esp_uuid 2>/dev/null || true)"
      fi
      if [[ -n "$key_uuid" ]]; then
        state_set 'crypt.keyfile_uuid' "$key_uuid"
      fi
    fi
  fi
}
