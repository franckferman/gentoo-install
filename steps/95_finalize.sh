#!/usr/bin/env bash
#
# gentoo-install — step 95: the last five checks, the recap, the release
# ----------------------------------------------------------------------------
# The only step that builds nothing. It asks whether what the previous steps
# built will actually come back up, says what is left to do by hand, releases
# exactly what this install mounted, and stops.
#
# The check that pays for this file is the initramfs one. An image without the
# modules the encryption variant needs produces a machine that stops at a
# dracut prompt with no root and no explanation, and diagnosing that from a
# LiveUSB costs an hour. So it is asked of the image itself — lsinitrd when
# there is one, the cpio archive when there is not — and never of the
# configuration that was meant to produce it.
#
# The reboot is a tri-state and never happens on its own. Win-PostInstall ends
# its main with an unconditional Restart-System, no confirmation and no
# --no-reboot (docs/research/01-win-postinstall.md §3.4, defect 7). This is the
# one step where repeating that mistake would be easy.
#
# Usage:  sourced by gentoo-install.sh, which calls step_95_finalize()
#
set -euo pipefail

if [[ -n "${_GI_STEP_95_LOADED:-}" ]]; then
  return 0
fi
_GI_STEP_95_LOADED=1

# The entry point sources the libraries before this file, so these guards never
# fire in production. They exist so that `shellcheck steps/95_finalize.sh` and a
# standalone `source steps/95_finalize.sh` both see the same definitions the
# runner does, instead of a file full of undefined names.
_gi_step95_steps="${BASH_SOURCE[0]%/*}"
_gi_step95_lib="${GI_LIB_DIR:-${_gi_step95_steps}/../lib}"
if [[ -z "${_GI_CORE_LOADED:-}" ]]; then
  # shellcheck source=lib/core.sh
  source "${_gi_step95_lib}/core.sh"
fi
if [[ -z "${_GI_CONFIG_LOADED:-}" ]]; then
  # shellcheck source=lib/config.sh
  source "${_gi_step95_lib}/config.sh"
fi
if [[ -z "${_GI_STATE_LOADED:-}" ]]; then
  # shellcheck source=lib/state.sh
  source "${_gi_step95_lib}/state.sh"
fi
if [[ -z "${_GI_UI_LOADED:-}" ]]; then
  # shellcheck source=lib/ui.sh
  source "${_gi_step95_lib}/ui.sh"
fi
if [[ -z "${_GI_CHROOT_LOADED:-}" ]]; then
  # shellcheck source=lib/chroot.sh
  source "${_gi_step95_lib}/chroot.sh"
fi
if [[ -z "${_GI_DISK_LOADED:-}" ]]; then
  # shellcheck source=lib/disk.sh
  source "${_gi_step95_lib}/disk.sh"
fi
# steps/70_kernel.sh owns kernel_installed(). Step 80 sources it for the same
# reason this one does: the question "what ended up in /boot" must have exactly
# one implementation, or the step that verifies the answer and the step that
# produced it drift apart.
if [[ -z "${_GI_STEP_70_LOADED:-}" ]]; then
  # shellcheck source=steps/70_kernel.sh
  source "${_gi_step95_steps}/70_kernel.sh"
fi
unset _gi_step95_lib _gi_step95_steps

# --------------------------------------------------------------------------- #
#  Thresholds                                                                 #
# --------------------------------------------------------------------------- #
# Named once, here, so that a verdict can quote the number it judged against
# instead of asserting that something is "too small".
readonly _FIN_MIN_KERNEL_KIB=512  # a real bzImage is megabytes; 0 is a stub
readonly _FIN_MIN_INITRD_KIB=256  # a dracut image with crypt in it is bigger
readonly _FIN_REBOOT_DELAY=5      # seconds between the answer and the reboot
readonly _FIN_ESP_SCAN_DEPTH=4    # directory levels an EFI file may hide in
readonly _FIN_OFFSET_CANDIDATES=4 # compressed segments tried behind the microcode

# --------------------------------------------------------------------------- #
#  Verdicts                                                                   #
# --------------------------------------------------------------------------- #
# The rendering half of DESIGN.md §7, and deliberately the same shape as step
# 10's: an operator who has read the pre-flight screen can read this one. The
# checks decide and record; only _fin_verdict draws.
_FIN_INDEX=0
_FIN_TOTAL=0
_FIN_FAILED=()
_FIN_WARNED=()

# The ordered list is the check list. Adding a check is one name here plus one
# _fin_check_<name> function; the numbering and the total follow.
_FIN_CHECKS=(kernel initramfs bootentry fstab access)

# Filled once by _fin_read_installed_kernel(), read by three of the checks and
# by the recap. Kept as globals rather than recomputed because kernel_installed
# walks /boot, and a check that disagrees with the check above it about which
# kernel is installed is worse than no check at all.
_FIN_KVERSION=""
_FIN_KIMAGE=""
_FIN_KINITRD=""

# How the initramfs was read, so a verdict can say how much its answer is
# worth: lsinitrd is dracut's own answer, contents is inference from the cpio
# file list, none means the image could not be opened at all. The payload is
# module names under the first method and file paths under the second, which
# is exactly why the two travel together.
_FIN_INITRD_METHOD="none"
_FIN_INITRD_PAYLOAD=""

_fin_verdict() {
  # Args: $1 = PASS|WARN|FAIL|SKIP, $2 = key, $3 = title, $4 = one-line detail.
  local status="$1" key="$2" title="$3" detail="$4" colour="$C_0"
  _FIN_INDEX=$((_FIN_INDEX + 1))
  case "$status" in
    PASS) colour="$C_G" ;;
    WARN)
      colour="$C_Y"
      _FIN_WARNED+=("$key")
      ;;
    FAIL)
      colour="$C_R"
      _FIN_FAILED+=("$key")
      ;;
    SKIP) colour="$C_D" ;;
    *) die "internal: _fin_verdict got an unknown status: ${status}" ;;
  esac
  printf '  %2d/%2d  %s[%s]%s %-24s %s\n' \
    "$_FIN_INDEX" "$_FIN_TOTAL" "$colour" "$status" "$C_0" "$title" "$detail" >&2
  _journal "[${status}]" "finalize ${key}: ${title} — ${detail}"
}

_fin_note() {
  # An explanation line, indented under the verdict it belongs to.
  printf '         %s\n' "$*" >&2
  _journal '[.]' "finalize: $*"
}

_fin_fix() {
  # The command that makes the check pass. Copyable as printed, always.
  printf '         %s$ %s%s\n' "$C_D" "$*" "$C_0" >&2
  _journal '[$]' "finalize fix: $*"
}

_fin_item() {
  # One aligned row of the recap. Prints nothing for an empty value, so the
  # recap of a minimal install is short instead of full of blanks.
  local label="$1" value="$2"
  [[ -n "$value" ]] || return 0
  printf '         %-12s %s\n' "$label" "$value" >&2
  _journal '[.]' "finalize recap: ${label} ${value}"
}

# --------------------------------------------------------------------------- #
#  Small readers                                                              #
# --------------------------------------------------------------------------- #
_fin_fact() {
  # Args: $1 = CFG key ("" for none), $2 = state key ("" for none),
  #       $3 = fallback. A returned value, so stdout.
  #
  # steps/70_kernel.sh has target_fact() for the same job and this step does
  # not use it, for one reason that only matters here. target_fact reads CFG
  # first, and lib/config.sh gives crypt, layout, kernel and bootloader
  # non-empty built-in defaults; so on a --resume run with no configuration
  # file, `cfg crypt` answers "none" about a machine step 30 encrypted three
  # hours ago. Every check below would then be verifying a plain install that
  # does not exist, and the initramfs check — the one this file is written for
  # — would pass an image that cannot open the container.
  #
  # The order here is explicit setting, then the journal, then the built-in
  # default. An explicit value still wins, because that is the operator talking
  # and DESIGN.md §5 says nothing may override an intention; a default loses to
  # the record of what was actually done, because a verifier that trusts the
  # plan over the machine is not a verifier.
  local cfg_key="$1" state_key="${2:-}" fallback="${3:-}" value=""

  if [[ -n "$cfg_key" ]] && is_explicit "$cfg_key"; then
    value="$(cfg "$cfg_key")"
  fi
  if [[ -z "$value" && -n "$state_key" ]]; then
    value="$(state_get "$state_key" 2>/dev/null || true)"
  fi
  if [[ -z "$value" && -n "$cfg_key" ]]; then
    value="$(cfg "$cfg_key")"
  fi
  printf '%s\n' "${value:-$fallback}"
}

_fin_recorded() {
  # A fact only the journal ever knows: which stage tarball step 40 unpacked,
  # which keyslots step 30 filled. Args: $1 = state key, $2 = fallback.
  _fin_fact "" "$1" "${2:-}"
}

_fin_esp_mount() {
  # Where the ESP is mounted inside the target. A returned value.
  _fin_fact esp_mount disk.esp_mount "/efi"
}

_fin_root() {
  # Where the installed system is mounted. Four sources in falling order of
  # authority: the setting, what step 50 recorded, what step 20 recorded, the
  # default. The journal matters here more than anywhere else — after a
  # --resume the whole install happened in another process, and CFG knows
  # nothing about it. A returned value, so stdout.
  local root
  root="$(_fin_fact root chroot.target "")"
  if [[ -z "$root" ]]; then
    root="$(_fin_fact chroot_dir disk.mountpoint "")"
  fi
  if [[ -z "$root" ]]; then
    root="$(_fin_fact target_root chroot.target "${GI_ROOT:-/mnt/gentoo}")"
  fi
  printf '%s\n' "${root%/}"
}

_fin_firmware() {
  # How this machine was booted, for want of a recorded answer.
  if [[ -d /sys/firmware/efi ]]; then
    printf 'uefi\n'
  else
    printf 'bios\n'
  fi
}

_fin_crypt() {
  # The encryption variant, spelled one way. Step 30's catalogue is the
  # directory variants/crypt, so its journal entry reads luks-tpm; step 70's
  # command-line composer spells the same choice tpm. Step 95 reads a journal
  # that may carry either, and normalising here is cheaper than a check that
  # silently believes an encrypted machine needs no crypt module.
  crypt_family "$(_fin_fact crypt crypt.variant "none")"
}

_fin_uses_lvm() {
  # True when root sits on a logical volume, in either vocabulary. lib/disk.sh
  # records disk.lvm=yes|no next to a layout name from variants/layout
  # (minimal, server, desktop, custom); steps/70_kernel.sh calls the same idea a
  # layout of plain|lvm. Both are asked, because getting this wrong drops dm and
  # lvm from the list of modules the image is checked for.
  local value
  value="$(_fin_fact disk_lvm disk.lvm "")"
  if [[ "$value" == "yes" ]]; then
    return 0
  fi
  [[ "$(_fin_fact disk_layout disk.layout "")" == "lvm" ]]
}

_fin_esp_dir() {
  # The EFI system partition as this run can reach it. Args: $1 = target root.
  # Split across two locals: in one, ${root} expands empty and the path becomes
  # the HOST's ESP mountpoint (SC2318).
  local root="${1%/}"
  local mount
  mount="$(_fin_esp_mount)"
  printf '%s\n' "${root}${mount}"
}

_fin_size_kib() {
  # Args: $1 = path. Prints 0 for anything that is not a readable file.
  local path="$1" bytes
  bytes="$(stat -c '%s' -- "$path" 2>/dev/null || printf '0')"
  printf '%s\n' "$((bytes / 1024))"
}

_fin_wanted_modules() {
  # The initramfs modules this machine's root cannot be reached without, one
  # per line. Composed from the same two facts step 70 composed its dracut
  # configuration from — the encryption variant and the layout — because the
  # question here is whether the image matches the plan, and two different
  # ideas of the plan would make the answer meaningless.
  local crypt
  local -a mods=()

  crypt="$(_fin_crypt)"

  # The same rule step 70 builds by, and for the same reason: lvm belongs to the
  # topology, not to the encryption. Asking for it on a plain LUKS root made
  # dracut refuse to build at all, and expecting it here made a correct image
  # read as "1 of 3 modules missing". Twice now these two steps have drifted on
  # this list; they derive it separately on purpose — a check that trusted the
  # builder would agree with it about a mistake — so the rule is what has to
  # match, not the code.
  if [[ "$crypt" != "none" ]]; then
    mods+=(crypt dm)
  fi
  if _fin_uses_lvm; then
    mods+=(dm lvm)
  fi

  case "$crypt" in
    tpm) mods+=(clevis clevis-pin-tpm2) ;;
    keyfile) mods+=(crypt-gpg) ;;
    *) ;;
  esac

  ((${#mods[@]} > 0)) || return 0
  printf '%s\n' "${mods[@]}" | awk '!seen[$0]++'
}

_fin_module_package() {
  # Where a missing module comes from. A missing name with no package beside it
  # costs a web search, which is what these verdicts exist to save.
  case "$1" in
    clevis | clevis-pin-tpm2) printf 'app-crypt/clevis (with the tpm2 USE flag)\n' ;;
    crypt-gpg) printf 'sys-kernel/dracut, and app-crypt/gnupg in the target\n' ;;
    crypt | dm | lvm) printf 'sys-kernel/dracut\n' ;;
    *) printf 'provider unknown to gentoo-install\n' ;;
  esac
}

_fin_read_installed_kernel() {
  # Fills the three _FIN_K* globals. Called once, before the checks, so that
  # every check below judges the same kernel. kernel_installed() prints its own
  # diagnosis on stderr; it is silenced here because the verdict format is
  # where this step says what is wrong.
  # Args: $1 = target root.
  local root="$1" record
  _FIN_KVERSION=""
  _FIN_KIMAGE=""
  _FIN_KINITRD=""
  record="$(kernel_installed "$root" 2>/dev/null)" || return 1
  IFS=$'\t' read -r _FIN_KVERSION _FIN_KIMAGE _FIN_KINITRD <<<"$record"
  [[ -n "$_FIN_KIMAGE" ]]
}

# --------------------------------------------------------------------------- #
#  1 — a kernel, and not an empty file where one should be                    #
# --------------------------------------------------------------------------- #
_fin_check_kernel() {
  local root="$1" kib

  if [[ -z "$_FIN_KIMAGE" ]]; then
    _fin_verdict FAIL kernel "Kernel image" "nothing bootable under ${root}/boot"
    _fin_note "Step 80 wrote a boot entry for a file that is not there, or step"
    _fin_note "70 never produced one. Either way the firmware will find a loader"
    _fin_note "pointing at nothing, which looks like a dead machine."
    _fin_fix "ls -l ${root}/boot"
    _fin_fix "./gentoo-install.sh --steps 70,80"
    return 0
  fi

  kib="$(_fin_size_kib "${root}${_FIN_KIMAGE}")"

  if ((kib == 0)); then
    _fin_verdict FAIL kernel "Kernel image" "${_FIN_KIMAGE} is empty"
    _fin_note "The file exists and holds nothing. A build killed by the OOM"
    _fin_note "killer, or a /boot that filled up mid-copy, leaves exactly this."
    _fin_fix "df -h ${root}/boot"
    _fin_fix "./gentoo-install.sh --steps 70"
    return 0
  fi

  if ((kib < _FIN_MIN_KERNEL_KIB)); then
    _fin_verdict FAIL kernel "Kernel image" "${_FIN_KIMAGE}, ${kib} KiB, minimum ${_FIN_MIN_KERNEL_KIB}"
    _fin_note "Too small to be a kernel. A truncated copy weighs this much, and"
    _fin_note "the firmware will load it and stop with no message worth reading."
    _fin_fix "file ${root}${_FIN_KIMAGE}"
    _fin_fix "./gentoo-install.sh --steps 70"
    return 0
  fi

  _fin_verdict PASS kernel "Kernel image" "${_FIN_KIMAGE}, $((kib / 1024)) MiB"
  _fin_note "version ${_FIN_KVERSION}, built by the $(_fin_fact kernel kernel.variant "dist-kernel") variant"
  return 0
}

# --------------------------------------------------------------------------- #
#  Reading an initramfs                                                       #
# --------------------------------------------------------------------------- #
# Three ways, in falling order of authority. lsinitrd is dracut asking dracut,
# and it is the only one that returns module names. Failing that the cpio
# archive is listed and the modules are inferred from what is in it — the
# absence of a cryptsetup binary is proof that the image cannot open a LUKS
# container, whatever any configuration file claims.
_fin_magic() {
  # Args: $1 = file, $2 = byte offset. Six bytes as lowercase hex, no spaces.
  od -An -N6 -j "${2:-0}" -tx1 -- "$1" 2>/dev/null | tr -d ' \n'
}

_fin_segment_list() {
  # The cpio file list of the archive that starts at an offset, one path per
  # line. Args: $1 = image, $2 = offset (default 0).
  local img="$1" off="${2:-0}" magic
  local -a filter=()

  have cpio || return 1
  magic="$(_fin_magic "$img" "$off")"

  case "$magic" in
    1f8b*) filter=(gzip -dc) ;;
    fd377a585a*) filter=(xz -dc) ;;
    28b52ffd*) filter=(zstd -dcq) ;;
    04226d18*) filter=(lz4 -dc) ;;
    894c5a4f*) filter=(lzop -dc) ;;
    425a68*) filter=(bzip2 -dc) ;;
    3037303730*) filter=(cat) ;; # "07070" — an uncompressed cpio archive
    *) return 1 ;;
  esac

  have "${filter[0]}" || return 1

  # cpio complains about the padding after TRAILER!!! and about a second
  # archive concatenated behind the first; the list it printed before saying so
  # is still the list. `|| true` keeps that, and the caller judges emptiness.
  tail -c "+$((off + 1))" -- "$img" 2>/dev/null \
    | "${filter[@]}" 2>/dev/null \
    | cpio -t --quiet 2>/dev/null || true
}

# What an early microcode archive holds, and nothing else. Used twice: to
# recognise that the first archive was the early one, and to reject a candidate
# offset that led back into it.
readonly _FIN_EARLY_ONLY='^(\./)?(\.|early_cpio|kernel(/.*)?)$'

_fin_second_segment_offsets() {
  # Where the compressed image may begin behind the early microcode archive,
  # in file order, at most _FIN_OFFSET_CANDIDATES of them. Args: $1 = image.
  #
  # Not simply "the first compression magic in the file". A real 80 MB image on
  # this machine carries a spurious gzip magic 22 MB into the AMD microcode
  # blob and its actual zstd segment at 36 MB, so the first hit decompresses to
  # nothing and the check reports an unreadable image. The early archive's own
  # TRAILER!!! is the floor: 110 bytes of newc header, an eleven-byte name,
  # padded to four. Every candidate is still verified by listing it, because
  # TRAILER!!! can appear in a blob too.
  local img="$1" trailer="" after=0

  trailer="$(LC_ALL=C grep -aboFm1 -e 'TRAILER!!!' -- "$img" 2>/dev/null | head -n 1)" || true
  if [[ -n "$trailer" ]]; then
    trailer="${trailer%%:*}"
    after=$(((trailer + 11 + 3) / 4 * 4))
  fi

  LC_ALL=C grep -aboF \
    -e $'\x1f\x8b\x08' -e $'\xfd7zXZ' -e $'\x28\xb5\x2f\xfd' -e $'\x04\x22\x4d\x18' \
    -- "$img" 2>/dev/null \
    | awk -F: -v a="$after" -v n="$_FIN_OFFSET_CANDIDATES" \
      '$1 >= a { print $1; if (++seen >= n) { exit } }' || true
}

_fin_initrd_contents() {
  # The file list of the image proper. Args: $1 = image.
  local img="$1" list="" candidate offset

  list="$(_fin_segment_list "$img" 0)" || list=""

  # Only microcode and the marker came back: that was the early archive, not
  # the image. Its first entry is a bare directory name rather than a path, so
  # a pattern anchored on "kernel/" alone would miss it and the real image
  # would never be looked for.
  if [[ -n "$list" ]] && ! grep -qvE "$_FIN_EARLY_ONLY" <<<"$list"; then
    while IFS= read -r offset; do
      [[ -n "$offset" ]] || continue
      candidate="$(_fin_segment_list "$img" "$offset")" || candidate=""
      if [[ -n "$candidate" ]] && grep -qvE "$_FIN_EARLY_ONLY" <<<"$candidate"; then
        list="$candidate"
        break
      fi
    done < <(_fin_second_segment_offsets "$img")
  fi

  [[ -n "$list" ]] || return 1
  # Still nothing but microcode: the image proper was never reached, and
  # reporting its file list would be reporting the wrong archive.
  grep -qvE "$_FIN_EARLY_ONLY" <<<"$list" || return 1
  printf '%s\n' "$list"
}

_fin_module_evidence() {
  # Is the one file that only this module puts in an image there?
  # Args: $1 = module name, $2 = the file list. Returns 2 when this function
  # has no opinion, which a caller must not read as "missing".
  local name="$1" list="$2"
  case "$name" in
    crypt) grep -qE '(^|/)cryptsetup$' <<<"$list" ;;
    dm) grep -qE '(^|/)dmsetup$' <<<"$list" ;;
    lvm) grep -qE '(^|/)lvm$' <<<"$list" ;;
    clevis) grep -qE '(^|/)clevis(-[a-z0-9-]+)*$' <<<"$list" ;;
    clevis-pin-tpm2) grep -qE 'clevis-(decrypt|encrypt)-tpm2$' <<<"$list" ;;
    crypt-gpg) grep -qE '(^|/)gpg$|crypt-gpg' <<<"$list" ;;
    *) return 2 ;;
  esac
}

_fin_lsinitrd() {
  # lsinitrd's module list, one name per line, and nothing else.
  # Args: $1 = chroot root ("" to run here), $2.. = the argv.
  #
  # Two details, and both have teeth. lsinitrd wraps the list in a banner —
  # "Image: <path>: 6.1M", a rule of equals signs, "Version:" — so without the
  # filter those words become module names. And on an image it cannot open it
  # prints that same banner with an empty list and exits 4, which is how "this
  # file is not an initramfs" turns into "every module is missing" and a FAIL
  # that names five packages the operator does not need.
  local root="$1"
  shift
  local out
  if [[ -n "$root" ]]; then
    out="$(chroot "$root" "$@" 2>/dev/null)" || return 1
  else
    out="$("$@" 2>/dev/null)" || return 1
  fi
  printf '%s\n' "$out" | grep -E '^[a-z0-9][a-z0-9._+-]*$' || return 1
}

_fin_read_initrd() {
  # Fills _FIN_INITRD_METHOD and _FIN_INITRD_PAYLOAD. Returns 1 when the image
  # could not be read at all.
  # Args: $1 = image as this run sees it, $2 = target root,
  #       $3 = image as the target sees it.
  #
  # It fills globals instead of printing, and that is not a style choice.
  # `payload="$(_fin_read_initrd ...)"` runs the function in a subshell, and
  # the method it recorded — the one thing that says whether the payload is a
  # list of module names or a list of file paths — dies with that subshell,
  # leaving the caller to grep module names for a cryptsetup binary and
  # conclude that a perfectly good image is missing crypt. lib/core.sh
  # documents the same trap for its file writers and lib/crypt.sh for
  # CRYPT_RECORD; this is the third place it bites.
  local img="$1" root="$2" rel="$3" out=""

  _FIN_INITRD_METHOD="none"
  _FIN_INITRD_PAYLOAD=""

  if have lsinitrd; then
    if out="$(_fin_lsinitrd "" lsinitrd "$img" --mod)" && [[ -n "$out" ]]; then
      _FIN_INITRD_METHOD="lsinitrd"
      _FIN_INITRD_PAYLOAD="$out"
      return 0
    fi
  fi

  # The target has dracut installed — it is what built this image — and the
  # chroot is still mounted at this point in the run, so its own lsinitrd is
  # available even when the live medium carries none.
  if [[ "$root" != "/" && -n "$rel" && "$DRY_RUN" != "yes" ]] \
    && [[ -x "${root}/usr/bin/lsinitrd" || -x "${root}/bin/lsinitrd" ]]; then
    if out="$(_fin_lsinitrd "$root" lsinitrd "$rel" --mod)" && [[ -n "$out" ]]; then
      _FIN_INITRD_METHOD="lsinitrd"
      _FIN_INITRD_PAYLOAD="$out"
      return 0
    fi
  fi

  if out="$(_fin_initrd_contents "$img")" && [[ -n "$out" ]]; then
    _FIN_INITRD_METHOD="contents"
    _FIN_INITRD_PAYLOAD="$out"
    return 0
  fi

  return 1
}

# --------------------------------------------------------------------------- #
#  2 — the initramfs, and whether it can open the container                   #
# --------------------------------------------------------------------------- #
_fin_check_initramfs() {
  local root="$1" crypt kib module verdict
  local -a wanted=() present=() missing=() unknown=()

  crypt="$(_fin_crypt)"
  mapfile -t wanted < <(_fin_wanted_modules)

  if [[ -z "$_FIN_KINITRD" ]]; then
    if ((${#wanted[@]} == 0)); then
      _fin_verdict WARN initramfs "Initramfs" "none, and none is strictly needed"
      _fin_note "An unencrypted root on a plain partition can boot without one,"
      _fin_note "provided the kernel has its disk and filesystem drivers built in"
      _fin_note "rather than as modules. A dist-kernel does not."
      _fin_fix "chroot ${root} dracut --force --kver ${_FIN_KVERSION}"
      return 0
    fi
    _fin_verdict FAIL initramfs "Initramfs" "none, and crypt=${crypt} needs one"
    _fin_note "There is no initramfs for ${_FIN_KVERSION}, and the root of this"
    _fin_note "machine is behind ${wanted[*]}. The kernel will start, fail to"
    _fin_note "find a root filesystem, and panic."
    _fin_fix "chroot ${root} dracut --force --kver ${_FIN_KVERSION}"
    _fin_fix "./gentoo-install.sh --steps 70,80"
    return 0
  fi

  kib="$(_fin_size_kib "${root}${_FIN_KINITRD}")"
  if ((kib < _FIN_MIN_INITRD_KIB)); then
    _fin_verdict FAIL initramfs "Initramfs" "${_FIN_KINITRD}, ${kib} KiB, minimum ${_FIN_MIN_INITRD_KIB}"
    _fin_note "Too small to hold a shell, let alone cryptsetup. A dracut run that"
    _fin_note "ran out of space in /boot leaves a truncated image behind it."
    _fin_fix "df -h ${root}/boot"
    _fin_fix "chroot ${root} dracut --force --kver ${_FIN_KVERSION}"
    return 0
  fi

  if ((${#wanted[@]} == 0)); then
    _fin_verdict PASS initramfs "Initramfs" "${_FIN_KINITRD}, $((kib / 1024)) MiB"
    _fin_note "crypt=none on a plain layout, so no module is required to reach"
    _fin_note "the root filesystem."
    return 0
  fi

  if ! _fin_read_initrd "${root}${_FIN_KINITRD}" "$root" "$_FIN_KINITRD" \
    || [[ -z "$_FIN_INITRD_PAYLOAD" ]]; then
    _fin_verdict WARN initramfs "Initramfs" "${_FIN_KINITRD}, contents unreadable"
    _fin_note "Neither lsinitrd nor the cpio archive could be read here, so"
    _fin_note "whether ${wanted[*]} made it in is unproven — not proven wrong."
    _fin_note "This is the one check worth repeating by hand before rebooting:"
    _fin_fix "lsinitrd ${root}${_FIN_KINITRD} --mod"
    _fin_fix "chroot ${root} lsinitrd ${_FIN_KINITRD} --mod"
    return 0
  fi

  mapfile -t present <<<"$_FIN_INITRD_PAYLOAD"

  for module in "${wanted[@]}"; do
    if [[ "$_FIN_INITRD_METHOD" == "lsinitrd" ]]; then
      if ! printf '%s\n' "${present[@]}" | grep -qxF -- "$module"; then
        missing+=("$module")
      fi
      continue
    fi
    verdict=0
    _fin_module_evidence "$module" "$_FIN_INITRD_PAYLOAD" || verdict=$?
    case "$verdict" in
      0) ;;
      1) missing+=("$module") ;;
      *) unknown+=("$module") ;;
    esac
  done

  if ((${#missing[@]} > 0)); then
    _fin_verdict FAIL initramfs "Initramfs" "${#missing[@]} of ${#wanted[@]} module(s) missing"
    _fin_note "Read with ${_FIN_INITRD_METHOD} from ${_FIN_KINITRD}."
    for module in "${missing[@]}"; do
      _fin_note "$(printf '%-18s %s' "$module" "$(_fin_module_package "$module")")"
    done
    _fin_note "This machine's root is behind ${crypt}. An initramfs without these"
    _fin_note "cannot open the container: the boot stops at a dracut prompt with"
    _fin_note "no root, and the message names none of the missing pieces. Fixing"
    _fin_note "it afterwards means booting a LiveUSB and chrooting back in."
    _fin_fix "chroot ${root} emerge --noreplace sys-kernel/dracut"
    _fin_fix "chroot ${root} dracut --force --add '${wanted[*]}' --kver ${_FIN_KVERSION}"
    _fin_fix "lsinitrd ${root}${_FIN_KINITRD} --mod"
    return 0
  fi

  if ((${#unknown[@]} > 0)); then
    _fin_verdict WARN initramfs "Initramfs" "${#unknown[@]} module(s) not verifiable"
    _fin_note "The image was read by ${_FIN_INITRD_METHOD}, which recognises a"
    _fin_note "module by a file only that module ships. These have no such file"
    _fin_note "known to gentoo-install: ${unknown[*]}"
    _fin_fix "lsinitrd ${root}${_FIN_KINITRD} --mod"
    return 0
  fi

  _fin_verdict PASS initramfs "Initramfs" "${_FIN_KINITRD}, ${wanted[*]}"
  _fin_note "Read with ${_FIN_INITRD_METHOD}: every module this machine needs to"
  _fin_note "reach its root is in the image, not merely in the configuration."
  return 0
}

# --------------------------------------------------------------------------- #
#  3 — something the firmware will actually pick up                           #
# --------------------------------------------------------------------------- #
_fin_find_efi() {
  # Args: $1 = ESP directory, $2 = case-insensitive name pattern.
  # The first match, or nothing. A returned value.
  local esp="$1" pattern="$2"
  [[ -d "$esp" ]] || return 1
  find "$esp" -maxdepth "$_FIN_ESP_SCAN_DEPTH" -type f -iname "$pattern" \
    -print -quit 2>/dev/null | grep . || return 1
}

_fin_nvram_entry() {
  # Is there an NVRAM boot entry carrying this label? Args: $1 = label.
  # Only ever asked on a machine that booted UEFI: efibootmgr on a BIOS boot
  # answers about nothing, and a warning drawn from that is noise.
  local label="$1"
  [[ -d /sys/firmware/efi ]] || return 1
  have efibootmgr || return 1
  efibootmgr 2>/dev/null | grep -qiF -- "$label"
}

_fin_mentions_kernel() {
  # Args: $1 = version, $2.. = configuration files. True when at least one of
  # them names the kernel that check 1 found.
  local version="$1" file
  shift
  for file in "$@"; do
    [[ -f "$file" ]] || continue
    if grep -qF -- "$version" "$file" 2>/dev/null; then
      return 0
    fi
  done
  return 1
}

_fin_efi_spelling() {
  # A path on the ESP as the firmware spells it: leading backslash, backslash
  # separators. Args: $1 = the path relative to the root of the ESP.
  local path="/${1#/}"
  printf '%s\n' "${path//\//\\}"
}

_fin_check_bootentry() {
  local root="$1" variant firmware esp label
  local primary="" fallback="" nvram="no" rel=""
  local -a configs=()

  variant="$(_fin_fact bootloader boot.variant "grub")"
  firmware="$(_fin_fact firmware boot.firmware "$(_fin_firmware)")"
  label="$(_fin_fact boot_label boot.label "gentoo")"
  esp="$(_fin_esp_dir "$root")"

  case "$variant" in
    grub)
      configs=("${root}/boot/grub/grub.cfg")
      if [[ ! -f "${configs[0]}" ]]; then
        _fin_verdict FAIL bootentry "Boot entry" "no ${root}/boot/grub/grub.cfg"
        _fin_note "GRUB was recorded as the bootloader and its configuration is"
        _fin_note "not there, so it would drop to a rescue prompt at power-on."
        _fin_fix "chroot ${root} grub-mkconfig -o /boot/grub/grub.cfg"
        _fin_fix "./gentoo-install.sh --steps 80"
        return 0
      fi
      if [[ "$firmware" == "uefi" ]]; then
        primary="$(_fin_find_efi "$esp" 'grub*.efi' || true)"
        if [[ -z "$primary" ]]; then
          _fin_verdict FAIL bootentry "Boot entry" "no GRUB EFI binary on ${esp}"
          _fin_note "The configuration is there but the loader it configures is"
          _fin_note "not on the EFI system partition. If ${esp} was an empty"
          _fin_note "directory when step 80 ran, the install went into the root"
          _fin_note "filesystem, where no firmware will ever look for it."
          _fin_fix "findmnt ${esp}"
          _fin_fix "chroot ${root} grub-install --target=x86_64-efi --efi-directory=$(_fin_esp_mount) --bootloader-id=${label}"
          return 0
        fi
      else
        primary="${root}/boot/grub/i386-pc/core.img"
        if [[ ! -f "$primary" ]]; then
          _fin_verdict FAIL bootentry "Boot entry" "no BIOS core.img under ${root}/boot/grub"
          _fin_note "A legacy BIOS install needs GRUB's i386-pc image, and the"
          _fin_note "boot sector that chain-loads it, on $(_fin_fact disk disk.device '<the disk>')."
          _fin_fix "chroot ${root} grub-install --target=i386-pc $(_fin_fact disk disk.device '/dev/sdX')"
          return 0
        fi
      fi
      ;;
    systemd-boot)
      primary="$(_fin_find_efi "$esp" 'systemd-boot*.efi' || true)"
      fallback="$(_fin_find_efi "$esp" 'boot*.efi' || true)"
      if [[ -z "$primary" && -z "$fallback" ]]; then
        _fin_verdict FAIL bootentry "Boot entry" "no systemd-boot binary on ${esp}"
        _fin_note "Neither EFI/systemd/systemd-bootx64.efi nor the removable"
        _fin_note "fallback EFI/BOOT/BOOTX64.EFI is on the EFI system partition."
        _fin_fix "findmnt ${esp}"
        _fin_fix "chroot ${root} bootctl --esp-path=$(_fin_esp_mount) install"
        return 0
      fi
      mapfile -t configs < <(find "${esp}/loader/entries" -maxdepth 1 -name '*.conf' \
        -type f 2>/dev/null || true)
      if ((${#configs[@]} == 0)); then
        _fin_verdict FAIL bootentry "Boot entry" "no loader entry under ${esp}/loader/entries"
        _fin_note "The loader is installed and has nothing to offer: systemd-boot"
        _fin_note "with no entry shows an empty menu and stops there."
        _fin_fix "ls ${esp}/loader/entries"
        _fin_fix "./gentoo-install.sh --steps 80"
        return 0
      fi
      ;;
    efistub)
      primary="$(_fin_find_efi "$esp" '*.efi' || true)"
      if [[ -z "$primary" ]]; then
        _fin_verdict FAIL bootentry "Boot entry" "no EFI image on ${esp}"
        _fin_note "With no bootloader at all, the kernel itself is the EFI binary"
        _fin_note "and it has to be on the EFI system partition. There is none."
        _fin_fix "findmnt ${esp}"
        _fin_fix "./gentoo-install.sh --steps 80"
        return 0
      fi
      ;;
    *)
      _fin_verdict SKIP bootentry "Boot entry" "unknown bootloader '${variant}'"
      _fin_note "The journal names a bootloader this step does not know how to"
      _fin_note "verify, so nothing is claimed about it either way."
      _fin_fix "ls -R ${esp}"
      return 0
      ;;
  esac

  if _fin_nvram_entry "$label"; then
    nvram="yes"
  fi

  # An NVRAM entry lives in the firmware of the machine running this check, not
  # on the disk being checked. When the target is some other disk, that entry
  # says nothing about whether the target can boot — and counting it as proof is
  # exactly how a run reported a healthy "Boot entry" for an image whose ESP
  # held no loader any firmware would look for. The image then dropped straight
  # to PXE on its first power-on.
  if [[ "$nvram" == "yes" ]] \
    && ! disk_may_write_firmware_state "$(_fin_fact disk disk.device "")"; then
    nvram="no"
  fi

  # An efistub install has no configuration file: the NVRAM entry carries the
  # command line, and without it the firmware has nothing to start.
  if [[ "$variant" == "efistub" && "$firmware" == "uefi" && "$nvram" == "no" ]]; then
    if [[ -z "$(_fin_find_efi "$esp" 'boot*.efi' || true)" ]]; then
      rel="${primary#"$root"}"
      _fin_verdict FAIL bootentry "Boot entry" "${rel} on the ESP, no NVRAM entry"
      _fin_note "The kernel is on the ESP and nothing points the firmware at it."
      _fin_note "There is no removable fallback either, so this machine will boot"
      _fin_note "into the firmware menu and stay there."
      _fin_fix "efibootmgr --create --disk $(_fin_fact disk disk.device '/dev/sdX') --part 1 --label '${label}' --loader $(_fin_efi_spelling "${primary#"$esp"}")"
      return 0
    fi
  fi

  if ((${#configs[@]} > 0)) && [[ -n "$_FIN_KVERSION" ]] \
    && ! _fin_mentions_kernel "$_FIN_KVERSION" "${configs[@]}"; then
    _fin_verdict WARN bootentry "Boot entry" "${variant}, but it names another kernel"
    _fin_note "The installed kernel is ${_FIN_KVERSION} and no boot entry mentions"
    _fin_note "it. An entry left over from an earlier run points at an image that"
    _fin_note "may no longer be there."
    _fin_fix "grep -n vmlinuz ${configs[0]}"
    _fin_fix "./gentoo-install.sh --steps 80"
    return 0
  fi

  if [[ "$firmware" == "uefi" && "$nvram" == "no" ]] \
    && [[ -z "$(_fin_find_efi "$esp" 'bootx64.efi' || true)" ]]; then
    _fin_verdict FAIL bootentry "Boot entry" "${variant} installed, no NVRAM entry and no removable fallback"
    _fin_note "Nothing on this disk tells a firmware where to start, and there is"
    _fin_note "no EFI/BOOT/BOOTX64.EFI for it to fall back to. The machine will"
    _fin_note "reach its own boot menu and stop there."
    _fin_fix "./gentoo-install.sh --steps 80 --boot-removable yes"
    return 0
  fi

  if [[ "$firmware" == "uefi" && "$nvram" == "no" ]]; then
    _fin_verdict WARN bootentry "Boot entry" "${variant} installed, not in NVRAM"
    _fin_note "The files are on the EFI system partition and the firmware has no"
    _fin_note "entry for them. Many machines still find the removable fallback"
    _fin_note "EFI/BOOT/BOOTX64.EFI; a machine that does not will boot to its own"
    _fin_note "menu. efivarfs has to be mounted for the entry to be written."
    _fin_fix "mount -t efivarfs efivarfs /sys/firmware/efi/efivars"
    _fin_fix "efibootmgr -v"
    return 0
  fi

  _fin_verdict PASS bootentry "Boot entry" "${variant} on ${firmware}, label ${label}"
  rel="${primary#"$root"}"
  _fin_note "loader ${rel}"
  if ((${#configs[@]} > 0)); then
    _fin_note "entry  ${configs[0]#"$root"}"
  fi
  return 0
}

# --------------------------------------------------------------------------- #
#  4 — fstab against the partitions that exist                                #
# --------------------------------------------------------------------------- #
_fin_fstab_rows() {
  # "spec<TAB>target<TAB>type" for every real row. A returned value.
  awk '
    { sub(/#.*/, "") }
    NF >= 3 { printf "%s\t%s\t%s\n", $1, $2, $3 }
  ' "$1"
}

_fin_uuid_exists() {
  # Three ways to ask, because the install medium may carry any of them.
  local uuid="$1"
  if [[ -e "/dev/disk/by-uuid/${uuid}" ]]; then
    return 0
  fi
  if have blkid && blkid -U "$uuid" >/dev/null 2>&1; then
    return 0
  fi
  if have findfs && findfs "UUID=${uuid}" >/dev/null 2>&1; then
    return 0
  fi
  return 1
}

_fin_check_fstab() {
  local root="$1"
  local fstab="${root}/etc/fstab"
  local spec target fstype uuid live rel row_count=0 has_root="no"
  local -a dangling=() unlisted=()

  if [[ ! -f "$fstab" ]]; then
    _fin_verdict FAIL fstab "fstab" "no ${fstab}"
    _fin_note "Without it the installed system mounts nothing but the root the"
    _fin_note "kernel command line names — no /boot, no ESP, no separate /home."
    _fin_fix "./gentoo-install.sh --steps 90"
    return 0
  fi

  while IFS=$'\t' read -r spec target fstype; do
    [[ -n "$spec" ]] || continue
    row_count=$((row_count + 1))
    if [[ "$target" == "/" ]]; then
      has_root="yes"
    fi
    case "$spec" in
      UUID=*)
        uuid="${spec#UUID=}"
        uuid="${uuid%\"}"
        uuid="${uuid#\"}"
        if ! _fin_uuid_exists "$uuid"; then
          dangling+=("${target} ${fstype} ${spec}")
        fi
        ;;
    esac
  done < <(_fin_fstab_rows "$fstab")

  if ((row_count == 0)); then
    _fin_verdict FAIL fstab "fstab" "${fstab} has no entries"
    _fin_note "The file is there and describes nothing, which is the same"
    _fin_note "machine as no file at all."
    _fin_fix "./gentoo-install.sh --steps 90"
    return 0
  fi

  if [[ "$has_root" == "no" ]]; then
    _fin_verdict FAIL fstab "fstab" "${row_count} entries, none for /"
    _fin_note "Nothing describes the root filesystem, so it stays mounted with"
    _fin_note "whatever options the initramfs used — read-only, in practice."
    _fin_fix "./gentoo-install.sh --steps 90"
    return 0
  fi

  # The other direction: a filesystem mounted here and absent from the file is
  # a filesystem the installed system will not mount. An ESP missing from fstab
  # is the expensive one — the machine boots, and the next kernel update writes
  # into an empty directory on the root filesystem instead.
  if have findmnt; then
    # SOURCE comes along so that pseudo-filesystems can be told apart from
    # the machine's own. Step 50 binds /proc, /sys, /dev and /run into the
    # target to make the chroot work; none of them are mounted from fstab at
    # boot, and counting them as missing turned a correct fstab into a
    # blocking failure naming fifteen filesystems no fstab should ever list.
    while IFS=' ' read -r live source; do
      [[ -n "$live" ]] || continue
      [[ -b "$source" ]] || continue
      live="${live//\\x20/ }"
      if [[ "$live" == "$root" ]]; then
        rel="/"
      else
        rel="${live#"$root"}"
      fi
      [[ "${rel:0:1}" == "/" ]] || continue
      if ! awk -F'\t' -v m="$rel" '$2 == m { found = 1 } END { exit !found }' \
        < <(_fin_fstab_rows "$fstab"); then
        unlisted+=("$rel")
      fi
    done < <(findmnt --real -nr -o TARGET,SOURCE -R -- "$root" 2>/dev/null || true)
  fi

  if ((${#dangling[@]} > 0)); then
    _fin_verdict FAIL fstab "fstab" "${#dangling[@]} of ${row_count} entries name a UUID that does not exist"
    for spec in "${dangling[@]}"; do
      _fin_note "$spec"
    done
    _fin_note "The installed system stops in the initramfs waiting for a device"
    _fin_note "that will never appear, and the wait is ninety seconds per entry"
    _fin_note "before it drops to a shell. Nothing about the message names fstab."
    _fin_fix "blkid -o list"
    _fin_fix "./gentoo-install.sh --steps 90   # regenerates it from what is mounted"
    return 0
  fi

  if ((${#unlisted[@]} > 0)); then
    _fin_verdict FAIL fstab "fstab" "${#unlisted[@]} mounted filesystem(s) absent from the file"
    for spec in "${unlisted[@]}"; do
      _fin_note "${spec} is mounted now and nothing in fstab mounts it at boot"
    done
    _fin_note "Whatever step 20 put there stays there and is never reached, and"
    _fin_note "for the ESP that means the next kernel is written into a directory"
    _fin_note "the firmware does not read."
    _fin_fix "findmnt -R ${root}"
    _fin_fix "./gentoo-install.sh --steps 90"
    return 0
  fi

  _fin_verdict PASS fstab "fstab" "${row_count} entries, every UUID resolves"
  if ! have findmnt; then
    _fin_note "findmnt is absent, so the reverse half — is anything mounted that"
    _fin_note "the file does not describe — was not asked."
  fi
  return 0
}

# --------------------------------------------------------------------------- #
#  5 — a way in, once it has booted                                           #
# --------------------------------------------------------------------------- #
_fin_password_accounts() {
  # Accounts with a usable password hash, one name per line. A returned value.
  # Locked (!), disabled (*) and empty fields are not ways in.
  local file="$1"
  [[ -r "$file" ]] || return 1
  awk -F: '$2 ~ /^\$/ { print $1 }' "$file"
}

_fin_authorized_keys() {
  # Every authorized_keys in the tree that holds at least one key, as the
  # installed system will see it. A returned value.
  local root="$1" file
  while IFS= read -r file; do
    [[ -f "$file" ]] || continue
    if grep -qE '^[[:space:]]*(ssh-|ecdsa-|sk-|ssh_)' "$file" 2>/dev/null; then
      printf '%s\n' "${file#"$root"}"
    fi
  done < <(find "${root}/root" "${root}/home" -maxdepth 3 -name authorized_keys \
    -type f 2>/dev/null || true)
}

_fin_check_access() {
  local root="$1"
  local shadow="${root}/etc/shadow"
  local privilege sshd others
  local -a accounts=() keys=()

  privilege="$(_fin_fact privilege system.privilege "")"
  sshd="$(_fin_fact sshd system.sshd "")"

  mapfile -t keys < <(_fin_authorized_keys "$root")

  if [[ ! -r "$shadow" ]]; then
    _fin_verdict SKIP access "A way in" "${shadow} is not readable"
    _fin_note "Only root reads a shadow file, so this check has no answer here."
    _fin_note "It is the one check whose failure is invisible until the machine"
    _fin_note "has booted and refused every password, so it is worth rerunning."
    _fin_fix "sudo ./gentoo-install.sh --steps 95"
    return 0
  fi

  mapfile -t accounts < <(_fin_password_accounts "$shadow")

  if ((${#accounts[@]} == 0)); then
    if ((${#keys[@]} > 0)) && [[ "$sshd" == "enabled" ]]; then
      _fin_verdict WARN access "A way in" "no password anywhere, ssh key only"
      _fin_note "The only way into this machine is ${keys[0]} over ssh. If the"
      _fin_note "network does not come up, or sshd fails to start, there is no"
      _fin_note "console login to fall back on."
      _fin_fix "chroot ${root} /bin/bash -lc 'passwd root'"
      return 0
    fi
    _fin_verdict FAIL access "A way in" "no password set and no usable ssh key"
    _fin_note "Every account in ${shadow} is locked and there is no"
    _fin_note "authorized_keys with a key in it. This machine will boot, ask for"
    _fin_note "the LUKS passphrase, present a login prompt, and refuse every"
    _fin_note "answer. Recovering from that means a LiveUSB and a chroot."
    _fin_fix "chroot ${root} /bin/bash -lc 'passwd root'"
    _fin_fix "./gentoo-install.sh --steps 90"
    return 0
  fi

  if printf '%s\n' "${accounts[@]}" | grep -qx 'root'; then
    _fin_verdict PASS access "A way in" "root has a password"
    others="$(printf '%s\n' "${accounts[@]}" | grep -vx 'root' | tr '\n' ' ' || true)"
    if [[ -n "${others// /}" ]]; then
      _fin_note "and so do: ${others}"
    fi
    if ((${#keys[@]} > 0)); then
      _fin_note "ssh key(s) installed: ${keys[*]}"
    fi
    return 0
  fi

  if [[ "$privilege" == "sudo" || "$privilege" == "doas" ]]; then
    _fin_verdict PASS access "A way in" "${accounts[*]} + ${privilege}"
    _fin_note "root itself is locked, which is the safer arrangement: the"
    _fin_note "account above logs in and becomes root through ${privilege}."
    return 0
  fi

  _fin_verdict WARN access "A way in" "${accounts[*]} can log in, root cannot"
  _fin_note "No privilege tool was configured (privilege=${privilege:-none}), so"
  _fin_note "the account above logs in and has no way to become root. Everything"
  _fin_note "that needs root then needs a LiveUSB."
  _fin_fix "chroot ${root} /bin/bash -lc 'passwd root'"
  _fin_fix "./gentoo-install.sh --steps 90   # privilege = sudo"
  return 0
}

# --------------------------------------------------------------------------- #
#  The recap                                                                  #
# --------------------------------------------------------------------------- #
_fin_recap_installed() {
  local root="$1" layout line

  log "what is on ${root}"
  _fin_item "stage" "$(_fin_recorded stage.variant)"
  _fin_item "verified" "$(_fin_recorded stage.verified)"
  _fin_item "disk" "$(_fin_fact disk disk.device "")"

  layout="$(_fin_recorded disk.layout)"
  if [[ -n "$layout" ]]; then
    line="${layout}, $(_fin_recorded disk.filesystem "unknown fs")"
    if _fin_uses_lvm; then
      line="${line}, LVM group $(_fin_recorded disk.vg)"
    fi
    _fin_item "layout" "$line"
  fi

  line="$(_fin_crypt)"
  layout="$(_fin_recorded crypt.device)"
  if [[ -n "$layout" ]]; then
    line="${line} on ${layout}"
  fi
  _fin_item "encryption" "$line"

  _fin_item "kernel" "${_FIN_KVERSION:-none} ($(_fin_fact kernel kernel.variant "dist-kernel"))"
  _fin_item "initramfs" "${_FIN_KINITRD:-none}"
  _fin_item "bootloader" "$(_fin_fact bootloader boot.variant "")"
  _fin_item "hostname" "$(_fin_fact hostname system.hostname "")"
  _fin_item "timezone" "$(_fin_fact timezone system.timezone "")"
  _fin_item "locale" "$(_fin_fact locale system.locale "")"
  _fin_item "network" "$(_fin_fact network system.network "")"
  _fin_item "user" "$(_fin_fact user system.user "")"
  _fin_item "sshd" "$(_fin_recorded system.sshd)"
}

_fin_recap_todo() {
  # Everything the steps could not finish, as they recorded it. Step 90 warns
  # about each one as it happens, hours before this screen; a --resume run
  # never saw those warnings at all, and the journal is what carries them.
  local line count=0
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    if ((count == 0)); then
      warn "left to do by hand:"
    fi
    count=$((count + 1))
    _fin_note "$(printf '%2d. %s' "$count" "${line#*=}")"
  done < <(state_dump 2>/dev/null | grep '^system\.todo\.[0-9]' || true)

  if ((count == 0)); then
    ok "nothing was left half-done: no step recorded a manual follow-up"
  fi
}

_fin_recap_secrets() {
  # The one screen an operator must not scroll past. A passphrase that was
  # typed once, an hour ago, and never written down is a machine that is lost
  # at the next power-on — there is no recovery path for a LUKS container.
  local crypt slots dir name
  crypt="$(_fin_crypt)"

  if [[ "$crypt" == "none" ]]; then
    warn "this disk is not encrypted: whoever holds it reads it"
    return 0
  fi

  warn "before you reboot, write these down somewhere that is not this machine:"
  _fin_note "the LUKS passphrase for $(_fin_recorded crypt.device "the container")."
  _fin_note "Nothing recovers it — not this installer, not Gentoo, not the TPM."

  slots="$(_fin_recorded crypt.slots)"
  if [[ -n "$slots" ]]; then
    _fin_note "keyslots in use: ${slots}"
  fi

  case "$crypt" in
    tpm)
      _fin_note "The TPM unseals the key at boot, so you will not be asked for a"
      _fin_note "passphrase and will not be reminded that one exists. A firmware"
      _fin_note "update changes PCR 0, the policy stops matching, and the"
      _fin_note "recovery passphrase is then the only way in."
      ;;
    keyfile)
      dir="$(cfg crypt_key_dir)"
      name="$(cfg crypt_key_name)"
      _fin_note "the GPG-wrapped key file lives at ${dir:-the ESP}/${name:-luks-key.gpg}"
      _fin_note "on an unencrypted partition. Copy it somewhere off this machine:"
      _fin_note "losing that partition loses the disk, and the passphrase that"
      _fin_note "unwraps it is a second secret worth writing down too."
      ;;
    passphrase)
      _fin_note "You will be asked for it at every boot, on a console that comes"
      _fin_note "up with the $(_fin_fact keymap system.keymap "us") keymap — type it there before"
      _fin_note "trusting that a non-ASCII character survives."
      ;;
    *) ;;
  esac
}

_fin_recap_next() {
  local root="$1" crypt
  crypt="$(_fin_crypt)"
  log "at the next power-on"
  case "$crypt" in
    none) _fin_note "the machine boots straight to a login prompt" ;;
    tpm) _fin_note "the TPM unseals the container; no passphrase is asked for" ;;
    keyfile) _fin_note "the initramfs reads the key file and unwraps it" ;;
    *) _fin_note "the initramfs asks for the LUKS passphrase before anything else" ;;
  esac
  _fin_note "remove the install medium first, or the firmware may boot it again"
  _fin_fix "emerge --sync && emerge --ask --update --deep --newuse @world"
  log "to go back in without rebooting the target:"
  _fin_fix "./gentoo-install.sh --steps 50   # then: chroot ${root} /bin/bash -l"
}

# --------------------------------------------------------------------------- #
#  The release                                                                #
# --------------------------------------------------------------------------- #
_fin_umount_root() {
  # Args: $1 = target root. Recursive, so the kernel releases the deepest
  # mount first, which is the reverse of the order they were made in.
  local root="$1"

  if [[ "$DRY_RUN" == "yes" ]]; then
    log "dry-run: would unmount ${root} recursively"
    return 0
  fi

  if ! mountpoint -q -- "$root" 2>/dev/null; then
    skip "${root} is not a mountpoint; there is nothing to unmount"
    return 0
  fi

  if run_quiet umount -R -- "$root"; then
    ok "unmounted ${root} and everything under it"
    return 0
  fi

  warn "${root} is busy; unmounting lazily"
  if run_quiet umount -Rl -- "$root"; then
    warn "       a lazy unmount detaches the tree and finishes when the last"
    warn "       user lets go; the reboot below completes it"
    return 0
  fi

  err "Could not unmount ${root}"
  err "       something still has a file open there, or a shell is sitting in it"
  err "       fuser -vm ${root}"
  err "       lsof +D ${root}"
  return 1
}

_fin_close_container() {
  # The last layer of the stack this install built: an open LUKS mapping on a
  # tree that is no longer mounted. Journal-driven, like everything else here —
  # a name this run did not record is a name this run did not open.
  local name
  name="$(_fin_fact crypt_name crypt.name "")"

  [[ "$(_fin_crypt)" != "none" ]] || return 0
  [[ -n "$name" ]] || return 0

  if [[ "$DRY_RUN" == "yes" ]]; then
    log "dry-run: would close /dev/mapper/${name}"
    return 0
  fi
  if [[ ! -e "/dev/mapper/${name}" ]]; then
    skip "/dev/mapper/${name} is already closed"
    return 0
  fi
  if ! have cryptsetup; then
    warn "cryptsetup is not installed here; /dev/mapper/${name} stays open"
    return 0
  fi
  if run_quiet cryptsetup close "$name"; then
    ok "closed /dev/mapper/${name}"
    return 0
  fi
  warn "could not close /dev/mapper/${name}; something still holds it"
  warn "       fuser -vm /dev/mapper/${name}"
  warn "       it does not stop a reboot: the container closes with the machine"
  return 0
}

_fin_release() {
  # Only what this install mounted, in the reverse of the order it was mounted
  # in. Two sources of ownership and no guessing: lib/chroot.sh knows what this
  # process mounted, and the disk plan step 20 wrote down knows what an earlier
  # process did. Nothing scans the system for things that look like ours.
  # Args: $1 = target root.
  local root="$1" failed=0 plan="" recorded=""
  local plan_file="${CFG[state_dir]:-${STATE_DIR}}/disk-plan.tsv"

  log "releasing what this install mounted, innermost first"

  # 1. The pseudo-filesystems, and the ESP if this process mounted it. Mounts
  #    that were already there when step 50 arrived were adopted, and
  #    chroot_cleanup leaves every one of those alone.
  chroot_cleanup || failed=$((failed + 1))

  # 2. The target tree itself. The plan is used only when it agrees with the
  #    root everything above was checked against; a plan describing another
  #    mountpoint is a plan from another install, and unmounting by it would be
  #    exactly the guess this function refuses to make.
  if [[ -r "$plan_file" ]]; then
    plan="$(cat -- "$plan_file" 2>/dev/null || true)"
    recorded="$(disk_plan_meta "$plan" mountpoint)"
  fi

  if [[ -n "$plan" && "$recorded" == "$root" ]]; then
    log "using the disk plan step 20 recorded (${plan_file})"
    disk_teardown "$plan" || failed=$((failed + 1))
  else
    if [[ -n "$recorded" ]]; then
      warn "the recorded plan mounts ${recorded}, not ${root}; it is not used here"
    fi
    _fin_umount_root "$root" || failed=$((failed + 1))
  fi

  # 3. The container, once nothing is standing on it.
  if ((failed == 0)); then
    _fin_close_container
  else
    warn "leaving the encryption layer alone: the tree above it is still held"
  fi

  ((failed == 0)) || return 1
  return 0
}

# --------------------------------------------------------------------------- #
#  The reboot — a tri-state, and never taken on its own                       #
# --------------------------------------------------------------------------- #
_fin_reboot() {
  # Reached only with an empty _FIN_FAILED: the caller returns before this when
  # a check or the unmount failed, because a machine that failed a proof is not
  # a machine to reboot into on the installer's initiative.
  local target
  target="$(_fin_fact disk disk.device "")"

  # First question: would this reboot even enter the target? On a live medium,
  # yes. Reinstalling the machine we are running on, yes. Anywhere else the
  # reboot restarts the running system and enters nothing — and that is how a
  # working machine got rebooted into a firmware entry pointing at a loop
  # device that no longer existed.
  if ! disk_may_write_firmware_state "$target"; then
    skip "not rebooting: ${target:-the target} is not the disk this machine booted from"
    log "       this installer is running on an installed system, not a live medium,"
    log "       so a reboot would restart this machine rather than enter the target"
    _fin_fix "reboot   # only when that is really what you want"
    return 0
  fi

  # Second question: was it actually asked for? A reboot is irreversible in the
  # same way wiping a disk is, so it follows the rule typed proofs follow
  # (DESIGN.md §12): --yes and --force do not answer it. Only reboot = yes, set
  # on purpose, or a person at a terminal.
  case "${CFG[reboot]:-ask}" in
    yes) ;;
    no)
      skip "not rebooting (reboot=no). When you are ready:"
      _fin_fix "reboot"
      return 0
      ;;
    *)
      if [[ "$NON_INTERACTIVE" == "yes" || "$ASSUME_YES" == "yes" || ! -r /dev/tty ]]; then
        skip "not rebooting: --yes does not answer this one"
        log "       pass --reboot yes to mean it, or reboot by hand:"
        _fin_fix "reboot"
        return 0
      fi
      if ! confirm "Reboot into the installed system now?" "no"; then
        log "not rebooting. When you are ready:"
        _fin_fix "reboot"
        return 0
      fi
      ;;
  esac

  warn "rebooting in ${_FIN_REBOOT_DELAY}s — Ctrl-C now if that was not the answer"
  run_cmd sleep "$_FIN_REBOOT_DELAY"
  run_cmd reboot
}

# --------------------------------------------------------------------------- #
#  The journal                                                                #
# --------------------------------------------------------------------------- #
_fin_journal_result() {
  # What was found, never a secret. Silent when there is no journal.
  local result="$1"
  [[ -n "${STATE_FILE:-}" ]] || return 0
  state_set "finalize.result" "$result" || true
  state_set "finalize.checks" \
    "total=${_FIN_TOTAL} fail=${#_FIN_FAILED[@]} warn=${#_FIN_WARNED[@]}" || true
  if ((${#_FIN_FAILED[@]} > 0)); then
    state_set "finalize.failed" "${_FIN_FAILED[*]}" || true
  else
    state_unset "finalize.failed" || true
  fi
  if ((${#_FIN_WARNED[@]} > 0)); then
    state_set "finalize.warned" "${_FIN_WARNED[*]}" || true
  else
    state_unset "finalize.warned" || true
  fi
}

# --------------------------------------------------------------------------- #
#  The step                                                                   #
# --------------------------------------------------------------------------- #
step_95_finalize() {
  local root name

  _FIN_INDEX=0
  _FIN_FAILED=()
  _FIN_WARNED=()
  _FIN_TOTAL=${#_FIN_CHECKS[@]}

  root="$(_fin_root)"

  if [[ -z "$root" || "$root" == "/" ]]; then
    err "Refusing to finalize / as the target"
    err "       step 95 unmounts the tree it is pointed at, and pointing it at /"
    err "       would unmount the machine running the installer"
    err "       the target defaults to /mnt/gentoo; set it explicitly with"
    err "       root = /mnt/gentoo in the configuration file"
    return "$EXIT_FAILURE"
  fi

  if [[ ! -d "$root" ]]; then
    err "Target root does not exist: ${root}"
    err "       there is nothing installed to check, and nothing mounted to release"
    err "       steps 20 to 90 build it; run those first"
    err "       example:  ./gentoo-install.sh --resume"
    return "$EXIT_FAILURE"
  fi

  _fin_read_installed_kernel "$root" || true

  log "final checks on ${root}: ${_FIN_TOTAL} checks, nothing is modified"
  printf '\n' >&2

  for name in "${_FIN_CHECKS[@]}"; do
    "_fin_check_${name}" "$root"
  done

  printf '\n' >&2

  _fin_recap_installed "$root"
  printf '\n' >&2
  _fin_recap_todo
  printf '\n' >&2
  _fin_recap_secrets
  printf '\n' >&2
  _fin_recap_next "$root"
  printf '\n' >&2

  if ! _fin_release "$root"; then
    _FIN_FAILED+=("unmount")
  fi

  printf '\n' >&2

  if ((${#_FIN_FAILED[@]} > 0)); then
    _fin_journal_result "fail"
    err "Finalize failed: ${#_FIN_FAILED[@]} blocking, ${#_FIN_WARNED[@]} warning(s)"
    err "       blocking: ${_FIN_FAILED[*]}"
    err "       each one above carries the command that fixes it"
    err "       this machine is not being rebooted into: a failed proof is not"
    err "       an opinion to override"
    err "       fix them, then: ./gentoo-install.sh --steps 50,95"
    return "$EXIT_FAILURE"
  fi

  if ((${#_FIN_WARNED[@]} > 0)); then
    _fin_journal_result "warn"
    warn "Finalize passed with ${#_FIN_WARNED[@]} warning(s): ${_FIN_WARNED[*]}"
  else
    _fin_journal_result "pass"
    ok "finalize: ${_FIN_TOTAL} checks, all clear"
  fi

  _fin_reboot
  return "$EXIT_SUCCESS"
}
