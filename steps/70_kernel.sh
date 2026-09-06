#!/usr/bin/env bash
#
# gentoo-install — step 70: kernel, initramfs and the command line that boots it
# ----------------------------------------------------------------------------
# Three ways to get a kernel — dist-kernel, genkernel, manual — behind one step.
# What the step itself owns is the part that decides whether an encrypted
# machine comes back up: the dracut module list and the kernel command line,
# both composed from what steps 20 and 30 recorded rather than hardcoded. An
# initramfs that cannot open the container leaves the operator at a dracut
# prompt with no root and no explanation, and that is the expensive failure
# this file exists to prevent.
#
# Step 80 sources this file for target_fact(), kernel_cmdline() and
# kernel_installed(): the bootloader has to put the same command line in front
# of the same image, and two implementations of that is one too many.
#
# Usage:  source steps/70_kernel.sh   (needs lib/core.sh, lib/config.sh,
#                                      lib/state.sh)
#
set -euo pipefail

if [[ -n "${_GI_STEP_70_LOADED:-}" ]]; then
  return 0
fi
_GI_STEP_70_LOADED=1

# Where this file sits, so the variants can be found whether the repository is
# run in place or installed under a prefix. Sourcing lib/ when the entry point
# has not already done it keeps the step usable on its own, which is what makes
# kernel_cmdline() testable without an installer around it.
_gi_self="$(readlink -f -- "${BASH_SOURCE[0]}")"
GI_STEP_DIR="${_gi_self%/*}"
GI_BASE_DIR="${GI_STEP_DIR%/*}"
GI_LIB_DIR="${GI_LIB_DIR:-${GI_BASE_DIR}/lib}"
GI_VARIANT_DIR="${GI_VARIANT_DIR:-${GI_BASE_DIR}/variants}"
unset _gi_self

if [[ -z "${_GI_CORE_LOADED:-}" ]]; then
  # shellcheck source=lib/core.sh
  source "${GI_LIB_DIR}/core.sh"
fi
if [[ -z "${_GI_CONFIG_LOADED:-}" ]]; then
  # shellcheck source=lib/config.sh
  source "${GI_LIB_DIR}/config.sh"
fi
if [[ -z "${_GI_STATE_LOADED:-}" ]]; then
  # shellcheck source=lib/state.sh
  source "${GI_LIB_DIR}/state.sh"
fi

# --------------------------------------------------------------------------- #
#  What steps 20 and 30 decided                                               #
# --------------------------------------------------------------------------- #
# Two sources, in this order: CFG, because an explicit flag outranks everything
# (DESIGN.md §5), then the state journal, because a --resume run has a fresh
# CFG and every fact about the disk was discovered hours ago. Neither is
# assumed present: a step that dies because step 20 spelled a key differently
# is worse than one that says what it is missing.

target_root() {
  # The mounted target, /mnt/gentoo during an install and / inside a chroot.
  local root
  root="$(target_fact root chroot.target "${GI_ROOT:-/mnt/gentoo}")"
  # Strip a trailing slash so that "${root}/boot" never becomes "//boot":
  # cosmetic in a path, load-bearing in a log line an operator has to compare.
  printf '%s\n' "${root%/}"
}

target_crypt() {
  # Normalised, because everything below compares against the short spelling.
  crypt_family "$(target_fact crypt crypt.variant "none")"
}
target_layout() { target_fact disk_layout disk.layout "minimal"; }

target_topology() {
  # plain | lvm — the storage shape the kernel command line, the initramfs and
  # the bootloaders have to speak to.
  #
  # Not the same question as disk_layout, and confusing the two cost a whole
  # install: disk_layout names a partitioning profile (minimal, desktop,
  # server, custom), while every consumer here compares against "lvm" or
  # "plain". A profile name matched neither, so kernel_cmdline() fell to its
  # `*)` arm and refused with "Unknown disk layout: minimal" for every layout
  # this installer offers. Step 20 records the real answer as disk.lvm.
  if [[ "$(target_fact disk_lvm disk.lvm "no")" == "yes" ]]; then
    printf 'lvm\n'
  else
    printf 'plain\n'
  fi
}

kernel_initramfs_generator() {
  # Which initramfs the command line has to speak to. dracut and genkernel do
  # not share a single parameter name for unlocking a container: dracut reads
  # rd.luks.uuid, genkernel's own initramfs reads crypt_root, and a line
  # written for one is silently ignored by the other. The kernel variant
  # decides, and the setting exists for the operator who runs genkernel and
  # then builds the initramfs with dracut by hand.
  local generator
  generator="$(target_fact initramfs kernel.initramfs_generator "")"
  if [[ -z "$generator" ]]; then
    if [[ "$(kernel_variant)" == "genkernel" ]]; then
      generator="genkernel"
    else
      generator="dracut"
    fi
  fi
  printf '%s\n' "$generator"
}

target_init() { target_fact init "" "openrc"; }
target_esp_mount() { target_fact esp_mount disk.esp_mount "/efi"; }

kernel_variant() {
  # "dist" is accepted as the short spelling of the file that implements it.
  local want
  want="$(target_fact kernel kernel.variant "dist-kernel")"
  if [[ "$want" == "dist" ]]; then
    want="dist-kernel"
  fi
  printf '%s\n' "$want"
}

# --------------------------------------------------------------------------- #
#  The kernel command line                                                    #
# --------------------------------------------------------------------------- #
kernel_cmdline() {
  # Composed from the crypt variant, the disk layout and the initramfs that
  # will read it — never hardcoded. Four crypt variants times two layouts is
  # eight command lines, and the one that is wrong is the one nobody tested.
  # Prints on stdout and changes nothing, so all eight can be exercised without
  # a disk anywhere near the machine (DESIGN.md §7).
  local crypt layout generator fstype extra
  local -a parts=()

  crypt="$(target_crypt)"
  layout="$(target_topology)"
  generator="$(kernel_initramfs_generator)"

  case "$layout" in
    lvm)
      local vg lv
      vg="$(target_fact vg_name disk.vg_name "")"
      lv="$(target_fact root_lv disk.root_lv "root")"
      if [[ -z "$vg" ]]; then
        err "Cannot compose a kernel command line: layout is lvm but no volume group is named"
        err "       step 20 records disk.vg_name in the state journal"
        err "       vgs --noheadings -o vg_name prints it"
        err "       example:  vg_name = vg0"
        return 1
      fi
      # /dev/mapper doubles every hyphen in a volume group or logical volume
      # name: a group called vg-crypt appears there as vg--crypt. A root= that
      # spells it once boots to a dracut prompt, and it looks right in the log.
      parts+=("root=/dev/mapper/${vg//-/--}-${lv//-/--}")
      ;;
    plain)
      if [[ "$crypt" == "none" ]]; then
        local uuid device
        uuid="$(target_fact root_uuid disk.root_uuid "")"
        device="$(target_fact root_device disk.root_device "")"
        if [[ -n "$uuid" ]]; then
          # A UUID survives a disk moving from sda to nvme0n1; a kernel name
          # does not, and that reorder happens on the reboot after the install.
          parts+=("root=UUID=${uuid}")
        elif [[ -n "$device" ]]; then
          parts+=("root=${device}")
        else
          err "Cannot compose a kernel command line: nothing says where the root filesystem is"
          err "       step 20 records disk.root_uuid in the state journal"
          err "       set root_uuid, or root_device, to say it by hand"
          err "       example:  root_device = /dev/nvme0n1p3"
          return 1
        fi
      elif [[ "$generator" == "genkernel" ]]; then
        # genkernel's initramfs always opens crypt_root as /dev/mapper/root.
        # The name step 30 chose does not reach it.
        parts+=("root=/dev/mapper/root")
      else
        local name
        # crypt_name is the setting the three crypt variants actually open the
        # container under, and step 30 journals it as crypt.name. This asked for
        # luks_name / crypt.luks_name, which nothing writes and nothing else
        # sets: an encrypted install with the defaults created /dev/mapper/gentoo
        # and told the kernel root=/dev/mapper/cryptroot, so it could not boot.
        name="$(target_fact crypt_name crypt.name "gentoo")"
        parts+=("root=/dev/mapper/${name}")
      fi
      ;;
    *)
      err "Unknown disk layout: ${layout}"
      err "       plain  root sits on a partition, or on the LUKS mapping of one"
      err "       lvm    root is a logical volume, possibly inside LUKS"
      err "       example:  layout = lvm"
      return 1
      ;;
  esac

  fstype="$(target_fact root_fstype disk.root_fstype "")"
  if [[ -n "$fstype" ]]; then
    parts+=("rootfstype=${fstype}")
  fi
  parts+=("ro")

  if [[ "$layout" == "lvm" ]]; then
    if [[ "$generator" == "genkernel" ]]; then
      parts+=("dolvm")
    else
      # dracut activates every volume group it can see; naming ours keeps a
      # second disk carrying a same-named group out of the decision. dolvm is
      # genkernel's spelling and is quietly ignored here, which is why it is
      # not written on a dracut line even though it does no harm.
      local vg
      vg="$(target_fact vg_name disk.vg_name "")"
      parts+=("rd.lvm.vg=${vg}")
    fi
  fi

  case "$crypt" in
    none) ;;
    passphrase | tpm | keyfile)
      local luks_uuid
      luks_uuid="$(target_fact luks_uuid crypt.uuid "")"
      if [[ -z "$luks_uuid" ]]; then
        err "Cannot compose a kernel command line: crypt is '${crypt}' but no LUKS UUID is known"
        err "       step 30 records crypt.luks_uuid in the state journal"
        err "       cryptsetup luksUUID <device> prints it"
        err "       example:  luks_uuid = 1d3f0f4a-0f5a-4c7e-9a2b-2f9d3c5e7a11"
        return 1
      fi
      if [[ "$generator" == "genkernel" ]]; then
        parts+=("crypt_root=UUID=${luks_uuid}")
      else
        # The luks- prefix is what dracut prints for a container it found, and
        # what the internal installer this module is drawn from has been
        # booting for two years. dracut strips it before comparing, so the bare
        # UUID works too; matching what dracut prints makes the two comparable.
        parts+=("rd.luks.uuid=luks-${luks_uuid}")
      fi
      ;;
    *)
      err "Unknown crypt variant: ${crypt}"
      err "       none        no encryption at all"
      err "       passphrase  the operator types it at every boot"
      err "       tpm         clevis unseals the key from the TPM"
      err "       keyfile     a GPG-wrapped key file, read from another partition"
      err "       example:  crypt = tpm"
      return 1
      ;;
  esac

  if [[ "$crypt" == "keyfile" ]]; then
    local keyfile key_uuid
    keyfile="$(target_fact crypt_keyfile crypt.keyfile "/luks-key.gpg")"
    key_uuid="$(target_fact crypt_keyfile_uuid crypt.keyfile_uuid "$(target_fact esp_uuid disk.esp_uuid "")")"
    if [[ "$generator" == "genkernel" ]]; then
      parts+=("root_key=${keyfile}")
      if [[ -n "$key_uuid" ]]; then
        parts+=("root_keydev=UUID=${key_uuid}")
      fi
    elif [[ -n "$key_uuid" ]]; then
      # path:UUID=<the device holding it>. Without the second half dracut looks
      # for the path inside the initramfs, which is a different plan entirely.
      parts+=("rd.luks.key=${keyfile}:UUID=${key_uuid}")
    else
      warn "crypt=keyfile but no UUID for the device that holds ${keyfile}"
      warn "       falling back to rd.luks.key=${keyfile}, which dracut reads from inside the initramfs"
      warn "       set crypt_keyfile_uuid to the filesystem UUID of the partition that carries it"
      parts+=("rd.luks.key=${keyfile}")
    fi
  fi

  extra="$(target_fact kernel_cmdline_extra "" "")"
  if [[ -n "$extra" ]]; then
    parts+=("$extra")
  fi

  printf '%s\n' "${parts[*]}"
}

kernel_warn_console_takeover() {
  # A console= that names only a serial port takes the screen away.
  #
  # The kernel prints to every console= it is given and makes the last one
  # /dev/console. Name ttyS0 and nothing else and the framebuffer goes quiet —
  # including the initramfs asking for the LUKS passphrase, which is the one
  # message a person has to see. If the machine also has no serial driver
  # available that early, it prints nowhere at all, and a machine that boots
  # correctly and says nothing is indistinguishable from a machine that hung.
  #
  # That is not hypothetical: this project's own testing notes recommended
  # console=ttyS0,115200 to make a boot drivable, an install took the advice,
  # and the result was read as a hung UKI for most of an afternoon.
  #
  # Args: $1 = the command line.
  local line="$1" consoles
  consoles="$(printf '%s\n' "$line" | tr ' ' '\n' | sed -n 's/^console=//p')"
  [[ -n "$consoles" ]] || return 0
  # tty0 is the screen; ttyS0 is a serial port, and `tty` alone would match
  # both — which is how the first version of this check passed a command line
  # naming only ttyS0 and warned about nothing.
  grep -qE '^tty[0-9]+([,[:space:]]|$)' <<<"$consoles" && return 0

  warn "the kernel command line names a console and none of them is the screen:"
  while IFS= read -r one; do
    [[ -n "$one" ]] || continue
    warn "       console=${one}"
  done <<<"$consoles"
  warn "       the kernel prints to every console= it is given, so this one"
  warn "       takes the framebuffer away — the initramfs asks for the LUKS"
  warn "       passphrase where nobody is looking, and a machine that boots"
  warn "       correctly and says nothing looks exactly like one that hung"
  warn "       add the screen back by naming it too:"
  warn "       example:  kernel_cmdline_extra = \"console=tty0 console=ttyS0,115200\""
}

show_kernel_cmdline() {
  # Displays; changes nothing (DESIGN.md §7).
  local line
  line="$(kernel_cmdline)" || return 1
  log "kernel command line:"
  log "       ${line}"
  kernel_warn_console_takeover "$line"
}

# --------------------------------------------------------------------------- #
#  The initramfs                                                              #
# --------------------------------------------------------------------------- #
kernel_dracut_modules() {
  # crypt, dm and lvm for anything encrypted; clevis and clevis-pin-tpm2 on top
  # for the TPM variant; crypt-gpg on top for the wrapped key file. Getting
  # this list wrong is the single most common way an encrypted Gentoo install
  # fails to boot, and the symptom — a dracut shell with no root — names none
  # of the missing pieces.
  local crypt layout extra
  local -a mods=()

  crypt="$(target_crypt)"
  layout="$(target_topology)"

  if [[ "$crypt" != "none" ]]; then
    mods+=(crypt dm)
  fi
  if [[ "$layout" == "lvm" ]]; then
    mods+=(dm lvm)
  fi

  case "$crypt" in
    tpm) mods+=(clevis clevis-pin-tpm2) ;;
    keyfile) mods+=(crypt-gpg) ;;
    *) ;;
  esac

  extra="$(target_fact dracut_modules_extra "" "")"
  if [[ -n "$extra" ]]; then
    # Word splitting is the point: the setting is a space-separated list.
    # shellcheck disable=SC2206
    mods+=($extra)
  fi

  if ((${#mods[@]} == 0)); then
    return 0
  fi
  # dm is asked for by both the crypt arm and the lvm one, and dracut is handed
  # the list verbatim. De-duplicate here rather than let it read "crypt dm dm
  # lvm", which works but makes the configuration file look like a mistake.
  printf '%s\n' "${mods[*]}" | tr ' ' '\n' | awk '!seen[$0]++' | paste -sd' ' -
}

kernel_dracut_omit() {
  local -a omit=()
  if [[ "$(target_init)" != "systemd" ]]; then
    omit+=(systemd)
  fi
  # A splash screen draws over the passphrase prompt. On an encrypted machine
  # that turns "type your passphrase" into "the boot hangs".
  omit+=(plymouth)
  printf '%s\n' "${omit[*]}"
}

kernel_dracut_module_present() {
  # Args: $1 = target root, $2 = module name. dracut names its module
  # directories <NN><name>; the number is a load order and changes between
  # releases, so it is globbed rather than spelled.
  local root="$1" name="$2" dir
  for dir in "${root}/usr/lib/dracut/modules.d/"[0-9][0-9]"${name}" \
    "${root}/usr/lib/dracut/modules.d/"[0-9][0-9][0-9]"${name}"; do
    if [[ -d "$dir" ]]; then
      return 0
    fi
  done
  return 1
}

kernel_check_dracut_modules() {
  # Stage 3 of validation (DESIGN.md §5): the value was legal at parse time and
  # available at pre-flight, but the package that provides it may still be
  # missing here. Warns rather than fails — dracut itself is the authority, and
  # this runs before the packages of the variant have been emerged.
  local root="$1" module
  local -a wanted=() missing=()
  local list
  list="$(kernel_dracut_modules)" || return 1
  [[ -n "$list" ]] || return 0
  read -r -a wanted <<<"$list"

  for module in "${wanted[@]}"; do
    if ! kernel_dracut_module_present "$root" "$module"; then
      missing+=("$module")
    fi
  done

  if ((${#missing[@]} == 0)); then
    ok "dracut modules present in the target: ${wanted[*]}"
    return 0
  fi

  warn "dracut modules not found under ${root}/usr/lib/dracut/modules.d: ${missing[*]}"
  for module in "${missing[@]}"; do
    case "$module" in
      clevis | clevis-pin-tpm2)
        warn "       ${module}  comes from app-crypt/clevis (with the tpm2 USE flag)"
        ;;
      crypt-gpg)
        warn "       ${module}  comes from sys-kernel/dracut and needs app-crypt/gnupg in the target"
        ;;
      crypt | dm | lvm)
        warn "       ${module}  comes from sys-kernel/dracut"
        ;;
      *)
        warn "       ${module}  provider unknown to gentoo-install"
        ;;
    esac
  done
  warn "       the initramfs will build without them and the machine will not open its container"
  return 0
}

kernel_initramfs_missing_modules() {
  # Which of the modules the configuration asks for are absent from the image
  # that exists. A returned value, so stdout; empty when there is nothing to
  # say, including when there is no image or no lsinitrd to read it with.
  # Args: $1 = target root, $2 = the initramfs, as the target sees it.
  local root="${1%/}" initrd="$2" module wanted
  local -a want=() missing=()

  [[ -n "$initrd" && -f "${root}${initrd}" ]] || return 0
  wanted="$(kernel_dracut_modules)" || return 0
  wanted="$(kernel_dracut_prune_modules "$root" "$wanted")" || return 0
  [[ -n "$wanted" ]] || return 0
  read -r -a want <<<"$wanted"

  # lsinitrd comes from dracut, which is installed in the target and not on the
  # live medium — so it is run in the target, exactly as step 95 does. Asking
  # the host for it found nothing, said nothing, and let a stale initramfs
  # through: the check existed and never ran.
  local -a carried=()
  if [[ -n "$root" && "$root" != "/" ]]; then
    mapfile -t carried < <(chroot "$root" lsinitrd "$initrd" --mod 2>/dev/null)
  else
    have lsinitrd || return 0
    mapfile -t carried < <(lsinitrd "$initrd" --mod 2>/dev/null)
  fi
  ((${#carried[@]} > 0)) || return 0
  for module in "${want[@]}"; do
    printf '%s\n' "${carried[@]}" | grep -qx -- "$module" || missing+=("$module")
  done
  ((${#missing[@]} > 0)) || return 0
  printf '%s\n' "${missing[*]}"
}

kernel_dracut_prune_modules() {
  # Drop the modules that are not in the target, and say what each one costs.
  #
  # dracut fails the entire initramfs when it is asked for a module it cannot
  # find, and that initramfs is built inside the emerge of the kernel. So a
  # module named here and missing there does not degrade the machine — it stops
  # the kernel from installing at all:
  #
  #   dist-kernel_install_kernel: die "Kernel install failed, please fix the
  #   problems and run emerge --config"
  #
  # which is what happened with clevis, whose package is not in the official
  # Gentoo repository. Letting that emerge fail was not enough; the module list
  # has to stop asking for what is not there.
  #
  # Nothing is pruned while dracut itself is absent — that is the first write,
  # before any package is installed, and "not there yet" is not "not coming".
  # Args: $1 = target root, $2 = the module list. Prints what survives.
  local root="$1" module lost=0
  local -a kept=() wanted=()
  read -r -a wanted <<<"${2:-}"

  ((${#wanted[@]} > 0)) || return 0
  [[ -d "${root%/}/usr/lib/dracut/modules.d" ]] || {
    printf '%s\n' "${wanted[*]}"
    return 0
  }

  for module in "${wanted[@]}"; do
    if kernel_dracut_module_present "$root" "$module"; then
      kept+=("$module")
      continue
    fi
    case "$module" in
      clevis | clevis-pin-tpm2)
        warn "dracut module ${module} is not in the target; leaving it out"
        warn "       app-crypt/clevis provides it, and it is not in the official"
        warn "       Gentoo repository — the GURU overlay carries it"
        warn "       the machine boots and asks for the recovery passphrase;"
        warn "       step 75 says the same thing and how to seal it later"
        ;;
      crypt-gpg)
        warn "dracut module ${module} is not in the target; leaving it out"
        warn "       it comes from sys-kernel/dracut and needs app-crypt/gnupg"
        warn "       the machine boots and asks for the recovery passphrase"
        ;;
      *)
        err "dracut module ${module} is not in the target"
        err "       it is what opens the container at boot, so an initramfs"
        err "       without it produces a machine that cannot start"
        err "       sys-kernel/dracut provides crypt, dm and lvm"
        lost=$((lost + 1))
        ;;
    esac
  done

  ((lost == 0)) || return 1
  printf '%s\n' "${kept[*]}"
}

kernel_dracut_conf_body() {
  # Renders the configuration; writes nothing.
  # Args: $1 = target root, for the modules that have to be there.
  local root="${1:-/}" cmdline modules omit
  cmdline="$(kernel_cmdline)" || return 1
  modules="$(kernel_dracut_modules)" || return 1
  modules="$(kernel_dracut_prune_modules "$root" "$modules")" || return 1
  omit="$(kernel_dracut_omit)"

  cat <<EOF
# gentoo-install — dracut configuration for the target system
#
# hostonly_cmdline="no" is the line that matters. Built from a live medium,
# dracut otherwise bakes in the live medium's own kernel command line and the
# initramfs then looks for a root filesystem the target does not have.
hostonly="yes"
hostonly_cmdline="no"

kernel_cmdline="${cmdline}"
EOF

  if [[ -n "$modules" ]]; then
    printf 'add_dracutmodules+=" %s "\n' "$modules"
  fi
  if [[ -n "$omit" ]]; then
    printf 'omit_dracutmodules+=" %s "\n' "$omit"
  fi

  cat <<'EOF'

# Conservative by default — each of these is off because turning it on costs
# something named. Uncomment the one whose price is worth paying.
#
# A rescue shell in the initramfs, for when the container does not open. It
# also gives anyone with the machine a root shell before the disk is unlocked.
#add_dracutmodules+=" rescue "
#
# Stop probing for software RAID and multipath at boot. Shaves a second or two
# and removes a class of surprise — and breaks the boot outright if the root
# filesystem turns out to live on an md array this installer did not create.
#kernel_cmdline+=" rd.md=0 rd.multipath=0 "
EOF
}

kernel_dracut_setting() {
  # dracut sources its configuration, so a commented line means nothing and the
  # last assignment wins. Grepping for the literal string reports success on a
  # file that comments the setting out and then overrides it three lines down.
  # Ask a shell instead, exactly as dracut will.
  # Args: $1 = file, $2 = variable name.
  (
    set +eu
    unset "$2"
    # shellcheck disable=SC1090  # the path is the argument
    . "$1" >/dev/null 2>&1
    eval "printf '%s\n' \"\${$2-}\""
  )
}

kernel_dracut_effective() {
  # What dracut will actually use: /etc/dracut.conf, then the .conf files of
  # /etc/dracut.conf.d in collating order. A file sorting after ours wins.
  # Args: $1 = target root, $2 = variable name.
  local root="$1" name="$2"
  (
    set +eu
    unset "$name"
    # shellcheck source=/dev/null  # a file on the target, absent at lint time
    [[ -f "${root}/etc/dracut.conf" ]] && . "${root}/etc/dracut.conf" >/dev/null 2>&1
    for _f in "${root}/etc/dracut.conf.d/"*.conf; do
      # shellcheck source=/dev/null  # a file on the target, absent at lint time
      [[ -f "$_f" ]] && . "$_f" >/dev/null 2>&1
    done
    eval "printf '%s\n' \"\${$name-}\""
  )
}

kernel_validate_dracut_conf() {
  # The validator write_validated hands the last word to. Silent: its output is
  # discarded, and show_dracut_conf() below is what an operator reads.
  # Args: $1 = the file, $2 = target root.
  local file="$1" root="$2"
  [[ -f "$file" ]] || return 1
  [[ "$(kernel_dracut_setting "$file" hostonly_cmdline)" == "no" ]] || return 1
  [[ -n "$(kernel_dracut_setting "$file" kernel_cmdline)" ]] || return 1
  [[ "$(kernel_dracut_effective "$root" hostonly_cmdline)" == "no" ]] || return 1
  return 0
}

show_dracut_conf() {
  # Args: $1 = target root.
  local root="$1" effective
  effective="$(kernel_dracut_effective "$root" kernel_cmdline)"
  log "dracut, after every file in ${root}/etc/dracut.conf.d:"
  log "       hostonly_cmdline  $(kernel_dracut_effective "$root" hostonly_cmdline)"
  log "       kernel_cmdline    ${effective:-<unset>}"
  log "       add_dracutmodules $(kernel_dracut_effective "$root" add_dracutmodules)"
}

kernel_write_dracut_conf() {
  # Args: $1 = target root.
  local root="$1" conf="${1}/etc/dracut.conf.d/70-gentoo-install.conf" body

  body="$(kernel_dracut_conf_body "$root")" || return 1

  # write_validated, not write_file: dracut has no --check, but sourcing the
  # file back and reading the effective value across the whole directory
  # catches both a mangled line and a later file that overrides it. Content on
  # stdin from a here-string, never from a pipe — the writers record the backup
  # they took, and a subshell would take that record with it.
  write_validated "$conf" kernel_validate_dracut_conf "$conf" "$root" <<<"$body" || {
    err "the initramfs configuration was rejected and rolled back"
    err "       another file in ${root}/etc/dracut.conf.d may override hostonly_cmdline"
    err "       ls ${root}/etc/dracut.conf.d shows what sorts after 70-gentoo-install.conf"
    return 1
  }

  if [[ "$DRY_RUN" != "yes" ]]; then
    show_dracut_conf "$root"
  fi
  kernel_check_dracut_modules "$root"
}

# --------------------------------------------------------------------------- #
#  What ended up in /boot                                                     #
# --------------------------------------------------------------------------- #
kernel_installed() {
  # Prints "version<TAB>image<TAB>initramfs" with paths as the target sees them
  # (/boot/..., not <root>/boot/...), because that is what a bootloader entry
  # needs. Returns 1 when there is no kernel, which is the one thing every
  # variant must have produced.
  local root="$1" boot version image initrd candidate
  boot="${root%/}/boot"

  version="$(target_fact kernel_version kernel.version "")"

  if [[ -z "$version" ]]; then
    # Newest by version sort, not by mtime: a rebuilt older kernel is still an
    # older kernel. .old and .signed are results, not kernels.
    version="$(
      shopt -s nullglob
      for candidate in "${boot}"/vmlinuz-* "${boot}"/kernel-*; do
        case "$candidate" in
          *.old | *.signed | *.efi | *.sig) continue ;;
        esac
        [[ -f "$candidate" ]] || continue
        candidate="${candidate##*/}"
        candidate="${candidate#vmlinuz-}"
        candidate="${candidate#kernel-}"
        printf '%s\n' "$candidate"
      done | sort -V | tail -n 1
    )"
  fi

  if [[ -z "$version" ]]; then
    err "No kernel image under ${boot}"
    err "       step 70 must run before step 80"
    err "       example:  ./gentoo-install.sh --steps 70,80"
    return 1
  fi

  image=""
  for candidate in "vmlinuz-${version}" "kernel-${version}" "vmlinuz" "bzImage-${version}"; do
    if [[ -f "${boot}/${candidate}" ]]; then
      image="/boot/${candidate}"
      break
    fi
  done
  if [[ -z "$image" ]]; then
    err "No kernel image for version ${version} under ${boot}"
    err "       expected ${boot}/vmlinuz-${version}"
    return 1
  fi

  initrd=""
  for candidate in "initramfs-${version}.img" "initramfs-${version}" \
    "initrd-${version}" "initramfs-genkernel-${version}"; do
    if [[ -f "${boot}/${candidate}" ]]; then
      initrd="/boot/${candidate}"
      break
    fi
  done

  printf '%s\t%s\t%s\n' "$version" "$image" "$initrd"
}

kernel_verify() {
  # Args: $1 = target root. The proof the step produced something bootable.
  local root="$1" record version image initrd crypt

  if [[ "$DRY_RUN" == "yes" ]]; then
    log "dry-run: would verify that ${root}/boot holds a kernel and an initramfs"
    return 0
  fi

  record="$(kernel_installed "$root")" || return 1
  IFS=$'\t' read -r version image initrd <<<"$record"

  ok "kernel ${version}: ${image}"

  crypt="$(target_crypt)"
  if [[ -z "$initrd" ]]; then
    if [[ "$crypt" == "none" && "$(target_topology)" == "plain" ]]; then
      warn "no initramfs for ${version}; an unencrypted root on a plain partition can boot without one"
    else
      err "No initramfs for kernel ${version} under ${root}/boot"
      err "       crypt=${crypt} topology=$(target_topology) cannot boot without one"
      err "       dracut --force --kver ${version} builds it from the configuration just written"
      return 1
    fi
  else
    ok "initramfs: ${initrd}"
    if [[ "$crypt" != "none" ]] && have lsinitrd; then
      # The one check that answers "will it open the container": ask the image
      # itself which modules it carries, rather than trusting the config.
      if lsinitrd "${root}${initrd}" --mod 2>/dev/null | grep -qx "crypt"; then
        ok "initramfs carries the crypt module"
      else
        warn "the crypt module is not visible in ${initrd}"
        warn "       lsinitrd ${root}${initrd} --mod lists what is there"
        warn "       a machine whose initramfs cannot open the container stops at a dracut prompt"
      fi
    fi
  fi

  state_set kernel.version "$version"
  state_set kernel.image "$image"
  state_set kernel.initramfs "${initrd:-none}"
  state_set kernel.cmdline "$(kernel_cmdline)"
  state_set kernel.variant "$(kernel_variant)"
  # Both of these are decisions this run made from a setting that may be empty,
  # and both are read back by name on the next one. Unrecorded, a --resume
  # three hours later re-derives them from the defaults and can reach a
  # different answer than the kernel already on the disk was built with.
  state_set kernel.build "$(target_fact kernel_build kernel.build "binary")"
  state_set kernel.initramfs_generator "$(kernel_initramfs_generator)"
}

# --------------------------------------------------------------------------- #
#  Shared plumbing for the variants                                           #
# --------------------------------------------------------------------------- #
kernel_in_target() {
  # Run a command as the target system sees it. A root of / means the caller is
  # already inside the chroot, and chrooting to / would only add a mount
  # namespace's worth of ways to go wrong.
  local root="$1"
  shift
  if [[ "$root" == "/" || -z "$root" ]]; then
    run_cmd "$@"
  else
    run_cmd chroot "$root" "$@"
  fi
}

kernel_emerge() {
  # Args: $1 = target root, $2.. = packages.
  local root="$1"
  shift
  (($# > 0)) || return 0
  log "emerging: $*"
  kernel_in_target "$root" emerge --verbose --noreplace --quiet-build=n "$@"
}

kernel_pkg_installed() {
  # Read-only, works on an unmounted tree and inside a chroot alike.
  #
  # A package directory is name-version, and a Gentoo version always starts with
  # a digit. Checking that matters more than it looks: the glob for
  # sys-boot/grub also matches sys-boot/grub-themes-gentoo, so a machine with
  # only the theme installed answered "sys-boot/grub already installed", the
  # emerge was skipped, and step 80 died on "chroot: cannot execute
  # grub-install: No such file or directory" — with the log one line above it
  # saying grub was there. The same trap is waiting for sys-kernel/linux against
  # linux-firmware, and for anything else whose name is a prefix of a sibling's.
  # Args: $1 = target root, $2 = category/name.
  local root="$1" atom="$2" dir name rest
  name="${atom##*/}"
  for dir in "${root}/var/db/pkg/${atom}"-*; do
    [[ -d "$dir" ]] || continue
    rest="${dir##*/}"
    rest="${rest#"${name}-"}"
    [[ "$rest" == [0-9]* ]] || continue
    return 0
  done
  return 1
}

kernel_write_package_use() {
  # A file of our own under package.use, so a rerun replaces its own work and
  # step 60's file is never touched. Args: $1 = target root, $2.. = lines.
  local root="$1"
  shift
  local target="${root}/etc/portage/package.use/70-gentoo-install-kernel"
  (($# > 0)) || return 0
  printf '%s\n' "$@" | write_block "$target" "kernel USE flags"
}

kernel_ensure_lvm_tools() {
  # dracut's lvm module needs the lvm binary, and sys-fs/lvm2 does not install
  # one unless it is built with USE=lvm — without the flag the package is
  # device-mapper and nothing else.
  #
  # cryptsetup pulls sys-fs/lvm2 in as a dependency, so it is present and looks
  # right, and dracut then says one line about it:
  #
  #   dracut[E]: Module 'lvm' cannot be installed.
  #   ERROR: Installing 6.18.48-gentoo-dist-bin failed
  #
  # which fails the initramfs, which fails the kernel's own install phase, which
  # fails step 70 — and the operator is left with a partitioned disk, a stage3,
  # no kernel and a message about a dracut module. Every LVM install with the
  # distribution kernel hit this; it is why an LVM layout had never booted.
  # Args: $1 = target root.
  local root="$1"

  [[ "$(target_topology)" == "lvm" ]] || return 0

  kernel_write_package_use "$root" \
    "# dracut builds an lvm module for an LVM root, and that module needs the" \
    "# lvm binary itself — sys-fs/lvm2 installs device-mapper and no more" \
    "# without this flag." \
    "sys-fs/lvm2 lvm" || return 1

  if ! kernel_pkg_installed "$root" "sys-fs/lvm2"; then
    kernel_emerge "$root" "sys-fs/lvm2" || return 1
    return 0
  fi

  # Already there — as a dependency of cryptsetup, most likely, and therefore
  # without the flag. --noreplace would leave it exactly as it is, so this is
  # the one case that has to ask for a rebuild.
  log "sys-fs/lvm2 is installed; rebuilding it if the lvm flag is new"
  kernel_in_target "$root" emerge --verbose --changed-use --quiet-build=n \
    sys-fs/lvm2 || {
    err "sys-fs/lvm2 would not rebuild with USE=lvm"
    err "       dracut's lvm module needs the lvm binary; without it the"
    err "       initramfs cannot activate the volume group and the machine"
    err "       stops in a dracut shell with no root"
    return 1
  }
}

kernel_ensure_crypt_packages() {
  # The dracut modules the crypt variant needs come from packages, and dracut
  # builds an initramfs without them without saying a word. Emerging them here
  # is idempotent: --noreplace on a package already in the tree is a no-op.
  #
  # Two lists, and the split is the point. `want` is what the machine needs to
  # open its container at all; without it there is no reason to build a kernel.
  # `optional` is what seals a slot to the TPM afterwards, in step 75 — useful,
  # and not worth a kernel.
  #
  # That distinction was learned in one run. app-crypt/clevis is not in the
  # official Gentoo repository (it is in GURU), so `emerge` answered "there are
  # no ebuilds to satisfy app-crypt/clevis", this function returned non-zero,
  # step 70 failed, and with it went the kernel, the bootloader and the final
  # verification. The machine was left unbootable because an optional helper was
  # unavailable — while the container it was for opened perfectly well with the
  # recovery passphrase.
  # Args: $1 = target root.
  local root="$1" crypt
  local -a want=() optional=() missing=() spare=() use=()

  kernel_ensure_lvm_tools "$root" || return 1

  crypt="$(target_crypt)"
  case "$crypt" in
    none)
      # An unencrypted LVM install needs the lvm tools just the same, and the
      # dracut configuration has to be rewritten with what is really there.
      kernel_write_dracut_conf "$root"
      return
      ;;
    passphrase) want=(sys-fs/cryptsetup sys-kernel/dracut) ;;
    tpm)
      want=(sys-fs/cryptsetup sys-kernel/dracut)
      optional=(app-crypt/clevis app-crypt/tpm2-tss)
      # dracut, not tpm2. The flag list of the only clevis ebuild that exists
      # for Gentoo — app-crypt/clevis in GURU — is
      #
      #   IUSE="dracut pkcs11 test tpm1 udisks"
      #
      # so tpm2 was a flag nobody had, silently ignored, while the one that
      # matters was never asked for. Without dracut the package installs the
      # clevis binaries and no initramfs module, dracut says
      #
      #   Module 'clevis-pin-file' depends on module 'clevis', which can't be
      #   installed
      #
      # and builds an initramfs with no way to reach the TPM. The sealing then
      # works, is proved, and the machine still asks for the passphrase at
      # every boot — which is the failure this project exists to not ship.
      # The tpm2 pin itself comes from app-crypt/tpm2-tools, pulled in as a
      # dependency.
      use=("app-crypt/clevis dracut")
      ;;
    keyfile) want=(sys-fs/cryptsetup sys-kernel/dracut app-crypt/gnupg) ;;
    *) return 0 ;;
  esac

  local atom
  for atom in "${want[@]}"; do
    if ! kernel_pkg_installed "$root" "$atom"; then
      missing+=("$atom")
    fi
  done
  # Every optional atom, installed or not: the emerge below is --changed-use,
  # which is a no-op when nothing changed and the only thing that acts when a
  # flag has just been written for a package that is already there.
  spare=(${optional[@]+"${optional[@]}"})

  if ((${#use[@]} > 0)); then
    kernel_write_package_use "$root" "${use[@]}" || return 1
  fi

  if ((${#missing[@]} == 0)); then
    skip "crypt=${crypt}: every package the initramfs needs is already installed"
  elif ! kernel_emerge "$root" "${missing[@]}"; then
    return 1
  fi

  if ((${#spare[@]} > 0)); then
    # --changed-use and not --noreplace: these carry USE flags this step has
    # just written, and a package already installed without them would be left
    # exactly as it is by --noreplace. That is how clevis ended up installed
    # with no dracut module.
    if ! kernel_in_target "$root" emerge --verbose --changed-use --quiet-build=n \
      "${spare[@]}"; then
      _kernel_warn_no_sealing "${spare[*]}"
    fi
  fi

  # Written once more, now that the packages are either there or known not to
  # be. The first write happened before any of them existed, so it could only
  # name what the configuration asks for; this one names what dracut will
  # actually find. Getting that wrong costs the kernel, not the feature.
  kernel_write_dracut_conf "$root"
}

_kernel_warn_no_sealing() {
  # Said here rather than left to step 75, because this is the moment the
  # reason is known: emerge has just printed it.
  # Args: $1 = the packages that would not merge.
  warn "the TPM sealing helpers would not merge: $1"
  warn "       app-crypt/clevis is not in the official Gentoo repository — the"
  warn "       GURU overlay carries it, and there it is unstable-keyworded:"
  warn "         app-crypt/clevis-23-r1::guru (masked by: ~amd64 keyword)"
  warn "       so it takes both steps, in the target:"
  warn "         eselect repository enable guru && emaint sync -r guru"
  warn "         echo '*/*::guru ~amd64' >> /etc/portage/package.accept_keywords/guru"
  warn "         emerge --ask app-crypt/clevis"
  warn "       this does not stop the install and does not cost the kernel:"
  warn "       the container opens with the recovery passphrase, at every boot,"
  warn "       and step 75 will say plainly that nothing was sealed"
  warn "       once clevis is there:  ./gentoo-install.sh --steps 50,75"
}

kernel_nproc() {
  local n
  n="$(target_fact jobs "" "")"
  if [[ -z "$n" ]]; then
    n="$(nproc 2>/dev/null || printf '1')"
  fi
  printf '%s\n' "$n"
}

kernel_load_variant() {
  # Args: $1 = variant name. The file name is the public spelling of the
  # variant, so a reader who sees --kernel genkernel knows which file to open.
  local name="$1"
  # Split: bash does not bind the first assignment before evaluating the
  # second, so ${name} would expand empty here (SC2318).
  local file="${GI_VARIANT_DIR}/kernel/${name}.sh"
  if [[ ! -r "$file" ]]; then
    err "Missing kernel variant implementation: ${file}"
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
show_kernel_plan() {
  # Args: $1 = target root, $2 = variant.
  local root="$1" variant="$2"
  log "kernel variant   ${variant}"
  log "target root      ${root}"
  log "crypt / layout   $(target_crypt) / $(target_layout) ($(target_topology))"
  log "dracut modules   $(kernel_dracut_modules)"
  log "dracut omits     $(kernel_dracut_omit)"
  show_kernel_cmdline
}

step_70_kernel() {
  local root variant fn

  root="$(target_root)"
  variant="$(kernel_variant)"

  case "$variant" in
    dist-kernel) fn="kernel_dist_kernel_build" ;;
    genkernel) fn="kernel_genkernel_build" ;;
    manual) fn="kernel_manual_build" ;;
    *)
      err "Unknown kernel variant: ${variant}"
      err "       dist-kernel  sys-kernel/gentoo-kernel-bin, prebuilt and signed by Gentoo"
      err "       genkernel    compiled here, configured for you"
      err "       manual       your own sources and your own .config"
      err "       example:  kernel = dist-kernel"
      return 1
      ;;
  esac

  if [[ ! -d "$root" ]]; then
    err "Target root does not exist: ${root}"
    err "       step 50 mounts it; run step 70 after it"
    err "       example:  ./gentoo-install.sh --steps 50,70"
    return 1
  fi

  show_kernel_plan "$root" "$variant"

  # The initramfs configuration goes down first. sys-kernel/installkernel runs
  # dracut from inside the emerge of the dist kernel, so a configuration
  # written afterwards would arrive one initramfs too late.
  kernel_write_dracut_conf "$root" || return 1

  kernel_load_variant "$variant" || return 1
  "$fn" "$root" || return 1

  kernel_verify "$root"
}
