#!/usr/bin/env bash
#
# gentoo-install — kernel variant: your own sources, your own .config
# ----------------------------------------------------------------------------
# For the operator who knows what they want in the kernel. This variant fetches
# the sources, puts a .config in place — one you supply, or the running
# kernel's, or a defconfig — and compiles it. It refuses to invent a
# configuration out of nothing: a kernel built from a guess is a machine that
# boots to a blinking cursor.
#
# What it does insist on is the handful of options without which the rest of
# the install cannot work: device-mapper for a LUKS root, the EFI stub when the
# firmware is meant to launch the kernel directly. Those are set with the
# kernel tree's own scripts/config and then re-resolved by make olddefconfig,
# not by sed-ing .config and hoping the dependencies agree.
#
# Usage:  sourced by steps/70_kernel.sh   (kernel = manual)
#
set -euo pipefail

if [[ -n "${_GI_KERNEL_MANUAL_LOADED:-}" ]]; then
  return 0
fi
_GI_KERNEL_MANUAL_LOADED=1

kernel_manual_required_options() {
  # One "NAME=value" per line; prints and changes nothing, so the list can be
  # read without a kernel tree in sight.
  local crypt layout
  crypt="$(target_crypt)"
  layout="$(target_layout)"

  printf '%s\n' "CONFIG_BLK_DEV_INITRD=y"

  if [[ "$crypt" != "none" || "$layout" == "lvm" ]]; then
    printf '%s\n' "CONFIG_MD=y"
    printf '%s\n' "CONFIG_BLK_DEV_DM=y"
  fi

  if [[ "$crypt" != "none" ]]; then
    # cryptsetup needs the algorithms in the kernel and the user-space crypto
    # API to reach them; a LUKS2 header with argon2 also needs a random source.
    printf '%s\n' "CONFIG_DM_CRYPT=y"
    printf '%s\n' "CONFIG_CRYPTO_AES=y"
    printf '%s\n' "CONFIG_CRYPTO_XTS=y"
    printf '%s\n' "CONFIG_CRYPTO_SHA256=y"
    printf '%s\n' "CONFIG_CRYPTO_USER_API_SKCIPHER=y"
  fi

  if [[ "$crypt" == "tpm" ]]; then
    printf '%s\n' "CONFIG_TCG_TPM=y"
    printf '%s\n' "CONFIG_TCG_CRB=y"
    printf '%s\n' "CONFIG_HW_RANDOM_TPM=y"
  fi

  if [[ "$(target_fact bootloader boot.variant "grub")" == "efistub" ]]; then
    # Without the stub the firmware has a file it cannot execute, and the only
    # symptom is an EFI entry that silently falls through to the next one.
    printf '%s\n' "CONFIG_EFI=y"
    printf '%s\n' "CONFIG_EFI_STUB=y"
  fi
}

kernel_manual_place_config() {
  # Args: $1 = target root, $2 = kernel source directory as the target sees it.
  # Prints nothing; says which of the four sources it used.
  local root="$1" src="$2"
  # Split: ${root} is not bound yet in the same local (SC2318).
  local host_src="${root%/}${2}" want
  want="$(target_fact kernel_config "" "")"

  if [[ -n "$want" && "$want" != "defconfig" && "$want" != "running" ]]; then
    if [[ ! -r "$want" ]]; then
      err "Cannot read the kernel configuration: ${want}"
      err "       kernel_config takes a path to a .config, or one of two words"
      err "       defconfig  the architecture's default configuration"
      err "       running    /proc/config.gz, the configuration of the kernel running now"
      err "       example:  --kernel-config /root/.config"
      return 1
    fi
    log "kernel .config from ${want}"
    run_cmd cp -- "$want" "${host_src}/.config"
    return 0
  fi

  if [[ "$want" == "defconfig" ]]; then
    log "kernel .config from make defconfig"
    kernel_in_target "$root" make -C "$src" defconfig
    return 0
  fi

  if [[ "$want" == "running" ]]; then
    if [[ ! -r /proc/config.gz ]]; then
      err "kernel_config = running, but /proc/config.gz is not readable"
      err "       the running kernel was built without CONFIG_IKCONFIG_PROC"
      err "       give a path instead, or use defconfig"
      err "       example:  --kernel-config /boot/config-6.12.0"
      return 1
    fi
    log "kernel .config from /proc/config.gz"
    if [[ "$DRY_RUN" == "yes" ]]; then
      log "dry-run: would expand /proc/config.gz into ${host_src}/.config"
    else
      zcat /proc/config.gz >"${host_src}/.config"
    fi
    return 0
  fi

  if [[ -f "${host_src}/.config" ]]; then
    skip "kernel .config already present in ${src}"
    return 0
  fi

  err "No kernel configuration to build from"
  err "       kernel = manual does not invent one: a guessed .config boots to nothing"
  err "       kernel_config = /path/to/.config   a configuration you already trust"
  err "       kernel_config = running            /proc/config.gz of the kernel running now"
  err "       kernel_config = defconfig          the architecture default, then adjusted below"
  err "       example:  --kernel-config running"
  return 1
}

kernel_manual_apply_options() {
  # scripts/config ships with the kernel tree and knows about dependencies;
  # sed-ing .config sets a symbol whose prerequisites are still off, and make
  # silently drops it again. Args: $1 = target root, $2 = source directory.
  local root="$1" src="$2"
  # Split: ${root} is not bound yet in the same local (SC2318).
  local host_src="${root%/}${2}" entry name value
  local -a options=()
  mapfile -t options < <(kernel_manual_required_options)
  ((${#options[@]} > 0)) || return 0

  if [[ ! -x "${host_src}/scripts/config" && "$DRY_RUN" != "yes" ]]; then
    warn "no scripts/config in ${src}; the required options are not being enforced"
    for entry in "${options[@]}"; do
      warn "       set by hand: ${entry}"
    done
    return 0
  fi

  for entry in "${options[@]}"; do
    name="${entry%%=*}"
    value="${entry#*=}"
    case "$value" in
      y) kernel_in_target "$root" "${src}/scripts/config" --file "${src}/.config" --enable "$name" ;;
      n) kernel_in_target "$root" "${src}/scripts/config" --file "${src}/.config" --disable "$name" ;;
      *) kernel_in_target "$root" "${src}/scripts/config" --file "${src}/.config" --set-str "$name" "$value" ;;
    esac
  done

  if [[ "$(target_fact kernel_embed_cmdline "" "no")" == "yes" ]]; then
    # The internal installer this module is drawn from bakes the command line
    # into the image, so the EFI stub needs nothing from the firmware's load
    # options. It also means a change to the command line is a kernel rebuild.
    local line
    line="$(kernel_cmdline)" || return 1
    kernel_in_target "$root" "${src}/scripts/config" --file "${src}/.config" --enable CONFIG_CMDLINE_BOOL
    kernel_in_target "$root" "${src}/scripts/config" --file "${src}/.config" --set-str CONFIG_CMDLINE "$line"
    ok "command line embedded in the kernel image"
  fi

  # scripts/config writes the symbol and nothing else; olddefconfig is what
  # turns it into a configuration the build agrees with.
  kernel_in_target "$root" make -C "$src" olddefconfig
}

kernel_manual_build() {
  # Args: $1 = target root.
  local root="$1" src sources jobs version
  sources="$(target_fact kernel_sources "" "sys-kernel/gentoo-sources")"
  src="$(target_fact kernel_source_dir "" "/usr/src/linux")"

  if ! kernel_pkg_installed "$root" "$sources"; then
    kernel_emerge "$root" "$sources" || return 1
  else
    skip "${sources} already installed"
  fi

  kernel_ensure_crypt_packages "$root" || return 1

  if [[ ! -d "${root%/}${src}" && "$DRY_RUN" != "yes" ]]; then
    err "No kernel sources at ${src} inside ${root}"
    err "       eselect kernel list shows what is unpacked"
    err "       eselect kernel set 1 points ${src} at it"
    err "       example:  --kernel-source-dir /usr/src/linux-6.12.0-gentoo"
    return 1
  fi

  kernel_manual_place_config "$root" "$src" || return 1
  kernel_manual_apply_options "$root" "$src" || return 1

  jobs="$(kernel_nproc)"
  log "compiling with -j${jobs}; this is the long part"
  kernel_in_target "$root" make -C "$src" "-j${jobs}" || {
    err "the kernel did not compile"
    err "       the last lines of the build name the file and the symbol"
    err "       make -C ${src} 2>&1 | tail -40 inside the chroot reproduces it"
    return 1
  }
  kernel_in_target "$root" make -C "$src" modules_install || return 1
  kernel_in_target "$root" make -C "$src" install || return 1

  # make install copies the image and nothing else. Without this the machine
  # has a kernel and no way to open its root.
  if [[ "$DRY_RUN" == "yes" ]]; then
    log "dry-run: would run dracut against the configuration written above"
    return 0
  fi

  version="$(kernel_in_target "$root" make -C "$src" -s kernelrelease 2>/dev/null | tail -n 1)"
  if [[ -z "$version" ]]; then
    err "cannot determine the kernel release from ${src}"
    err "       make -C ${src} -s kernelrelease prints it"
    return 1
  fi
  state_set kernel.version "$version"

  if [[ -f "${root%/}/boot/initramfs-${version}.img" ]] \
    && [[ "${root%/}/boot/initramfs-${version}.img" -nt "${root%/}/boot/vmlinuz-${version}" ]]; then
    skip "initramfs for ${version} is newer than the image it goes with"
  else
    kernel_in_target "$root" dracut --force --kver "$version" "/boot/initramfs-${version}.img" || {
      err "dracut could not build the initramfs for ${version}"
      err "       dracut --force --kver ${version} inside the chroot shows why"
      return 1
    }
  fi

  ok "kernel ${version} built and installed"
}
