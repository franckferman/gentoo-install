#!/usr/bin/env bash
#
# gentoo-install — kernel variant: the Gentoo distribution kernel
# ----------------------------------------------------------------------------
# The default, and the one a first Gentoo install should get: portage installs
# a kernel the way it installs anything else, sys-kernel/installkernel runs
# dracut against the configuration step 70 has already written, and the machine
# boots. sys-kernel/gentoo-kernel-bin is prebuilt — minutes, not hours — and
# sys-kernel/gentoo-kernel builds the same configuration from source for anyone
# who would rather compile.
#
# It also updates itself: `emerge -uDN @world` brings a new kernel and a new
# initramfs with it, which none of the other two variants do.
#
# Usage:  sourced by steps/70_kernel.sh   (kernel = dist-kernel)
#
set -euo pipefail

if [[ -n "${_GI_KERNEL_DIST_LOADED:-}" ]]; then
  return 0
fi
_GI_KERNEL_DIST_LOADED=1

kernel_dist_package() {
  # binary is the default: it is what makes this variant the beginner's answer.
  local build
  build="$(target_fact kernel_build kernel.build "binary")"
  case "$build" in
    binary) printf '%s\n' "sys-kernel/gentoo-kernel-bin" ;;
    source) printf '%s\n' "sys-kernel/gentoo-kernel" ;;
    *)
      err "Unknown kernel build mode: ${build}"
      err "       binary  sys-kernel/gentoo-kernel-bin, prebuilt by Gentoo, installs in minutes"
      err "       source  sys-kernel/gentoo-kernel, the same configuration compiled here"
      err "       example:  kernel_build = binary"
      return 1
      ;;
  esac
}

kernel_dist_kernel_build() {
  # Args: $1 = target root.
  local root="$1" package firmware

  package="$(kernel_dist_package)" || return 1

  # installkernel is what runs dracut when the kernel package is merged. Without
  # the dracut USE flag the kernel lands in /boot with no initramfs beside it,
  # and an encrypted machine has nothing to open its container with.
  kernel_write_package_use "$root" \
    "# The kernel package installs through installkernel; dracut is what turns" \
    "# the dracut.conf.d written by step 70 into an actual initramfs." \
    "sys-kernel/installkernel dracut" || return 1

  if ! kernel_pkg_installed "$root" "sys-kernel/installkernel"; then
    kernel_emerge "$root" "sys-kernel/installkernel" || return 1
  else
    skip "sys-kernel/installkernel already installed"
  fi

  kernel_ensure_crypt_packages "$root" || return 1

  # Safe by default: without firmware a laptop boots and then has no wireless,
  # no GPU acceleration and no obvious reason why. It needs a linux-fw-redistributable
  # licence acceptance, which step 60 owns; the failure names it clearly enough.
  firmware="$(target_fact kernel_firmware "" "yes")"
  if [[ "$firmware" == "yes" ]]; then
    if kernel_pkg_installed "$root" "sys-kernel/linux-firmware"; then
      skip "sys-kernel/linux-firmware already installed"
    elif ! kernel_emerge "$root" "sys-kernel/linux-firmware"; then
      warn "sys-kernel/linux-firmware did not install"
      warn "       it needs ACCEPT_LICENSE to allow @BINARY-REDISTRIBUTABLE"
      warn "       the system will boot; wireless and graphics may not work"
      warn "       set kernel_firmware = no to stop trying"
    fi
  else
    skip "linux-firmware not requested (kernel_firmware=no)"
  fi

  if kernel_pkg_installed "$root" "$package" && [[ "$DRY_RUN" != "yes" ]] \
    && kernel_installed "$root" >/dev/null 2>&1; then
    skip "${package} already installed and /boot holds a kernel"
    return 0
  fi

  kernel_emerge "$root" "$package" || {
    err "${package} failed to install"
    err "       emerge --info in the chroot shows the profile and USE flags in force"
    err "       kernel_build = source compiles the same configuration if the binary package will not fetch"
    return 1
  }

  # A merge that already happened is a no-op, and this package deploys /boot from
  # its postinst — so a first attempt that failed there leaves the package
  # installed and /boot empty, and every later run emerges nothing and then finds
  # nothing. That is not a corner case: a dracut module that will not build is
  # enough, and it is exactly what a --resume after such a failure walks into.
  # The ebuild names the way out itself.
  if [[ "$DRY_RUN" != "yes" ]] && ! kernel_installed "$root" >/dev/null 2>&1; then
    warn "${package} is installed but deployed no kernel image"
    warn "       /boot is written by its postinst, and that did not finish"
    log "re-running the deployment: emerge --config ${package}"
    if ! kernel_in_target "$root" emerge --config "$package"; then
      err "emerge --config ${package} deployed no kernel either"
      err "       the initramfs is the usual reason; the dracut lines above name the module"
      err "       kernel_build = source compiles the same configuration instead"
      return 1
    fi
    ok "deployment re-run: ${package}"
  fi

  # The dist kernel is signed by Gentoo's own key. That key is not enrolled in
  # most firmware, so it is not a Secure Boot answer on its own — step 80 signs
  # with the operator's key when one is given, and says so when none is.
  ok "distribution kernel installed: ${package}"
}
