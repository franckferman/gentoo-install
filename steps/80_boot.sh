#!/usr/bin/env bash
#
# gentoo-install — step 80: make the kernel of step 70 reachable at power-on
# ----------------------------------------------------------------------------
# Three answers, because there is no single right one: GRUB, which works
# everywhere including legacy BIOS and is the default; the EFI stub, where the
# firmware launches the kernel itself and there is no bootloader to go wrong;
# and systemd-boot, for the systemd installs that want it.
#
# Every one of them checks its own work before returning — the EFI file exists,
# grub-script-check accepts the generated configuration, the boot entry is in
# NVRAM, the loader entry points at files that are actually there. A bootloader
# written and not verified is a problem discovered at the next power-on, in
# front of a firmware menu, with no shell.
#
# The command line and the kernel image come from steps/70_kernel.sh, which
# this file sources: the bootloader must hand the kernel the same line the
# initramfs was built for, and two implementations of that is one too many.
#
# Usage:  source steps/80_boot.sh   (needs lib/core.sh, lib/config.sh,
#                                    lib/state.sh, steps/70_kernel.sh)
#
set -euo pipefail

if [[ -n "${_GI_STEP_80_LOADED:-}" ]]; then
  return 0
fi
_GI_STEP_80_LOADED=1

_gi_self="$(readlink -f -- "${BASH_SOURCE[0]}")"
GI_STEP_DIR="${_gi_self%/*}"
GI_BASE_DIR="${GI_STEP_DIR%/*}"
GI_VARIANT_DIR="${GI_VARIANT_DIR:-${GI_BASE_DIR}/variants}"
unset _gi_self

if [[ -z "${_GI_STEP_70_LOADED:-}" ]]; then
  # shellcheck source=steps/70_kernel.sh
  source "${GI_STEP_DIR}/70_kernel.sh"
fi

# --------------------------------------------------------------------------- #
#  Firmware, ESP, identity                                                    #
# --------------------------------------------------------------------------- #
boot_firmware() {
  # uefi or bios. The automatic answer describes how *this* boot happened,
  # which is right until someone starts the installer in legacy mode on a
  # machine that will run UEFI. That is what the setting is for.
  local mode
  mode="$(target_fact firmware preflight.firmware "auto")"
  if [[ "$mode" == "auto" ]]; then
    if [[ -d /sys/firmware/efi ]]; then
      mode="uefi"
    else
      mode="bios"
    fi
  fi
  printf '%s\n' "$mode"
}

boot_variant() { target_fact bootloader boot.variant "grub"; }
boot_label() { target_fact boot_label boot.label "gentoo"; }
boot_esp_device() { target_fact esp_device disk.esp_device ""; }
boot_esp_uuid() { target_fact esp_uuid disk.esp_uuid ""; }
boot_disk() { target_fact boot_disk disk.device ""; }
boot_timeout() { target_fact boot_timeout "" "5"; }

boot_esp_dir() {
  # The ESP as this run can reach it: the target root plus the mount point the
  # target will see it at. Args: $1 = target root.
  local root="${1%/}" mount
  mount="$(target_esp_mount)"
  printf '%s\n' "${root}${mount}"
}

boot_efi_path() {
  # A path on the ESP, written the way the firmware spells it. Args: $1 = the
  # path relative to the ESP root, with forward slashes.
  local path="$1"
  path="/${path#/}"
  printf '%s\n' "${path//\//\\}"
}

boot_needs_efi() {
  case "$(boot_variant)" in
    efistub | systemd-boot | uki) return 0 ;;
    *) return 1 ;;
  esac
}

# --------------------------------------------------------------------------- #
#  Secure Boot                                                                #
# --------------------------------------------------------------------------- #
# Optional throughout. A machine with no key pair gets an unsigned binary and
# is told so in one line; a machine in Secure Boot that is handed an unsigned
# binary refuses it at the next power-on and says nothing useful about why.
boot_secureboot_keyfile() {
  # Not read from the state journal: state_get refuses any key ending in _key,
  # and a setting that half works is worse than one that does not.
  local value
  value="$(cfg secureboot_keyfile)"
  printf '%s\n' "$value"
}

boot_secureboot_cert() { target_fact secureboot_cert boot.secureboot_cert ""; }

boot_secureboot_ready() {
  # 0 when both halves of a usable pair are on disk. Explains once, then stays
  # quiet: it is called before every signature.
  local key cert
  key="$(boot_secureboot_keyfile)"
  cert="$(boot_secureboot_cert)"
  [[ -n "$key" && -n "$cert" ]] || return 1
  [[ -r "$key" ]] || {
    err "Secure Boot key not readable: ${key}"
    return 1
  }
  [[ -r "$cert" ]] || {
    err "Secure Boot certificate not readable: ${cert}"
    return 1
  }
  have sbsign || {
    err "sbsign is not installed, but a Secure Boot key pair was given"
    err "       app-crypt/sbsigntools provides sbsign and sbverify"
    err "       clear secureboot_keyfile to install unsigned instead"
    return 1
  }
  return 0
}

boot_signature_state() {
  # signed | unsigned | missing | unknown, on stdout.
  #
  # The trap this exists for: `sbverify --list` exits 0 on a binary that has no
  # signature at all — it prints "No signature table present" and returns
  # success, because listing nothing is not a failure to list. Code that tests
  # $? here concludes that an unsigned kernel is signed, copies it to the ESP,
  # and the machine refuses to boot with a firmware message that names nothing.
  # The verdict is the text.
  local file="$1" out
  if [[ ! -f "$file" ]]; then
    printf 'missing\n'
    return 0
  fi
  if ! have sbverify; then
    printf 'unknown\n'
    return 0
  fi
  out="$(sbverify --list "$file" 2>&1)" || true
  # "No signature table present" itself contains the word signature, so the
  # negative has to be tested first.
  case "$out" in
    *"No signature table present"*) printf 'unsigned\n' ;;
    *"signature "*) printf 'signed\n' ;;
    *) printf 'unknown\n' ;;
  esac
}

show_signature() {
  # Displays; changes nothing.
  local file="$1" state
  state="$(boot_signature_state "$file")"
  case "$state" in
    signed) ok "${file}: signed" ;;
    unsigned)
      warn "${file}: no signature table present"
      warn "       a machine with Secure Boot enabled will refuse it"
      warn "       give secureboot_keyfile and secureboot_cert to sign it here"
      ;;
    missing) err "${file}: not there" ;;
    *) warn "${file}: signature state unknown (sbverify says nothing conclusive)" ;;
  esac
  if have sbverify && [[ -f "$file" ]]; then
    sbverify --list "$file" 2>&1 | sed 's/^/       /' >&2 || true
  fi
}

boot_strip_signatures() {
  # Every signature on a PE image, removed. sbattach takes one per call, so
  # the loop is the strip; it is bounded because an unbounded loop over an
  # external tool's exit code is one bug away from never ending.
  # Args: $1 = the image.
  local file="$1" i
  have sbattach || return 0
  [[ -f "$file" ]] || return 0
  for ((i = 0; i < 16; i++)); do
    sbattach --remove "$file" >/dev/null 2>&1 || return 0
  done
  return 0
}

boot_install_efi() {
  # The one door every EFI binary goes through: sign it when there is a key,
  # copy it when there is not, and say which happened.
  # Args: $1 = source file (host path), $2 = destination (host path).
  local src="$1" dest="$2" dir key cert

  if [[ ! -f "$src" && "$DRY_RUN" != "yes" ]]; then
    err "Nothing to install: ${src} does not exist"
    return 1
  fi

  dir="${dest%/*}"
  run_cmd mkdir -p -- "$dir" || return 1

  if boot_secureboot_ready; then
    key="$(boot_secureboot_keyfile)"
    cert="$(boot_secureboot_cert)"

    # sbsign appends; it does not replace. Signing an image in place — which is
    # what happens when the ESP is mounted at /boot and the kernel is already
    # where the loader reads it — leaves one more signature on the file every
    # time step 80 runs. Measured on a real PE: four runs, four signatures.
    #
    # The size is the least of it. After rotating the key pair the image still
    # verifies against the retired certificate, so any firmware that still has
    # it enrolled starts the image — which is the one thing rotating a key is
    # meant to end. Stripping first leaves exactly one signature, from the pair
    # in force. Where source and destination differ, sbsign writes a fresh file
    # from a pristine one and there is nothing to strip.
    if [[ "$src" == "$dest" ]]; then
      run_cmd boot_strip_signatures "$dest" || return 1
    fi

    run_cmd sbsign --key "$key" --cert "$cert" --output "$dest" "$src" || {
      err "sbsign failed on ${src}"
      err "       the key and the certificate must be a matching pair, in PEM"
      err "       sbverify --list ${src} shows what is already on it"
      return 1
    }
    ok "signed ${src} -> ${dest}"
  else
    if [[ -n "$(boot_secureboot_keyfile)$(boot_secureboot_cert)" ]]; then
      # Half a pair was given: that is a mistake worth stopping for, and
      # boot_secureboot_ready has already said which half is missing.
      err "Secure Boot signing was asked for and cannot be done"
      err "       secureboot_keyfile and secureboot_cert are both required"
      err "       example:  --secureboot-keyfile /root/db.key --secureboot-cert /root/db.crt"
      return 1
    fi
    run_cmd cp -- "$src" "$dest" || return 1
    log "installed unsigned: ${dest}"
    log "       no Secure Boot key pair was given, so nothing was signed"
    log "       a machine with Secure Boot enabled will not start this image"
  fi

  if [[ "$DRY_RUN" != "yes" ]]; then
    show_signature "$dest"
  fi
}

# --------------------------------------------------------------------------- #
#  NVRAM boot entries                                                         #
# --------------------------------------------------------------------------- #
boot_install_removable_fallback() {
  # \EFI\BOOT\BOOTX64.EFI — the one path a UEFI firmware tries with no NVRAM
  # entry to guide it. Copying the loader there costs a megabyte and is the
  # difference between a disk that boots anywhere and a disk that boots only on
  # the machine whose firmware still remembers it.
  # Args: $1 = ESP mountpoint, $2 = loader path relative to the ESP.
  local esp="$1" loader="$2" src dst
  src="${esp}${loader}"
  dst="${esp}/EFI/BOOT/BOOTX64.EFI"

  if [[ "$DRY_RUN" != "yes" && ! -f "$src" ]]; then
    err "no loader at ${src} to copy to the removable path"
    return 1
  fi
  if [[ "$DRY_RUN" != "yes" && -f "$dst" ]]; then
    skip "removable path already present: ${dst}"
    return 0
  fi

  run_cmd mkdir -p -- "${esp}/EFI/BOOT" || return 1
  run_cmd cp -- "$src" "$dst" || {
    err "could not copy ${src} to ${dst}"
    return 1
  }
  ok "removable path: ${dst} — the firmware finds this one with no entry"
}

boot_esp_disk_and_part() {
  # efibootmgr wants the disk and the partition number, not the partition.
  # Prints "disk<TAB>number", or returns 1 and says what is missing.
  local dev="$1" name parent number
  if [[ -z "$dev" ]]; then
    err "No EFI system partition is known"
    err "       step 20 records disk.esp_device in the state journal"
    err "       lsblk -o NAME,PARTTYPENAME shows which partition it is"
    err "       example:  esp_device = /dev/nvme0n1p1"
    return 1
  fi
  name="${dev##*/}"
  if [[ -r "/sys/class/block/${name}/partition" ]]; then
    number="$(cat "/sys/class/block/${name}/partition")"
    parent="$(lsblk -dno PKNAME -- "$dev" 2>/dev/null | head -n 1)"
  fi
  if [[ -z "${number:-}" || -z "${parent:-}" ]]; then
    err "Cannot tell which disk and partition ${dev} is"
    err "       lsblk -no PKNAME ${dev} should name the disk"
    err "       set boot_disk and esp_partition to say it by hand"
    err "       example:  boot_disk = /dev/nvme0n1"
    return 1
  fi
  printf '%s\t%s\n' "/dev/${parent}" "$number"
}

boot_entry_exists() {
  # Args: $1 = label, $2 = loader path in firmware notation.
  local label="$1" loader="$2"
  have efibootmgr || return 1
  efibootmgr -v 2>/dev/null | grep -F -- "$label" | grep -qF -- "$loader"
}

boot_create_entry() {
  # Idempotent: an entry with the same label and the same loader is left alone
  # rather than added a second time. NVRAM has a size and duplicates fill it.
  # Args: $1 = ESP device, $2 = label, $3 = loader path (forward slashes),
  #       $4 = load options (may be empty).
  local esp="$1" label="$2" loader="$3" options="${4:-}"
  local efi_loader disk part record
  local -a argv=()

  efi_loader="$(boot_efi_path "$loader")"

  if ! have efibootmgr; then
    warn "efibootmgr is not installed; no boot entry was created"
    warn "       sys-boot/efibootmgr provides it"
    warn "       the firmware may still find ${efi_loader} through the removable-media path"
    return 0
  fi

  if boot_entry_exists "$label" "$efi_loader"; then
    skip "boot entry '${label}' already points at ${efi_loader}"
    return 0
  fi

  record="$(boot_esp_disk_and_part "$esp")" || return 1
  IFS=$'\t' read -r disk part <<<"$record"

  # An NVRAM entry is firmware state about a disk, not a file in the target
  # tree: it outlives this run and it is global to the machine. Writing one for
  # a disk this machine did not boot from, while running on an installed system,
  # replaces that machine's own entry of the same label with a pointer to a disk
  # that may not exist at the next power-on. That happened here — an install to
  # a loop image took the host's 'gentoo' entry with it — and the machine had to
  # be recovered from a live USB.
  if ! disk_may_write_firmware_state "$disk"; then
    warn "not writing an NVRAM entry: ${disk} is not the disk this machine booted from"
    warn "       and this is not a live medium, so the entry would name a disk the"
    warn "       firmware may not find, over the label this machine already uses"
    log "       write it yourself once the target is the machine being booted:"
    log "         efibootmgr --create --disk ${disk} --part ${part} --label ${label} --loader ${efi_loader}"
    # Without an entry the firmware has only one way left to find a loader: the
    # removable-media path. Leaving the target with neither is how an install
    # that reported success produced a disk that drops straight to PXE — which
    # is what a fresh OVMF did with the first image this project ever built.
    boot_install_removable_fallback "$esp" "$efi_loader" || return 1
    return 0
  fi

  argv=(efibootmgr --create --disk "$disk" --part "$part" --label "$label" --loader "$efi_loader")
  if [[ -n "$options" ]]; then
    # --unicode, because the firmware reads the load options as UCS-2 and an
    # ASCII command line arrives as one character followed by nothing.
    argv+=(--unicode "$options")
  fi

  run_cmd "${argv[@]}" || {
    err "efibootmgr could not create the '${label}' entry"
    err "       efibootmgr -v lists what is there now"
    err "       some firmware refuses new entries until its own boot menu is opened once"
    return 1
  }

  if [[ "$DRY_RUN" == "yes" ]]; then
    return 0
  fi
  if boot_entry_exists "$label" "$efi_loader"; then
    ok "boot entry '${label}' -> ${efi_loader}"
  else
    err "efibootmgr reported success but no '${label}' entry names ${efi_loader}"
    err "       efibootmgr -v shows the current list"
    return 1
  fi
}

show_boot_entries() {
  if ! have efibootmgr; then
    skip "efibootmgr is not installed; the NVRAM boot order cannot be shown"
    return 0
  fi
  log "NVRAM boot entries:"
  efibootmgr 2>/dev/null | sed 's/^/       /' >&2 || true
}

# --------------------------------------------------------------------------- #
#  Shared verification                                                        #
# --------------------------------------------------------------------------- #
boot_require_file() {
  # Args: $1 = path, $2 = what it is.
  local path="$1" what="$2"
  if [[ "$DRY_RUN" == "yes" ]]; then
    log "dry-run: would check that ${what} exists at ${path}"
    return 0
  fi
  if [[ -f "$path" ]]; then
    ok "${what}: ${path}"
    return 0
  fi
  err "${what} is missing: ${path}"
  return 1
}

boot_copy_to_esp() {
  # Args: $1 = source (host path), $2 = destination (host path).
  local src="$1" dest="$2"
  if [[ ! -f "$src" && "$DRY_RUN" != "yes" ]]; then
    err "Cannot copy to the ESP: ${src} does not exist"
    return 1
  fi
  run_cmd mkdir -p -- "${dest%/*}" || return 1
  # files_identical rather than `cmp -s`, for the reason written where it is
  # defined: no cmp on the minimal ISO. Here the polarity made it harmless —
  # a failed comparison only meant copying a file that was already right — but
  # the same call one file away was refusing to install a key.
  if [[ -f "$dest" && "$DRY_RUN" != "yes" ]] && files_identical "$src" "$dest"; then
    skip "${dest}: already identical"
    return 0
  fi
  run_cmd cp -- "$src" "$dest" || return 1
  ok "${dest}: copied"
}

boot_load_variant() {
  local name="$1"
  # Split: ${name} is not bound yet inside the same local (SC2318).
  local file="${GI_VARIANT_DIR}/boot/${name}.sh"
  if [[ ! -r "$file" ]]; then
    err "Missing bootloader variant implementation: ${file}"
    err "       GI_VARIANT_DIR points at ${GI_VARIANT_DIR}"
    err "       example:  GI_VARIANT_DIR=/usr/local/share/gentoo-install/variants"
    return 1
  fi
  # shellcheck disable=SC1090  # one of three files, chosen at run time
  # shellcheck source=/dev/null  # the variant file is chosen at run time
  source "$file"
}

# --------------------------------------------------------------------------- #
#  The step                                                                   #
# --------------------------------------------------------------------------- #
show_boot_plan() {
  # Args: $1 = target root, $2 = variant, $3 = firmware.
  local root="$1" variant="$2" firmware="$3" key esp
  log "bootloader       ${variant}"
  log "firmware         ${firmware}"
  log "target root      ${root}"
  if [[ "$firmware" == "uefi" ]]; then
    esp="$(boot_esp_device)"
    log "ESP              $(boot_esp_dir "$root")  (device ${esp:-unknown})"
  else
    log "boot disk        $(boot_disk)"
  fi
  key="$(boot_secureboot_keyfile)"
  if [[ -n "$key" ]]; then
    log "Secure Boot      sign with ${key}"
  else
    log "Secure Boot      no key pair given; binaries are installed unsigned"
  fi
  show_kernel_cmdline
}

step_80_boot() {
  local root variant firmware fn

  root="$(target_root)"
  variant="$(boot_variant)"
  firmware="$(boot_firmware)"

  case "$variant" in
    grub) fn="boot_grub_install" ;;
    efistub) fn="boot_efistub_install" ;;
    systemd-boot) fn="boot_systemd_boot_install" ;;
    uki) fn="boot_uki_install" ;;
    *)
      err "Unknown bootloader: ${variant}"
      err "       grub          works everywhere, legacy BIOS included; the default"
      err "       efistub       the firmware starts the kernel itself, no loader at all"
      err "       systemd-boot  small UEFI loader, one file per boot entry"
      err "       uki           kernel, initramfs and command line in one signed EFI binary,"
      err "                     started from the fallback path with no NVRAM entry at all"
      err "       example:  bootloader = grub"
      return 1
      ;;
  esac

  case "$firmware" in
    uefi | bios) ;;
    *)
      err "Unknown firmware mode: ${firmware}"
      err "       uefi  the machine boots through an EFI system partition"
      err "       bios  legacy boot from a master boot record"
      err "       auto  look at how this run itself was booted"
      err "       example:  firmware = uefi"
      return 1
      ;;
  esac

  if [[ "$firmware" == "bios" ]] && boot_needs_efi; then
    err "bootloader=${variant} needs UEFI firmware"
    err "       this run was booted in legacy BIOS mode, so there is no ESP to install into"
    err "       bootloader = grub  is the one that boots a BIOS machine"
    err "       firmware = uefi    if the target really is UEFI and the installer was not"
    err "       example:  --bootloader grub"
    return 1
  fi

  if [[ ! -d "$root" ]]; then
    err "Target root does not exist: ${root}"
    err "       step 50 mounts it; run step 80 after it"
    err "       example:  ./gentoo-install.sh --steps 50,70,80"
    return 1
  fi

  show_boot_plan "$root" "$variant" "$firmware"

  boot_load_variant "$variant" || return 1
  "$fn" "$root" "$firmware" || return 1

  state_set boot.variant "$variant"
  state_set boot.firmware "$firmware"
  state_set boot.label "$(boot_label)"
  # Same reasoning as the kernel facts: what this run put in the NVRAM entry,
  # and which certificate it signed with, are read back by name and must not be
  # re-derived from a default on the next run.
  state_set boot.efistub_cmdline "$(target_fact efistub_cmdline boot.efistub_cmdline "")"
  state_set boot.secureboot_cert "$(boot_secureboot_cert)"
  # The key's path as well as the certificate's, and for a reason that only
  # shows up much later: tools/bios-update.sh has to sign fwupdx64.efi with the
  # same pair the kernel was signed with, or the machine boots and will not
  # flash. It had two sources for that pair and neither was this installer, so a
  # machine signed here recorded which certificate it used and nothing about
  # which key — half a pair, which is exactly what boot_secureboot_ready()
  # refuses to work with.
  #
  # The path, never the key: the same rule crypt.keyfile follows. The journal
  # refuses a name ending in _key outright, which is how this went unnoticed —
  # boot.secureboot_key would have died on the spot, and boot.secureboot_cert
  # alone looked complete.
  state_set boot.secureboot_keyfile "$(boot_secureboot_keyfile)"
}
