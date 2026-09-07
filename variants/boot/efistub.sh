#!/usr/bin/env bash
#
# gentoo-install — bootloader variant: the EFI stub
# ----------------------------------------------------------------------------
# No loader at all. The kernel is itself a PE executable, the firmware launches
# it, and nothing sits between the two that can be misconfigured. What is
# missing is everything a loader gives: no menu, no second entry to fall back
# to, no line to edit when root= turns out to be wrong. A repair happens from
# the firmware's own boot menu or from a live medium.
#
# With no loader there is nothing to read a configuration file either, so the
# kernel command line has to reach the kernel some other way. Two ways exist
# and this file implements both:
#
#   efibootmgr  the load options of the NVRAM entry carry it. This is the
#               default here, because the line is then visible — efibootmgr -v
#               prints it — and modifiable from the firmware's boot menu or
#               with one command, instead of a kernel rebuild.
#   builtin     CONFIG_CMDLINE, compiled into the image. This is what the
#               internal installer this module is drawn from does, and what
#               variants/kernel/manual.sh writes when kernel_embed_cmdline is
#               yes. It is the only one that survives cleared NVRAM, and the
#               only one that works when the image is launched from the
#               removable-media path, which is handed no load options at all.
#
# A kernel update does not refresh what this variant put on the ESP: it copies
# the image, it does not hook into installkernel. Rerun step 80 after one.
#
# Usage:  sourced by steps/80_boot.sh   (bootloader = efistub)
#
set -euo pipefail

if [[ -n "${_GI_BOOT_EFISTUB_LOADED:-}" ]]; then
  return 0
fi
_GI_BOOT_EFISTUB_LOADED=1

boot_efistub_removable() {
  # \EFI\BOOT\BOOTX64.EFI, the path firmware falls back to with no NVRAM entry.
  [[ "$(target_fact boot_removable "" "no")" == "yes" ]]
}

boot_efistub_needs_initramfs() {
  # An encrypted container or a root on LVM cannot be opened by the kernel
  # alone. Anything else can, provided the drivers are built in.
  [[ "$(target_crypt)" != "none" || "$(target_topology)" == "lvm" ]]
}

boot_efistub_cmdline_source() {
  # efibootmgr | builtin, on stdout. The default follows the kernel: an
  # operator who asked variants/kernel/manual.sh to bake the line into the
  # image said where they want it, and saying it twice is one place too many.
  local want
  want="$(target_fact efistub_cmdline boot.efistub_cmdline "")"
  if [[ -z "$want" ]]; then
    if [[ "$(target_fact kernel_embed_cmdline "" "no")" == "yes" ]]; then
      want="builtin"
    else
      want="efibootmgr"
    fi
  fi
  case "$want" in
    efibootmgr | builtin) printf '%s\n' "$want" ;;
    *)
      err "Unknown place for the kernel command line: ${want}"
      err "       efibootmgr  the NVRAM entry carries it; efibootmgr -v shows it and the firmware can point elsewhere"
      err "       builtin     CONFIG_CMDLINE, compiled in; changing it means rebuilding the kernel"
      err "       example:  efistub_cmdline = efibootmgr"
      return 1
      ;;
  esac
}

boot_efistub_efi_name() {
  # The file the firmware launches, as a path relative to the ESP root. The
  # name carries no version on purpose: the NVRAM entry names one file, nothing
  # rewrites that entry when the kernel version changes, and an entry pointing
  # at a version that has been cleaned out of the ESP is a machine that does
  # not start.
  local label
  label="$(boot_label)"
  if boot_efistub_removable; then
    printf '%s\n' "/EFI/BOOT/BOOTX64.EFI"
  else
    printf '%s\n' "/EFI/${label}/vmlinuz.efi"
  fi
}

boot_efistub_initrd_name() {
  local label
  label="$(boot_label)"
  printf '%s\n' "/EFI/${label}/initramfs.img"
}

boot_efistub_kernel_config() {
  # The .config the image on the target was built from, or nothing.
  # Args: $1 = target root, $2 = kernel version.
  local root="${1%/}" version="$2" candidate
  for candidate in "${root}/boot/config-${version}" "${root}/usr/src/linux/.config"; do
    if [[ -f "$candidate" ]]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  return 1
}

boot_efistub_is_efi_binary() {
  # An x86_64 kernel built with CONFIG_EFI_STUB starts with the PE "MZ" magic;
  # one built without it starts with the boot sector's jump instruction. The
  # firmware's answer to the second is to fall through to the next entry
  # without a word, which is the failure this check exists to name.
  # Args: $1 = file.
  local file="$1" magic
  magic="$(head -c 2 -- "$file" 2>/dev/null || true)"
  [[ "$magic" == "MZ" ]]
}

boot_efistub_check_kernel_config() {
  # Stage 3 of validation (DESIGN.md §5): the plan was legal, but the kernel
  # that was actually built has the last word on whether it can carry it.
  # Args: $1 = target root, $2 = kernel version, $3 = efibootmgr|builtin.
  local root="$1" version="$2" place="$3" conf embedded expected
  conf="$(boot_efistub_kernel_config "$root" "$version")" || {
    warn "no kernel configuration at ${root%/}/boot/config-${version}"
    warn "       CONFIG_EFI_STUB and CONFIG_CMDLINE cannot be checked from here"
    warn "       the image was checked for the PE magic instead, which is the part that must be right"
    return 0
  }

  if grep -q '^CONFIG_EFI_STUB=y' "$conf"; then
    ok "${conf}: CONFIG_EFI_STUB=y"
  else
    err "${conf} does not set CONFIG_EFI_STUB=y"
    err "       without the stub the firmware has a file it cannot execute"
    err "       kernel = dist-kernel ships it; kernel = manual sets it when bootloader = efistub"
    err "       example:  --kernel dist-kernel"
    return 1
  fi

  if [[ "$place" == "builtin" ]]; then
    if ! grep -q '^CONFIG_CMDLINE_BOOL=y' "$conf"; then
      err "efistub_cmdline = builtin, but ${conf} has no CONFIG_CMDLINE_BOOL=y"
      err "       nothing then tells the kernel where its root is, and it panics with 'unable to mount root fs'"
      err "       kernel_embed_cmdline = yes   with kernel = manual, compiles the line in"
      err "       efistub_cmdline = efibootmgr the NVRAM entry carries it instead, with no rebuild"
      err "       example:  --efistub-cmdline efibootmgr"
      return 1
    fi
    embedded="$(sed -n 's/^CONFIG_CMDLINE="\(.*\)"$/\1/p' "$conf")"
    expected="$(kernel_cmdline)" || return 1
    if [[ "$embedded" == "$expected" ]]; then
      ok "CONFIG_CMDLINE matches the command line step 70 composed"
    else
      warn "CONFIG_CMDLINE differs from the command line step 70 composed"
      warn "       compiled in:  ${embedded:-<empty>}"
      warn "       expected:     ${expected}"
      warn "       the image is what boots; rebuild the kernel to change it"
    fi
  elif grep -q '^CONFIG_CMDLINE_OVERRIDE=y' "$conf"; then
    # CONFIG_CMDLINE_OVERRIDE replaces whatever the firmware passed instead of
    # being appended to it, so every load option this variant just wrote is
    # discarded at boot — including root=.
    err "${conf} sets CONFIG_CMDLINE_OVERRIDE=y, which throws away the load options"
    err "       efistub_cmdline = efibootmgr puts the command line in the NVRAM entry, and this ignores it"
    err "       efistub_cmdline = builtin    accepts that the image owns the line"
    err "       or rebuild the kernel without CONFIG_CMDLINE_OVERRIDE"
    err "       example:  --efistub-cmdline builtin"
    return 1
  fi
}

boot_efistub_check_plan() {
  # Everything that makes the combination impossible, said before anything is
  # written. Args: $1 = target root.
  local root="$1" place
  place="$(boot_efistub_cmdline_source)" || return 1
  log "kernel command line travels by: ${place}"

  if [[ "$place" == "builtin" ]]; then
    log "       nothing else carries it, so a change to it is a kernel rebuild"
  else
    log "       efibootmgr -v prints it, and the firmware's boot menu can point at another entry"
  fi

  if ! boot_efistub_removable; then
    if [[ -z "$(boot_esp_device)" ]]; then
      err "No EFI system partition is known, and the NVRAM entry cannot be created without one"
      err "       step 20 records disk.esp_device in the state journal"
      err "       boot_removable = yes installs to \\EFI\\BOOT\\BOOTX64.EFI, which needs no entry"
      err "       example:  esp_device = /dev/nvme0n1p1"
      return 1
    fi
    return 0
  fi

  # From here on, boot_removable is yes: the firmware launches the file it
  # finds on the fallback path, and it launches it with no load options.
  if [[ "$place" != "builtin" ]]; then
    err "boot_removable = yes leaves nowhere to put the kernel command line"
    err "       the fallback path \\EFI\\BOOT\\BOOTX64.EFI is launched with no load options at all"
    err "       efistub_cmdline = builtin  compile it in, with kernel = manual and kernel_embed_cmdline = yes"
    err "       boot_removable = no        keep the NVRAM entry, which is what carries the line"
    err "       example:  --efistub-cmdline builtin"
    return 1
  fi
  if boot_efistub_needs_initramfs; then
    err "boot_removable = yes cannot hand the kernel an initramfs either"
    err "       initrd= is a load option too, and the fallback path is launched without any"
    err "       crypt = $(target_crypt) and topology = $(target_topology) cannot reach the root without one"
    err "       boot_removable = no  the NVRAM entry carries initrd= and the command line"
    err "       bootloader = grub    if this machine forgets NVRAM entries, which is what removable is for"
    err "       example:  --bootloader grub"
    return 1
  fi
  warn "boot_removable = yes: no initrd= can be passed, so the kernel reaches its root on its own"
  warn "       an initramfs on the ESP would be copied and never loaded"
}

boot_efistub_packages() {
  # There is no bootloader to install, so there is no bootloader package. What
  # is needed is efibootmgr, and it is needed twice: here, on the host, to
  # write the NVRAM entry — the firmware whose NVRAM this is, is this machine's
  # — and later in the target, to read and repair that entry after the reboot.
  # Args: $1 = target root, $2 = firmware.
  local root="$1" firmware="$2"
  [[ "$firmware" == "uefi" ]] || return 0

  if boot_efistub_removable; then
    skip "boot_removable = yes: no NVRAM entry is created, so efibootmgr is not required"
    return 0
  fi

  if ! have efibootmgr; then
    warn "efibootmgr is not installed on this machine"
    warn "       sys-boot/efibootmgr provides it, and the NVRAM entry is written from here"
    warn "       without it the image lands on the ESP and nothing points the firmware at it"
  fi

  if kernel_pkg_installed "$root" "sys-boot/efibootmgr"; then
    skip "sys-boot/efibootmgr already installed"
    return 0
  fi
  kernel_emerge "$root" "sys-boot/efibootmgr"
}

boot_efistub_write_images() {
  # Copy — and sign, when a key pair was given — what the firmware will launch.
  # Args: $1 = target root.
  local root="$1" esp record version image initrd dest_efi dest_initrd
  esp="$(boot_esp_dir "$root")"

  record="$(kernel_installed "$root")" || return 1
  IFS=$'\t' read -r version image initrd <<<"$record"

  dest_efi="${esp}$(boot_efistub_efi_name)"
  log "EFI stub: ${image} -> ${dest_efi}"
  boot_install_efi "${root%/}${image}" "$dest_efi" || return 1

  if [[ -z "$initrd" ]]; then
    if boot_efistub_needs_initramfs; then
      err "No initramfs for kernel ${version} under ${root%/}/boot"
      err "       crypt = $(target_crypt) and topology = $(target_topology) cannot reach the root without one"
      err "       dracut --force --kver ${version} inside the chroot builds it"
      err "       example:  ./gentoo-install.sh --steps 70,80"
      return 1
    fi
    warn "no initramfs for ${version}; the kernel must carry the drivers for its root itself"
    return 0
  fi

  if boot_efistub_removable; then
    skip "boot_removable = yes: the initramfs is not copied, because no initrd= can point at it"
    return 0
  fi

  # The initramfs is not a PE binary and cannot be signed. Under Secure Boot
  # the firmware therefore vouches for the kernel and for nothing that comes
  # after it; a unified kernel image is the answer to that, and this variant
  # does not build one.
  dest_initrd="${esp}$(boot_efistub_initrd_name)"
  boot_copy_to_esp "${root%/}${initrd}" "$dest_initrd" || return 1
}

boot_efistub_run_install() {
  # The whole of "installing" this bootloader: one NVRAM entry, whose load
  # options are the only channel the kernel has to the outside world.
  # Args: $1 = target root, $2 = firmware.
  local root="$1" esp_device label loader place record version image initrd
  local options=""

  if boot_efistub_removable; then
    skip "boot_removable = yes: the firmware finds \\EFI\\BOOT\\BOOTX64.EFI on its own, no entry is created"
    return 0
  fi

  record="$(kernel_installed "$root")" || return 1
  IFS=$'\t' read -r version image initrd <<<"$record"
  place="$(boot_efistub_cmdline_source)" || return 1
  label="$(boot_label)"
  loader="$(boot_efistub_efi_name)"
  esp_device="$(boot_esp_device)"

  # initrd= goes in whatever carries the command line: the EFI stub reads it
  # from the load options and from nowhere else, so it is required even when
  # CONFIG_CMDLINE owns the rest of the line.
  if [[ -n "$initrd" ]]; then
    options="initrd=$(boot_efi_path "$(boot_efistub_initrd_name)")"
  fi
  if [[ "$place" == "efibootmgr" ]]; then
    local cmdline
    cmdline="$(kernel_cmdline)" || return 1
    options="${options:+${options} }${cmdline}"
  fi

  # boot_create_entry says what it did, including the one case where it does
  # nothing: no efibootmgr here means no entry, and claiming one was made would
  # be a line in the log that the next reboot contradicts.
  boot_create_entry "$esp_device" "$label" "$loader" "$options"
}

boot_efistub_verify() {
  # Args: $1 = target root, $2 = firmware.
  local root="${1%/}" label esp efi_file initrd_file place record
  local version image initrd

  if [[ "$DRY_RUN" == "yes" ]]; then
    log "dry-run: would check the EFI binary, its signature, the kernel configuration and the NVRAM entry"
    return 0
  fi

  label="$(boot_label)"
  esp="$(boot_esp_dir "$root")"
  efi_file="${esp}$(boot_efistub_efi_name)"
  place="$(boot_efistub_cmdline_source)" || return 1

  record="$(kernel_installed "$root")" || return 1
  IFS=$'\t' read -r version image initrd <<<"$record"

  boot_require_file "$efi_file" "EFI stub kernel" || return 1
  if [[ ! -s "$efi_file" ]]; then
    err "${efi_file} is empty"
    err "       the copy or the signature produced a zero-length file"
    err "       ls -l ${efi_file} and rerun step 80"
    return 1
  fi
  if boot_efistub_is_efi_binary "$efi_file"; then
    ok "${efi_file}: starts with the PE magic, the firmware can execute it"
  else
    err "${efi_file} is not an EFI executable"
    err "       an x86_64 kernel built with CONFIG_EFI_STUB=y begins with 'MZ'; this one does not"
    err "       the firmware skips such an entry silently and falls through to the next one"
    err "       head -c 2 ${efi_file} | xxd shows what is actually there"
    return 1
  fi
  show_signature "$efi_file"

  if [[ -n "$initrd" ]] && ! boot_efistub_removable; then
    initrd_file="${esp}$(boot_efistub_initrd_name)"
    boot_require_file "$initrd_file" "initramfs on the ESP" || return 1
  fi

  boot_efistub_check_kernel_config "$root" "$version" "$place" || return 1

  if boot_efistub_removable; then
    ok "removable path: the firmware launches $(boot_efi_path "$(boot_efistub_efi_name)") with no entry"
    return 0
  fi

  # Same question as boot_create_entry asked before writing: an entry may only
  # be read back as this install's when this install was allowed to write one.
  # Without this the check demanded an entry that step 80 had deliberately not
  # written, and failed a correct install — the mirror image of the false pass
  # the other two variants gave, and the same cause.
  if ! disk_may_write_firmware_state "$(boot_disk)"; then
    skip "no NVRAM entry was written: ${label} would have named this machine's own"
    skip "       \\EFI\\BOOT\\BOOTX64.EFI carries the kernel instead"
    skip "       write the entry on the target itself, as step 80 printed it"
  elif have efibootmgr; then
    if boot_entry_exists "$label" "$(boot_efi_path "$(boot_efistub_efi_name)")"; then
      ok "NVRAM entry '${label}' points at the kernel"
    else
      err "no NVRAM entry names $(boot_efi_path "$(boot_efistub_efi_name)")"
      err "       with no loader and no entry, nothing on this machine starts the kernel"
      err "       efivarfs must be mounted and writable: mount -t efivarfs none /sys/firmware/efi/efivars"
      err "       efibootmgr -v lists what is there now"
      return 1
    fi
  else
    warn "efibootmgr is not installed here; the NVRAM entry could not be verified"
    warn "       sys-boot/efibootmgr provides it"
    warn "       check it from the target after the reboot: efibootmgr -v"
  fi
  show_boot_entries
}

boot_efistub_install() {
  # Args: $1 = target root, $2 = firmware.
  local root="$1" firmware="$2"

  # The dispatcher refuses this variant on a BIOS run before it gets here. The
  # check is repeated because the function is callable on its own, and because
  # "the caller already checked" is how an unchecked path is born.
  if [[ "$firmware" != "uefi" ]]; then
    err "bootloader = efistub needs UEFI firmware"
    err "       the EFI stub is launched by the firmware itself; a legacy BIOS has no ESP and no boot entries"
    err "       grub          the one that boots a BIOS machine, from a master boot record"
    err "       systemd-boot  also UEFI only, but with a menu"
    err "       example:  --bootloader grub"
    return 1
  fi

  boot_efistub_check_plan "$root" || return 1
  boot_efistub_packages "$root" "$firmware" || return 1
  boot_efistub_write_images "$root" || return 1
  boot_efistub_run_install "$root" "$firmware" || return 1
  boot_efistub_verify "$root" "$firmware"
}
