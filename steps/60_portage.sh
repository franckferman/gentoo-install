#!/usr/bin/env bash
#
# gentoo-install — step 60: Portage — profile, make.conf, tree, package sets
# ----------------------------------------------------------------------------
# Everything the target's /etc/portage has to say before a single package is
# built: the profile that matches the init system and the flavour, a make.conf
# whose MAKEOPTS is computed from this machine's cores *and* its memory, the
# ebuild tree, the three per-package directories, and the package set that
# data/packages describes.
#
# Two rules carry this file. The profile is never set on trust — the directory
# is looked up in the synced tree first, so a profile that is not there is a
# sentence naming every candidate tried instead of eselect's "invalid profile"
# on a machine three steps into an install. And make.conf is written, then
# handed to `emerge --info`, then rolled back when Portage refuses it: one
# unbalanced quote in that file makes every later emerge fail with a parse
# error that names no file at all.
#
# Nothing here is a literal list. Profiles come from data/profiles.tsv, the
# graphics drivers from data/video-cards.tsv, the packages from
# data/packages/*.list through the inheritance table in data/packages/sets.tsv.
#
# Usage:  sourced by gentoo-install.sh, which calls step_60_portage()
#
set -euo pipefail

if [[ -n "${_GI_STEP_60_LOADED:-}" ]]; then
  return 0
fi
_GI_STEP_60_LOADED=1

# Where this file sits, so data/ and lib/ are found whether the repository runs
# in place or from an install prefix.
_gi_step60_self="$(readlink -f -- "${BASH_SOURCE[0]}")"
_gi_step60_base="${_gi_step60_self%/*}"
_gi_step60_base="${_gi_step60_base%/*}"
GI_LIB_DIR="${GI_LIB_DIR:-${_gi_step60_base}/lib}"
GI_DATA_DIR="${GI_DATA_DIR:-${_gi_step60_base}/data}"
unset _gi_step60_self _gi_step60_base

# The entry point sources the libraries before this file, so these guards never
# fire in production. They exist so that `shellcheck steps/60_portage.sh` and a
# standalone source of this file both see what the runner sees.
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
if [[ -z "${_GI_CHROOT_LOADED:-}" ]]; then
  # shellcheck source=lib/chroot.sh
  source "${GI_LIB_DIR}/chroot.sh"
fi

# --------------------------------------------------------------------------- #
#  Constants                                                                  #
# --------------------------------------------------------------------------- #
# 2048 MiB per parallel job is the number steps/10_preflight.sh already judges
# the machine against (_PF_MIB_PER_JOB) and announces as "step 60 writes it".
# The two have to agree, so the value is written twice and named twice rather
# than being a magic 2048 in either place.
readonly _PORTAGE_MIB_PER_JOB=2048

# The marked block gentoo-install owns inside make.conf. The tag is the one
# docs/DESIGN.md §8 uses as its example, on purpose: this is that file.
readonly _PORTAGE_TAG_MAKE_CONF="portage make.conf"

# The Portage set this step generates, emerged as @gentoo-install.
readonly _PORTAGE_SET_NAME="gentoo-install"

# One subject, one file, and the numeric prefix keeps the order readable.
readonly _PORTAGE_FILE_STEM="10-gentoo-install"

# A malformed inheritance table must not spin forever.
readonly _PORTAGE_MAX_DEPTH=10

# Counted so the step can end with "4 of 9 parts changed something" instead of
# claiming success it did not have to earn.
_PORTAGE_CHANGED=0

# Filled as the step goes, read by the summary and by the state journal.
PORTAGE_PROFILE=""
PORTAGE_MAKEOPTS=""

# --------------------------------------------------------------------------- #
#  Settings                                                                   #
# --------------------------------------------------------------------------- #
portage_init_defaults() {
  # Declared here rather than in lib/config.sh so the step stays one file.
  # set_default never overwrites an explicit value, so calling this twice, or
  # after parse_args, is harmless.
  #
  # Safe by default: nothing here builds for a CPU the operator did not name,
  # accepts a licence they did not accept, or installs a desktop they did not
  # ask for.
  set_default portage_profile ""        # empty: data/profiles.tsv decides
  set_default portage_sync "webrsync"   # webrsync|rsync|none
  set_default portage_sync_max_age "24" # hours; a younger tree is left alone
  set_default portage_makeopts ""       # empty: computed from cores and memory
  set_default portage_common_flags "-O2 -pipe"
  set_default portage_use "" # added to what the profile row asks for
  set_default portage_accept_license "-* @FREE"
  set_default portage_video_cards ""    # empty: detect through data/video-cards.tsv
  set_default portage_grub_platforms "" # empty: follow the firmware
  set_default portage_tmpdir "/var/tmp" # a path inside the target, not on the host
  set_default portage_emerge_opts "--verbose --with-bdeps=y --complete-graph=y --nospinner"
  set_default portage_packages ""        # empty: derived from the flavour and the layout
  set_default portage_package_use ""     # "atom flags; atom flags"
  set_default portage_accept_keywords "" # "atom keyword; atom keyword"

  # Conservative by default: each of these costs hours the operator did not
  # ask for, and the comment names what leaving it off means.
  set_default portage_emerge_set "yes" # no: the set file is written, nothing is built
  set_default portage_update_world "no"
}

portage_validate_sync() {
  # Stage 1 of the three validations (DESIGN.md §5): the value must be
  # spellable, and the message says what each spelling means.
  validate_enum "Portage tree sync method" "$1" "${2:---portage-sync}" \
    "webrsync:a signed daily snapshot over HTTPS: one file, GPG-checked, and it crosses a proxy" \
    "rsync:rsync to a mirror: the tree as of an hour ago, but rsync/873 is often filtered" \
    "none:leave the tree exactly as the stage3 shipped it"
}

# --------------------------------------------------------------------------- #
#  Reading the configuration                                                  #
# --------------------------------------------------------------------------- #
_portage_cfg() {
  # First non-empty CFG value among the candidate keys, else the fallback.
  # Args: $1 = fallback, $2.. = keys. Prints on stdout: it is a returned value.
  local fallback="$1" key
  shift
  for key in "$@"; do
    if [[ -n "${CFG[$key]:-}" ]]; then
      printf '%s\n' "${CFG[$key]}"
      return 0
    fi
  done
  printf '%s\n' "$fallback"
}

_portage_data_dir() {
  printf '%s\n' "${DATA_DIR:-$GI_DATA_DIR}"
}

_portage_root() {
  # Where the target is mounted. chroot_target() already honours GI_TARGET;
  # this looks at the setting first so that an explicit --root outranks it.
  # It used to look at three names for the same directory, on the theory that
  # a step dying because a sibling spelled it differently is worse than one
  # that looks everywhere. It is not: two of the three were never set by
  # anything, and the one an operator could set moved some steps and not others.
  local root
  root="$(_portage_cfg "" root)"
  if [[ -z "$root" ]]; then
    root="$(chroot_target)"
  fi
  printf '%s\n' "${root%/}"
}

_portage_init() { _portage_cfg "openrc" init; }
_portage_arch() { _portage_cfg "amd64" arch; }
_portage_flavour() { _portage_cfg "base" flavour; }

_portage_firmware() {
  # uefi or bios, and it decides GRUB_PLATFORMS. Three sources in the order
  # DESIGN.md §5 demands: the flag, then what step 10 recorded, then the way
  # this very boot happened.
  local mode
  mode="$(_portage_cfg "" firmware)"
  if [[ -z "$mode" ]]; then
    mode="$(state_get "preflight.firmware" 2>/dev/null || true)"
  fi
  if [[ -z "$mode" || "$mode" == "unknown" ]]; then
    if [[ -d /sys/firmware/efi ]]; then
      mode="uefi"
    else
      mode="bios"
    fi
  fi
  printf '%s\n' "$mode"
}

_portage_record() {
  # Args: $1 = key suffix, $2 = value. Never a secret: state.sh refuses those
  # and nothing here has one to offer.
  [[ -n "${STATE_FILE:-}" ]] || return 0
  state_set "portage.${1}" "$2" || true
}

_portage_note_change() {
  if [[ "$WRITE_RESULT" == "written" ]]; then
    _PORTAGE_CHANGED=$((_PORTAGE_CHANGED + 1))
  fi
}

# --------------------------------------------------------------------------- #
#  MAKEOPTS — the engine half: it returns a record and says nothing (§7)       #
# --------------------------------------------------------------------------- #
_portage_cpu_count() {
  local cpus=""
  cpus="$(nproc 2>/dev/null || true)"
  if [[ ! "$cpus" =~ ^[0-9]+$ || "$cpus" -lt 1 ]]; then
    cpus="$(grep -c '^processor' /proc/cpuinfo 2>/dev/null || true)"
  fi
  if [[ ! "$cpus" =~ ^[0-9]+$ || "$cpus" -lt 1 ]]; then
    cpus=1
  fi
  printf '%s\n' "$cpus"
}

_portage_meminfo_mib() {
  # Args: $1 = a /proc/meminfo field name. Prints MiB, or 0.
  local kb=""
  kb="$(awk -v k="$1:" '$1 == k { print $2; exit }' /proc/meminfo 2>/dev/null || true)"
  [[ "$kb" =~ ^[0-9]+$ ]] || kb=0
  printf '%s\n' "$((kb / 1024))"
}

portage_job_record() {
  # cores|usable MiB|jobs memory allows|jobs chosen|what capped it
  #
  # -j equal to the core count is the advice everybody repeats and it is how a
  # 32-core machine with 8 GiB dies linking the kernel: the OOM killer takes a
  # compiler process and the build stops with no error worth reading. A
  # parallel job wants about 2 GiB at link time — rust, llvm and webkit all
  # do — so the memory budget and the core count are both ceilings and the
  # smaller one wins. Swap counts: spilling is slow, being killed is fatal.
  local cpus mem swap total by_mem jobs capped
  cpus="$(_portage_cpu_count)"
  mem="$(_portage_meminfo_mib MemTotal)"
  swap="$(_portage_meminfo_mib SwapTotal)"
  total=$((mem + swap))

  by_mem=$((total / _PORTAGE_MIB_PER_JOB))
  if ((by_mem < 1)); then
    by_mem=1
  fi

  if ((by_mem < cpus)); then
    jobs=$by_mem
    capped="memory"
  else
    jobs=$cpus
    capped="cores"
  fi

  printf '%s|%s|%s|%s|%s\n' "$cpus" "$total" "$by_mem" "$jobs" "$capped"
}

portage_makeopts() {
  # The value make.conf gets. An explicit setting is never second-guessed.
  local explicit record cpus total by_mem jobs capped
  explicit="$(_portage_cfg "" portage_makeopts)"
  if [[ -n "$explicit" ]]; then
    printf '%s\n' "$explicit"
    return 0
  fi
  record="$(portage_job_record)"
  IFS='|' read -r cpus total by_mem jobs capped <<<"$record"
  : "$cpus" "$total" "$by_mem" "$capped"
  printf -- '-j%s\n' "$jobs"
}

show_portage_makeopts() {
  # The rendering half: it prints and changes nothing. Showing the arithmetic
  # is the point — an operator who disagrees with -j4 on a 32-core machine can
  # only argue with a number they can see.
  local explicit record cpus total by_mem jobs capped
  explicit="$(_portage_cfg "" portage_makeopts)"
  if [[ -n "$explicit" ]]; then
    log "MAKEOPTS: \"${explicit}\" (set explicitly, not computed)"
    return 0
  fi
  record="$(portage_job_record)"
  IFS='|' read -r cpus total by_mem jobs capped <<<"$record"
  log "MAKEOPTS: ${cpus} core(s), ${total} MiB of RAM+swap"
  log "       memory: ${total} / ${_PORTAGE_MIB_PER_JOB} MiB per job = ${by_mem} job(s)"
  log "       cores:  ${cpus} job(s)"
  log "       the smaller wins, capped by ${capped}:  MAKEOPTS=\"-j${jobs}\""
}

# --------------------------------------------------------------------------- #
#  The ebuild tree                                                            #
# --------------------------------------------------------------------------- #
portage_repo_path() {
  # Where the gentoo repository lives *inside* the target. Portage itself is
  # asked first; the two historical locations are the fallback, because a dry
  # run has nothing to ask and a stage3 that has never synced answers nothing.
  # Args: $1 = root. Prints an absolute path inside the target.
  local root="$1" answer candidate
  answer="$(chroot_capture portageq get_repo_path / gentoo 2>/dev/null || true)"
  answer="${answer%%$'\n'*}"
  if [[ -n "$answer" && "$answer" == /* ]]; then
    printf '%s\n' "$answer"
    return 0
  fi
  for candidate in /var/db/repos/gentoo /usr/portage; do
    if [[ -d "${root}${candidate}" ]]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  # The modern default. Nothing is there yet, which is what the sync is for.
  printf '%s\n' "/var/db/repos/gentoo"
}

_portage_tree_age_hours() {
  # Age of the synced tree in hours, or 1 when it cannot be told.
  # Args: $1 = root, $2 = repo path inside the target.
  local root="$1" repo="$2" stamp mtime now
  stamp="${root}${repo}/metadata/timestamp.chk"
  [[ -f "$stamp" ]] || return 1
  mtime="$(stat -c %Y -- "$stamp" 2>/dev/null || true)"
  [[ "$mtime" =~ ^[0-9]+$ ]] || return 1
  now="$(date +%s)"
  printf '%s\n' "$(((now - mtime) / 3600))"
}

portage_ensure_repos_conf() {
  # emerge --sync needs the repository to be declared. A stage3 ships the
  # declaration under /usr/share/portage/config/repos.conf, which Portage reads
  # but which an operator cannot edit without it being overwritten by the next
  # portage upgrade; the handbook's copy into /etc/portage/repos.conf is what
  # makes it theirs.
  local root="$1" target source
  target="${root}/etc/portage/repos.conf/gentoo.conf"
  source="${root}/usr/share/portage/config/repos.conf"

  if [[ -f "$target" ]]; then
    skip "/etc/portage/repos.conf/gentoo.conf: already there"
    return 0
  fi
  if [[ ! -f "$source" && "$DRY_RUN" != "yes" ]]; then
    warn "no ${source} to copy: the stage3 declares the repository elsewhere"
    return 0
  fi
  run_cmd mkdir -p -- "${root}/etc/portage/repos.conf" || return 1
  if run_cmd cp -a -- "$source" "$target"; then
    ok "/etc/portage/repos.conf/gentoo.conf: copied from the stage3 defaults"
    _PORTAGE_CHANGED=$((_PORTAGE_CHANGED + 1))
    return 0
  fi
  err "could not copy ${source} to ${target}"
  return 1
}

portage_sync_tree() {
  # emerge-webrsync fetches one signed daily snapshot over HTTPS and checks its
  # GPG signature, which is both faster on a fresh install and able to cross a
  # proxy; emerge --sync speaks rsync to a mirror and gives the tree as of an
  # hour ago, at the cost of a port (873) that firewalls routinely drop.
  # Args: $1 = root, $2 = repo path inside the target.
  local root="$1" repo="$2" method max_age age
  method="$(_portage_cfg "webrsync" portage_sync)"
  portage_validate_sync "$method" "--portage-sync"

  if [[ "$method" == "none" ]]; then
    skip "Portage tree: left as the stage3 shipped it (portage_sync = none)"
    return 0
  fi

  max_age="$(_portage_cfg "24" portage_sync_max_age)"
  [[ "$max_age" =~ ^[0-9]+$ ]] || max_age=24
  if age="$(_portage_tree_age_hours "$root" "$repo")"; then
    if ((age < max_age)); then
      skip "Portage tree: synced ${age}h ago, under the ${max_age}h threshold"
      return 0
    fi
    log "Portage tree: ${age}h old, syncing"
  else
    log "Portage tree: not there yet, syncing"
  fi

  case "$method" in
    webrsync)
      if chroot_run emerge-webrsync; then
        ok "Portage tree: signed snapshot unpacked (emerge-webrsync)"
        _PORTAGE_CHANGED=$((_PORTAGE_CHANGED + 1))
        return 0
      fi
      err "emerge-webrsync failed inside ${root}"
      err "       the snapshot is fetched over HTTPS and its signature checked"
      err "       a clock more than a day out makes that signature look invalid"
      err "       rsync is the other way in:  portage_sync = rsync"
      return 1
      ;;
    rsync)
      if chroot_run emerge --sync --quiet; then
        ok "Portage tree: synced over rsync"
        _PORTAGE_CHANGED=$((_PORTAGE_CHANGED + 1))
        return 0
      fi
      err "emerge --sync failed inside ${root}"
      err "       rsync speaks port 873, which firewalls and hotel networks drop"
      err "       the signed HTTPS snapshot needs neither:  portage_sync = webrsync"
      return 1
      ;;
  esac
}

# --------------------------------------------------------------------------- #
#  The profile                                                                #
# --------------------------------------------------------------------------- #
_portage_profiles_tsv() {
  local file
  file="$(_portage_data_dir)/profiles.tsv"
  if [[ ! -r "$file" ]]; then
    err "Cannot read the profile catalogue: ${file}"
    err "       data/profiles.tsv maps (flavour, init) to a Portage profile"
    err "       set GI_DATA_DIR if the data directory is not beside the script"
    return 1
  fi
  printf '%s\n' "$file"
}

portage_profile_row() {
  # The data/profiles.tsv record for a (flavour, init, arch) triple, tabs and
  # all. Args: $1 = flavour, $2 = init, $3 = arch.
  local flavour="$1" init="$2" arch="$3" file
  file="$(_portage_profiles_tsv)" || return 1
  awk -F'\t' -v f="$flavour" -v i="$init" -v a="$arch" \
    '$1 == f && $2 == i && $3 == a { print; found = 1; exit } END { exit(found ? 0 : 1) }' \
    "$file"
}

_portage_profile_candidates() {
  # The profile named by the row, then its fallbacks, left to right. The 23.0
  # profiles arrived in 2023 and the 17.x ones outlived them in real trees, so
  # a snapshot from before the switch still installs.
  # Args: $1 = the row.
  local row="$1" wanted fallbacks item
  wanted="$(printf '%s' "$row" | cut -f5)"
  fallbacks="$(printf '%s' "$row" | cut -f6)"
  [[ -n "$wanted" ]] && printf '%s\n' "$wanted"
  [[ -n "$fallbacks" && "$fallbacks" != "-" ]] || return 0
  # `|| [[ -n "$item" ]]`: tr leaves no newline after the last field, and a
  # bare `read` reports EOF for it — which silently drops the last fallback,
  # the one that carries the 17.1 profiles a pre-2023 tree still has.
  while IFS= read -r item || [[ -n "$item" ]]; do
    item="${item#"${item%%[![:space:]]*}"}"
    item="${item%"${item##*[![:space:]]}"}"
    [[ -n "$item" && "$item" != "-" ]] || continue
    printf '%s\n' "$item"
  done < <(printf '%s' "$fallbacks" | tr ',' '\n')
}

_portage_profile_index() {
  # The number `eselect profile list` gives a profile, for the eselect versions
  # that only take a number. Args: $1 = profile name.
  local name="$1" listing
  listing="$(chroot_capture eselect profile list 2>/dev/null || true)"
  [[ -n "$listing" ]] || return 1
  printf '%s\n' "$listing" \
    | awk -v p="$name" '$2 == p { gsub(/[][]/, "", $1); print $1; exit }' \
    | grep -E '^[0-9]+$'
}

_portage_current_profile() {
  # What /etc/portage/make.profile points at, as a profile name.
  # Args: $1 = root.
  local root="$1" link
  link="$(readlink -f -- "${root}/etc/portage/make.profile" 2>/dev/null || true)"
  [[ -n "$link" && "$link" == */profiles/* ]] || return 1
  printf '%s\n' "${link#*/profiles/}"
}

portage_select_profile() {
  # Pick a profile, prove it exists in the tree, then set it. Fills
  # PORTAGE_PROFILE. Args: $1 = root, $2 = repo path inside the target.
  local root="$1" repo="$2" flavour init arch row explicit current chosen="" index
  local -a candidates=() missing=()

  flavour="$(_portage_flavour)"
  init="$(_portage_init)"
  arch="$(_portage_arch)"
  explicit="$(_portage_cfg "" portage_profile)"

  if [[ -n "$explicit" ]]; then
    candidates=("$explicit")
  else
    if ! row="$(portage_profile_row "$flavour" "$init" "$arch")"; then
      err "No Portage profile for flavour '${flavour}' with init '${init}' on ${arch}"
      err "       data/profiles.tsv holds one record per (flavour, init) pair"
      err "       name one by hand to skip the table entirely:"
      err "       example:  portage_profile = default/linux/amd64/23.0/desktop/plasma"
      return 1
    fi
    mapfile -t candidates < <(_portage_profile_candidates "$row")
    _portage_warn_experimental "$row"
  fi

  if ((${#candidates[@]} == 0)); then
    err "data/profiles.tsv names no profile for ${flavour}/${init}/${arch}"
    return 1
  fi

  # The directory test, before eselect gets a say. `eselect profile set` on a
  # name the tree does not carry says "invalid profile" and nothing else; this
  # can name every candidate it tried and the directory it looked in.
  for index in "${candidates[@]}"; do
    if [[ -d "${root}${repo}/profiles/${index}" ]]; then
      chosen="$index"
      break
    fi
    missing+=("$index")
  done

  if [[ -z "$chosen" ]]; then
    if [[ "$DRY_RUN" == "yes" && ! -d "${root}${repo}/profiles" ]]; then
      # Nothing was synced, because nothing runs in a dry run. Report the
      # first choice rather than a failure that only means "not yet".
      chosen="${candidates[0]}"
      log "dry-run: would select the profile ${chosen}"
      PORTAGE_PROFILE="$chosen"
      return 0
    fi
    err "None of the candidate profiles exists in ${repo}"
    for index in "${missing[@]}"; do
      err "       tried: ${index}"
    done
    err "       the tree may be older or newer than this table expects"
    err "       list what it really offers:  chroot ${root} eselect profile list"
    err "       example:  portage_profile = default/linux/amd64/17.1"
    return 1
  fi

  if ((${#missing[@]} > 0)); then
    log "profile: ${missing[*]} not in this tree, falling back"
  fi

  PORTAGE_PROFILE="$chosen"

  if current="$(_portage_current_profile "$root")" && [[ "$current" == "$chosen" ]]; then
    skip "profile: already ${chosen}"
    return 0
  fi

  # `eselect profile list` is what the operator would read, and on the eselect
  # versions that refuse a name it is also where the number comes from.
  index="$(_portage_profile_index "$chosen" || true)"
  if [[ -n "$index" ]]; then
    log "profile: ${chosen} is [${index}] in eselect's list"
  fi

  if chroot_run eselect profile set "$chosen"; then
    ok "profile: set to ${chosen}"
    _PORTAGE_CHANGED=$((_PORTAGE_CHANGED + 1))
    return 0
  fi

  if [[ -n "$index" ]] && chroot_run eselect profile set "$index"; then
    ok "profile: set to ${chosen} (by number, this eselect refuses names)"
    _PORTAGE_CHANGED=$((_PORTAGE_CHANGED + 1))
    return 0
  fi

  err "eselect profile set ${chosen} failed inside ${root}"
  err "       the directory ${repo}/profiles/${chosen} exists, so this is eselect"
  err "       see the list it works from:  chroot ${root} eselect profile list"
  return 1
}

_portage_warn_experimental() {
  # The status column of data/profiles.tsv, said out loud. A profile upstream
  # publishes as experimental is a legitimate choice and a surprise nobody
  # should get from a table they did not read. Args: $1 = the row.
  local row="$1" status
  status="$(printf '%s' "$row" | cut -f7)"
  case "$status" in
    exp)
      warn "this profile is experimental upstream: expect masked packages and churn"
      ;;
    dev)
      warn "this profile is a development profile: it moves faster than stable"
      ;;
  esac
}

portage_profile_use() {
  # The USE delta the profile row asks for, or nothing. Most rows are "-", and
  # that is the point: the profile carries the distribution's opinion and USE
  # in make.conf is a delta on top of it (DESIGN.md §15).
  local flavour init arch row use
  flavour="$(_portage_flavour)"
  init="$(_portage_init)"
  arch="$(_portage_arch)"
  row="$(portage_profile_row "$flavour" "$init" "$arch")" || return 0
  use="$(printf '%s' "$row" | cut -f8)"
  [[ -n "$use" && "$use" != "-" ]] || return 0
  printf '%s\n' "$use"
}

# --------------------------------------------------------------------------- #
#  VIDEO_CARDS                                                                #
# --------------------------------------------------------------------------- #
portage_video_cards() {
  # data/video-cards.tsv, first match wins, rows ordered specific to general.
  # When nothing matches the variable is left out of make.conf entirely: the
  # profile's own default is a better answer than a guessed one.
  local explicit file display match cards
  explicit="$(_portage_cfg "" portage_video_cards)"
  if [[ -n "$explicit" ]]; then
    printf '%s\n' "$explicit"
    return 0
  fi

  file="$(_portage_data_dir)/video-cards.tsv"
  [[ -r "$file" ]] || return 1
  have lspci || return 1
  display="$(lspci 2>/dev/null | grep -Ei 'VGA compatible|Display controller|3D controller' || true)"
  [[ -n "$display" ]] || return 1

  while IFS=$'\t' read -r match cards _; do
    [[ -n "$match" && "${match:0:1}" != "#" ]] || continue
    [[ -n "$cards" ]] || continue
    if grep -qiF -- "$match" <<<"$display"; then
      printf '%s\n' "$cards"
      return 0
    fi
  done <"$file"
  return 1
}

portage_grub_platforms() {
  # sys-boot/grub builds one platform per GRUB_PLATFORMS entry, and getting it
  # wrong is found out at grub-install time, after the compile.
  local explicit
  explicit="$(_portage_cfg "" portage_grub_platforms)"
  if [[ -n "$explicit" ]]; then
    printf '%s\n' "$explicit"
    return 0
  fi
  if [[ "$(_portage_firmware)" == "bios" ]]; then
    printf '%s\n' "pc"
  else
    printf '%s\n' "efi-64"
  fi
}

# --------------------------------------------------------------------------- #
#  make.conf — the engine half: it prints a body and touches nothing (§7)      #
# --------------------------------------------------------------------------- #
portage_make_conf_body() {
  local flags makeopts use profile_use extra license tmpdir opts cards platforms
  local record cpus total by_mem jobs capped

  flags="$(_portage_cfg "-O2 -pipe" portage_common_flags)"
  makeopts="$(portage_makeopts)"
  license="$(_portage_cfg "-* @FREE" portage_accept_license)"
  tmpdir="$(_portage_cfg "/var/tmp" portage_tmpdir)"
  opts="$(_portage_cfg "" portage_emerge_opts)"
  platforms="$(portage_grub_platforms)"

  profile_use="$(portage_profile_use)"
  extra="$(_portage_cfg "" portage_use)"
  use="${profile_use}${profile_use:+ }${extra}"
  use="${use%"${use##*[![:space:]]}"}"

  record="$(portage_job_record)"
  IFS='|' read -r cpus total by_mem jobs capped <<<"$record"
  : "$by_mem" "$jobs"

  # An unquoted heredoc, so that the computed values land and the \$ escapes
  # stay literal: CFLAGS has to reference COMMON_FLAGS in the written file, not
  # in this shell.
  cat <<EOF
# Written by gentoo-install. Everything between the markers is replaced on the
# next run; anything you add outside them is kept.
#
# COMMON_FLAGS is re-exported into CFLAGS and friends right here on purpose.
# The make.conf a stage3 ships assigns CFLAGS="\${COMMON_FLAGS}" *above* this
# block, so a COMMON_FLAGS set below it would never reach them and the flags
# you thought you changed would be the stage's.
COMMON_FLAGS="${flags}"
CFLAGS="\${COMMON_FLAGS}"
CXXFLAGS="\${COMMON_FLAGS}"
FCFLAGS="\${COMMON_FLAGS}"
FFLAGS="\${COMMON_FLAGS}"

# -march=native builds for this exact CPU. The binaries then die with SIGILL
# on any other machine — including the real one, when the build happened in a
# VM that hid half the instruction set:
#     portage_common_flags = "-O2 -pipe -march=native"

# ${cpus} core(s), ${total} MiB of RAM+swap, ${_PORTAGE_MIB_PER_JOB} MiB per parallel job: capped by ${capped}.
# -j equal to the core count is how a 32-core machine with 8 GiB is killed by
# the OOM killer halfway through linking the kernel, with no error to read.
MAKEOPTS="${makeopts}"

# A delta on top of the profile, never a replacement for it.
USE="${use}"

# The two licence groups Gentoo ships. Anything else is granted per package in
# /etc/portage/package.license, so accepting a firmware blob stays a decision
# about that one package.
ACCEPT_LICENSE="${license}"
EOF

  if cards="$(portage_video_cards)"; then
    cat <<EOF

# Detected from lspci through data/video-cards.tsv.
VIDEO_CARDS="${cards}"
EOF
  else
    cat <<'EOF'

# No graphics device matched data/video-cards.tsv, so VIDEO_CARDS is left to
# the profile rather than guessed. Name it if you know better:
#     portage_video_cards = "amdgpu radeonsi"
EOF
  fi

  cat <<EOF

# One platform per entry, and each one is a separate build of sys-boot/grub.
GRUB_PLATFORMS="${platforms}"

# A path inside the installed system, not on the host. /var/tmp is on the root
# filesystem, which is where a 20 GiB webkit build needs the room to be.
PORTAGE_TMPDIR="${tmpdir}"

# --keep-going is deliberately absent: it turns one broken package into a
# report nobody reads and a world that is half updated. Add it knowingly:
#     portage_emerge_opts = "${opts} --keep-going"
EMERGE_DEFAULT_OPTS="${opts}"
EOF
}

PORTAGE_EMERGE_REFUSAL=""

portage_validate_make_conf() {
  # `emerge --info` parses make.conf, the profile and every repository before
  # printing a line, so it is the checker this file has. sshd -t, visudo -c and
  # findmnt --verify are the same idea in the same project.
  #
  # Its own words are kept, because the caller used to guess at the reason and
  # guessed wrong: "one unbalanced quote is enough" about a make.conf that
  # emerge had refused to look at for a reason it stated plainly.
  PORTAGE_EMERGE_REFUSAL=""
  chroot_run_quiet emerge --info && return 0
  PORTAGE_EMERGE_REFUSAL="$(chroot "$CHROOT_ROOT" /bin/bash -c \
    "$_GI_CHROOT_PRELUDE" emerge --info 2>&1 | tail -n 5 || true)"
  return 1
}

portage_write_make_conf() {
  # Write the marked block, then let Portage have the last word, then put the
  # backup back when it objects. Args: $1 = root.
  local root="$1" conf body rc=0 _line
  conf="${root}/etc/portage/make.conf"

  body="$(portage_make_conf_body)" || {
    err "could not compose make.conf"
    return 1
  }

  # Unconditionally, before the write: the rollback below needs a copy even
  # when --on-conflict would not have taken one.
  backup_file "$conf" || return 1

  write_block "$conf" "$_PORTAGE_TAG_MAKE_CONF" <<EOF || rc=$?
${body}
EOF
  if ((rc != 0)); then
    return "$rc"
  fi
  if [[ "$WRITE_RESULT" != "written" ]]; then
    return 0
  fi
  _PORTAGE_CHANGED=$((_PORTAGE_CHANGED + 1))

  # PORTAGE_TMPDIR is read before anything is built, and a path that is not
  # there is a build that stops on its first ebuild.
  run_cmd mkdir -p -- "${root}$(_portage_cfg "/var/tmp" portage_tmpdir)" || true

  if [[ "$DRY_RUN" == "yes" ]]; then
    log "dry-run: would validate ${conf} with emerge --info inside the chroot"
    return 0
  fi

  if portage_validate_make_conf; then
    ok "${conf}: accepted by emerge --info"
    return 0
  fi

  err "${conf}: rejected by emerge --info"
  if restore_backup "$conf"; then
    err "       the previous make.conf is back in place"
  else
    err "       there was no previous make.conf; ${conf} is left as written"
  fi
  if [[ -n "$PORTAGE_EMERGE_REFUSAL" ]]; then
    err "       what it said:"
    while IFS= read -r _line; do
      [[ -n "$_line" ]] && err "         ${_line}"
    done <<<"$PORTAGE_EMERGE_REFUSAL"
  else
    err "       one unbalanced quote is enough, and Portage names no file"
  fi
  err "       read it in full:  chroot ${root} /bin/bash -lc 'emerge --info'"
  WRITE_RESULT="failed"
  return 1
}

# --------------------------------------------------------------------------- #
#  package.use, package.accept_keywords, package.license — directories        #
# --------------------------------------------------------------------------- #
_portage_ensure_dir() {
  # Each of the three is a directory here, never a file, so that one subject is
  # one file and two subjects never collide in a diff. A stage3 that shipped
  # one as a regular file is converted, and whatever it held is kept.
  # Args: $1 = absolute path.
  local path="$1" keep
  if [[ -d "$path" ]]; then
    return 0
  fi
  if [[ -e "$path" ]]; then
    if [[ "$DRY_RUN" == "yes" ]]; then
      log "dry-run: would turn the file ${path} into a directory"
      return 0
    fi
    keep="$(cat -- "$path" 2>/dev/null || true)"
    backup_file "$path" || return 1
    rm -f -- "$path" || return 1
    mkdir -p -- "$path" || {
      err "cannot create ${path}"
      return 1
    }
    if [[ -n "${keep//[[:space:]]/}" ]]; then
      write_file "${path}/00-from-stage3" <<EOF
# Kept from the regular file gentoo-install found here and turned into a
# directory. Nothing in this project writes to it again.
${keep}
EOF
    fi
    ok "${path}: was a file, is now a directory"
    return 0
  fi
  run_cmd mkdir -p -- "$path"
}

_portage_records() {
  # Split "atom flags; atom flags" into one record per line. Args: $1 = value.
  local value="$1" item
  [[ -n "$value" ]] || return 0
  # The last field has no newline after it, so EOF and "one more record" arrive
  # together; a bare `read` would throw that record away.
  while IFS= read -r item || [[ -n "$item" ]]; do
    item="${item#"${item%%[![:space:]]*}"}"
    item="${item%"${item##*[![:space:]]}"}"
    [[ -n "$item" ]] || continue
    printf '%s\n' "$item"
  done < <(printf '%s' "$value" | tr ';' '\n')
}

portage_write_package_use() {
  local root="$1" dir records
  dir="${root}/etc/portage/package.use"
  _portage_ensure_dir "$dir" || return 1
  records="$(_portage_records "$(_portage_cfg "" portage_package_use)")"
  write_file "${dir}/${_PORTAGE_FILE_STEM}" <<EOF
# gentoo-install — per-package USE flags
# ---------------------------------------------------------------------------
# One atom per line, then its flags:
#
#     media-video/ffmpeg  x264 x265 -vaapi
#
# The profile already carries the distribution's opinion; this file and USE in
# make.conf are the delta on top of it. gentoo-install adds nothing of its own
# here, because an installer that fills this file with its author's taste is an
# installer nobody else can use.
#
#     portage_package_use = "media-video/ffmpeg x264; app-editors/vim python"
${records}
EOF
  _portage_note_change
}

portage_write_accept_keywords() {
  local root="$1" dir records
  dir="${root}/etc/portage/package.accept_keywords"
  _portage_ensure_dir "$dir" || return 1
  records="$(_portage_records "$(_portage_cfg "" portage_accept_keywords)")"
  write_file "${dir}/${_PORTAGE_FILE_STEM}" <<EOF
# gentoo-install — testing keywords, per package
# ---------------------------------------------------------------------------
# An atom and the keyword it is allowed to use:
#
#     app-editors/vim  ~amd64
#
# Empty by default, and that is the conservative answer: one ~amd64 package
# pulls its ~amd64 dependencies, and an install that started stable ends up
# half testing without anyone deciding it should.
#
#     portage_accept_keywords = "app-editors/vim ~amd64"
${records}
EOF
  _portage_note_change
}

portage_license_records() {
  # Licence grants read out of the package lists themselves. A list that says
  #
  #     sys-kernel/linux-firmware   # LICENCE: needs @BINARY-REDISTRIBUTABLE
  #
  # is the only place that knows why the grant exists, so it is the place the
  # grant is taken from — not a literal in this function (DESIGN.md §10).
  # Args: $@ = the .list files, in order.
  local file line atom comment group
  for file in "$@"; do
    [[ -r "$file" ]] || continue
    while IFS= read -r line || [[ -n "$line" ]]; do
      [[ "$line" == *"#"* ]] || continue
      comment="${line#*#}"
      atom="${line%%#*}"
      atom="${atom#"${atom%%[![:space:]]*}"}"
      atom="${atom%"${atom##*[![:space:]]}"}"
      [[ -n "$atom" ]] || continue
      if [[ "$comment" =~ LICEN[SC]E:[[:space:]]+needs[[:space:]]+([^,[:space:]]+) ]]; then
        group="${BASH_REMATCH[1]}"
        printf '%s %s\n' "$atom" "$group"
      fi
    done <"$file"
  done
}

portage_write_package_license() {
  # Args: $1 = root, $2.. = the .list files of the resolved set.
  local root="$1" dir records
  shift
  dir="${root}/etc/portage/package.license"
  _portage_ensure_dir "$dir" || return 1
  records="$(portage_license_records "$@")"
  write_file "${dir}/${_PORTAGE_FILE_STEM}" <<EOF
# gentoo-install — licence grants, per package
# ---------------------------------------------------------------------------
# ACCEPT_LICENSE in make.conf is "-* @FREE": nothing but free software is
# accepted globally. Each line below lifts that for exactly one package, and
# every one of them was read out of the comment beside the atom in
# data/packages/*.list, where the reason is written down.
#
#     sys-firmware/intel-microcode  @BINARY-REDISTRIBUTABLE intel-ucode
${records}
EOF
  _portage_note_change
}

# --------------------------------------------------------------------------- #
#  Package sets — data/packages/sets.tsv is the inheritance table              #
# --------------------------------------------------------------------------- #
_portage_sets_tsv() {
  local file
  file="$(_portage_data_dir)/packages/sets.tsv"
  if [[ ! -r "$file" ]]; then
    err "Cannot read the package set table: ${file}"
    err "       data/packages/sets.tsv declares each set and what it inherits"
    err "       set GI_DATA_DIR if the data directory is not beside the script"
    return 1
  fi
  printf '%s\n' "$file"
}

portage_known_sets() {
  local file
  file="$(_portage_sets_tsv)" || return 1
  awk -F'\t' '$1 !~ /^#/ && NF > 1 { print $1 }' "$file"
}

_portage_set_parent() {
  # The inherits column, empty for a root set. Fails when the set is unknown.
  local want="$1" file
  file="$(_portage_sets_tsv)" || return 1
  awk -F'\t' -v s="$want" \
    '$1 == s { if ($2 != "-") print $2; found = 1; exit } END { exit(found ? 0 : 1) }' \
    "$file"
}

portage_set_chain() {
  # A set and everything it inherits, root first, so concatenating the .list
  # files in this order reads the way the inheritance table reads.
  # Args: $1 = set name.
  local want="$1" current parent depth=0
  local -a chain=()
  current="$want"
  while [[ -n "$current" ]]; do
    depth=$((depth + 1))
    if ((depth > _PORTAGE_MAX_DEPTH)); then
      err "package set inheritance loops at '${current}'"
      err "       data/packages/sets.tsv has a cycle in its inherits column"
      return 1
    fi
    if ! parent="$(_portage_set_parent "$current")"; then
      err "Unknown package set: ${current}"
      err "       valid values: $(portage_known_sets | tr '\n' ' ')"
      err "       example:  portage_packages = minimal"
      return 1
    fi
    chain=("$current" "${chain[@]}")
    current="$parent"
  done
  printf '%s\n' "${chain[@]}"
}

portage_selected_set() {
  # Which set to install. The flavour and the disk layout share the vocabulary
  # of data/packages/sets.tsv, so either can name one — but only when the
  # operator actually asked for it, since both carry a default of their own and
  # a plain run must not quietly install a desktop.
  local want candidate
  want="$(_portage_cfg "" portage_packages)"
  if [[ -n "$want" ]]; then
    printf '%s\n' "$want"
    return 0
  fi
  for candidate in flavour disk_layout; do
    if is_explicit "$candidate" && [[ -n "${CFG[$candidate]:-}" ]]; then
      if portage_known_sets | grep -qxF -- "${CFG[$candidate]}"; then
        printf '%s\n' "${CFG[$candidate]}"
        return 0
      fi
    fi
  done
  printf '%s\n' "minimal"
}

portage_set_files() {
  # The .list files of a set, root first, then the init overlay. Prints paths.
  # Args: $1 = set name, $2 = init.
  local want="$1" init="$2" dir name file declared parent
  local -a chain=()
  dir="$(_portage_data_dir)/packages"
  mapfile -t chain < <(portage_set_chain "$want") || return 1
  ((${#chain[@]} > 0)) || return 1

  for name in "${chain[@]}"; do
    file="${dir}/${name}.list"
    if [[ ! -r "$file" ]]; then
      err "data/packages/sets.tsv declares '${name}' but ${file} is missing"
      return 1
    fi
    # The .list header repeats its parent. Cross-checking the two is the only
    # way to notice that one of them was edited and the other was not.
    declared="$(awk '/^# inherits:/ { print $3; exit }' "$file")"
    parent="$(_portage_set_parent "$name" || true)"
    if [[ -n "$declared" && "$declared" != "${parent:--}" ]]; then
      warn "${name}.list says it inherits '${declared}', sets.tsv says '${parent:--}'"
    fi
    printf '%s\n' "$file"
  done

  file="${dir}/init-${init}.list"
  if [[ -r "$file" ]]; then
    printf '%s\n' "$file"
  else
    warn "no overlay for init '${init}': ${file} is missing"
  fi
}

portage_set_atoms() {
  # One atom per line, in file order, each one once. Args: $@ = the .list files.
  local file line atom
  local -A seen=()
  for file in "$@"; do
    [[ -r "$file" ]] || continue
    while IFS= read -r line || [[ -n "$line" ]]; do
      atom="${line%%#*}"
      atom="${atom#"${atom%%[![:space:]]*}"}"
      atom="${atom%"${atom##*[![:space:]]}"}"
      [[ -n "$atom" ]] || continue
      [[ -z "${seen[$atom]:-}" ]] || continue
      seen[$atom]=1
      printf '%s\n' "$atom"
    done <"$file"
  done
}

portage_write_set() {
  # Args: $1 = root, $2 = set name, $3 = the atoms, one per line.
  local root="$1" name="$2" atoms="$3" dir
  dir="${root}/etc/portage/sets"
  _portage_ensure_dir "$dir" || return 1
  write_file "${dir}/${_PORTAGE_SET_NAME}" <<EOF
# gentoo-install — the package set this install asked for: ${name}
# ---------------------------------------------------------------------------
# Generated from data/packages/sets.tsv and the .list files it names, root set
# first. Emerging it registers the set in /var/lib/portage/world_sets, so a
# later 'emerge --update --deep --newuse @world' keeps these packages too.
#
# Rebuild it by hand at any time:  emerge --noreplace @${_PORTAGE_SET_NAME}
${atoms}
EOF
  _portage_note_change
}

portage_emerge_set() {
  # Args: $1 = root, $2 = how many atoms the set holds.
  local root="$1" count="$2" want
  want="$(_portage_cfg "yes" portage_emerge_set)"
  if [[ "$want" != "yes" ]]; then
    skip "@${_PORTAGE_SET_NAME}: written, not built (portage_emerge_set = no)"
    log "       build it when you are ready:  chroot ${root} emerge --noreplace @${_PORTAGE_SET_NAME}"
    return 0
  fi
  if ((count == 0)); then
    skip "@${_PORTAGE_SET_NAME}: nothing to build, the set is empty"
    return 0
  fi

  log "building @${_PORTAGE_SET_NAME}: ${count} package(s), and their dependencies"
  # --noreplace is what makes a rerun cheap: a package already installed is
  # left alone instead of being rebuilt to the same version.
  if chroot_run emerge --noreplace --quiet-build=n "@${_PORTAGE_SET_NAME}"; then
    ok "@${_PORTAGE_SET_NAME}: built"
    _PORTAGE_CHANGED=$((_PORTAGE_CHANGED + 1))
    return 0
  fi
  err "emerge @${_PORTAGE_SET_NAME} failed inside ${root}"
  err "       a blocked or masked package stops the whole set, and names itself"
  err "       retry just that one:  chroot ${root} emerge --ask <atom>"
  err "       or write the set now and build it later:  portage_emerge_set = no"
  return 1
}

portage_update_world() {
  # Changing the profile changes USE for everything the stage3 already carries.
  # Rebuilding it is the handbook's next move and it costs hours, so it is off
  # by default and this says exactly what off means.
  local root="$1" want
  want="$(_portage_cfg "no" portage_update_world)"
  if [[ "$want" != "yes" ]]; then
    skip "@world: not rebuilt (portage_update_world = no)"
    log "       the stage3's packages keep the USE flags they were built with"
    log "       reconcile them when convenient, before or after the kernel:"
    log "       chroot ${root} emerge --update --deep --newuse @world"
    return 0
  fi
  log "rebuilding @world for the new profile: this is the long one"
  if chroot_run emerge --update --deep --newuse --quiet-build=n @world; then
    ok "@world: up to date with the profile"
    _PORTAGE_CHANGED=$((_PORTAGE_CHANGED + 1))
    return 0
  fi
  err "emerge --update --deep --newuse @world failed inside ${root}"
  err "       the package that stopped it names itself in the output above"
  return 1
}

# --------------------------------------------------------------------------- #
#  Rendering                                                                  #
# --------------------------------------------------------------------------- #
show_portage_summary() {
  # Prints and changes nothing. Args: $1 = root, $2 = set name, $3 = atom count.
  local root="$1" name="$2" count="$3"
  log "Portage on ${root}:"
  log "       profile   ${PORTAGE_PROFILE:-unchanged}"
  log "       MAKEOPTS  ${PORTAGE_MAKEOPTS}"
  log "       set       @${_PORTAGE_SET_NAME} (${name}, ${count} package(s))"
  log "       ${_PORTAGE_CHANGED} change(s) written, the rest was already in place"
}

# --------------------------------------------------------------------------- #
#  The step                                                                   #
# --------------------------------------------------------------------------- #
step_60_portage() {
  local root repo set_name atoms count=0
  local -a files=()

  # Reset, not just initialised at source time: a --resume run calls this
  # function again in the same shell, and a counter that carried over would
  # report changes the second run never made.
  _PORTAGE_CHANGED=0
  PORTAGE_PROFILE=""
  PORTAGE_MAKEOPTS=""

  portage_init_defaults

  root="$(_portage_root)"
  if [[ -z "$root" || "$root" == "/" ]]; then
    err "Refusing to configure Portage on /"
    err "       step 60 writes /etc/portage of the system being installed"
    err "       on / it would replace the make.conf of the machine you are using"
    err "       example:  --root /mnt/gentoo"
    return "$EXIT_FAILURE"
  fi

  # chroot_attach only points the module at the target; step 50 did the
  # mounting and step 95 releases it. Attaching again is free and lets step 60
  # run on its own against a target that is already mounted.
  chroot_attach "$root" || return "$EXIT_FAILURE"
  if ! chroot_run_quiet /bin/true; then
    err "step 60: no command runs inside ${root}"
    err "       step 50 mounts the pseudo-filesystems this step needs"
    err "       example:  ./gentoo-install.sh --steps 50,60"
    return "$EXIT_FAILURE"
  fi
  chroot_pseudo_ready || return "$EXIT_FAILURE"

  log "target: ${root}"

  repo="$(portage_repo_path "$root")"
  log "repository: ${repo}"

  portage_ensure_repos_conf "$root" || return "$EXIT_FAILURE"
  portage_sync_tree "$root" "$repo" || return "$EXIT_FAILURE"
  portage_select_profile "$root" "$repo" || return "$EXIT_FAILURE"

  show_portage_makeopts
  PORTAGE_MAKEOPTS="$(portage_makeopts)"
  portage_write_make_conf "$root" || return "$EXIT_FAILURE"

  set_name="$(portage_selected_set)"
  mapfile -t files < <(portage_set_files "$set_name" "$(_portage_init)")
  if ((${#files[@]} == 0)); then
    err "step 60: the package set '${set_name}' resolved to no files at all"
    return "$EXIT_FAILURE"
  fi
  log "package set ${set_name}: ${files[*]##*/}"

  atoms="$(portage_set_atoms "${files[@]}")"
  if [[ -n "$atoms" ]]; then
    count="$(printf '%s\n' "$atoms" | grep -c .)"
  fi

  portage_write_package_use "$root" || return "$EXIT_FAILURE"
  portage_write_accept_keywords "$root" || return "$EXIT_FAILURE"
  portage_write_package_license "$root" "${files[@]}" || return "$EXIT_FAILURE"
  portage_write_set "$root" "$set_name" "$atoms" || return "$EXIT_FAILURE"

  portage_update_world "$root" || return "$EXIT_FAILURE"
  portage_emerge_set "$root" "$count" || return "$EXIT_FAILURE"

  _portage_record profile "$PORTAGE_PROFILE"
  _portage_record makeopts "$PORTAGE_MAKEOPTS"
  _portage_record set "$set_name"
  _portage_record packages "$count"
  _portage_record sync "$(_portage_cfg "webrsync" portage_sync)"

  show_portage_summary "$root" "$set_name" "$count"
  return "$EXIT_SUCCESS"
}
