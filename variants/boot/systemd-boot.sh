#!/usr/bin/env bash
#
# gentoo-install — bootloader variant: systemd-boot
# ----------------------------------------------------------------------------
# A small UEFI loader whose menu is a directory listing: one file per entry,
# five readable lines each, no scripting language and nothing to generate. An
# entry can be written or repaired from any machine that can mount a FAT
# partition, which is the argument for it.
#
# It is UEFI only by construction — bootctl install writes an EFI application
# into an EFI system partition, and a legacy BIOS machine has neither — so this
# file refuses a BIOS run before it touches anything, and names grub.
#
# It does not need systemd as init. bootctl and systemd-bootx64.efi come from
# sys-apps/systemd-utils with the boot USE flag, which merges on an OpenRC
# system like any other package, and nothing here starts a unit. What it does
# need is that flag: systemd-utils merged without it installs cleanly and
# leaves no bootctl behind, so the binary is checked for rather than assumed.
#
# The loader configuration and the entry are written here, so the first boot
# works with no hook installed. Keeping them up to date across later kernel
# updates is sys-kernel/installkernel's job (USE="systemd-boot"); until that is
# merged, a kernel update means rerunning step 80.
#
# Usage:  sourced by steps/80_boot.sh   (bootloader = systemd-boot)
#
set -euo pipefail

if [[ -n "${_GI_BOOT_SYSTEMD_BOOT_LOADED:-}" ]]; then
  return 0
fi
_GI_BOOT_SYSTEMD_BOOT_LOADED=1

# What bootctl installs, and where. The removable path matters here even on a
# machine with working NVRAM: bootctl writes both, and it is the copy that
# survives a firmware that forgets its boot entries.
readonly BOOT_SDB_LOADER="/EFI/systemd/systemd-bootx64.efi"
readonly BOOT_SDB_REMOVABLE="/EFI/BOOT/BOOTX64.EFI"
# The label bootctl gives its own NVRAM entry. It is not boot_label: bootctl
# chooses it, and looking for our label there finds nothing forever.
readonly BOOT_SDB_NVRAM_LABEL="Linux Boot Manager"

boot_systemd_boot_entry_id() {
  # The entry file's name, which is also what loader.conf's default matches.
  printf '%s.conf\n' "$(boot_label)"
}

boot_systemd_boot_bootctl() {
  # The target's own bootctl, or nothing. Checked as a file rather than with
  # have(): the command that matters runs inside the target, and the host of an
  # install is a live medium whose bootctl says nothing about the target's.
  # Args: $1 = target root.
  local root="${1%/}" candidate
  for candidate in "${root}/usr/bin/bootctl" "${root}/bin/bootctl" "${root}/usr/sbin/bootctl"; do
    if [[ -x "$candidate" ]]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  return 1
}

boot_systemd_boot_require_bootctl() {
  # Args: $1 = target root.
  local root="$1" path
  if path="$(boot_systemd_boot_bootctl "$root")"; then
    ok "bootctl: ${path}"
    return 0
  fi
  if [[ "$DRY_RUN" == "yes" ]]; then
    log "dry-run: no bootctl under ${root%/}/usr/bin; the merge above is what puts it there"
    return 0
  fi
  err "bootctl is not in the target: ${root%/}/usr/bin/bootctl"
  err "       sys-apps/systemd-utils provides it, but only with the boot USE flag"
  err "       init = openrc:   USE=\"boot\" emerge --oneshot sys-apps/systemd-utils   inside the chroot"
  err "       init = systemd:  sys-apps/systemd carries it, and is already in the stage"
  err "       bootloader = grub  needs none of this"
  err "       example:  echo 'sys-apps/systemd-utils boot kernel-install' >> ${root%/}/etc/portage/package.use/70-gentoo-install-kernel"
  return 1
}

boot_systemd_boot_entry_paths() {
  # Prints "linux<TAB>initrd<TAB>version". The two paths are relative to the
  # ESP root, because that is what a Type #1 entry names: systemd-boot reads
  # the FAT partition it was launched from and knows nothing of the root
  # filesystem the kernel lives on. Copies nothing.
  # Args: $1 = target root.
  local root="$1" esp_mount label record version image initrd
  local linux_rel initrd_rel=""

  esp_mount="$(target_esp_mount)"
  label="$(boot_label)"
  record="$(kernel_installed "$root")" || return 1
  IFS=$'\t' read -r version image initrd <<<"$record"

  if [[ "$esp_mount" == "/boot" ]]; then
    # /boot is the ESP: the files are already where the loader can read them,
    # and copying them would only give the machine two kernels to keep in step.
    linux_rel="${image#/boot}"
    if [[ -n "$initrd" ]]; then
      initrd_rel="${initrd#/boot}"
    fi
  else
    # The version stays in the file name here, unlike the EFI stub variant:
    # entries are files, a second kernel is a second file, and having somewhere
    # to fall back to is the reason to run a loader at all.
    linux_rel="/EFI/${label}/${image##*/}"
    if [[ -n "$initrd" ]]; then
      initrd_rel="/EFI/${label}/${initrd##*/}"
    fi
  fi

  printf '%s\t%s\t%s\n' "$linux_rel" "$initrd_rel" "$version"
}

boot_systemd_boot_loader_body() {
  # Renders loader.conf; writes nothing.
  local timeout entry
  timeout="$(boot_timeout)"
  entry="$(boot_systemd_boot_entry_id)"

  cat <<EOF
# gentoo-install — systemd-boot loader configuration
#
# default names an entry file under loader/entries. A machine that dual-boots
# keeps its other entries; only this one is preselected.
default ${entry}
timeout ${timeout}
EOF

  cat <<'EOF'

# Conservative by default — what each one costs is named next to it.
#
# Refuse the on-screen editor. It closes the door where anyone holding the
# keyboard appends init=/bin/sh, and it closes the only door left for fixing a
# wrong root= without a live medium.
#editor no
#
# Stop offering what systemd-boot finds by itself: other operating systems,
# the EFI shell, the firmware setup entry. Worth it on a machine that must show
# one entry and nothing else, and a nuisance on every other machine.
#auto-entries no
#auto-firmware no
EOF
}

boot_systemd_boot_entry_body() {
  # Renders one Type #1 entry; writes nothing. Args: $1 = target root.
  local root="$1" record linux_rel initrd_rel version cmdline label
  record="$(boot_systemd_boot_entry_paths "$root")" || return 1
  IFS=$'\t' read -r linux_rel initrd_rel version <<<"$record"
  cmdline="$(kernel_cmdline)" || return 1
  label="$(boot_label)"

  printf 'title      Gentoo Linux (%s)\n' "$label"
  printf 'version    %s\n' "$version"
  printf 'linux      %s\n' "$linux_rel"
  if [[ -n "$initrd_rel" ]]; then
    printf 'initrd     %s\n' "$initrd_rel"
  fi
  printf 'options    %s\n' "$cmdline"
}

boot_systemd_boot_validate_entry() {
  # The checker write_validated hands the last word to. An entry that names a
  # file the ESP does not carry is a menu line that fails at the moment it is
  # chosen, with the machine already out of the operator's hands. Silent: its
  # output is discarded, and boot_systemd_boot_verify() is what an operator
  # reads. Args: $1 = entry file, $2 = ESP directory as a host path.
  local file="$1" esp="$2" key value seen_linux="no" seen_options="no"

  [[ -f "$file" ]] || return 1
  while read -r key value; do
    case "$key" in
      linux)
        [[ -n "$value" && -f "${esp}${value}" ]] || return 1
        seen_linux="yes"
        ;;
      initrd)
        [[ -n "$value" && -f "${esp}${value}" ]] || return 1
        ;;
      options)
        [[ -n "$value" ]] || return 1
        seen_options="yes"
        ;;
      *) ;;
    esac
  done <"$file"

  [[ "$seen_linux" == "yes" && "$seen_options" == "yes" ]]
}

boot_systemd_boot_packages() {
  # Args: $1 = target root, $2 = firmware.
  local root="$1" firmware="$2" init
  init="$(target_init)"

  if [[ "$init" == "systemd" ]]; then
    if kernel_pkg_installed "$root" "sys-apps/systemd"; then
      skip "sys-apps/systemd already installed; it carries bootctl"
    else
      kernel_emerge "$root" "sys-apps/systemd" || return 1
    fi
  else
    # OpenRC. systemd-utils packages the pieces of systemd that stand on their
    # own, and the boot flag is the one that builds bootctl and the loader.
    # Without it the merge succeeds and leaves nothing behind that can install
    # a bootloader, which is a failure with no symptom until step 80.
    # kernel-install comes with boot because the ebuild demands it —
    # REQUIRED_USE carries boot? ( kernel-install ) — and asking for boot alone
    # does not merge the package, it refuses to resolve at all:
    #   The following REQUIRED_USE flag constraints are unsatisfied:
    #     boot? ( kernel-install )
    # which is what every openrc install with bootloader = systemd-boot walked
    # into, including the advice the old error message gave the operator.
    kernel_write_package_use "$root" \
      "# bootctl and systemd-bootx64.efi come from systemd-utils, and only with" \
      "# these flags. Without boot the package merges and installs no bootctl;" \
      "# without kernel-install beside it the ebuild refuses boot outright." \
      "sys-apps/systemd-utils boot kernel-install" || return 1

    if ! kernel_pkg_installed "$root" "sys-apps/systemd-utils"; then
      kernel_emerge "$root" "sys-apps/systemd-utils" || return 1
    elif boot_systemd_boot_bootctl "$root" >/dev/null 2>&1; then
      skip "sys-apps/systemd-utils already installed, and it carries bootctl"
    else
      # Installed, and no bootctl: the copy in the stage3 was merged before the
      # boot flag existed in this configuration, and --noreplace will not rebuild
      # it. Saying so and stopping was the old behaviour, and it left an operator
      # who had asked for systemd-boot to emerge the bootloader by hand — which
      # the grub variant never asks of anyone. --changed-use is exactly what the
      # flag written just above calls for.
      log "sys-apps/systemd-utils is installed without bootctl; rebuilding it for the boot flag"
      kernel_in_target "$root" emerge --verbose --changed-use --quiet-build=n \
        sys-apps/systemd-utils || {
        err "sys-apps/systemd-utils would not rebuild with the boot flag"
        err "       emerge --info sys-apps/systemd-utils in the chroot shows what it read"
        err "       bootloader = grub needs none of this"
        return 1
      }
    fi
  fi

  if [[ "$firmware" == "uefi" ]] && ! kernel_pkg_installed "$root" "sys-boot/efibootmgr"; then
    # bootctl writes the NVRAM entry itself through efivarfs and does not call
    # efibootmgr. It is merged for the operator who has to look at that entry,
    # or delete it, after the reboot.
    kernel_emerge "$root" "sys-boot/efibootmgr" || return 1
  fi
}

boot_systemd_boot_write_loader() {
  # Args: $1 = target root.
  local root="$1" esp body
  esp="$(boot_esp_dir "$root")"
  body="$(boot_systemd_boot_loader_body)" || return 1
  # write_file, not write_block: loader.conf has no owner but this project —
  # bootctl install does not create one — and --on-conflict backup is what
  # protects a file another distribution left there. Here-string, never a pipe:
  # the writers record the backup they take, and a subshell would carry that
  # record away with it.
  write_file "${esp}/loader/loader.conf" <<<"$body"
}

boot_systemd_boot_write_images() {
  # Put the kernel and its initramfs where the loader can read them: on the
  # ESP, unless the ESP is already mounted at /boot and they are on it.
  # Args: $1 = target root.
  local root="$1" esp esp_mount record version image initrd
  local linux_rel initrd_rel

  esp="$(boot_esp_dir "$root")"
  esp_mount="$(target_esp_mount)"
  record="$(kernel_installed "$root")" || return 1
  IFS=$'\t' read -r version image initrd <<<"$record"
  record="$(boot_systemd_boot_entry_paths "$root")" || return 1
  IFS=$'\t' read -r linux_rel initrd_rel version <<<"$record"

  if [[ "$esp_mount" == "/boot" ]]; then
    skip "the ESP is mounted at /boot: the loader reads ${image} where it already is"
    if boot_secureboot_ready; then
      # systemd-boot loads the kernel with LoadImage, which the firmware
      # checks: an unsigned kernel behind a signed loader is refused, and the
      # message names neither.
      boot_install_efi "${root%/}${image}" "${root%/}${image}" || return 1
    fi
    return 0
  fi

  boot_install_efi "${root%/}${image}" "${esp}${linux_rel}" || return 1
  if [[ -n "$initrd" ]]; then
    boot_copy_to_esp "${root%/}${initrd}" "${esp}${initrd_rel}" || return 1
  else
    warn "no initramfs for ${version}; the entry will name a kernel and nothing else"
    warn "       an encrypted or LVM root cannot be reached that way"
  fi
}

boot_systemd_boot_write_entry() {
  # Args: $1 = target root.
  local root="$1" esp body entry
  esp="$(boot_esp_dir "$root")"
  entry="${esp}/loader/entries/$(boot_systemd_boot_entry_id)"
  body="$(boot_systemd_boot_entry_body "$root")" || return 1

  write_validated "$entry" boot_systemd_boot_validate_entry "$entry" "$esp" <<<"$body" || {
    err "the loader entry was rejected and rolled back"
    err "       it names a kernel or an initramfs that is not on the ESP: ${esp}"
    err "       ls -R ${esp}/EFI shows what is actually there"
    err "       an entry pointing at a missing file fails at the moment it is chosen, not now"
    return 1
  }
}

boot_systemd_boot_run_install() {
  # bootctl install is idempotent: on a second run it refreshes the loader it
  # already put there. Args: $1 = target root.
  local root="$1" esp_mount
  local -a argv=()
  esp_mount="$(target_esp_mount)"

  if [[ ! -d "${root%/}${esp_mount}" && "$DRY_RUN" != "yes" ]]; then
    err "The EFI system partition is not mounted at ${esp_mount} inside ${root%/}"
    err "       bootctl install writes into it and will not create it"
    err "       mount the ESP there first, or set esp_mount to where it is"
    err "       example:  esp_mount = /efi"
    return 1
  fi

  argv=(bootctl "--esp-path=${esp_mount}" install)

  # Two different reasons to install without variables, and they were one.
  #
  # The first is "bootctl cannot": no efivarfs in the chroot, so there is
  # nothing to write through.
  #
  # The second is "bootctl must not", and it was missing. Step 50 binds this
  # machine's /sys into the target, so on a UEFI host the efivarfs bootctl
  # finds in the chroot is *this machine's* — the check above passes and the
  # entry lands in the NVRAM of the machine running the installer. That is the
  # accident disk_may_write_firmware_state was written against, in its own
  # words: "An install to a loop image, run on a working machine, replaced that
  # machine's own 'gentoo' NVRAM entry with one pointing at the loop device's
  # ESP; the installer then rebooted, and the firmware found nothing to boot."
  # The efistub path was routed through that guard when it happened. This one
  # writes its entry through bootctl rather than efibootmgr, and was not.
  #
  # Nothing is lost by refusing: bootctl install writes \EFI\BOOT\BOOTX64.EFI
  # as well as its own directory, so the disk still boots on a firmware with no
  # entry for it — which is the firmware it will meet.
  if [[ ! -d "${root%/}/sys/firmware/efi/efivars" && "$DRY_RUN" != "yes" ]]; then
    warn "no efivarfs at ${root%/}/sys/firmware/efi/efivars; installing with --no-variables"
    warn "       bootctl cannot write a boot entry from a chroot that does not carry it"
    warn "       mount -t efivarfs none ${root%/}/sys/firmware/efi/efivars makes it writable"
    warn "       without an entry the firmware still finds \\EFI\\BOOT\\BOOTX64.EFI, which bootctl installs too"
    argv+=(--no-variables)
  elif ! disk_may_write_firmware_state "$(boot_disk)"; then
    warn "installing with --no-variables: $(boot_disk) is not the disk this machine"
    warn "       booted from, and this is not a live medium — the efivarfs in the"
    warn "       chroot is this machine's own, and the entry would replace its"
    warn "       label with a pointer to a disk the firmware may not find"
    warn "       \\EFI\\BOOT\\BOOTX64.EFI is written either way, and needs no entry"
    log "       write it yourself once the target is the machine being booted:"
    log "         bootctl --esp-path=${esp_mount} install"
    argv+=(--no-variables)
  fi

  kernel_in_target "$root" "${argv[@]}" || {
    err "bootctl install failed"
    err "       it refuses anything that is not a FAT EFI system partition, by partition type"
    err "       bootctl --esp-path=${esp_mount} status inside the chroot says what it sees"
    err "       example:  esp_mount = /efi"
    return 1
  }
  ok "bootctl install finished"
}

boot_systemd_boot_sign_loader() {
  # The loader is the binary the firmware checks, and bootctl installs two
  # copies of it. Both are signed, or the removable one is refused on the day
  # the NVRAM entry is lost — which is the day it is needed.
  # Args: $1 = target root.
  local root="$1" esp file
  boot_secureboot_ready || return 0
  esp="$(boot_esp_dir "$root")"
  for file in "${esp}${BOOT_SDB_LOADER}" "${esp}${BOOT_SDB_REMOVABLE}"; do
    if [[ -f "$file" || "$DRY_RUN" == "yes" ]]; then
      boot_install_efi "$file" "$file" || return 1
    fi
  done
}

boot_systemd_boot_verify() {
  # Args: $1 = target root, $2 = firmware.
  local root="${1%/}" esp esp_mount entry entry_file listing
  esp_mount="$(target_esp_mount)"

  if [[ "$DRY_RUN" == "yes" ]]; then
    log "dry-run: would check the loader binary, the entry file, what bootctl lists and the NVRAM entry"
    return 0
  fi

  esp="$(boot_esp_dir "$root")"
  entry="$(boot_systemd_boot_entry_id)"
  entry_file="${esp}/loader/entries/${entry}"

  boot_require_file "${esp}${BOOT_SDB_LOADER}" "systemd-boot loader" || return 1
  show_signature "${esp}${BOOT_SDB_LOADER}"
  if [[ -f "${esp}${BOOT_SDB_REMOVABLE}" ]]; then
    ok "removable copy: ${esp}${BOOT_SDB_REMOVABLE}"
  else
    warn "no ${esp}${BOOT_SDB_REMOVABLE}"
    warn "       bootctl install writes it; a firmware that loses its entries has nothing left to find"
  fi

  boot_require_file "$entry_file" "loader entry" || return 1
  if boot_systemd_boot_validate_entry "$entry_file" "$esp"; then
    ok "${entry}: names a kernel that is on the ESP"
  else
    err "${entry_file} names a file the ESP does not carry"
    err "       grep -E '^(linux|initrd)' ${entry_file} lists what it expects"
    err "       the paths in an entry are relative to the root of the ESP, not to /boot"
    return 1
  fi

  # bootctl list is the loader's own reading of the directory, which is the
  # only reading that counts: it applies the same parser the firmware will.
  if ! boot_systemd_boot_bootctl "$root" >/dev/null; then
    warn "no bootctl in the target; the entry was checked by hand instead of by the loader"
    return 0
  fi
  if ! listing="$(kernel_in_target "$root" bootctl "--esp-path=${esp_mount}" list 2>&1)"; then
    warn "bootctl list failed inside ${root:-/}; the entry file itself checks out"
    warn "       it needs /proc and /sys mounted in the chroot to read the ESP"
    warn "       bootctl --esp-path=${esp_mount} list says why"
    return 0
  fi
  if grep -qF -- "$entry" <<<"$listing"; then
    ok "bootctl lists '${entry}'"
    printf '%s\n' "$listing" | sed 's/^/       /' >&2
  else
    err "bootctl does not list '${entry}'"
    err "       the file is there and the loader ignored it, so a field in it is not understood"
    err "       bootctl --esp-path=${esp_mount} list shows the entries it did accept"
    return 1
  fi

  # The NVRAM belongs to the machine efibootmgr runs on, which is only the
  # machine being installed when the guard says so. Asking unconditionally is
  # how this check reported
  #
  #     [+] NVRAM entry 'Linux Boot Manager' points at the loader
  #
  # about an install to /dev/loop0 that had just been given --no-variables and
  # had written no entry at all: it had found the *host's* own Linux Boot
  # Manager entry, dated the day before, and called it this install's. A
  # verifier that reads another machine's firmware is not a verifier.
  if ! disk_may_write_firmware_state "$(boot_disk)"; then
    skip "no NVRAM entry was written, and this machine's own is not this install's"
    skip "       the firmware will start \\EFI\\BOOT\\BOOTX64.EFI, which bootctl wrote"
    skip "       bootctl --esp-path=${esp_mount} install writes the entry on the target itself"
  elif have efibootmgr; then
    if boot_entry_exists "$BOOT_SDB_NVRAM_LABEL" "$(boot_efi_path "$BOOT_SDB_LOADER")"; then
      ok "NVRAM entry '${BOOT_SDB_NVRAM_LABEL}' points at the loader"
    else
      warn "no NVRAM entry named '${BOOT_SDB_NVRAM_LABEL}'"
      warn "       bootctl creates it, and cannot when efivarfs is missing from the chroot"
      warn "       the firmware can still start \\EFI\\BOOT\\BOOTX64.EFI from the removable path"
    fi
  fi
  show_boot_entries
}

boot_systemd_boot_install() {
  # Args: $1 = target root, $2 = firmware.
  local root="$1" firmware="$2"

  # Refused here and not three functions later: bootctl install has no meaning
  # on a legacy BIOS machine, and everything after this line writes into an ESP
  # that such a machine does not have.
  if [[ "$firmware" != "uefi" ]]; then
    err "bootloader = systemd-boot needs UEFI firmware, and this run is on legacy BIOS"
    err "       grub          boots a BIOS machine from a master boot record; the one answer here"
    err "       systemd-boot  an EFI application, installed into an EFI system partition"
    err "       efistub       also UEFI only: the firmware launches the kernel itself"
    err "       firmware = uefi  if the target really is UEFI and only the installer was not"
    err "       example:  --bootloader grub"
    return 1
  fi

  boot_systemd_boot_packages "$root" "$firmware" || return 1
  boot_systemd_boot_require_bootctl "$root" || return 1
  boot_systemd_boot_write_loader "$root" || return 1
  boot_systemd_boot_run_install "$root" || return 1
  boot_systemd_boot_sign_loader "$root" || return 1
  boot_systemd_boot_write_images "$root" || return 1
  boot_systemd_boot_write_entry "$root" || return 1
  boot_systemd_boot_verify "$root" "$firmware"
}
