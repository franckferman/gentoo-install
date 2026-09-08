#!/usr/bin/env bash
#
# gentoo-install — bootloader variant: GRUB
# ----------------------------------------------------------------------------
# The default, because it is the one that boots everything: UEFI and legacy
# BIOS, an encrypted /boot, a root on LVM, a disk that also carries Windows.
# It is the largest of the three and the only one with a menu that can be
# edited from the keyboard when something is wrong, which is worth more on the
# first reboot than every byte it costs.
#
# The generated grub.cfg is written through grub-script-check, and rolled back
# if it is refused. grub-mkconfig produces a shell script; a machine that finds
# out at power-on that the script does not parse has no shell to fix it from.
#
# Usage:  sourced by steps/80_boot.sh   (bootloader = grub)
#
set -euo pipefail

if [[ -n "${_GI_BOOT_GRUB_LOADED:-}" ]]; then
  return 0
fi
_GI_BOOT_GRUB_LOADED=1

boot_grub_needs_cryptodisk() {
  # GRUB has to unlock the container itself only when what it must read — the
  # kernel, the initramfs, its own modules — lives inside it. With /boot on the
  # ESP or on its own plain partition it never sees the encryption at all, and
  # turning cryptodisk on there only adds a second passphrase prompt.
  local crypt boot_device
  crypt="$(target_crypt)"
  [[ "$crypt" != "none" ]] || return 1
  boot_device="$(target_fact boot_device disk.boot_device "")"
  [[ -z "$boot_device" ]] || return 1
  [[ "$(boot_firmware)" != "uefi" ]] || {
    # An ESP is FAT and cannot be inside LUKS, so with UEFI the kernel is
    # reachable unencrypted unless the operator deliberately put /boot elsewhere.
    local esp_is_boot
    esp_is_boot="$(target_esp_mount)"
    [[ "$esp_is_boot" == "/boot" ]] && return 1
    return 0
  }
  return 0
}

boot_grub_default_body() {
  # Renders /etc/default/grub's block; writes nothing.
  local cmdline timeout crypto="" preload=""
  cmdline="$(kernel_cmdline)" || return 1
  timeout="$(boot_timeout)"

  if boot_grub_needs_cryptodisk; then
    crypto="y"
  fi
  if [[ "$(target_topology)" == "lvm" ]]; then
    preload="lvm"
  fi
  if [[ -n "$crypto" ]]; then
    preload="${preload:+${preload} }cryptodisk luks2"
  fi

  cat <<EOF
GRUB_DISTRIBUTOR="Gentoo"
GRUB_TIMEOUT=${timeout}

# grub-mkconfig writes its own root= from grub-probe and then appends this
# line, so ours is the last root= on the kernel command line and the one the
# kernel keeps. That is deliberate: grub-probe run from inside a chroot has
# been known to name the installer's disk rather than the target's.
GRUB_CMDLINE_LINUX="${cmdline}"
EOF

  if [[ -n "$crypto" ]]; then
    cat <<'EOF'

# /boot is inside the LUKS container, so GRUB itself has to open it. This is
# the second passphrase prompt an encrypted machine shows: one for GRUB, one
# for the initramfs.
GRUB_ENABLE_CRYPTODISK=y
EOF
  fi

  if [[ -n "$preload" ]]; then
    printf 'GRUB_PRELOAD_MODULES="%s"\n' "$preload"
  fi

  cat <<'EOF'

# Conservative by default — what each one costs is named next to it.
#
# Look for other operating systems and add them to the menu. It mounts every
# filesystem it finds, including ones belonging to a machine you are only
# borrowing a disk from.
#GRUB_DISABLE_OS_PROBER=false
#
# Keep the menu on screen even when nothing else is installed.
#GRUB_TIMEOUT_STYLE=menu
EOF
}

boot_grub_packages() {
  # Args: $1 = target root, $2 = firmware.
  local root="$1" firmware="$2" platform
  if [[ "$firmware" == "uefi" ]]; then
    platform="grub_platforms_efi-64"
  else
    platform="grub_platforms_pc"
  fi

  # GRUB_PLATFORMS decides which of grub's targets are built at all. Merged
  # with the wrong one, grub-install has no target directory and says so in a
  # message that mentions neither USE flags nor this variable.
  kernel_write_package_use "$root" \
    "# GRUB builds only the platforms named here; grub-install needs the one" \
    "# this machine boots with." \
    "sys-boot/grub ${platform}" || return 1

  if kernel_pkg_installed "$root" "sys-boot/grub"; then
    skip "sys-boot/grub already installed"
  else
    kernel_emerge "$root" "sys-boot/grub" || return 1
  fi

  if [[ "$firmware" == "uefi" ]] && ! kernel_pkg_installed "$root" "sys-boot/efibootmgr"; then
    kernel_emerge "$root" "sys-boot/efibootmgr" || return 1
  fi
}

boot_grub_write_default() {
  # Args: $1 = target root.
  local root="$1" target="${1%/}/etc/default/grub" body
  body="$(boot_grub_default_body)" || return 1
  # A marked block: /etc/default/grub belongs to sys-boot/grub and carries the
  # distribution's own comments. A rerun replaces our block and leaves the rest.
  # Here-string, never a pipe: the writers record the backup they take, and a
  # subshell would carry that record away with it.
  write_block "$target" "grub defaults" <<<"$body"
}

boot_grub_removable() {
  # \EFI\BOOT\BOOTX64.EFI, the path a firmware tries with no NVRAM entry to
  # guide it. One predicate, so that what grub-install is asked to do and what
  # is checked afterwards cannot disagree.
  [[ "$(target_fact boot_removable "" "no")" == "yes" ]]
}

boot_grub_run_install() {
  # Args: $1 = target root, $2 = firmware.
  local root="$1" firmware="$2" esp_mount label disk nvram="yes"
  local -a argv=()

  label="$(boot_label)"

  if [[ "$firmware" == "uefi" ]]; then
    esp_mount="$(target_esp_mount)"
    if [[ ! -d "${root%/}${esp_mount}" && "$DRY_RUN" != "yes" ]]; then
      err "The EFI system partition is not mounted at ${esp_mount} inside ${root}"
      err "       grub-install writes into it and cannot create it"
      err "       mount the ESP there first, or set esp_mount to where it is"
      err "       example:  esp_mount = /boot/efi"
      return 1
    fi
    argv=(grub-install --target=x86_64-efi "--efi-directory=${esp_mount}" "--bootloader-id=${label}")
    if boot_grub_removable; then
      # \EFI\BOOT\BOOTX64.EFI is the path firmware falls back to with no NVRAM
      # entry. It is also the path another operating system's installer uses,
      # so writing it replaces whatever was there.
      argv+=(--removable)
    fi

    # grub-install writes an NVRAM entry itself, through the efivarfs it finds
    # in the chroot — and step 50 binds this machine's /sys into the target, so
    # on a UEFI host that efivarfs is this machine's. The question of whether
    # firmware state may be touched at all is disk_may_write_firmware_state's,
    # and it is asked here for the same reason step 80 asks it before running
    # efibootmgr: an install to a loop image, on a working machine, replaced
    # that machine's own entry with a pointer to the loop device's ESP, and it
    # took a live USB to come back. The efistub path was routed through the
    # guard when that happened; grub and systemd-boot write their entries
    # through their own installers and were not.
    if ! disk_may_write_firmware_state "$(boot_disk)"; then
      warn "not letting grub-install write an NVRAM entry: $(boot_disk) is not the"
      warn "       disk this machine booted from, and this is not a live medium"
      warn "       the entry would name a disk the firmware may not find, over the"
      warn "       label this machine already uses"
      log "       write it yourself once the target is the machine being booted:"
      log "         grub-install --target=x86_64-efi --efi-directory=${esp_mount} --bootloader-id=${label}"
      argv+=(--no-nvram)
      nvram="no"
    fi
  else
    disk="$(boot_disk)"
    if [[ -z "$disk" ]]; then
      err "Legacy BIOS GRUB needs the disk to write the boot record to"
      err "       step 20 records disk.device in the state journal"
      err "       it is the whole disk, not a partition"
      err "       example:  boot_disk = /dev/sda"
      return 1
    fi
    argv=(grub-install --target=i386-pc "$disk")
  fi

  if ! have grub-install && [[ "$root" == "/" ]]; then
    err "grub-install is not installed"
    err "       sys-boot/grub provides it"
    return 1
  fi

  kernel_in_target "$root" "${argv[@]}" || {
    err "grub-install failed"
    err "       with UEFI it needs the ESP mounted and efivarfs available in the chroot"
    err "       mount -t efivarfs none ${root%/}/sys/firmware/efi/efivars makes NVRAM writable"
    return 1
  }
  ok "grub-install finished"

  # Without an entry the firmware has one way left to find a loader: the
  # removable path. Leaving the target with neither is how an install that
  # reported success produces a disk that drops straight to PXE.
  if [[ "$nvram" == "no" ]] && ! boot_grub_removable; then
    boot_install_removable_fallback "${root%/}${esp_mount}" \
      "/EFI/${label}/grubx64.efi" || return 1
  fi
}

boot_grub_check_cmdline() {
  # grub-mkconfig writes its own root= from grub-probe and then appends
  # GRUB_CMDLINE_LINUX, so the generated line carries two of them. The kernel
  # keeps the last, which is exactly why this project puts its own in
  # GRUB_CMDLINE_LINUX: grub-probe run from inside a chroot has been known to
  # name the installer's disk rather than the target's, and being second is
  # what makes ours the one that counts.
  #
  # That ordering is load-bearing and nothing checked it. Measured on a
  # custom-layout install, in the generated file:
  #
  #   linux /vmlinuz-… root=/dev/mapper/gi--vg0-root ro root=/dev/mapper/gi--vg0-root rootfstype=ext4 …
  #
  # grub's first, ours second. If grub's template ever appended
  # GRUB_CMDLINE_LINUX before its own root=, or if this project stopped
  # putting one there, the machine would boot from whatever grub-probe
  # guessed and nothing would say so.
  # Args: $1 = the grub.cfg to read.
  local cfg="$1" ours line last
  ours="$(kernel_cmdline | tr ' ' '\n' | grep -m1 '^root=' || true)"
  if [[ -z "$ours" ]]; then
    warn "this run composed no root=; grub-probe's answer is the only one"
    warn "       grep -m1 linux ${cfg}   shows what the kernel will be given"
    return 0
  fi

  line="$(grep -m1 -E '^[[:space:]]*linux[[:space:]]' "$cfg" 2>/dev/null || true)"
  if [[ -z "$line" ]]; then
    warn "no linux line in ${cfg}; the root= ordering could not be checked"
    return 0
  fi

  # shellcheck disable=SC2020  # character for character is what is wanted: a
  # space and a tab each become a newline, which is how the line gets split.
  # `|| true`: a linux line with no root= on it at all is the case this check
  # exists to catch, and under set -o pipefail the failing grep would take the
  # whole run down instead of reporting it.
  last="$(printf '%s\n' "$line" | tr ' \t' '\n\n' | grep '^root=' | tail -n 1 || true)"
  if [[ "$last" == "$ours" ]]; then
    ok "grub.cfg: the kernel is given ${ours} last, which is the one it keeps"
    return 0
  fi

  err "grub.cfg gives the kernel ${last:-no root= at all} last, not ${ours}"
  err "       grub-mkconfig writes its own root= and then appends"
  err "       GRUB_CMDLINE_LINUX, so ours has to come second to win"
  err "       grub-probe from inside a chroot has named the installer's disk"
  err "       grep -m1 linux ${cfg}"
  err "       example:  ./gentoo-install.sh --steps 80"
  return 1
}

boot_grub_script_checker() {
  # The argv that will read the generated grub.cfg, one word per line, or
  # nothing when no machine here has the tool. The target first, the host only
  # as a fallback.
  #
  # grub-script-check belongs to sys-boot/grub, which boot_grub_packages has
  # just installed *in the target*. This asked `have`, which looks at the
  # installer's own PATH, and a live medium need not carry grub at all — so the
  # one check this whole function exists for was skipped with a warning, and the
  # generated script went in unread. That it never showed up here is the
  # giveaway: this is a Gentoo box with grub installed, so every run took the
  # checked path. Same shape as the lsinitrd check that existed and never ran,
  # and fixed the same way: ask the machine that has the tool.
  #
  # Args: $1 = target root, $2 = the config as this machine sees it.
  local root="${1%/}" cfg="$2"

  if [[ -n "$root" && "$root" != "/" ]] \
    && chroot "$root" grub-script-check --version >/dev/null 2>&1; then
    printf '%s\n' chroot "$root" grub-script-check "/boot/grub/grub.cfg"
    return 0
  fi
  if have grub-script-check; then
    printf '%s\n' grub-script-check "$cfg"
    return 0
  fi
  return 0
}

boot_grub_write_config() {
  # grub-mkconfig writes a shell script. grub-script-check is the only thing
  # standing between a mistake in it and a machine that stops at a rescue
  # prompt, so the generated file is checked before it replaces the old one.
  # Args: $1 = target root.
  local root="${1%/}" cfg="${1%/}/boot/grub/grub.cfg"
  local staged="${1%/}/boot/grub/grub.cfg.gentoo-install-new"

  if [[ "$DRY_RUN" == "yes" ]]; then
    log "dry-run: would run grub-mkconfig and check it with grub-script-check before installing it"
    return 0
  fi

  run_cmd mkdir -p -- "${root}/boot/grub" || return 1
  track_temp "$staged"

  kernel_in_target "$1" grub-mkconfig -o "/boot/grub/grub.cfg.gentoo-install-new" || {
    err "grub-mkconfig failed"
    err "       it reads /etc/default/grub and everything in /etc/grub.d"
    err "       run it inside the chroot to see which script objected"
    rm -f -- "$staged"
    return 1
  }

  if [[ ! -s "$staged" ]]; then
    err "grub-mkconfig produced nothing at ${staged}"
    rm -f -- "$staged"
    return 1
  fi

  local -a checker=()
  mapfile -t checker < <(boot_grub_script_checker "$root" "$cfg")

  if ((${#checker[@]} > 0)); then
    write_validated "$cfg" "${checker[@]}" <"$staged" || {
      rm -f -- "$staged"
      return 1
    }
  else
    warn "grub-script-check is in neither ${root} nor this machine"
    warn "       the generated grub.cfg goes in unread, and a script that does"
    warn "       not parse is found out at power-on, with no shell to fix it from"
    warn "       sys-boot/grub provides it; step 80 installs that in the target"
    write_file "$cfg" <"$staged" || {
      rm -f -- "$staged"
      return 1
    }
  fi
  rm -f -- "$staged"
}

boot_grub_verify() {
  # Args: $1 = target root, $2 = firmware.
  local root="${1%/}" firmware="$2" cfg="${1%/}/boot/grub/grub.cfg" label esp
  local efi_file

  if [[ "$DRY_RUN" == "yes" ]]; then
    log "dry-run: would check grub.cfg, the EFI binary and the NVRAM entry"
    return 0
  fi

  boot_require_file "$cfg" "grub configuration" || return 1

  # The same question as the writer asks, and it was asked the same wrong way
  # here: of the host. A live medium without grub then verified nothing and
  # said nothing, three lines after the writer had done the same.
  local -a checker=()
  mapfile -t checker < <(boot_grub_script_checker "$root" "$cfg")
  if ((${#checker[@]} > 0)); then
    if ! "${checker[@]}" >/dev/null 2>&1; then
      err "${cfg} does not parse"
      err "       $(_cmdline "${checker[@]}") points at the line"
      return 1
    fi
  else
    warn "grub-script-check is in neither ${root} nor this machine"
    warn "       whether ${cfg} parses has not been established"
  fi

  if ! grep -q '^menuentry' "$cfg"; then
    err "${cfg} contains no menu entry"
    err "       /etc/grub.d/10_linux finds kernels in /boot; there is none it recognised"
    err "       ls ${root}/boot shows what is actually there"
    return 1
  fi
  ok "grub.cfg parses and has $(grep -c '^menuentry' "$cfg") menu entry/entries"
  boot_grub_check_cmdline "$cfg" || return 1

  if [[ "$firmware" != "uefi" ]]; then
    ok "legacy BIOS: the boot record on $(boot_disk) is what starts GRUB"
    return 0
  fi

  label="$(boot_label)"
  esp="$(boot_esp_dir "$root")"

  # Where grub-install was told to put the binary. --removable writes the
  # firmware's fallback path and creates no NVRAM entry at all, which is the
  # whole reason to ask for it; checking the other path anyway called a correct
  # install broken — grub-install had just reported success and BOOTX64.EFI was
  # sitting on the ESP.
  if boot_grub_removable; then
    efi_file="${esp}/EFI/BOOT/BOOTX64.EFI"
  else
    efi_file="${esp}/EFI/${label}/grubx64.efi"
  fi
  boot_require_file "$efi_file" "GRUB EFI binary" || return 1
  show_signature "$efi_file"

  if boot_grub_removable; then
    ok "removable path: the firmware starts \\EFI\\BOOT\\BOOTX64.EFI with no entry"
  elif ! disk_may_write_firmware_state "$(boot_disk)"; then
    # The NVRAM efibootmgr reads is the NVRAM of the machine it runs on, and
    # that is only the target when the guard says so. Asking anyway made this
    # check answer about the host: boot_label defaults to 'gentoo', a Gentoo
    # workstation has an entry of exactly that name, and an install to a loop
    # image was told "NVRAM entry 'gentoo' points at the GRUB binary" about the
    # entry the host itself boots from.
    skip "no NVRAM entry was written, and this machine's own is not this install's"
    skip "       \\EFI\\BOOT\\BOOTX64.EFI was written instead and needs no entry"
    skip "       grub-install writes the entry when run on the target itself"
  elif have efibootmgr; then
    if boot_entry_exists "$label" "$(boot_efi_path "/EFI/${label}/grubx64.efi")"; then
      ok "NVRAM entry '${label}' points at the GRUB binary"
    else
      warn "no NVRAM entry names \\EFI\\${label}\\grubx64.efi"
      warn "       grub-install creates it; efivarfs may not have been writable in the chroot"
      warn "       boot_removable = yes installs to \\EFI\\BOOT\\BOOTX64.EFI instead, which needs no entry"
    fi
  fi
  show_boot_entries
}

boot_grub_install() {
  # Args: $1 = target root, $2 = firmware.
  local root="$1" firmware="$2" label
  label="$(boot_label)"

  boot_grub_packages "$root" "$firmware" || return 1
  boot_grub_write_default "$root" || return 1
  boot_grub_run_install "$root" "$firmware" || return 1

  # Signing GRUB's own binary is only half an answer: GRUB then loads modules
  # and a configuration that are not signed, so a machine in Secure Boot needs
  # a shim or its own enrolled key either way. It is offered because it is what
  # an operator with an enrolled key expects, and it is said plainly here.
  if [[ "$firmware" == "uefi" ]] && boot_secureboot_ready; then
    local esp efi_file
    esp="$(boot_esp_dir "$root")"
    # The same path grub-install was asked for: signing the one it did not write
    # would leave the binary the firmware actually starts unsigned.
    if boot_grub_removable; then
      efi_file="${esp}/EFI/BOOT/BOOTX64.EFI"
    else
      efi_file="${esp}/EFI/${label}/grubx64.efi"
    fi
    if [[ -f "$efi_file" || "$DRY_RUN" == "yes" ]]; then
      boot_install_efi "$efi_file" "$efi_file" || return 1
    fi
  fi

  boot_grub_write_config "$root" || return 1
  boot_grub_verify "$root" "$firmware"
}
