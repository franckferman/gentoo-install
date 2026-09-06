#!/usr/bin/env bash
#
# gentoo-install — bootloader variant: uki (unified kernel image)
# ----------------------------------------------------------------------------
# One signed EFI binary carrying the kernel, the initramfs and the command line
# together, started by the firmware with nothing in between.
#
# This variant exists because of a failure the other three share. GRUB and
# systemd-boot need a loader on the ESP and, to be found reliably, an NVRAM
# entry pointing at it; efistub needs that entry even more, because the entry is
# where its command line and its initrd= live. An NVRAM entry is firmware state:
# it can be overwritten by another operating system's installer, cleared by a
# firmware update, lost with a dead CMOS battery, or — as happened to the
# machine this project was written on — replaced by an installer aimed at some
# other disk. When it goes, a perfectly intact system stops booting.
#
# A unified kernel image at \EFI\BOOT\BOOTX64.EFI needs no entry at all. That is
# the path a UEFI firmware tries when nothing in NVRAM points anywhere, so the
# disk boots in the machine it was built in, in a different machine, and after
# the NVRAM has been wiped. It is also the shape Secure Boot wants: one file to
# sign, rather than a loader that then reads unsigned modules and an unsigned
# configuration.
#
# The image is built by dracut --uefi, which wraps the kernel and initramfs
# around systemd's EFI stub. Both come from packages this installer already
# knows how to place: sys-kernel/dracut, and sys-apps/systemd-utils with the
# boot flag, which is what carries linuxx64.efi.stub.
#
# Usage:  sourced by steps/80_boot.sh when bootloader = uki
#
set -euo pipefail

# Where systemd-utils installs the stub dracut wraps the kernel in. The
# gummiboot path is there for the machines that still carry the old package.
readonly BOOT_UKI_STUB_CANDIDATES=(
  "/usr/lib/systemd/boot/efi/linuxx64.efi.stub"
  "/usr/lib/gummiboot/linuxx64.efi.stub"
)

# \EFI\Linux is where a UKI belongs: systemd-boot and several firmwares
# enumerate it on their own, so a machine that does have an entry finds this one
# without being told.
readonly BOOT_UKI_DIR="/EFI/Linux"
readonly BOOT_UKI_FALLBACK="/EFI/BOOT/BOOTX64.EFI"

boot_uki_stub() {
  # The stub, as a path inside the target. A returned value.
  # Args: $1 = target root.
  local root="${1%/}" candidate
  for candidate in "${BOOT_UKI_STUB_CANDIDATES[@]}"; do
    if [[ -f "${root}${candidate}" ]]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  return 1
}

boot_uki_name() {
  # <label>-<version>.efi — the version is in the name so that two kernels can
  # sit on the ESP at once, which is what makes a fallback entry possible.
  # Args: $1 = kernel version.
  printf '%s-%s.efi\n' "$(boot_label)" "$1"
}

boot_uki_packages() {
  # Args: $1 = target root.
  local root="$1"

  # The stub comes from systemd-utils, and only with the boot flag — which the
  # ebuild will not accept without kernel-install beside it. The systemd-boot
  # variant learned that the hard way; this one is written knowing it.
  kernel_write_package_use "$root" \
    "# A unified kernel image is the kernel wrapped in systemd's EFI stub." \
    "# linuxx64.efi.stub comes from systemd-utils, and only with these flags." \
    "sys-apps/systemd-utils boot kernel-install" || return 1

  if ! kernel_pkg_installed "$root" "sys-kernel/dracut"; then
    kernel_emerge "$root" "sys-kernel/dracut" || return 1
  fi

  if boot_uki_stub "$root" >/dev/null 2>&1; then
    return 0
  fi
  if ! kernel_pkg_installed "$root" "sys-apps/systemd-utils"; then
    kernel_emerge "$root" "sys-apps/systemd-utils" || return 1
  else
    # Installed without the flag, so --noreplace would leave it alone and the
    # stub would never appear. Same shape as the systemd-boot variant.
    log "sys-apps/systemd-utils is installed without the EFI stub; rebuilding it"
    kernel_in_target "$root" emerge --verbose --changed-use --quiet-build=n \
      sys-apps/systemd-utils || {
      err "sys-apps/systemd-utils would not rebuild with the boot flag"
      err "       linuxx64.efi.stub is what a unified kernel image is built around"
      err "       bootloader = grub needs none of this"
      return 1
    }
  fi
}

boot_uki_require_stub() {
  # Args: $1 = target root.
  local root="$1" stub
  if stub="$(boot_uki_stub "$root")"; then
    ok "EFI stub: ${stub}"
    return 0
  fi
  if [[ "$DRY_RUN" == "yes" ]]; then
    log "dry-run: no EFI stub in the target; the merge above is what puts it there"
    return 0
  fi
  err "No EFI stub in the target: ${root%/}${BOOT_UKI_STUB_CANDIDATES[0]}"
  err "       sys-apps/systemd-utils provides it, with USE=\"boot kernel-install\""
  err "       a unified kernel image is the kernel wrapped in that stub"
  err "       example:  bootloader = systemd-boot   # a loader instead of a UKI"
  return 1
}

boot_uki_build() {
  # dracut --uefi does the wrapping: kernel, initramfs and command line into one
  # PE binary. The command line has to be given here and not left to the running
  # system's /proc/cmdline, which is the installer's, not the target's.
  # Args: $1 = target root, $2 = kernel version, $3 = path on the ESP as the
  #       target sees it.
  local root="$1" version="$2" out="$3" cmdline stub
  cmdline="$(kernel_cmdline)" || return 1
  stub="$(boot_uki_stub "$root")" || {
    [[ "$DRY_RUN" == "yes" ]] || return 1
    stub="${BOOT_UKI_STUB_CANDIDATES[0]}"
  }

  log "building the unified kernel image"
  log "       kernel     ${version}"
  log "       stub       ${stub}"
  log "       cmdline    ${cmdline}"
  log "       output     ${out}"

  kernel_in_target "$root" mkdir -p -- "${out%/*}" || return 1
  kernel_in_target "$root" dracut --force --uefi \
    --kver "$version" \
    --uefi-stub "$stub" \
    --kernel-cmdline "$cmdline" \
    "$out" || {
    err "dracut could not build the unified kernel image"
    err "       dracut --force --uefi --kver ${version} ${out}   reproduces it in the chroot"
    err "       the stub, the kernel and the initramfs all have to be in the target"
    return 1
  }
}

boot_uki_write_fallback() {
  # \EFI\BOOT\BOOTX64.EFI — the reason to build a UKI in the first place.
  #
  # Written unless the operator turned it off, and not only when boot_removable
  # asks: an image that needs an NVRAM entry to be found gives up the one
  # property this variant exists for. Anything already at that path is another
  # system's loader, so it is backed up rather than overwritten in silence.
  # Args: $1 = target root, $2 = the UKI as the target sees it, $3 = where the
  #       ESP is mounted inside the target.
  local root="${1%/}" uki="$2" esp_mount="${3%/}" src dst
  if [[ "$(target_fact boot_removable "" "yes")" == "no" ]]; then
    skip "boot_removable = no: nothing written to ${BOOT_UKI_FALLBACK}"
    return 0
  fi
  src="${root}${uki}"
  dst="${root}${esp_mount}${BOOT_UKI_FALLBACK}"

  if [[ "$DRY_RUN" != "yes" && ! -f "$src" ]]; then
    err "no image at ${src} to copy to the fallback path"
    return 1
  fi
  run_cmd mkdir -p -- "${dst%/*}" || return 1
  if [[ -f "$dst" ]]; then
    backup_file "$dst" || true
  fi
  run_cmd cp -- "$src" "$dst" || {
    err "could not copy ${src} to ${dst}"
    return 1
  }
  ok "fallback: ${dst} — started by a firmware with nothing in NVRAM"
}

boot_uki_verify() {
  # Args: $1 = target root, $2 = the UKI, as the target sees it.
  local root="${1%/}" uki="$2" file size
  file="${root}${uki}"
  boot_require_file "$file" "unified kernel image" || return 1

  # A UKI is a PE binary; anything else means dracut wrote something the
  # firmware will refuse without saying why.
  if [[ "$DRY_RUN" != "yes" ]]; then
    if ! head -c 2 -- "$file" | grep -q 'MZ'; then
      err "${uki} is not a PE binary"
      err "       a firmware refuses it with no message worth reading"
      err "       file ${file}   says what it actually is"
      return 1
    fi
    size="$(stat -c '%s' -- "$file" 2>/dev/null || printf '0')"
    ok "unified kernel image: ${uki}, $((size / 1024 / 1024)) MiB"
  fi
  show_signature "$file"
}

boot_uki_install() {
  # Args: $1 = target root, $2 = firmware.
  local root="$1" firmware="$2" record version esp_mount uki

  if [[ "$firmware" != "uefi" ]]; then
    err "bootloader = uki needs UEFI firmware, and this run is on legacy BIOS"
    err "       a unified kernel image is an EFI application; a BIOS has nothing to start it with"
    err "       example:  --bootloader grub"
    return 1
  fi

  boot_uki_packages "$root" || return 1
  boot_uki_require_stub "$root" || return 1

  if ! record="$(kernel_installed "$root")"; then
    err "No kernel in the target to wrap"
    err "       step 70 builds or installs one, and records the version"
    err "       example:  ./gentoo-install.sh --steps 70,80"
    return 1
  fi
  IFS=$'\t' read -r version _ _ <<<"$record"

  esp_mount="$(target_esp_mount)"
  uki="${esp_mount%/}${BOOT_UKI_DIR}/$(boot_uki_name "$version")"

  boot_uki_build "$root" "$version" "$uki" || return 1

  # Signed before it is copied: the fallback has to carry the signature too, or
  # a machine with Secure Boot on refuses exactly the file it falls back to.
  if boot_secureboot_ready; then
    boot_install_efi "${root%/}${uki}" "${root%/}${uki}" || return 1
  fi

  boot_uki_write_fallback "$root" "$uki" "$esp_mount" || return 1
  boot_uki_verify "$root" "$uki" || return 1

  log "no NVRAM entry is created, and none is needed:"
  log "       the firmware starts \\EFI\\BOOT\\BOOTX64.EFI when nothing points anywhere"
}
