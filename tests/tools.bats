#!/usr/bin/env bats
# The ten rescue tools, as a set.
#
# They are deliberately standalone — none of them sources lib/, so any one can be
# copied alone onto a USB stick and run on a machine that no longer boots. That
# independence is the point, and it is also why nothing was checking them: the
# suite loads the installer, and the tools share none of it.
#
# So these tests treat each tool as a black box and assert only what every one of
# them promises regardless of what it does: it explains itself, it refuses what
# it does not understand with the exit code the contract names, and it keeps
# stdout for values. A tool that fails here is broken for the person who reached
# for it at the worst possible moment.

load helper

gi_tools() {
  # Every executable tool, one path per line.
  local f
  for f in "${GI_ROOT}"/tools/*.sh; do
    [[ -e "$f" ]] || continue
    printf '%s\n' "$f"
  done
}

@test "there are tools to check at all" {
  # A glob that matches nothing would make every test below pass silently.
  local n
  n="$(gi_tools | wc -l)"
  [ "$n" -ge 10 ]
}

@test "every tool explains itself and exits zero doing it" {
  local tool out failures=""
  while read -r tool; do
    if ! out="$(bash "$tool" --help 2>&1)"; then
      failures+="  ${tool##*/}: --help exited non-zero"$'\n'
      continue
    fi
    # Twenty lines is not a style rule, it is the difference between a usage
    # block and a one-line "see the README".
    if [[ "$(printf '%s\n' "$out" | wc -l)" -lt 20 ]]; then
      failures+="  ${tool##*/}: --help printed almost nothing"$'\n'
    fi
    if [[ "$out" != *"${tool##*/}"* ]]; then
      failures+="  ${tool##*/}: --help never names the tool"$'\n'
    fi
  done < <(gi_tools)
  if [[ -n "$failures" ]]; then
    printf '%s' "$failures" >&2
    return 1
  fi
}

@test "every tool refuses an unknown flag with the usage exit code" {
  # DESIGN.md §3 fixes it at 2, and it is the difference a caller uses to tell
  # "you asked wrongly" from "it went wrong": a script that retries on 1 and
  # gives up on 2 needs both to mean what they say.
  local tool rc failures=""
  while read -r tool; do
    rc=0
    bash "$tool" --not-a-real-flag >/dev/null 2>&1 || rc=$?
    if [[ "$rc" -ne 2 ]]; then
      failures+="  ${tool##*/}: exited ${rc}, expected 2"$'\n'
    fi
  done < <(gi_tools)
  if [[ -n "$failures" ]]; then
    printf '%s' "$failures" >&2
    return 1
  fi
}

@test "no tool writes to stdout while refusing" {
  # stdout carries values — a device name, a UUID, a slot number — and a caller
  # reads it through $( ). A diagnostic printed there becomes part of whatever
  # the caller thought it was reading.
  local tool bytes failures=""
  while read -r tool; do
    bytes="$(bash "$tool" --not-a-real-flag 2>/dev/null | wc -c)"
    if [[ "$bytes" -ne 0 ]]; then
      failures+="  ${tool##*/}: ${bytes} byte(s) on stdout while refusing"$'\n'
    fi
  done < <(gi_tools)
  if [[ -n "$failures" ]]; then
    printf '%s' "$failures" >&2
    return 1
  fi
}

@test "every tool that writes a secret to disk puts it on a tmpfs, under a trap" {
  # A decrypted key in a temporary file is the one thing these tools must not
  # leave behind. secure_tmpdir() asks the filesystem which directory is in RAM
  # rather than assuming /tmp is — inside a chroot it usually is not — and a
  # trap removes the file however the tool ends.
  local tool failures=""
  while read -r tool; do
    grep -q 'mktemp' "$tool" || continue
    grep -q 'secure_tmpdir' "$tool" || {
      # A temporary file that holds no secret needs neither; say which it is.
      grep -qE 'mktemp [^)]*(pass|key|cred|secret)' "$tool" \
        && failures+="  ${tool##*/}: mktemps a secret outside secure_tmpdir"$'\n'
      continue
    }
    grep -qE '^\s*trap ' "$tool" \
      || failures+="  ${tool##*/}: mktemps a secret and installs no trap"$'\n'
  done < <(gi_tools)
  if [[ -n "$failures" ]]; then
    printf '%s' "$failures" >&2
    return 1
  fi
}

@test "a tool that documents a -- command mode actually parses --" {
  # rescue-chroot.sh enter -- CMD runs one command inside the rescued system
  # instead of an interactive shell. Before it existed the only way to run one
  # thing inside was to bypass the tool — prepare, then chroot by hand — which
  # is the sequence the tool exists to get right, and a recovery script or an
  # ssh check has nobody at a keyboard to type into a shell.
  #
  # Run as an ordinary user this stops on the root check or the target check.
  # What it must never say is "Unknown option: --".
  local tool out
  while read -r tool; do
    grep -q -- '-- CMD' "$tool" || continue
    out="$(bash "$tool" enter --target /nonexistent-target -- /bin/true 2>&1 || true)"
    if [[ "$out" == *"Unknown option: --"* ]]; then
      printf '%s documents -- and its parser refuses it\n' "${tool##*/}" >&2
      return 1
    fi
  done < <(gi_tools)
}

@test "a tool that takes --root says which paths it really looked at" {
  # key-backup.sh printed its bare candidates when it found nothing:
  #   Looked in: /boot/efi/luks-key.gpg
  # while it had actually searched <root>/boot/efi/luks-key.gpg. From a LiveCD —
  # the case --root exists for — that reads as though --root had been ignored,
  # and it sent this session hunting a bug that was not there. An operator
  # looking for a missing key has to be told where it was really looked for.
  local dir out
  dir="$(gi_tmp)/emptyroot"
  mkdir -p "$dir"
  out="$(bash "${GI_ROOT}/tools/key-backup.sh" show --root "$dir" 2>&1 || true)"
  [[ "$out" == *"Looked in:"* ]]
  if [[ "$out" != *"${dir}/boot/efi"* ]]; then
    printf 'the message does not name the searched path:\n%s\n' "$out" >&2
    return 1
  fi
}

@test "no tool names a volume group the installer does not create" {
  # The tools shipped assuming vg1, the group the machine this tooling grew up
  # on happened to have. gentoo-install creates vg0 (lib/disk.sh: disk_vg), so
  # every "detected from the volume group" path found nothing on the machines
  # this project installs, and luks-open.sh's close deactivated nothing and
  # then could not close the container it had opened.
  #
  # The fix is not to write vg0 here instead: it is to ask LVM which group sits
  # inside the container. So the rule is that no executable line names a group
  # at all. Comments explaining the history are exactly where the name belongs.
  local tool line offenders=""
  while read -r tool; do
    while IFS= read -r line; do
      offenders+="  ${tool##*/}: ${line}"$'\n'
    done < <(grep -nE '(^|[^#])[^#]*\bvg[0-9]+\b' "$tool" \
      | grep -vE '^[0-9]+: *#' || true)
  done < <(gi_tools)
  if [[ -n "$offenders" ]]; then
    printf 'a volume group name is hardcoded in a tool:\n%s\n' "$offenders" >&2
    return 1
  fi
}

@test "an fstab that names nothing usable is reported as naming nothing" {
  # luks-open.sh mounts what the machine's own fstab names, and falls back to
  # the volume names only when that gives nothing. It used to test whether the
  # file existed — and a stage3 ships an /etc/fstab whose every line is a
  # comment. So a rescue of a half-installed machine mounted / and stopped:
  # no /var, which is where the ebuild repository lives, and an emerge in that
  # chroot then built against a repository that was not there.
  #
  # The function is lifted out of the tool rather than the tool being run,
  # because it is the return value that carries the decision.
  local dir
  dir="$(gi_tmp)/fstabtest"
  mkdir -p "$dir/etc"

  run bash -c '
    warn() { :; }; skip() { :; }; log() { :; }
    mount_if_needed() { printf "MOUNT %s %s\n" "$1" "$2"; }
    eval "$(sed -n "/^mount_from_fstab() {/,/^}/p" "$1/tools/luks-open.sh")"
    mount_from_fstab "$2"
  ' bash "$GI_ROOT" "$dir"
  [ "$status" -ne 0 ]

  # Every line a comment, which is what a stage3 leaves behind.
  printf '# /dev/BOOT   /boot   vfat  defaults  0 2\n# nothing here\n' >"$dir/etc/fstab"
  run bash -c '
    warn() { :; }; skip() { :; }; log() { :; }
    mount_if_needed() { printf "MOUNT %s %s\n" "$1" "$2"; }
    eval "$(sed -n "/^mount_from_fstab() {/,/^}/p" "$1/tools/luks-open.sh")"
    mount_from_fstab "$2"
  ' bash "$GI_ROOT" "$dir"
  [ "$status" -ne 0 ]
  [ -z "$output" ]

  # And an entry naming a device that is not here is not a mount either.
  printf 'UUID=nope  /var  ext4  defaults  0 2\n' >"$dir/etc/fstab"
  run bash -c '
    warn() { :; }; skip() { :; }; log() { :; }
    blkid() { return 1; }
    mount_if_needed() { printf "MOUNT %s %s\n" "$1" "$2"; }
    eval "$(sed -n "/^mount_from_fstab() {/,/^}/p" "$1/tools/luks-open.sh")"
    mount_from_fstab "$2"
  ' bash "$GI_ROOT" "$dir"
  [ "$status" -ne 0 ]
  [ -z "$output" ]
}

@test "a reseal reproduces the policy in force, not this script's default" {
  # tpm-reseal.sh read the binding, printed it, and then resealed with its own
  # default — pcr_ids 0,2,3,6. A machine installed with another set of
  # registers, or with an RSA key instead of ECC, came back from a reseal bound
  # to something its operator never chose, with the old configuration printed
  # two lines above the new one.
  #
  # The function is lifted out of the tool: what matters is the value it
  # returns, and the tool around it needs root, a TPM and a container.
  run bash -c '
    eval "$(sed -n "/^policy_of_binding()/,/^}/p" "$1/tools/tpm-reseal.sh")"
    clevis() {
      printf "%s\n" "2: tpm2 '"'"'{\"hash\":\"sha256\",\"key\":\"ecc\",\"pcr_bank\":\"sha256\",\"pcr_ids\":\"0,7\"}'"'"'"
    }
    policy_of_binding /dev/sdz 2
  ' bash "$GI_ROOT"
  [ "$status" -eq 0 ]
  [[ "$output" == '{"hash":"sha256","key":"ecc","pcr_bank":"sha256","pcr_ids":"0,7"}' ]]
}

@test "a slot with no binding yields no policy to adopt" {
  run bash -c '
    eval "$(sed -n "/^policy_of_binding()/,/^}/p" "$1/tools/tpm-reseal.sh")"
    clevis() { printf "%s\n" "2: tpm2 '"'"'{\"pcr_ids\":\"0\"}'"'"'"; }
    policy_of_binding /dev/sdz 1
  ' bash "$GI_ROOT"
  [ "$status" -ne 0 ]
  [ -z "$output" ]
}

@test "the reseal adopts the slot and the policy before announcing either" {
  # Both were read from the container; only one was used. The order is the
  # test: what is printed as "Policy" has to be what will be sealed.
  local tool
  tool="${GI_ROOT}/tools/tpm-reseal.sh"
  local adopt announce
  adopt="$(grep -n 'adopt_real_policy "\$dev"' "$tool" | head -n1 | cut -d: -f1)"
  announce="$(grep -n 'ok "Policy    : \$PCR_POLICY"' "$tool" | head -n1 | cut -d: -f1)"
  [ -n "$adopt" ]
  [ -n "$announce" ]
  [ "$adopt" -lt "$announce" ]
}

@test "the flashing tool reads the pair this installer signed with" {
  # bios-update.sh had two sources for the Secure Boot pair and neither was
  # gentoo-install: a conventional /etc/efikeys, and a configuration file
  # belonging to another tool entirely. So a machine installed and signed by
  # this project reached "No Secure Boot signing pair found", having been asked
  # about two files it never creates — while its own journal, on that same
  # disk, recorded what step 80 used.
  local root
  root="$(gi_tmp)/signed"
  mkdir -p "${root}/var/lib/gentoo-install" "${root}/etc/keys"
  : >"${root}/etc/keys/db.key"
  : >"${root}/etc/keys/db.crt"
  printf 'boot.secureboot_keyfile=/etc/keys/db.key\nboot.secureboot_cert=/etc/keys/db.crt\n' \
    >"${root}/var/lib/gentoo-install/state"

  run bash -c '
    ok() { printf "OK %s\n" "$*"; }; err() { printf "ERR %s\n" "$*" >&2; }
    warn() { :; }; conf_var() { return 0; }
    ROOT_PREFIX="$2"; STATE_DIR="/var/lib/gentoo-install"
    SIGN_KEY=""; SIGN_CERT=""
    BUILDKERNEL_CONF="/nonexistent"; EFIKEYS_KEY="/nonexistent"; EFIKEYS_CERT="/nonexistent"
    eval "$(sed -n "/^journal_var()/,/^}/p" "$1/tools/bios-update.sh")"
    eval "$(sed -n "/^resolve_sign_pair()/,/^}/p" "$1/tools/bios-update.sh")"
    resolve_sign_pair
    printf "KEY=%s CERT=%s\n" "$SIGN_KEY" "$SIGN_CERT"
  ' bash "$GI_ROOT" "$root"
  [ "$status" -eq 0 ]
  [[ "$output" == *"install journal"* ]]
  [[ "$output" == *"KEY=${root}/etc/keys/db.key"* ]]
  [[ "$output" == *"CERT=${root}/etc/keys/db.crt"* ]]
}

@test "step 80 records the key's path, not only the certificate's" {
  # The journal refuses a key named *_key outright — boot.secureboot_key would
  # have died on the spot — so recording only the certificate looked complete
  # and left the machine with half a pair. The path, never the key, exactly as
  # crypt.keyfile does it.
  grep -q 'state_set boot.secureboot_keyfile' "${GI_ROOT}/steps/80_boot.sh"
  gi_bash '
    DRY_RUN=no
    STATE_DIR="$1"; STATE_FILE="$1/state"
    mkdir -p "$1"; : >"$STATE_FILE"
    state_set boot.secureboot_keyfile /etc/keys/db.key
    state_get boot.secureboot_keyfile
  ' "$(gi_tmp)/journalkey"
  [ "$status" -eq 0 ]
  [ "$output" = "/etc/keys/db.key" ]
}

@test "key-backup composes the key's path from the two journal entries" {
  # Neither entry is enough on its own. crypt.keyfile is what the initramfs is
  # told, and that path is relative to the root of the filesystem carrying it —
  # rd.luks.key names it that way — while disk.esp_mount says where that
  # filesystem is mounted in the installed system. A key recorded as
  # /efi/luks-key.gpg with an ESP at /boot is /boot/efi/luks-key.gpg to anything
  # walking the tree, and reading either entry alone gives a path that is not
  # there.
  local root
  root="$(gi_tmp)/kb"
  mkdir -p "${root}/var/lib/gentoo-install" "${root}/boot/efi"
  printf 'crypt.keyfile=/efi/luks-key.gpg\ndisk.esp_mount=/boot\n' \
    >"${root}/var/lib/gentoo-install/state"
  printf 'envelope\n' >"${root}/boot/efi/luks-key.gpg"

  run bash -c '
    ROOT_PREFIX="$2"
    KEY_PATH=""; KEY_CANDIDATES=("/nowhere/luks-key.gpg")
    err() { printf "ERR %s\n" "$*" >&2; }
    eval "$(sed -n "/^journal_var()/,/^}/p"      "$1/tools/key-backup.sh")"
    eval "$(sed -n "/^journal_key_path()/,/^}/p" "$1/tools/key-backup.sh")"
    eval "$(sed -n "/^resolve_key()/,/^}/p"      "$1/tools/key-backup.sh")"
    resolve_key
  ' bash "$GI_ROOT" "$root"
  [ "$status" -eq 0 ]
  [ "$output" = "${root}/boot/efi/luks-key.gpg" ]
}

@test "and says it looked there when nothing is found" {
  local root
  root="$(gi_tmp)/kb2"
  mkdir -p "${root}/var/lib/gentoo-install"
  printf 'crypt.keyfile=/efi/luks-key.gpg\ndisk.esp_mount=/boot\n' \
    >"${root}/var/lib/gentoo-install/state"
  run bash -c '
    ROOT_PREFIX="$2"; KEY_CANDIDATES=("/boot/efi/luks-key.gpg")
    eval "$(sed -n "/^journal_var()/,/^}/p"           "$1/tools/key-backup.sh")"
    eval "$(sed -n "/^journal_key_path()/,/^}/p"      "$1/tools/key-backup.sh")"
    eval "$(sed -n "/^key_candidates_searched()/,/^}/p" "$1/tools/key-backup.sh")"
    key_candidates_searched
  ' bash "$GI_ROOT" "$root"
  [ "$status" -eq 0 ]
  [[ "$output" == *"${root}/boot/efi/luks-key.gpg"* ]]
}

@test "no journal means the conventional candidates, exactly as before" {
  local root
  root="$(gi_tmp)/kb3"
  mkdir -p "${root}/boot/efi"
  printf 'envelope\n' >"${root}/boot/efi/luks-key.gpg"
  run bash -c '
    ROOT_PREFIX="$2"
    KEY_PATH=""; KEY_CANDIDATES=("/boot/efi/luks-key.gpg")
    err() { :; }
    eval "$(sed -n "/^journal_var()/,/^}/p"      "$1/tools/key-backup.sh")"
    eval "$(sed -n "/^journal_key_path()/,/^}/p" "$1/tools/key-backup.sh")"
    eval "$(sed -n "/^resolve_key()/,/^}/p"      "$1/tools/key-backup.sh")"
    resolve_key
  ' bash "$GI_ROOT" "$root"
  [ "$status" -eq 0 ]
  [ "$output" = "${root}/boot/efi/luks-key.gpg" ]
}

@test "every tool that resolves a container asks the journal first" {
  # The journal is a fact about the machine in front of the tool; the volume
  # group enumeration below it is a search. bios-update.sh was given that shape
  # for the Secure Boot pair and key-backup.sh for the key file; this is the
  # same rule for the container itself, in the seven tools that look for one.
  # And it checks the call, not the definition: removing the two lines that
  # invoke it left an earlier version of this test perfectly green, because the
  # helper was still sitting there unused.
  local tool missing=""
  while read -r tool; do
    grep -q '^resolve_device()' "$tool" || continue
    sed -n '/^resolve_device() {/,/^}/p' "$tool" | grep -q 'journal_device' \
      || missing+=" ${tool##*/}"
  done < <(gi_tools)
  if [[ -n "$missing" ]]; then
    printf 'tools that resolve a container without reading the journal:%s\n' "$missing" >&2
    return 1
  fi
}

@test "the recorded container is checked, not trusted" {
  # A disk is /dev/vda2 to the machine that was installed and can be /dev/sdb2
  # to the rescue medium looking at it. A recorded name that no longer points at
  # a LUKS header is worth less than the search that follows it.
  local root
  root="$(gi_tmp)/jd"
  mkdir -p "${root}/var/lib/gentoo-install"
  printf 'crypt.device=/dev/definitely-not-here\n' >"${root}/var/lib/gentoo-install/state"

  run bash -c '
    ROOT_PREFIX="$2"
    eval "$(sed -n "/^journal_device()/,/^}/p" "$1/tools/luks-check.sh")"
    journal_device
  ' bash "$GI_ROOT" "$root"
  [ "$status" -ne 0 ]
  [ -z "$output" ]

  # And no journal at all is simply no answer, not an error the caller has to
  # special-case.
  run bash -c '
    ROOT_PREFIX="$2/empty"
    eval "$(sed -n "/^journal_device()/,/^}/p" "$1/tools/luks-check.sh")"
    journal_device
  ' bash "$GI_ROOT" "$root"
  [ "$status" -ne 0 ]
  [ -z "$output" ]
}

@test "the diagnostic looks for the ESP where this installer mounts it" {
  # luks-check.sh tested /boot/efi, hardcoded — the layout of the machine this
  # tooling grew up on. gentoo-install mounts the ESP at /boot, so on a machine
  # it installed the tool said "the ESP is not mounted, cannot look for the key"
  # about a filesystem that had been mounted all along, one directory away.
  local root
  root="$(gi_tmp)/lc"
  mkdir -p "${root}/var/lib/gentoo-install"
  printf 'disk.esp_mount=/boot\ncrypt.keyfile=/efi/luks-key.gpg\n' \
    >"${root}/var/lib/gentoo-install/state"

  run bash -c '
    ROOT_PREFIX="$2"
    eval "$(sed -n "/^journal_var()/,/^}/p"      "$1/tools/luks-check.sh")"
    eval "$(sed -n "/^esp_mount_point()/,/^}/p"  "$1/tools/luks-check.sh")"
    eval "$(sed -n "/^journal_key_path()/,/^}/p" "$1/tools/luks-check.sh")"
    printf "%s %s\n" "$(esp_mount_point)" "$(journal_key_path)"
  ' bash "$GI_ROOT" "$root"
  [ "$status" -eq 0 ]
  [ "$output" = "/boot /boot/efi/luks-key.gpg" ]
}

@test "with no journal it keeps the conventional /boot/efi" {
  # The machine whose /var will not mount is the one these tools exist for, and
  # the old default is still the right guess there.
  run bash -c '
    ROOT_PREFIX="$2/nothing-here"
    eval "$(sed -n "/^journal_var()/,/^}/p"     "$1/tools/luks-check.sh")"
    eval "$(sed -n "/^esp_mount_point()/,/^}/p" "$1/tools/luks-check.sh")"
    esp_mount_point
  ' bash "$GI_ROOT" "$(gi_tmp)"
  [ "$status" -eq 0 ]
  [ "$output" = "/boot/efi" ]
}

@test "the slot report says what is nominal for this machine when it can" {
  # The table is right and an operator still has to apply it. The journal names
  # the variant that made the container, so the report can answer instead.
  local root
  root="$(gi_tmp)/lcv"
  mkdir -p "${root}/var/lib/gentoo-install"
  printf 'crypt.variant=luks-tpm\n' >"${root}/var/lib/gentoo-install/state"

  run bash -c '
    ROOT_PREFIX="$2"; C_B=""; C_0=""; C_G=""
    err() { printf "ERR %s\n" "$*" >&2; }
    list_slots() { printf "0\n1\n2\n"; }
    eval "$(sed -n "/^journal_var()/,/^}/p"  "$1/tools/luks-check.sh")"
    eval "$(sed -n "/^report_slots()/,/^}/p" "$1/tools/luks-check.sh")"
    report_slots /dev/sdz
  ' bash "$GI_ROOT" "$root" 2>&1
  [ "$status" -eq 0 ]
  [[ "$output" == *"encrypted with luks-tpm"* ]]
  [[ "$output" == *"slots 0, 1 and 2"* ]]
  [[ "$output" != *"What is nominal depends"* ]]
}

@test "and prints the table when the journal cannot say" {
  run bash -c '
    ROOT_PREFIX="$2/gone"; C_B=""; C_0=""; C_G=""
    err() { printf "ERR %s\n" "$*" >&2; }
    list_slots() { printf "0\n1\n"; }
    eval "$(sed -n "/^journal_var()/,/^}/p"  "$1/tools/luks-check.sh")"
    eval "$(sed -n "/^report_slots()/,/^}/p" "$1/tools/luks-check.sh")"
    report_slots /dev/sdz
  ' bash "$GI_ROOT" "$(gi_tmp)" 2>&1
  [ "$status" -eq 0 ]
  [[ "$output" == *"What is nominal depends"* ]]
}

@test "every clevis binding is refused, not only the first" {
  # clevis holds several pins at once by design: a tpm2 pin for the machine
  # that unlocks itself, a tang pin for the one that asks the network. The
  # guard in luks-addkey read `head -n 1`, so with two bindings
  # `remove --slot <the second>` killed the keyslot and left its token behind,
  # pointing at a slot that no longer exists — which is what the refusal it
  # printed for the first one says it prevents.
  run bash -c '
    eval "$(sed -n "/^clevis_slots()/,/^}/p" "$1/tools/luks-addkey.sh")"
    eval "$(sed -n "/^slot_is_clevis()/,/^}/p" "$1/tools/luks-addkey.sh")"
    clevis() {
      printf "%s\n" "1: tang '"'"'{\"url\":\"http://tang\"}'"'"'"
      printf "%s\n" "2: tpm2 '"'"'{\"pcr_ids\":\"0,7\"}'"'"'"
    }
    slot_is_clevis /dev/sdz 1 || echo "slot 1 not owned"
    slot_is_clevis /dev/sdz 2 || echo "slot 2 not owned"
    slot_is_clevis /dev/sdz 3 && echo "slot 3 wrongly owned"
    printf "slots=%s\n" "$(clevis_slots /dev/sdz | paste -sd, -)"
  ' bash "$GI_ROOT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"slots=1,2"* ]]
  [[ "$output" != *"not owned"* ]]
  [[ "$output" != *"wrongly owned"* ]]
}

@test "the TPM tools work on the tpm2 binding, not on whichever came first" {
  # A BIOS flash breaks a tpm2 sealing and does nothing to a tang one, so
  # picking the first binding pointed both tools at a slot that has nothing to
  # do with the TPM.
  local tool
  for tool in tpm-reseal bios-maint; do
    run bash -c '
      eval "$(sed -n "/^clevis_slot_of()/,/^}/p" "$1/tools/$2.sh")"
      clevis() {
        printf "%s\n" "1: tang '"'"'{\"url\":\"http://tang\"}'"'"'"
        printf "%s\n" "2: tpm2 '"'"'{\"pcr_ids\":\"0,7\"}'"'"'"
      }
      command() { [[ "$2" == clevis ]] && return 0; builtin command "$@"; }
      clevis_slot_of /dev/sdz
    ' bash "$GI_ROOT" "$tool"
    [ "$status" -eq 0 ]
    [ "$output" = "2" ] || {
      printf '%s picked slot %s\n' "$tool" "$output" >&2
      return 1
    }
  done
}

@test "a machine with no tpm2 binding gives the TPM tools nothing to adopt" {
  local tool
  for tool in tpm-reseal bios-maint; do
    run bash -c '
      eval "$(sed -n "/^clevis_slot_of()/,/^}/p" "$1/tools/$2.sh")"
      clevis() { printf "%s\n" "1: tang '"'"'{\"url\":\"http://tang\"}'"'"'"; }
      command() { [[ "$2" == clevis ]] && return 0; builtin command "$@"; }
      clevis_slot_of /dev/sdz
    ' bash "$GI_ROOT" "$tool"
    [ "$status" -ne 0 ]
  done
}

@test "the new passphrase is refused on the ESP this installer mounts" {
  # luks-addkey refused "/boot/efi" anywhere in the path — the layout of the
  # machine this tooling grew up on. gentoo-install mounts the ESP at /boot,
  # so on a machine it had installed the refusal never fired and
  # `--gen --pass-out /boot/pw` wrote the passphrase onto the partition the
  # firmware reads before anything is decrypted.
  local dir
  dir="$(gi_tmp)"
  mkdir -p "${dir}/j/var/lib/gentoo-install"
  printf 'disk.esp_mount=/boot\n' >"${dir}/j/var/lib/gentoo-install/state"
  run bash -c '
    for f in journal_var esp_mount_point lands_on_the_esp; do
      eval "$(sed -n "/^${f}()/,/^}/p" "$1/tools/luks-addkey.sh")"
    done
    ROOT_PREFIX="$2"
    lands_on_the_esp /boot            && echo "boot refused"
    lands_on_the_esp /boot/EFI/gentoo && echo "subdir refused"
    lands_on_the_esp /root            || echo "root allowed"
  ' bash "$GI_ROOT" "${dir}/j"
  [ "$status" -eq 0 ]
  [[ "$output" == *"boot refused"* ]]
  [[ "$output" == *"subdir refused"* ]]
  [[ "$output" == *"root allowed"* ]]
}

@test "with no journal the conventional ESP paths are still refused" {
  run bash -c '
    for f in journal_var esp_mount_point lands_on_the_esp; do
      eval "$(sed -n "/^${f}()/,/^}/p" "$1/tools/luks-addkey.sh")"
    done
    ROOT_PREFIX=/nonexistent
    lands_on_the_esp /boot/efi && echo "boot/efi refused"
    lands_on_the_esp /efi      && echo "efi refused"
  ' bash "$GI_ROOT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"boot/efi refused"* ]]
  [[ "$output" == *"efi refused"* ]]
}

@test "a vfat mount is refused wherever it sits" {
  # The mountpoint list cannot name every layout, and the filesystem answers
  # for itself: vfat has no modes, so the chmod 600 this tool reports would
  # have been a sentence about a file that had none.
  run bash -c '
    for f in journal_var esp_mount_point lands_on_the_esp; do
      eval "$(sed -n "/^${f}()/,/^}/p" "$1/tools/luks-addkey.sh")"
    done
    ROOT_PREFIX=/nonexistent
    findmnt() { printf "vfat\n"; }
    lands_on_the_esp /srv/somewhere && echo "vfat refused"
  ' bash "$GI_ROOT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"vfat refused"* ]]
}
