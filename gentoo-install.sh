#!/usr/bin/env bash
#
# gentoo-install — modular Gentoo installer
# ----------------------------------------------------------------------------
# Orchestrates the install as numbered steps. The number is the public API: it
# appears in --steps, in the documentation and in an operator's notes, and it
# never changes. The function behind it is an implementation detail and may be
# renamed freely. Nothing runs until show_plan() has said what is about to run.
#
# This file declares VERSION. No other file in the repository does.
#
# Usage:  ./gentoo-install.sh [--flag value ...]   (--help for the list)
#
set -euo pipefail

readonly VERSION="0.1.0"

# --------------------------------------------------------------------------- #
#  Libraries                                                                  #
# --------------------------------------------------------------------------- #
_self="$(readlink -f -- "${BASH_SOURCE[0]}")"
readonly SCRIPT_DIR="${_self%/*}"
readonly SCRIPT_NAME="${_self##*/}"
readonly LIB_DIR="${GI_LIB_DIR:-${SCRIPT_DIR}/lib}"
readonly STEP_DIR="${GI_STEP_DIR:-${SCRIPT_DIR}/steps}"
readonly DATA_DIR="${GI_DATA_DIR:-${SCRIPT_DIR}/data}"
readonly STAGES_TSV="${DATA_DIR}/stages.tsv"
unset _self

for _lib in core config state ui; do
  if [[ ! -r "${LIB_DIR}/${_lib}.sh" ]]; then
    printf 'gentoo-install: missing library %s/%s.sh\n' "$LIB_DIR" "$_lib" >&2
    exit 1
  fi
done
unset _lib

# shellcheck source=lib/core.sh
source "${LIB_DIR}/core.sh"
# shellcheck source=lib/config.sh
source "${LIB_DIR}/config.sh"
# shellcheck source=lib/state.sh
source "${LIB_DIR}/state.sh"
# shellcheck source=lib/ui.sh
source "${LIB_DIR}/ui.sh"

# The module libraries are sourced here too, and the reason is the configuration
# file. Each one declares its own settings — lib/disk.sh has disk_layout and the
# disk_allow_* overrides, lib/crypt.sh has twenty crypt_* keys — and cfg_known()
# only knows what CFG already carries. Loading them lazily, from the step that
# uses them, meant config_load_file ran first and refused every one of those
# names. They are guarded by _GI_*_LOADED and do nothing at source time, so
# loading them all up front costs a few milliseconds and makes the whole surface
# spellable in a .conf.
# shellcheck source=lib/disk.sh
source "${LIB_DIR}/disk.sh"
# shellcheck source=lib/crypt.sh
source "${LIB_DIR}/crypt.sh"
# shellcheck source=lib/stage.sh
source "${LIB_DIR}/stage.sh"
# shellcheck source=lib/chroot.sh
source "${LIB_DIR}/chroot.sh"
# shellcheck source=lib/cpu.sh
source "${LIB_DIR}/cpu.sh"

# --------------------------------------------------------------------------- #
#  Step registry                                                              #
# --------------------------------------------------------------------------- #
# Adding a step is one line here plus one line in STEP_DESC. Disabling one is
# `unset 'STEP_MAP[80]'` — never an if inside the loop, never a hardcoded case,
# which is how a project ends up with four points of truth per step.
declare -A STEP_MAP=(
  [10]=step_10_preflight
  [20]=step_20_disk
  [30]=step_30_crypt
  [40]=step_40_stage
  [50]=step_50_chroot
  [60]=step_60_portage
  [70]=step_70_kernel
  [75]=step_75_seal
  [80]=step_80_boot
  [90]=step_90_system
  [95]=step_95_finalize
)

# Steps whose failure stops the run instead of being accumulated.
#
# Accumulating is right for almost everything: a failed bootloader should not
# stop the accounts from being created, and the final summary names what went
# wrong (DESIGN.md §4). Pre-flight is the exception, and it took a real run to
# see it. Its checks decide whether anything may be written at all, and it says
# so itself —
#
#   [x] Pre-flight failed: 1 blocking, 0 warning(s)
#   [x]        blocking: disk
#   [x]        --force does not lift these: they are proofs, not confirmations
#
# — after which the run carried on and erased the disk it had just refused,
# because 16 GiB is under the 20 the same check insists on. A proof nothing
# acts on is a decoration.
#
# A table and not an `if` on a step number: the registry is the contract, and
# the loop below stays free of special cases.
declare -A STEP_HALTS=(
  [10]="pre-flight decides whether anything may be written at all"
)

declare -A STEP_DESC=(
  [10]="pre-flight: privileges, tools, network, disk inventory"
  [20]="partition and format the target disks (DESTRUCTIVE)"
  [30]="LUKS containers and keyfiles"
  [40]="fetch, verify and unpack the stage3 tarball"
  [50]="mount the pseudo-filesystems and enter the chroot"
  [60]="portage: make.conf, repositories, profile, USE flags"
  [70]="kernel sources, configuration and build"
  [75]="seal the container to the TPM, inside the target"
  [80]="bootloader install and entries"
  [90]="system: fstab, locale, timezone, network, users, packages"
  [95]="finalize: verify, unmount, report what to do next"
)

# --------------------------------------------------------------------------- #
#  Steps — placeholders                                                       #
# --------------------------------------------------------------------------- #
# One file per step under steps/, each defining the step_NN_* function the
# registry names. They are sourced here, before anything runs, so that a step
# file that is missing or misnamed is a startup error and not a surprise two
# hours into an install.
#
# The registry is the contract: every entry must resolve to a function once the
# sourcing is done. A placeholder that returns 0 would let the runner announce
# "done, none failed" for a step that did nothing, which is the defect
# docs/DESIGN.md §4 was written against.
for _step_file in "${STEP_DIR}"/*.sh; do
  [[ -r "$_step_file" ]] || continue
  # shellcheck source=/dev/null  # one file per step, discovered at run time
  source "$_step_file"
done
unset _step_file

steps_check_registry() {
  local n missing_count=0
  for n in "${!STEP_MAP[@]}"; do
    if ! declare -F "${STEP_MAP[$n]}" >/dev/null; then
      err "step ${n} names ${STEP_MAP[$n]}, which no file under ${STEP_DIR} defines"
      missing_count=$((missing_count + 1))
    fi
  done
  if ((missing_count > 0)); then
    err "       ${missing_count} step(s) unimplemented; this is a packaging error"
    err "       example:  ls ${STEP_DIR}"
    return 1
  fi
  return 0
}

step_numbers() {
  printf '%s\n' "${!STEP_MAP[@]}" | sort -n
}

# --------------------------------------------------------------------------- #
#  Stage catalogue                                                            #
# --------------------------------------------------------------------------- #
# data/stages.tsv is the only place the 19 published amd64 variants are named.
# Step 40 will grow this into a full fetch-and-verify module; what lives here
# is the part parse time needs, so that an impossible combination dies now
# instead of 404-ing after the disks have been wiped.
_stages_rows() {
  if [[ ! -r "$STAGES_TSV" ]]; then
    die "missing stage catalogue: ${STAGES_TSV}"
  fi
  awk -F'\t' '!/^#/ && NF == 7' "$STAGES_TSV"
}

stage_flavours() {
  _stages_rows | awk -F'\t' -v a="${CFG[arch]}" '$5 == a { print $4 }' | sort -u
}

stage_lookup() {
  # Print "id<TAB>libc<TAB>constraints" for an (arch, init, flavour) triple,
  # or return 1. A returned value, so stdout.
  local row
  row="$(_stages_rows | awk -F'\t' \
    -v a="${CFG[arch]}" -v i="${CFG[init]}" -v f="${CFG[flavour]}" \
    '$5 == a && $2 == i && $4 == f { print $1 "\t" $3 "\t" $6; exit }')"
  [[ -n "$row" ]] || return 1
  printf '%s\n' "$row"
}

resolve_stage() {
  # Fill in the derived settings, or explain why the combination has no stage.
  # This is where `--flavour splitusr --init systemd` dies: upstream publishes
  # splitusr for OpenRC only, and a selector that does not know that walks the
  # operator into a 404 halfway through an install.
  local row id libc constraints
  local -a alternatives=()

  if [[ ! -r "$STAGES_TSV" ]]; then
    die "missing stage catalogue: ${STAGES_TSV}"
  fi

  if row="$(stage_lookup)"; then
    IFS=$'\t' read -r id libc constraints <<<"$row"
    set_default stage_variant "$id"
    set_default libc "$libc"
    CFG[stage_constraints]="$constraints"
    return 0
  fi

  mapfile -t alternatives < <(_stages_rows | awk -F'\t' \
    -v a="${CFG[arch]}" -v f="${CFG[flavour]}" \
    '$5 == a && $4 == f { print $2 }' | sort -u)

  if ((${#alternatives[@]} > 0)); then
    die_usage "No ${CFG[arch]} stage3 is published for flavour '${CFG[flavour]}' with init '${CFG[init]}'" \
      "flavour '${CFG[flavour]}' exists only for: ${alternatives[*]}" \
      "example:  --flavour ${CFG[flavour]} --init ${alternatives[0]}"
  fi

  local -a flavours=()
  mapfile -t flavours < <(stage_flavours)
  die_usage "No ${CFG[arch]} stage3 is published for flavour '${CFG[flavour]}'" \
    "known flavours: ${flavours[*]}" \
    "example:  --flavour base --init openrc"
}

# --------------------------------------------------------------------------- #
#  Profiles                                                                   #
# --------------------------------------------------------------------------- #
apply_profile() {
  # A profile sets a coherent group of defaults with set_default, so it applies
  # after parsing and can never overwrite something the operator asked for.
  case "${CFG[profile]}" in
    minimal)
      set_default flavour "base"
      set_default init "openrc"
      ;;
    default)
      set_default flavour "base"
      set_default init "openrc"
      ;;
    desktop)
      set_default flavour "desktop"
      set_default init "systemd"
      ;;
    server)
      set_default flavour "nomultilib"
      set_default init "openrc"
      ;;
    hardened)
      set_default flavour "hardened"
      set_default init "openrc"
      set_default on_conflict "prompt"
      ;;
    *)
      die_usage "Unknown profile: ${CFG[profile]}" \
        "minimal   a bootable base system and nothing else" \
        "default   a balanced general-purpose system" \
        "desktop   desktop stage and systemd" \
        "server    headless, no 32-bit ABI" \
        "hardened  hardened toolchain, prompts before touching an existing file" \
        "example:  --profile server"
      ;;
  esac
}

# --------------------------------------------------------------------------- #
#  Step selection                                                             #
# --------------------------------------------------------------------------- #
parse_step_selection() {
  # Expand "10,30-60,95" into a sorted, de-duplicated list of numbers, one per
  # line on stdout. Explains and returns 1 on anything malformed; it never
  # exits, so the caller owns the exit code and the tests can call it directly.
  local spec="${1-}"
  local -a parts=() out=()
  local part start end i

  if [[ -z "${spec//[[:space:]]/}" ]]; then
    err "Empty step selection"
    err "       expected a list of numbers and ranges"
    err "       example:  --steps 20,40-60,95"
    return 1
  fi

  IFS=',' read -ra parts <<<"$spec"
  for part in "${parts[@]}"; do
    part="${part//[[:space:]]/}"
    if [[ -z "$part" ]]; then
      err "Empty item in step selection: ${spec}"
      err "       a stray comma, most likely"
      err "       example:  --steps 20,40-60"
      return 1
    fi
    if [[ "$part" =~ ^([0-9]+)-([0-9]+)$ ]]; then
      start=$((10#${BASH_REMATCH[1]}))
      end=$((10#${BASH_REMATCH[2]}))
      if ((start > end)); then
        err "Inverted range in step selection: ${part}"
        err "       a range reads low-high, so ${end}-${start} is what you meant"
        err "       example:  --steps 40-60"
        return 1
      fi
      if ((end - start > 1000)); then
        err "Absurd range in step selection: ${part}"
        err "       step numbers run from 10 to 95; a range spanning more than 1000 is a typo"
        err "       example:  --steps 40-60"
        return 1
      fi
      for ((i = start; i <= end; i++)); do
        out+=("$i")
      done
    elif [[ "$part" =~ ^[0-9]+$ ]]; then
      out+=("$((10#$part))")
    else
      err "Invalid item in step selection: ${part}"
      err "       expected a number (20) or a range (40-60)"
      err "       example:  --steps 20,40-60,95"
      return 1
    fi
  done

  printf '%s\n' "${out[@]}" | sort -nu
}

_err_step_table() {
  local n
  local -a nums=()
  mapfile -t nums < <(step_numbers)
  err "       valid steps:"
  for n in "${nums[@]}"; do
    err "$(printf '       %-4s %-18s %s' "$n" "${STEP_MAP[$n]}" "${STEP_DESC[$n]}")"
  done
}

resolve_steps() {
  # Match an expanded selection against the registry, at parse time, never in
  # the middle of an emerge.
  #
  # A bare number must name a real step: --steps 99 is a mistake worth stopping
  # for. A range is a span, not an enumeration: --steps 40-60 means "everything
  # between 40 and 60", and the steps that do not exist inside it are simply
  # not there.
  # Args: $1 = the original spec, $2.. = the expanded numbers.
  local spec="$1"
  shift
  local -a expanded=("$@") selected=() unknown=() parts=()
  local part n

  IFS=',' read -ra parts <<<"$spec"
  for part in "${parts[@]}"; do
    part="${part//[[:space:]]/}"
    if [[ "$part" =~ ^[0-9]+$ ]]; then
      n=$((10#$part))
      if [[ -z "${STEP_MAP[$n]+set}" ]]; then
        unknown+=("$n")
      fi
    fi
  done

  if ((${#unknown[@]} > 0)); then
    err "Unknown step: ${unknown[*]}"
    _err_step_table
    err "       example:  --steps 20,40-60"
    exit "$EXIT_USAGE"
  fi

  for n in "${expanded[@]}"; do
    if [[ -n "${STEP_MAP[$n]+set}" ]]; then
      selected+=("$n")
    fi
  done

  if ((${#selected[@]} == 0)); then
    err "No step matches the selection: ${spec}"
    _err_step_table
    err "       example:  --steps 20,40-60"
    exit "$EXIT_USAGE"
  fi

  printf '%s\n' "${selected[@]}"
}

remove_steps() {
  # Filter by exact comparison, one element at a time. Never
  # "${array[@]/$item}": that is substring substitution, and removing 10 from a
  # list holding 100 leaves 0.
  # Args: $1 = comma-separated list to drop, $2.. = the current selection.
  local drop_spec="$1"
  shift
  local -a keep=() dropped=()
  local n d skip_it raw

  # Command substitution, not `mapfile < <(...)`: mapfile reports on itself,
  # not on the process it read from, so a failing producer would go unnoticed.
  raw="$(parse_step_selection "$drop_spec")" || exit "$EXIT_USAGE"
  mapfile -t dropped <<<"$raw"

  for n in "$@"; do
    skip_it="no"
    for d in "${dropped[@]}"; do
      if [[ "$n" == "$d" ]]; then
        skip_it="yes"
        break
      fi
    done
    if [[ "$skip_it" == "no" ]]; then
      keep+=("$n")
    fi
  done

  if ((${#keep[@]} == 0)); then
    err "--skip-steps ${drop_spec} removes every selected step"
    err "       there would be nothing left to run"
    err "       example:  --skip-steps 30"
    exit "$EXIT_USAGE"
  fi

  printf '%s\n' "${keep[@]}"
}

list_steps() {
  # A returned value, so stdout.
  local n
  local -a nums=()
  mapfile -t nums < <(step_numbers)
  for n in "${nums[@]}"; do
    printf '%-4s %-18s %s\n' "$n" "${STEP_MAP[$n]}" "${STEP_DESC[$n]}"
  done
}

# --------------------------------------------------------------------------- #
#  Help                                                                       #
# --------------------------------------------------------------------------- #
usage() {
  # The body is a quoted heredoc: an unquoted one would run every $( ) and
  # expand every $ it contains, which is how a help screen starts executing
  # things. Whatever has to be computed is printed around it, not inside it.
  printf 'gentoo-install %s — modular Gentoo installer\n\n' "$VERSION"
  cat <<'EOF'
Usage:
  ./gentoo-install.sh [options]

Run with no options for the full install. Every option below is optional, and
--dry-run needs no privileges, so the plan can always be reviewed first.

Behaviour:
  -h, --help                Show this help and exit.
  -V, --version             Print the version and exit.
  -n, --dry-run             Print every action, change nothing. No root needed.
  -y, --yes                 Answer yes to confirmations. Not to typed proofs.
      --force               Lift confirmations. Does not lift proofs either.
      --non-interactive     Never prompt; fall back to the safe answer.
      --resume              Skip the steps the state journal marks as done.
      --restart             Clear the state journal and run from the top.
      --json                Print the plan as JSON on stdout and exit.
      --no-color            No colour, whatever the terminal says. NO_COLOR
                            in the environment does the same.

Selection:
      --steps SPEC          Run only these steps: 20,40-60,95.
                            A bare number must name a real step; a range
                            selects whatever exists inside it.
      --skip-steps SPEC     Remove these steps from the selection.
      --list-steps          Print the step registry and exit.

Configuration:
      --config FILE         Read 'key = value' lines. Beats a profile, loses
                            to a flag, whichever order they appear in.
      --profile NAME        minimal | default | desktop | server | hardened
      --dump-config         Print every setting, its value and where it came
                            from, then exit.
      --<setting> VALUE     Every setting this version declares is also a
                            flag, spelled with dashes: --bootloader efistub,
                            --crypt luks-tpm, --disk-layout server. They are
                            not listed here because a hand-kept copy drifts;
                            --dump-config prints the authoritative set.
      --on-conflict MODE    What to do about a file that already differs:
                            overwrite | skip | prompt | backup
      --log-file PATH       Timestamped journal (default /var/log/gentoo-install.log).
      --state-dir PATH      Resume journal (default /var/lib/gentoo-install).

Target system:
      --arch ARCH           Target architecture (default amd64).
      --init INIT           openrc | systemd
      --flavour NAME        Stage3 flavour; --list-flavours prints them.
      --list-flavours       Print the stage3 flavours for --arch and exit.
      --list-disks          Print the disks on this machine and exit. Reads
                            nothing else and writes nothing; this is the
                            question to ask before choosing --disk.

Precedence, always in this order:
  built-in default  <  profile  <  configuration file  <  explicit flag

EOF

  printf 'Steps:\n'
  local n
  local -a nums=()
  mapfile -t nums < <(step_numbers)
  for n in "${nums[@]}"; do
    printf '  %-4s %-18s %s\n' "$n" "${STEP_MAP[$n]}" "${STEP_DESC[$n]}"
  done

  cat <<'EOF'

Examples:
  ./gentoo-install.sh --dry-run
  ./gentoo-install.sh --profile server --dry-run
  ./gentoo-install.sh --steps 20,40-60 --on-conflict prompt
  ./gentoo-install.sh --flavour musl --init openrc --dry-run
  ./gentoo-install.sh --resume
EOF
}

# --------------------------------------------------------------------------- #
#  Rendering                                                                  #
# --------------------------------------------------------------------------- #
show_plan() {
  # Says what is about to happen, before it happens. On stderr: it is
  # diagnostics, not a value. Args: $@ = the selected step numbers.
  local n
  log "gentoo-install ${VERSION}"
  log "  profile      ${CFG[profile]}"
  log "  target       ${CFG[arch]} / ${CFG[init]} / ${CFG[flavour]} (${CFG[libc]})"
  log "  stage3       ${CFG[stage_variant]}  [${CFG[stage_constraints]:-none}]"
  log "  on conflict  ${CFG[on_conflict]}"
  log "  state        ${CFG[state_dir]}/state"
  log "  log          ${LOG_FILE:-<none>}"
  log "steps to run:"
  for n in "$@"; do
    if [[ "${CFG[resume]}" == "yes" ]] && state_is_done "$n"; then
      skip "$(printf '  %-4s %-18s already done, --resume will skip it' "$n" "${STEP_MAP[$n]}")"
    else
      log "$(printf '  %-4s %-18s %s' "$n" "${STEP_MAP[$n]}" "${STEP_DESC[$n]}")"
    fi
  done
  if [[ "$DRY_RUN" == "yes" ]]; then
    warn "dry run: nothing will be changed"
  fi
}

_json_escape() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\n'/\\n}"
  s="${s//$'\t'/\\t}"
  s="${s//$'\r'/\\r}"
  printf '%s' "$s"
}

emit_json() {
  # The one thing in this project that writes on stdout, alongside the values
  # helpers return. Secrets are masked here exactly as in --dump-config.
  # Args: $@ = the selected step numbers.
  local n key first
  printf '{\n'
  printf '  "version": "%s",\n' "$(_json_escape "$VERSION")"
  printf '  "dry_run": %s,\n' "$([[ "$DRY_RUN" == "yes" ]] && printf 'true' || printf 'false')"
  printf '  "config": {\n'
  first=1
  local -a keys=()
  mapfile -t keys < <(cfg_keys)
  for key in "${keys[@]}"; do
    if ((first)); then first=0; else printf ',\n'; fi
    printf '    "%s": "%s"' "$(_json_escape "$key")" "$(_json_escape "$(cfg_display "$key")")"
  done
  printf '\n  },\n'
  printf '  "steps": [\n'
  first=1
  for n in "$@"; do
    if ((first)); then first=0; else printf ',\n'; fi
    printf '    { "number": %s, "function": "%s", "description": "%s", "done": %s }' \
      "$n" "$(_json_escape "${STEP_MAP[$n]}")" "$(_json_escape "${STEP_DESC[$n]}")" \
      "$(state_is_done "$n" && printf 'true' || printf 'false')"
  done
  printf '\n  ]\n'
  printf '}\n'
}

# --------------------------------------------------------------------------- #
#  Argument parsing                                                           #
# --------------------------------------------------------------------------- #
OPT_STEPS=""
OPT_SKIP_STEPS=""
OPT_CONFIG=""
OPT_LIST_STEPS="no"
OPT_LIST_FLAVOURS="no"
OPT_LIST_DISKS="no"
OPT_DUMP_CONFIG="no"

_need_value() {
  # Args: $1 = the flag, $2 = whatever followed it (may be absent).
  if [[ $# -lt 2 || -z "${2:-}" || "${2}" == -* ]]; then
    err "Option ${1} requires a value"
    err "       --help shows what it accepts"
    exit "$EXIT_USAGE"
  fi
}

parse_args() {
  local _flag_key
  # One argument at a time, matched exactly. Never `[[ "$*" == *"-h"* ]]`:
  # that swallows every flag whose name happens to contain -h, and there are
  # always more of those than anybody expects.
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -h | --help)
        usage
        exit "$EXIT_SUCCESS"
        ;;
      -V | --version)
        printf '%s\n' "$VERSION"
        exit "$EXIT_SUCCESS"
        ;;
      -n | --dry-run) set_explicit dry_run "yes" ;;
      -y | --yes) set_explicit assume_yes "yes" ;;
      --force) set_explicit force "yes" ;;
      --non-interactive) set_explicit non_interactive "yes" ;;
      --resume) set_explicit resume "yes" ;;
      --restart) set_explicit restart "yes" ;;
      --json) set_explicit json "yes" ;;
      --no-color | --no-colour) set_explicit color "never" ;;
      --list-steps) OPT_LIST_STEPS="yes" ;;
      --list-flavours | --list-flavors) OPT_LIST_FLAVOURS="yes" ;;
      --list-disks) OPT_LIST_DISKS="yes" ;;
      --dump-config) OPT_DUMP_CONFIG="yes" ;;
      --steps)
        _need_value "$@"
        OPT_STEPS="$2"
        shift
        ;;
      --skip-steps)
        _need_value "$@"
        OPT_SKIP_STEPS="$2"
        shift
        ;;
      --config)
        _need_value "$@"
        OPT_CONFIG="$2"
        shift
        ;;
      --profile)
        _need_value "$@"
        set_explicit profile "$2"
        shift
        ;;
      --on-conflict)
        _need_value "$@"
        validate_enum "conflict policy" "$2" "--on-conflict" \
          "overwrite:replace what is there, no questions asked" \
          "skip:leave the existing file alone and carry on" \
          "prompt:ask, once per file, before replacing anything" \
          "backup:copy the original aside, then replace it"
        set_explicit on_conflict "$2"
        shift
        ;;
      --log-file)
        _need_value "$@"
        set_explicit log_file "$2"
        shift
        ;;
      --state-dir)
        _need_value "$@"
        set_explicit state_dir "$2"
        shift
        ;;
      --arch)
        _need_value "$@"
        validate_enum "architecture" "$2" "--arch" \
          "amd64:the only architecture data/stages.tsv covers so far"
        set_explicit arch "$2"
        shift
        ;;
      --init)
        _need_value "$@"
        validate_enum "init system" "$2" "--init" \
          "openrc:the default on Gentoo, no systemd anywhere" \
          "systemd:pulls the systemd stage and the systemd profile"
        set_explicit init "$2"
        shift
        ;;
      --flavour | --flavor)
        _need_value "$@"
        set_explicit flavour "$2"
        shift
        ;;
      --)
        shift
        break
        ;;
      -*)
        # Last resort: any declared setting is also a flag, so that the surface
        # of a .conf and the surface of the command line are the same surface.
        # Writing eleven more cases by hand would have meant eleven that drift.
        # Only the "--key value" form: the booleans above own their own spelling
        # (--dry-run, --force), and cfg_known() is what keeps a typo out.
        _flag_key="${1#--}"
        _flag_key="${_flag_key//-/_}"
        if [[ "$_flag_key" =~ ^[a-z][a-z0-9_]*$ ]] && cfg_known "$_flag_key"; then
          if [[ $# -lt 2 ]]; then
            err "$1 requires a value"
            err "       --dump-config shows what it is set to now"
            err "       example:  $1 ${CFG[$_flag_key]:-VALUE}"
            exit "$EXIT_USAGE"
          fi
          set_explicit "$_flag_key" "$2"
          shift 2
          continue
        fi
        err "Unknown option: $1"
        err "       --help lists them all"
        exit "$EXIT_USAGE"
        ;;
      *)
        err "Unexpected argument: $1"
        err "       gentoo-install takes options only, never bare arguments"
        err "       --help lists them all"
        exit "$EXIT_USAGE"
        ;;
    esac
    shift
  done

  if [[ $# -gt 0 ]]; then
    err "Unexpected argument after --: $1"
    err "       --help lists the options"
    exit "$EXIT_USAGE"
  fi
}

# --------------------------------------------------------------------------- #
#  Runner                                                                     #
# --------------------------------------------------------------------------- #
run_steps() {
  # Accumulates failures instead of stopping at the first one, and reports
  # them. A run that prints "completed successfully" after a failed step tells
  # the operator nothing.
  local -a selected=("$@") failed=()
  local n fn started elapsed entry ran=0 halted=""

  started=$SECONDS

  for n in "${selected[@]}"; do
    fn="${STEP_MAP[$n]}"
    if [[ "${CFG[resume]}" == "yes" ]] && state_is_done "$n"; then
      skip "step ${n} ${fn}: already done (--restart runs it again)"
      continue
    fi
    log "step ${n} — ${fn}"
    ran=$((ran + 1))
    if "$fn"; then
      state_done "$n"
      ok "step ${n} ${fn}: done"
      continue
    fi

    err "step ${n} ${fn}: failed"
    failed+=("${n} ${fn}")

    # Some failures are not a result to report alongside the others: they are
    # the reason the rest must not happen. STEP_HALTS says which.
    if [[ -n "${STEP_HALTS[$n]:-}" ]]; then
      halted="$n"
      break
    fi
  done

  elapsed=$((SECONDS - started))

  if ((${#failed[@]} == 0)); then
    ok "${#selected[@]} step(s) in ${elapsed}s, none failed"
    return "$EXIT_SUCCESS"
  fi

  if [[ -n "$halted" ]]; then
    err "stopped at step ${halted} after ${elapsed}s: ${STEP_HALTS[$halted]}"
    err "       $((${#selected[@]} - ran)) step(s) after it were not run, and"
    err "       nothing they would have written was written"
    err "       fix the cause, then: ./${SCRIPT_NAME} --resume"
    return "$EXIT_FAILURE"
  fi

  err "${#failed[@]} of ${#selected[@]} step(s) failed in ${elapsed}s:"
  for entry in "${failed[@]}"; do
    err "       ${entry}"
  done
  err "       fix the cause, then: ./${SCRIPT_NAME} --resume"
  return "$EXIT_FAILURE"
}

# --------------------------------------------------------------------------- #
#  Entry point                                                                #
# --------------------------------------------------------------------------- #
main() {
  config_init_defaults
  parse_args "$@"

  # Order is the precedence rule: the file is applied with set_default (a flag
  # already parsed wins) and marked explicit (the profile below cannot touch
  # it), so default < profile < file < flag holds whatever the argument order.
  if [[ -n "$OPT_CONFIG" ]]; then
    config_load_file "$OPT_CONFIG"
  fi
  apply_profile

  # Every source is merged by now, so a value can finally be judged.
  config_validate_enums || exit "$EXIT_USAGE"

  # A cipher has no closed set: what is available is what this kernel was built
  # with. Asked here, before step 20 wipes a disk for an encryption setting that
  # step 30 would then refuse.
  crypt_validate_early || exit "$EXIT_USAGE"
  crypt_validate_pbkdf_params || exit "$EXIT_USAGE"

  # Same reason, one layer down: the governors a machine has depend on its
  # cpufreq driver, so the list is asked of the machine rather than kept here.
  cpu_validate_governor "${CFG[cpu_governor]}" || exit "$EXIT_USAGE"

  # A named PCR policy becomes its numbers here, once, so that everything
  # downstream — the plan, the seal, the journal, a later reseal — reads the
  # same list.
  crypt_expand_pcrs

  # And the whole crypt surface is judged here, not at step 30. The function
  # says of itself "ten milliseconds, before a single sector is touched", and
  # it was called from step 30 alone: `--crypt-pcrs bogus` was accepted at the
  # prompt and refused after step 20 had erased the disk. Step 30 still calls
  # it, so the step stays drivable on its own.
  crypt_validate_config
  if [[ "${CFG[resume]}" == "yes" && "${CFG[restart]}" == "yes" ]]; then
    die_usage "--resume and --restart contradict each other" \
      "--resume   skip the steps the state journal marks as done" \
      "--restart  clear the journal and run everything again" \
      "example:  ./gentoo-install.sh --resume"
  fi
  config_export_runtime
  core_init_colours
  core_install_traps

  if [[ "$OPT_LIST_STEPS" == "yes" ]]; then
    list_steps
    exit "$EXIT_SUCCESS"
  fi

  # Before resolve_stage: what disks are here has nothing to do with which
  # stage3 would be fetched, and an operator asking this question does not want
  # the network touched to answer it.
  if [[ "$OPT_LIST_DISKS" == "yes" ]]; then
    disk_show_inventory
    exit "$EXIT_SUCCESS"
  fi

  resolve_stage

  if [[ "$OPT_LIST_FLAVOURS" == "yes" ]]; then
    stage_flavours
    exit "$EXIT_SUCCESS"
  fi
  if [[ "$OPT_DUMP_CONFIG" == "yes" ]]; then
    dump_config
    exit "$EXIT_SUCCESS"
  fi

  # A subshell cannot exit its parent, so every producer below is read through
  # a command substitution, whose status does propagate.
  local -a selected=() expanded=()
  local raw
  if [[ -n "$OPT_STEPS" ]]; then
    raw="$(parse_step_selection "$OPT_STEPS")" || exit "$EXIT_USAGE"
    mapfile -t expanded <<<"$raw"
    raw="$(resolve_steps "$OPT_STEPS" "${expanded[@]}")" || exit "$EXIT_USAGE"
    mapfile -t selected <<<"$raw"
  else
    mapfile -t selected < <(step_numbers)
  fi

  if [[ -n "$OPT_SKIP_STEPS" ]]; then
    raw="$(remove_steps "$OPT_SKIP_STEPS" "${selected[@]}")" || exit "$EXIT_USAGE"
    mapfile -t selected <<<"$raw"
  fi

  core_open_log "${CFG[log_file]}"
  state_attach "${CFG[state_dir]}"

  if [[ "${CFG[json]}" == "yes" ]]; then
    emit_json "${selected[@]}"
    exit "$EXIT_SUCCESS"
  fi

  # Fail here, before the plan is shown, rather than mid-run on a step the
  # registry names but no file defines.
  steps_check_registry || exit "$EXIT_FAILURE"

  show_plan "${selected[@]}"

  # --dry-run must be reviewable without privileges: an operator reads the plan
  # first and only then decides to sudo.
  if [[ "$DRY_RUN" != "yes" ]]; then
    require_root
  fi

  if [[ "${CFG[restart]}" == "yes" ]]; then
    state_reset
  fi
  state_init "${CFG[state_dir]}"

  # Nothing to confirm when nothing changes.
  if [[ "$DRY_RUN" != "yes" ]] && ! confirm "Run the ${#selected[@]} step(s) above?" "no"; then
    warn "Nothing done."
    exit "$EXIT_SUCCESS"
  fi

  run_steps "${selected[@]}"
}

# Executing this file runs the installer. Sourcing it defines everything and
# runs nothing, so tests/*.bats can call parse_step_selection(), resolve_steps()
# and the rest directly instead of asserting against a whole run's output.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
