#!/usr/bin/env bash
#
# gentoo-install — step 10: pre-flight, eleven checks that change nothing
# ----------------------------------------------------------------------------
# Runs before anything else and writes to nothing but the state journal. Each
# check ends in one of four verdicts — PASS, WARN, FAIL, SKIP — followed by why
# it says so and by the exact command that fixes it, so that an operator never
# has to leave this screen to make the next run pass.
#
# No check aborts the run on its own: an operator preparing an install wants
# the whole list in one pass, not one refusal per attempt. The aggregate at the
# bottom decides — a FAIL stops, a WARN asks. --force lifts the question a WARN
# asks; nothing lifts a FAIL, because a FAIL is a proof that failed.
#
# Usage:  sourced by gentoo-install.sh, which calls step_10_preflight()
#
set -euo pipefail

if [[ -n "${_GI_STEP_10_LOADED:-}" ]]; then
  return 0
fi
_GI_STEP_10_LOADED=1

# The entry point sources the libraries before this file, so these guards never
# fire in production. They exist so that `shellcheck steps/10_preflight.sh` and
# a standalone `source steps/10_preflight.sh` both see the same definitions the
# runner does, instead of a file full of undefined names.
_gi_step10_lib="${GI_LIB_DIR:-${BASH_SOURCE[0]%/*}/../lib}"
if [[ -z "${_GI_CORE_LOADED:-}" ]]; then
  # shellcheck source=lib/core.sh
  source "${_gi_step10_lib}/core.sh"
fi
if [[ -z "${_GI_CONFIG_LOADED:-}" ]]; then
  # shellcheck source=lib/config.sh
  source "${_gi_step10_lib}/config.sh"
fi
if [[ -z "${_GI_STATE_LOADED:-}" ]]; then
  # shellcheck source=lib/state.sh
  source "${_gi_step10_lib}/state.sh"
fi
if [[ -z "${_GI_UI_LOADED:-}" ]]; then
  # shellcheck source=lib/ui.sh
  source "${_gi_step10_lib}/ui.sh"
fi
unset _gi_step10_lib

# --------------------------------------------------------------------------- #
#  Thresholds                                                                 #
# --------------------------------------------------------------------------- #
# Named once, here, so that a verdict can quote the number it judged against
# instead of asserting that something is "too small".
readonly _PF_MIN_ROOT_GIB=20   # below this, the stage plus one @world fails
readonly _PF_WANT_ROOT_GIB=50  # below this, a desktop @world will be tight
readonly _PF_MIN_MEM_MIB=2048  # RAM + swap; below this the kernel link dies
readonly _PF_WANT_MEM_MIB=4096 # RAM + swap; below this rust and llvm hurt
readonly _PF_MIB_PER_JOB=2048  # memory a parallel compile job wants
readonly _PF_MAX_SKEW_SEC=3600 # clock skew a signature check survives
readonly _PF_NET_TIMEOUT=8     # seconds, per network probe

# --------------------------------------------------------------------------- #
#  Verdicts                                                                   #
# --------------------------------------------------------------------------- #
# The rendering half of DESIGN.md §7: these print and change nothing. The
# checks below decide and record; only _pf_verdict draws.
_PF_INDEX=0
_PF_TOTAL=0
_PF_FAILED=()
_PF_WARNED=()

# The ordered list is the check list. Adding a check is one name here plus one
# _pf_check_<name> function; the numbering and the total follow.
_PF_CHECKS=(root firmware arch tools network dns clock disk memory tpm keyring)

_pf_verdict() {
  # Args: $1 = PASS|WARN|FAIL|SKIP, $2 = key, $3 = title, $4 = one-line detail.
  local status="$1" key="$2" title="$3" detail="$4" colour="$C_0"
  _PF_INDEX=$((_PF_INDEX + 1))
  case "$status" in
    PASS) colour="$C_G" ;;
    WARN)
      colour="$C_Y"
      _PF_WARNED+=("$key")
      ;;
    FAIL)
      colour="$C_R"
      _PF_FAILED+=("$key")
      ;;
    SKIP) colour="$C_D" ;;
    *) die "internal: _pf_verdict got an unknown status: ${status}" ;;
  esac
  printf '  %2d/%2d  %s[%s]%s %-24s %s\n' \
    "$_PF_INDEX" "$_PF_TOTAL" "$colour" "$status" "$C_0" "$title" "$detail" >&2
  _journal "[${status}]" "preflight ${key}: ${title} — ${detail}"
}

_pf_note() {
  # An explanation line, indented under the verdict it belongs to.
  printf '         %s\n' "$*" >&2
  _journal '[.]' "preflight: $*"
}

_pf_fix() {
  # The command that makes the check pass. Copyable as printed, always.
  printf '         %s$ %s%s\n' "$C_D" "$*" "$C_0" >&2
  _journal '[$]' "preflight fix: $*"
}

# --------------------------------------------------------------------------- #
#  Small readers                                                              #
# --------------------------------------------------------------------------- #
_pf_cfg_first() {
  # The first non-empty value among a list of CFG keys, so that this step keeps
  # working while the neighbouring steps settle on a name. Prints on stdout.
  local key
  for key in "$@"; do
    if [[ -n "${CFG[$key]:-}" ]]; then
      printf '%s\n' "${CFG[$key]}"
      return 0
    fi
  done
  return 1
}

_pf_package_for() {
  # Gentoo package that provides a command. A missing tool with no package name
  # beside it costs a web search, which is the thing this step exists to save.
  case "$1" in
    lsblk | blkid | wipefs | findmnt | mount | umount | swapon | mountpoint)
      printf 'sys-apps/util-linux\n'
      ;;
    sgdisk | sfdisk) printf 'sys-apps/gptfdisk\n' ;;
    parted | partprobe) printf 'sys-block/parted\n' ;;
    mkfs.ext4 | e2fsck | tune2fs) printf 'sys-fs/e2fsprogs\n' ;;
    mkfs.fat | mkfs.vfat | fatlabel) printf 'sys-fs/dosfstools\n' ;;
    mkfs.xfs) printf 'sys-fs/xfsprogs\n' ;;
    mkfs.btrfs | btrfs) printf 'sys-fs/btrfs-progs\n' ;;
    mkfs.f2fs) printf 'sys-fs/f2fs-tools\n' ;;
    cryptsetup) printf 'sys-fs/cryptsetup\n' ;;
    gpg | gpgv) printf 'app-crypt/gnupg\n' ;;
    tpm2_pcrread | tpm2_getcap) printf 'app-crypt/tpm2-tools\n' ;;
    efibootmgr) printf 'sys-boot/efibootmgr\n' ;;
    grub-install | grub-mkconfig) printf 'sys-boot/grub\n' ;;
    curl) printf 'net-misc/curl\n' ;;
    wget) printf 'net-misc/wget\n' ;;
    tar) printf 'app-arch/tar\n' ;;
    xz | unxz) printf 'app-arch/xz-utils\n' ;;
    chroot | nproc | date | df | stat | getent) printf 'sys-apps/coreutils\n' ;;
    awk | gawk) printf 'sys-apps/gawk\n' ;;
    chronyd) printf 'net-misc/chrony\n' ;;
    ntpd) printf 'net-misc/ntp\n' ;;
    *) printf 'unknown package\n' ;;
  esac
}

_pf_mirror_url() {
  printf '%s\n' "${CFG[mirror]:-https://distfiles.gentoo.org}"
}

_pf_mirror_host() {
  local url
  url="$(_pf_mirror_url)"
  url="${url#*://}"
  url="${url%%/*}"
  url="${url%%\?*}"
  printf '%s\n' "${url%%:*}"
}

_pf_http_head() {
  # Response headers of a HEAD request, on stdout. Empty and non-zero when the
  # fetch fails, whichever tool did the fetching.
  local url="$1"
  if have curl; then
    curl -sSIL --max-time "$_PF_NET_TIMEOUT" -- "$url" 2>/dev/null
  elif have wget; then
    wget -q --timeout="$_PF_NET_TIMEOUT" --tries=1 --server-response \
      --spider -- "$url" 2>&1
  else
    return 1
  fi
}

_pf_tcp_probe() {
  # Last-resort reachability when neither curl nor wget is installed. The host
  # and the port reach the inner shell through the environment, never through
  # the text of the script it runs.
  local host="$1" port="$2"
  have timeout || return 1
  # shellcheck disable=SC2016  # single quotes are the point: the child shell
  # expands these, not this one. The directive goes before the whole command;
  # inside the line continuation it would eat the argument to bash -c.
  GI_PF_HOST="$host" GI_PF_PORT="$port" \
    timeout "$_PF_NET_TIMEOUT" bash -c \
    'exec 3<>"/dev/tcp/${GI_PF_HOST}/${GI_PF_PORT}"' 2>/dev/null
}

_pf_meminfo_kb() {
  # Args: $1 = a /proc/meminfo field name. Prints kB, or 0.
  local value
  value="$(awk -v k="$1:" '$1 == k { print $2; exit }' /proc/meminfo 2>/dev/null)"
  printf '%s\n' "${value:-0}"
}

_pf_wants_crypt() {
  local value
  value="$(_pf_cfg_first crypt encrypt luks 2>/dev/null)" || return 1
  [[ "$value" != "no" && "$value" != "none" ]]
}

_pf_wants_tpm() {
  local value
  value="$(_pf_cfg_first crypt_tpm tpm tpm2 2>/dev/null)" || value=""
  if [[ "$value" == "yes" || "$value" == "tpm2" ]]; then
    return 0
  fi
  case "$(_pf_cfg_first crypt encrypt luks variant 2>/dev/null || true)" in
    *tpm*) return 0 ;;
  esac
  return 1
}

# --------------------------------------------------------------------------- #
#  1 — privileges                                                             #
# --------------------------------------------------------------------------- #
_pf_check_root() {
  local uid="${EUID:-$(id -u)}"
  if ((uid == 0)); then
    _pf_verdict PASS root "Privileges" "uid 0"
    return 0
  fi
  if [[ "$DRY_RUN" == "yes" ]]; then
    _pf_verdict SKIP root "Privileges" "uid ${uid}, --dry-run changes nothing"
    _pf_note "Reviewing the plan needs no privileges, by design. Everything from"
    _pf_note "step 20 onwards does."
    return 0
  fi
  _pf_verdict FAIL root "Privileges" "uid ${uid}, not root"
  _pf_note "Partitioning a disk, unpacking a stage tarball and entering a chroot"
  _pf_note "all need uid 0. There is no partial mode that works without it."
  _pf_fix "sudo ./gentoo-install.sh"
  return 0
}

# --------------------------------------------------------------------------- #
#  2 — firmware: this is what decides which bootloaders exist                 #
# --------------------------------------------------------------------------- #
_pf_check_firmware() {
  local size=""

  if [[ ! -d /sys/firmware/efi ]]; then
    set_default firmware "bios"
    _pf_verdict WARN firmware "Firmware" "legacy BIOS (no /sys/firmware/efi)"
    _pf_note "The machine was booted in BIOS/CSM mode, so the firmware will not"
    _pf_note "read an EFI system partition and systemd-boot and an EFI stub are"
    _pf_note "both off the table. GRUB on a BIOS boot partition is what is left,"
    _pf_note "and step 20 must reserve a 1 MiB partition of type ef02 for it."
    _pf_note "If this machine is meant to boot UEFI, this is a firmware setting:"
    _pf_note "turn CSM / Legacy Boot off and boot the install medium again. A"
    _pf_note "system installed in BIOS mode does not become a UEFI one later."
    _pf_fix "sgdisk --new=1:0:+1M --typecode=1:ef02 /dev/sdX   # if BIOS is intended"
    return 0
  fi

  set_default firmware "uefi"
  if [[ -r /sys/firmware/efi/fw_platform_size ]]; then
    size="$(cat /sys/firmware/efi/fw_platform_size 2>/dev/null || true)"
  fi

  if [[ "$size" == "32" ]]; then
    _pf_verdict WARN firmware "Firmware" "UEFI, 32-bit platform on a 64-bit CPU"
    _pf_note "The firmware only loads 32-bit EFI binaries, so a plain amd64 GRUB"
    _pf_note "image will not start. Build the loader for the i386-efi target."
    _pf_fix "grub-install --target=i386-efi --efi-directory=/boot/efi"
    return 0
  fi

  if ! grep -q ' /sys/firmware/efi/efivars ' /proc/self/mounts 2>/dev/null; then
    _pf_verdict WARN firmware "Firmware" "UEFI ${size:-64}-bit, efivarfs not mounted"
    _pf_note "efibootmgr writes the boot entry through efivarfs. Without it step"
    _pf_note "80 installs the loader onto the ESP and the firmware never learns"
    _pf_note "it is there, which looks exactly like a failed install at reboot."
    _pf_fix "mount -t efivarfs efivarfs /sys/firmware/efi/efivars"
    return 0
  fi

  _pf_verdict PASS firmware "Firmware" "UEFI ${size:-64}-bit, efivars mounted"
  _pf_note "GRUB (x86_64-efi), systemd-boot and a bare EFI stub are all possible."
  return 0
}

# --------------------------------------------------------------------------- #
#  3 — architecture                                                           #
# --------------------------------------------------------------------------- #
_pf_host_arch() {
  case "$(uname -m)" in
    x86_64 | amd64) printf 'amd64\n' ;;
    i?86) printf 'x86\n' ;;
    aarch64 | arm64) printf 'arm64\n' ;;
    armv7* | armv6*) printf 'arm\n' ;;
    ppc64le) printf 'ppc64le\n' ;;
    riscv64) printf 'riscv\n' ;;
    *) uname -m ;;
  esac
}

_pf_check_arch() {
  local host want
  host="$(_pf_host_arch)"
  want="${CFG[arch]:-amd64}"

  if [[ "$host" == "$want" ]]; then
    _pf_verdict PASS arch "Architecture" "$(uname -m) → ${want}"
    return 0
  fi

  if [[ "$host" == "amd64" && "$want" == "x86" ]]; then
    _pf_verdict WARN arch "Architecture" "amd64 host, x86 target"
    _pf_note "A 64-bit kernel runs 32-bit userland, so this install can be built"
    _pf_note "here. Make sure it is deliberate: a 32-bit Gentoo on this machine"
    _pf_note "caps the address space at 4 GiB per process for good."
    _pf_fix "./gentoo-install.sh --arch amd64"
    return 0
  fi

  _pf_verdict FAIL arch "Architecture" "${host} host, ${want} target"
  _pf_note "The stage3 for ${want} holds binaries this CPU cannot execute, so the"
  _pf_note "chroot in step 50 fails with 'Exec format error' after the disks have"
  _pf_note "already been partitioned. That is why this is checked here."
  _pf_fix "./gentoo-install.sh --arch ${host}"
  return 0
}

# --------------------------------------------------------------------------- #
#  4 — tools, each with the package that carries it                           #
# --------------------------------------------------------------------------- #
_pf_required_tools() {
  # Always needed, whatever the configuration.
  printf '%s\n' lsblk blkid wipefs findmnt mount umount tar chroot awk date df

  # Partitioning: either of the two is enough, so they are checked as a pair
  # further down rather than listed here.

  # Fetching the stage.
  if have curl || have wget; then
    :
  else
    printf '%s\n' curl
  fi

  case "$(_pf_cfg_first fs filesystem root_fs 2>/dev/null || printf 'ext4')" in
    btrfs) printf '%s\n' mkfs.btrfs ;;
    xfs) printf '%s\n' mkfs.xfs ;;
    f2fs) printf '%s\n' mkfs.f2fs ;;
    *) printf '%s\n' mkfs.ext4 ;;
  esac

  if [[ "${CFG[firmware]:-uefi}" == "uefi" ]]; then
    printf '%s\n' mkfs.fat efibootmgr
  fi
  if _pf_wants_crypt; then
    printf '%s\n' cryptsetup
  fi
  if [[ "${CFG[verify_signatures]:-yes}" == "yes" ]]; then
    printf '%s\n' gpg
  fi
}

_pf_check_tools() {
  local tool pkg
  local -a required=() missing=() install=()

  mapfile -t required < <(_pf_required_tools)

  for tool in "${required[@]}"; do
    if ! have "$tool"; then
      missing+=("$tool")
    fi
  done

  if ! have sgdisk && ! have sfdisk && ! have parted; then
    missing+=("sgdisk")
  fi

  if ((${#missing[@]} == 0)); then
    _pf_verdict PASS tools "Required tools" "${#required[@]} present"
    return 0
  fi

  _pf_verdict FAIL tools "Required tools" "${#missing[@]} of ${#required[@]} missing"
  for tool in "${missing[@]}"; do
    pkg="$(_pf_package_for "$tool")"
    _pf_note "$(printf '%-14s %s' "$tool" "$pkg")"
    install+=("$pkg")
  done
  _pf_note "On the official Gentoo install medium every one of these is already"
  _pf_note "there; a missing one usually means a rescue image that is not it."
  mapfile -t install < <(printf '%s\n' "${install[@]}" | sort -u)
  _pf_fix "emerge --ask --oneshot ${install[*]}"
  return 0
}

# --------------------------------------------------------------------------- #
#  5 — connectivity                                                           #
# --------------------------------------------------------------------------- #
_pf_check_network() {
  local url host

  url="$(_pf_mirror_url)"
  host="$(_pf_mirror_host)"

  if _pf_http_head "$url" >/dev/null 2>&1; then
    _pf_verdict PASS network "Connectivity" "${host} answers"
    return 0
  fi

  if _pf_tcp_probe "$host" 443 || _pf_tcp_probe "$host" 80; then
    _pf_verdict WARN network "Connectivity" "${host} accepts TCP, no HTTP client"
    _pf_note "The host is reachable but neither curl nor wget is installed, so"
    _pf_note "step 40 has nothing to fetch the stage tarball with."
    _pf_fix "emerge --ask --oneshot net-misc/curl"
    return 0
  fi

  if ! ip route show default 2>/dev/null | grep -q .; then
    _pf_verdict FAIL network "Connectivity" "no default route"
    _pf_note "The machine has no way off its own link, so nothing can be fetched."
    _pf_note "On the Gentoo install medium, in this order:"
    _pf_fix "ip link                      # find the interface name"
    _pf_fix "dhcpcd <interface>           # or: net-setup <interface>"
    _pf_fix "ip route show default        # confirm a route appeared"
    return 0
  fi

  _pf_verdict FAIL network "Connectivity" "${host} unreachable"
  _pf_note "A default route exists, so this is a firewall, a captive portal or a"
  _pf_note "mirror that is down. Try another mirror before blaming the network."
  _pf_fix "curl -sSI --max-time ${_PF_NET_TIMEOUT} ${url}"
  _pf_fix "./gentoo-install.sh --config /etc/gentoo-install.conf   # mirror = ..."
  return 0
}

# --------------------------------------------------------------------------- #
#  6 — name resolution, told apart from connectivity on purpose               #
# --------------------------------------------------------------------------- #
_pf_check_dns() {
  local host addr line

  host="$(_pf_mirror_host)"

  if ! have getent; then
    _pf_verdict SKIP dns "DNS resolution" "getent is not installed"
    return 0
  fi

  addr="$(getent ahosts "$host" 2>/dev/null | awk 'NR == 1 { print $1 }')"
  if [[ -n "$addr" ]]; then
    _pf_verdict PASS dns "DNS resolution" "${host} → ${addr}"
    return 0
  fi

  _pf_verdict FAIL dns "DNS resolution" "${host} does not resolve"
  _pf_note "This is told apart from connectivity because the fix is different: a"
  _pf_note "reachable network with no resolver still fails every fetch, and the"
  _pf_note "error emerge prints for it names the mirror, not the resolver."
  if [[ -e /etc/resolv.conf ]]; then
    _pf_note "/etc/resolv.conf currently holds:"
    while IFS= read -r line; do
      _pf_note "  ${line}"
    done < <(grep -E '^[[:space:]]*(nameserver|search|domain)' /etc/resolv.conf 2>/dev/null || true)
  else
    _pf_note "/etc/resolv.conf does not exist."
  fi
  _pf_fix "printf 'nameserver 1.1.1.1\\nnameserver 9.9.9.9\\n' > /etc/resolv.conf"
  _pf_fix "getent ahosts ${host}"
  return 0
}

# --------------------------------------------------------------------------- #
#  7 — the clock, and why a wrong one is an incomprehensible failure           #
# --------------------------------------------------------------------------- #
_pf_source_epoch() {
  # The newest file of this installer: the code cannot predate itself, so this
  # is a lower bound on the real time that needs no network and no trust.
  local newest dir
  dir="${SCRIPT_DIR:-${BASH_SOURCE[0]%/*}/..}"
  newest="$(find "$dir" -maxdepth 2 -type f -printf '%T@\n' 2>/dev/null \
    | sort -rn | head -n 1)"
  printf '%s\n' "${newest%%.*}"
}

_pf_check_clock() {
  local now floor remote remote_epoch skew url

  now="$(date -u +%s)"
  floor="$(_pf_source_epoch)"
  url="$(_pf_mirror_url)"

  if [[ "$floor" =~ ^[0-9]+$ ]] && ((now < floor)); then
    _pf_verdict FAIL clock "System clock" "$(date -u '+%Y-%m-%d %H:%M:%SZ'), before this installer existed"
    _pf_note "The clock reads earlier than the newest file of gentoo-install, so"
    _pf_note "it is wrong by at least $(((floor - now) / 86400)) day(s)."
    _pf_note "A clock in the past makes every Gentoo release key look 'not yet"
    _pf_note "valid' and every TLS certificate look 'not yet valid' too. What"
    _pf_note "you would see instead is gpg saying BAD signature, which sends an"
    _pf_note "operator hunting a compromised mirror that is not compromised."
    _pf_fix "hwclock --hctosys                       # trust the RTC"
    _pf_fix "chronyd -q 'server pool.ntp.org iburst' # or trust the network"
    _pf_fix "date -u -s '$(date -u -d "@${floor}" '+%Y-%m-%d %H:%M:%S')'  # or set it by hand"
    return 0
  fi

  remote="$(_pf_http_head "$url" 2>/dev/null \
    | awk 'BEGIN { IGNORECASE = 1 } /^ *date:/ { sub(/^ *[Dd]ate: */, ""); sub(/\r$/, ""); print; exit }')"

  if [[ -z "$remote" ]]; then
    _pf_verdict WARN clock "System clock" "$(date -u '+%Y-%m-%d %H:%M:%SZ'), unverified"
    _pf_note "No Date header came back from ${url}, so the clock was only checked"
    _pf_note "against this installer's own files. It is plausible, not proven."
    _pf_fix "chronyd -q 'server pool.ntp.org iburst'"
    return 0
  fi

  remote_epoch="$(date -u -d "$remote" +%s 2>/dev/null || true)"
  if [[ ! "$remote_epoch" =~ ^[0-9]+$ ]]; then
    _pf_verdict WARN clock "System clock" "mirror sent an unparsable date"
    _pf_note "The header read: ${remote}"
    return 0
  fi

  skew=$((now - remote_epoch))
  if ((skew < 0)); then
    skew=$((-skew))
  fi

  if ((skew <= _PF_MAX_SKEW_SEC)); then
    _pf_verdict PASS clock "System clock" "$(date -u '+%Y-%m-%d %H:%M:%SZ'), ${skew}s off the mirror"
    return 0
  fi

  _pf_verdict FAIL clock "System clock" "${skew}s off the mirror ($((skew / 3600))h)"
  _pf_note "Local  $(date -u '+%Y-%m-%d %H:%M:%SZ')"
  _pf_note "Mirror $(date -u -d "@${remote_epoch}" '+%Y-%m-%d %H:%M:%SZ')"
  _pf_note "More than $((_PF_MAX_SKEW_SEC / 60)) minutes of skew breaks GPG signature"
  _pf_note "verification and TLS certificate validity. The failure it produces"
  _pf_note "names the signature, never the clock, which is why it is checked now."
  _pf_fix "chronyd -q 'server pool.ntp.org iburst'"
  _pf_fix "date -u -s '$(date -u -d "@${remote_epoch}" '+%Y-%m-%d %H:%M:%S')'"
  _pf_fix "hwclock --systohc   # and write it back to the RTC afterwards"
  return 0
}

# --------------------------------------------------------------------------- #
#  8 — the target disk                                                        #
# --------------------------------------------------------------------------- #
_pf_check_disk() {
  local disk size_bytes size_gib holders mounted tmp_avail_mib line

  if ! disk="$(_pf_cfg_first disk target_disk device 2>/dev/null)"; then
    _pf_verdict FAIL disk "Target disk" "none configured"
    _pf_note "Step 20 has nothing to partition. Name the disk explicitly: this"
    _pf_note "installer never guesses which disk it may destroy."
    if have lsblk; then
      _pf_note "Disks on this machine:"
      while IFS= read -r line; do
        _pf_note "  ${line}"
      done < <(lsblk -dn -o NAME,SIZE,TYPE,MODEL 2>/dev/null \
        | awk '$3 == "disk" { $3 = ""; print "/dev/" $0 }' || true)
    fi
    _pf_fix "./gentoo-install.sh --config /etc/gentoo-install.conf   # disk = /dev/nvme0n1"
    return 0
  fi

  if [[ ! -b "$disk" ]]; then
    _pf_verdict FAIL disk "Target disk" "${disk} is not a block device"
    _pf_note "Nothing at that path, or it is a regular file. A typo here is the"
    _pf_note "one that partitions the wrong disk, so it stops the run."
    _pf_fix "lsblk -dn -o NAME,SIZE,TYPE,MODEL"
    return 0
  fi

  size_bytes="$(blockdev --getsize64 "$disk" 2>/dev/null \
    || lsblk -bdn -o SIZE "$disk" 2>/dev/null || printf '0')"
  size_gib=$((size_bytes / 1073741824))

  mounted="$(findmnt -rno TARGET --source "$disk" 2>/dev/null | head -n 1 || true)"
  if [[ -z "$mounted" ]] && have lsblk; then
    mounted="$(lsblk -rno MOUNTPOINT "$disk" 2>/dev/null | grep -m1 . || true)"
  fi
  if [[ -n "$mounted" ]]; then
    _pf_verdict FAIL disk "Target disk" "${disk} carries a live mount (${mounted})"
    _pf_note "Something on this disk is mounted right now, which on an install"
    _pf_note "medium usually means it is the medium itself, or the machine you"
    _pf_note "meant to keep. Partitioning it would pull the floor out mid-run."
    _pf_fix "lsblk ${disk}"
    _pf_fix "umount -R ${mounted}   # only once you are sure what it is"
    return 0
  fi

  if ((size_gib < _PF_MIN_ROOT_GIB)); then
    _pf_verdict FAIL disk "Target disk" "${disk}, ${size_gib} GiB, minimum ${_PF_MIN_ROOT_GIB}"
    _pf_note "A stage3 unpacks to roughly 1.5 GiB, the portage tree to 1.5 GiB,"
    _pf_note "and one @world build needs several more for its temporary files."
    _pf_note "Below ${_PF_MIN_ROOT_GIB} GiB the install runs out during a compile, hours in."
    _pf_fix "lsblk -dn -o NAME,SIZE,TYPE,MODEL"
    return 0
  fi

  holders="$(lsblk -rno FSTYPE,PARTTYPENAME "$disk" 2>/dev/null \
    | grep -c . || true)"

  if ((size_gib < _PF_WANT_ROOT_GIB)); then
    _pf_verdict WARN disk "Target disk" "${disk}, ${size_gib} GiB (comfortable from ${_PF_WANT_ROOT_GIB})"
    _pf_note "Enough for a base system. A desktop @world, rust and llvm together"
    _pf_note "will make this tight; PORTAGE_TMPDIR alone can hold 20 GiB."
  else
    _pf_verdict PASS disk "Target disk" "${disk}, ${size_gib} GiB, not mounted"
  fi

  if ((holders > 0)); then
    _pf_note "It already holds ${holders} labelled partition(s) or filesystem(s);"
    _pf_note "step 20 will ask for a typed confirmation before erasing them."
  fi

  tmp_avail_mib="$(df -Pm /var/tmp 2>/dev/null | awk 'NR == 2 { print $4 }')"
  if [[ "$tmp_avail_mib" =~ ^[0-9]+$ ]] && ((tmp_avail_mib < 8192)); then
    _pf_note "/var/tmp on this medium has only ${tmp_avail_mib} MiB free. If PORTAGE_TMPDIR"
    _pf_note "is left there, a large build fails with no space rather than with a"
    _pf_note "compiler error. Step 60 should point it inside the target instead."
  fi
  return 0
}

# --------------------------------------------------------------------------- #
#  9 — memory and swap, judged as one budget                                  #
# --------------------------------------------------------------------------- #
_pf_check_memory() {
  local mem_mib swap_mib total_mib cpus jobs

  mem_mib=$(($(_pf_meminfo_kb MemTotal) / 1024))
  swap_mib=$(($(_pf_meminfo_kb SwapTotal) / 1024))
  total_mib=$((mem_mib + swap_mib))
  cpus="$(nproc 2>/dev/null || printf '1')"

  jobs=$((total_mib / _PF_MIB_PER_JOB))
  if ((jobs < 1)); then
    jobs=1
  fi
  if ((jobs > cpus)); then
    jobs="$cpus"
  fi

  if ((total_mib < _PF_MIN_MEM_MIB)); then
    _pf_verdict FAIL memory "Memory for building" "${mem_mib} MiB RAM + ${swap_mib} MiB swap"
    _pf_note "Below ${_PF_MIN_MEM_MIB} MiB the kernel link step is killed by the OOM killer,"
    _pf_note "which shows up as a compile that stops with no error at all."
    _pf_note "Swap on the target disk counts, and is the cheapest way out:"
    _pf_fix "fallocate -l 8G /mnt/gentoo/swapfile && chmod 600 /mnt/gentoo/swapfile"
    _pf_fix "mkswap /mnt/gentoo/swapfile && swapon /mnt/gentoo/swapfile"
    return 0
  fi

  if ((total_mib < _PF_WANT_MEM_MIB)); then
    _pf_verdict WARN memory "Memory for building" "${mem_mib} MiB RAM + ${swap_mib} MiB swap"
    _pf_note "Enough to finish, not enough to parallelise. rust, llvm and webkit"
    _pf_note "each want about 2 GiB per job at link time."
  else
    _pf_verdict PASS memory "Memory for building" "${mem_mib} MiB RAM + ${swap_mib} MiB swap, ${cpus} cpu(s)"
  fi

  _pf_note "Memory allows ${jobs} parallel job(s) on ${cpus} cpu(s):"
  _pf_note "  MAKEOPTS=\"-j${jobs}\"  in /etc/portage/make.conf (step 60 writes it)"
  if ((swap_mib == 0)); then
    _pf_note "No swap is active. One large link with nothing to spill into is how"
    _pf_note "an eight-hour build ends in an OOM kill:"
    _pf_fix "fallocate -l 8G /mnt/gentoo/swapfile && chmod 600 /mnt/gentoo/swapfile"
    _pf_fix "mkswap /mnt/gentoo/swapfile && swapon /mnt/gentoo/swapfile"
  fi
  return 0
}

# --------------------------------------------------------------------------- #
#  10 — TPM, only when the encryption variant asks for one                    #
# --------------------------------------------------------------------------- #
_pf_check_tpm() {
  local major=""

  if ! _pf_wants_tpm; then
    _pf_verdict SKIP tpm "TPM 2.0" "no TPM binding requested"
    if _pf_wants_crypt; then
      _pf_note "The container will be opened by passphrase at every boot."
    fi
    return 0
  fi

  if [[ ! -e /sys/class/tpm/tpm0 ]]; then
    _pf_verdict FAIL tpm "TPM 2.0" "no /sys/class/tpm/tpm0"
    _pf_note "A TPM binding was asked for and this kernel exposes no TPM at all:"
    _pf_note "the module is not loaded, or the firmware hides the device. Sealing"
    _pf_note "a key to it in step 30 would produce a machine that cannot open its"
    _pf_note "own root filesystem."
    _pf_fix "modprobe tpm_tis && ls /sys/class/tpm"
    _pf_fix "dmesg | grep -i tpm"
    return 0
  fi

  if [[ -r /sys/class/tpm/tpm0/tpm_version_major ]]; then
    major="$(cat /sys/class/tpm/tpm0/tpm_version_major 2>/dev/null || true)"
  fi
  if [[ -n "$major" && "$major" != "2" ]]; then
    _pf_verdict FAIL tpm "TPM 2.0" "TPM ${major}.x present, 2.0 required"
    _pf_note "systemd-cryptenrol and clevis both speak TPM 2.0 only. A 1.2 device"
    _pf_note "cannot be used for this, and there is no upgrade path in software."
    _pf_fix "# switch the firmware to TPM 2.0 if it offers both, or drop the binding"
    return 0
  fi

  if [[ ! -e /dev/tpmrm0 ]]; then
    _pf_verdict WARN tpm "TPM 2.0" "present, /dev/tpmrm0 missing"
    _pf_note "The in-kernel resource manager is what every userspace tool talks"
    _pf_note "to. Without it the sealing in step 30 fails on a healthy TPM."
    _pf_fix "modprobe tpm_tis && ls -l /dev/tpmrm0"
    return 0
  fi

  if ! have tpm2_pcrread; then
    _pf_verdict WARN tpm "TPM 2.0" "2.0 at /dev/tpmrm0, tpm2-tools absent"
    _pf_note "The device is usable but nothing here can read a PCR, so the before"
    _pf_note "and after comparison a reseal needs cannot be made."
    _pf_fix "emerge --ask --oneshot $(_pf_package_for tpm2_pcrread)"
    return 0
  fi

  _pf_verdict PASS tpm "TPM 2.0" "2.0 at /dev/tpmrm0, tpm2-tools present"
  _pf_note "A firmware update changes PCR 0 and breaks a policy sealed on it."
  _pf_note "Keep a passphrase in a second keyslot; step 30 adds one by default."
  return 0
}

# --------------------------------------------------------------------------- #
#  11 — the Gentoo release keyring                                            #
# --------------------------------------------------------------------------- #
_pf_check_keyring() {
  local candidate found="" key_count=0

  if [[ "${CFG[verify_signatures]:-yes}" != "yes" ]]; then
    _pf_verdict WARN keyring "Gentoo keyring" "signature verification is off"
    _pf_note "verify_signatures = no means step 40 trusts whatever the mirror"
    _pf_note "sends. A compromised or hijacked mirror then picks your stage3."
    _pf_fix "./gentoo-install.sh   # the default is to verify"
    return 0
  fi

  for candidate in \
    /usr/share/openpgp-keys/gentoo-release.asc \
    /usr/share/openpgp-keys/gentoo-release.gpg \
    /usr/share/gnupg/gentoo-release.asc; do
    if [[ -r "$candidate" ]]; then
      found="$candidate"
      break
    fi
  done

  if [[ -z "$found" ]]; then
    _pf_verdict FAIL keyring "Gentoo keyring" "gentoo-release keys not found"
    _pf_note "Step 40 verifies the clearsigned latest-stage3 file and then the"
    _pf_note "tarball's own detached signature. Both need the release keyring,"
    _pf_note "and fetching it from the same mirror it is meant to police proves"
    _pf_note "nothing — which is why it is a package, not a download."
    _pf_fix "emerge --ask --oneshot app-crypt/openpgp-keys-gentoo-release"
    _pf_fix "ls /usr/share/openpgp-keys/gentoo-release.asc"
    return 0
  fi

  if ! have gpg; then
    _pf_verdict FAIL keyring "Gentoo keyring" "keys at ${found}, gpg absent"
    _pf_fix "emerge --ask --oneshot $(_pf_package_for gpg)"
    return 0
  fi

  key_count="$(gpg --show-keys --with-colons -- "$found" 2>/dev/null \
    | grep -c '^pub' || true)"
  # [[ -eq ]] rather than (( )): a bare name inside an arithmetic context
  # reads as a possible array subscript to shellcheck (SC2178).
  if [[ "$key_count" -eq 0 ]]; then
    _pf_verdict FAIL keyring "Gentoo keyring" "${found} holds no public key"
    _pf_note "gpg parses the file but finds nothing in it. A truncated download"
    _pf_note "or an HTML error page saved under that name looks exactly so."
    _pf_fix "gpg --show-keys ${found}"
    _pf_fix "emerge --ask --oneshot app-crypt/openpgp-keys-gentoo-release"
    return 0
  fi

  _pf_verdict PASS keyring "Gentoo keyring" "${key_count} release key(s) in ${found##*/}"
  return 0
}

# --------------------------------------------------------------------------- #
#  The aggregate                                                              #
# --------------------------------------------------------------------------- #
_pf_journal_result() {
  # The journal records what was found, never a secret and never a device the
  # operator has not confirmed. Silent when there is no journal to write to.
  local result="$1"
  [[ -n "${STATE_FILE:-}" ]] || return 0
  state_set "preflight.result" "$result" || true
  state_set "preflight.checks" \
    "total=${_PF_TOTAL} fail=${#_PF_FAILED[@]} warn=${#_PF_WARNED[@]}" || true
  state_set "preflight.firmware" "${CFG[firmware]:-unknown}" || true
  if ((${#_PF_FAILED[@]} > 0)); then
    state_set "preflight.failed" "${_PF_FAILED[*]}" || true
  else
    state_unset "preflight.failed" || true
  fi
  if ((${#_PF_WARNED[@]} > 0)); then
    state_set "preflight.warned" "${_PF_WARNED[*]}" || true
  else
    state_unset "preflight.warned" || true
  fi
}

step_10_preflight() {
  local name

  _PF_INDEX=0
  _PF_FAILED=()
  _PF_WARNED=()
  _PF_TOTAL=${#_PF_CHECKS[@]}

  log "pre-flight: ${_PF_TOTAL} checks, nothing is modified"
  printf '\n' >&2

  for name in "${_PF_CHECKS[@]}"; do
    "_pf_check_${name}"
  done

  printf '\n' >&2

  if ((${#_PF_FAILED[@]} > 0)); then
    _pf_journal_result "fail"
    err "Pre-flight failed: ${#_PF_FAILED[@]} blocking, ${#_PF_WARNED[@]} warning(s)"
    err "       blocking: ${_PF_FAILED[*]}"
    err "       each one above carries the command that fixes it"
    err "       --force does not lift these: they are proofs, not confirmations"
    err "       fix them, then: ./gentoo-install.sh --steps 10"
    return "$EXIT_FAILURE"
  fi

  if ((${#_PF_WARNED[@]} > 0)); then
    _pf_journal_result "warn"
    warn "Pre-flight passed with ${#_PF_WARNED[@]} warning(s): ${_PF_WARNED[*]}"
    if [[ "$FORCE" == "yes" ]]; then
      warn "       --force given, continuing without asking"
      ok "pre-flight: ${_PF_TOTAL} checks, no blocking finding"
      return "$EXIT_SUCCESS"
    fi
    if ! confirm "Continue with ${#_PF_WARNED[@]} warning(s)?" "no"; then
      err "Stopped at pre-flight; nothing was changed."
      err "       --yes or --force answers this question up front"
      return "$EXIT_FAILURE"
    fi
    ok "pre-flight: ${_PF_TOTAL} checks, ${#_PF_WARNED[@]} warning(s) accepted"
    return "$EXIT_SUCCESS"
  fi

  _pf_journal_result "pass"
  ok "pre-flight: ${_PF_TOTAL} checks, all clear"
  return "$EXIT_SUCCESS"
}
