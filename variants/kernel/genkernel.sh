#!/usr/bin/env bash
#
# gentoo-install — kernel variant: genkernel
# ----------------------------------------------------------------------------
# For the operator who wants the kernel compiled here but does not want to
# answer nine hundred configuration questions. genkernel starts from a working
# configuration, builds the kernel and builds its own initramfs.
#
# The thing to know before touching this file: genkernel does not use dracut.
# Its initramfs reads crypt_root=, root_key= and dolvm, where dracut reads
# rd.luks.uuid= and rd.luks.key=. Step 70 composes the right dialect because
# kernel_initramfs_generator() tells it which one to speak — and neither
# dialect includes clevis, which is why the TPM variant is refused here rather
# than discovered at the first reboot.
#
# Usage:  sourced by steps/70_kernel.sh   (kernel = genkernel)
#
set -euo pipefail

if [[ -n "${_GI_KERNEL_GENKERNEL_LOADED:-}" ]]; then
  return 0
fi
_GI_KERNEL_GENKERNEL_LOADED=1

kernel_genkernel_args() {
  # Renders the argument list, one per line; runs nothing. The crypt variant
  # and the layout are what decide it, exactly as for the command line.
  # Takes no argument: it reads the same facts every other composer reads.
  local crypt layout config jobs
  crypt="$(target_crypt)"
  layout="$(target_topology)"

  printf '%s\n' "--bootdir=/boot"
  printf '%s\n' "--no-mountboot"

  jobs="$(kernel_nproc)"
  printf -- '--makeopts=-j%s\n' "$jobs"

  if [[ "$crypt" != "none" ]]; then
    # Without --luks the initramfs has no cryptsetup in it at all.
    printf '%s\n' "--luks"
  fi
  if [[ "$crypt" == "keyfile" ]]; then
    # genkernel's own support for a GnuPG-sealed LUKS key, which is what the
    # keyfile variant produces.
    printf '%s\n' "--gpg"
  fi
  if [[ "$layout" == "lvm" ]]; then
    printf '%s\n' "--lvm"
  fi

  config="$(target_fact kernel_config "" "")"
  if [[ -n "$config" && "$config" != "defconfig" ]]; then
    printf -- '--kernel-config=%s\n' "$config"
  fi

  if [[ "$(target_fact kernel_menuconfig "" "no")" == "yes" ]]; then
    printf '%s\n' "--menuconfig"
  fi

  if [[ "$(target_fact kernel_firmware "" "yes")" == "yes" ]]; then
    # Firmware in the initramfs, for a machine whose disk controller needs it
    # before there is a root filesystem to load it from.
    printf '%s\n' "--firmware"
  fi
}

kernel_genkernel_build() {
  # Args: $1 = target root.
  local root="$1" crypt
  local -a args=()

  crypt="$(target_crypt)"

  if [[ "$crypt" == "tpm" ]]; then
    err "crypt=tpm cannot be built with genkernel"
    err "       clevis and clevis-pin-tpm2 are dracut modules; genkernel builds its own initramfs"
    err "       kernel = dist-kernel  installs a kernel and lets dracut build the initramfs"
    err "       kernel = manual       compiles your own sources, initramfs still by dracut"
    err "       example:  --kernel dist-kernel"
    return 1
  fi

  if ! kernel_pkg_installed "$root" "sys-kernel/genkernel"; then
    kernel_emerge "$root" "sys-kernel/genkernel" || return 1
  else
    skip "sys-kernel/genkernel already installed"
  fi

  if ! kernel_pkg_installed "$root" "sys-kernel/gentoo-sources"; then
    kernel_emerge "$root" "sys-kernel/gentoo-sources" || return 1
  else
    skip "sys-kernel/gentoo-sources already installed"
  fi

  kernel_ensure_crypt_packages "$root" || return 1
  kernel_select_sources "$root" /usr/src/linux genkernel || return 1

  mapfile -t args < <(kernel_genkernel_args)

  log "genkernel all ${args[*]}"
  kernel_in_target "$root" genkernel "${args[@]}" all || {
    err "genkernel failed"
    err "       its log is /var/log/genkernel.log inside the target"
    err "       --kernel-config <file> starts it from a configuration you know builds"
    return 1
  }

  ok "genkernel finished"
}
