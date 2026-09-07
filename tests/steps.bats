#!/usr/bin/env bats
#
# gentoo-install — the step registry and the step selector
# ----------------------------------------------------------------------------
# The step number is the public API (DESIGN.md §4): it appears in --steps, in
# the README and in an operator's notes. The function behind it is an
# implementation detail — which is exactly why nothing but a test notices when
# the registry names a function no file defines. This repository shipped three
# cycles with ten placeholders that announced "done" and did nothing.
#

bats_require_minimum_version 1.5.0

load helper

# --------------------------------------------------------------------------- #
#  The registry                                                               #
# --------------------------------------------------------------------------- #
@test "every function STEP_MAP names must exist once steps/*.sh are sourced" {
  gi_bash '
    missing=""
    for n in $(printf "%s\n" "${!STEP_MAP[@]}" | sort -n); do
      declare -F "${STEP_MAP[$n]}" >/dev/null || missing="${missing} ${n}:${STEP_MAP[$n]}"
    done
    [[ -z "$missing" ]] || { printf "%s\n" "$missing"; exit 1; }
  '
  [ "$status" -eq 0 ] || {
    printf 'STEP_MAP names functions no file under steps/ defines:%s\n' "$output" >&2
    printf 'the runner would announce the step and run nothing.\n' >&2
    return 1
  }
}

@test "steps_check_registry must pass, since it is what stops a run before the plan is shown" {
  gi_bash 'steps_check_registry'
  [ "$status" -eq 0 ]
}

@test "every step number must carry a description, because the number is what an operator reads" {
  gi_bash '
    undocumented=""
    for n in "${!STEP_MAP[@]}"; do
      [[ -n "${STEP_DESC[$n]:-}" ]] || undocumented="${undocumented} ${n}"
    done
    [[ -z "$undocumented" ]] || { printf "%s\n" "$undocumented"; exit 1; }
  '
  [ "$status" -eq 0 ] || {
    printf 'steps with no entry in STEP_DESC:%s\n' "$output" >&2
    return 1
  }
}

@test "--list-steps must print the registry on stdout and keep stderr for diagnostics" {
  gi_run --list-steps
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | grep -c '^[0-9]')" -ge 10 ]
  [[ "$output" == *"step_10_preflight"* ]]
  [[ "$output" == *"step_95_finalize"* ]]
}

# --------------------------------------------------------------------------- #
#  parse_step_selection: what it accepts                                      #
# --------------------------------------------------------------------------- #
# It expands, it does not judge: a number that names no step is resolve_steps'
# business, so these cases use plain small numbers and stay independent of the
# registry the project happens to ship.
@test "a bare number expands to itself" {
  gi_bash 'parse_step_selection "$1"' '1'
  [ "$status" -eq 0 ]
  [ "$output" = "1" ]
}

@test "a comma-separated list expands to one number per line, in order" {
  gi_bash 'parse_step_selection "$1"' '1,3'
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf '1\n3')" ]
}

@test "a range expands to every number it spans, endpoints included" {
  gi_bash 'parse_step_selection "$1"' '3-7'
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf '3\n4\n5\n6\n7')" ]
}

@test "numbers and ranges mix, and the result is sorted and de-duplicated" {
  gi_bash 'parse_step_selection "$1"' '1,3-7,15'
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf '1\n3\n4\n5\n6\n7\n15')" ]
}

@test "a number repeated across a list and a range appears once" {
  gi_bash 'parse_step_selection "$1"' '5,3-7,5'
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf '3\n4\n5\n6\n7')" ]
}

@test "an expansion goes to stdout alone, so a caller can read it through a pipe" {
  gi_bash 'parse_step_selection "$1"' '1,3-7,15'
  [ "$status" -eq 0 ]
  [ "$stderr" = "" ]
}

# --------------------------------------------------------------------------- #
#  parse_step_selection: what it refuses                                      #
# --------------------------------------------------------------------------- #
@test "an inverted range must be refused and told which way round it reads" {
  gi_bash 'parse_step_selection "$1"' '7-3'
  [ "$status" -eq 1 ]
  [ "$output" = "" ]
  [[ "$stderr" == *"Inverted range"* ]]
  [[ "$stderr" == *"3-7"* ]] # the message says what was meant
  [[ "$stderr" == *"example:"* ]]
}

@test "a non-numeric item must be refused, not silently expanded to zero" {
  gi_bash 'parse_step_selection "$1"' 'abc'
  [ "$status" -eq 1 ]
  [ "$output" = "" ]
  [[ "$stderr" == *"Invalid item"* ]]
  [[ "$stderr" == *"abc"* ]]
}

@test "an empty selection must be refused rather than read as 'everything'" {
  gi_bash 'parse_step_selection ""'
  [ "$status" -eq 1 ]
  [ "$output" = "" ]
  [[ "$stderr" == *"Empty step selection"* ]]
}

@test "a stray comma must be refused rather than skipped" {
  gi_bash 'parse_step_selection "$1"' '10,,20'
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"Empty item"* ]]
}

@test "a step number that names no step must be refused at parse time, not inside an emerge" {
  # parse_step_selection expands; resolve_steps judges. 99 is arithmetically
  # fine and still a mistake worth stopping the run for.
  gi_run --steps 99 --dry-run
  [ "$status" -eq 2 ]
  [[ "$stderr" == *"Unknown step: 99"* ]]
  [[ "$stderr" == *"valid steps:"* ]]
  [[ "$stderr" == *"step_10_preflight"* ]] # the message lists the way out
}

@test "a range selects whatever exists inside it, and nothing that does not" {
  gi_run --steps 40-60 --json
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | grep -c '"number"')" -eq 3 ]
  [[ "$output" == *'"number": 40'* ]]
  [[ "$output" == *'"number": 50'* ]]
  [[ "$output" == *'"number": 60'* ]]
}

# --------------------------------------------------------------------------- #
#  remove_steps                                                               #
# --------------------------------------------------------------------------- #
@test "--skip-steps must compare whole numbers, never substrings" {
  # DESIGN.md §13: "${arr[@]/$item}" is substring substitution, so dropping 0
  # from a list of 10 20 30 would leave 1 2 3. Nothing matches 0, so the whole
  # registry must survive intact.
  gi_run --skip-steps 0 --json
  [ "$status" -eq 0 ]
  # Counted from the directory rather than written down: one file per step is
  # the rule (DESIGN.md §4), and a literal here would have to be edited by
  # whoever adds a step — which is exactly the second point of truth the step
  # registry exists to avoid.
  local expected
  expected="$(find "${GI_ROOT}/steps" -maxdepth 1 -name '*.sh' | wc -l)"
  [ "$(printf '%s\n' "$output" | grep -c '"number"')" -eq "$expected" ]
  [[ "$output" == *'"number": 10'* ]]
  [[ "$output" == *'"number": 95'* ]]
}

@test "--skip-steps that empties the selection must say so instead of running nothing" {
  gi_run --skip-steps 10-95 --json
  [ "$status" -eq 2 ]
  [[ "$stderr" == *"removes every selected step"* ]]
}

@test "every step in the registry has a section of its own in the README" {
  # The README's table of contents is the table of the steps, and its sections
  # are one per step. That 1:1 alignment is the promise that reading the README
  # tells you what the installer does — a step added to the registry and left
  # out of the page breaks it silently, which is what happened to the eleventh.
  local missing=""
  missing="$(gi_bash '
    for n in $(printf "%s\n" "${!STEP_MAP[@]}" | sort -n); do
      grep -q "^## ${n} " "${GI_ROOT}/README.md" || printf "%s " "$n"
    done' && printf '%s' "$output")"
  if [[ -n "$missing" ]]; then
    printf 'steps with no README section: %s\n' "$missing" >&2
    return 1
  fi
}

# --------------------------------------------------------------------------- #
#  A failure that must stop the run                                           #
# --------------------------------------------------------------------------- #
@test "a failed pre-flight stops the run instead of being accumulated" {
  # Found by running it. Pre-flight refused a 16 GiB disk — "minimum 20", and
  # "--force does not lift these: they are proofs, not confirmations" — and the
  # run carried on and erased that disk anyway. Accumulating is right for
  # almost every step; it is wrong for the one whose job is to decide whether
  # anything may be written at all.
  gi_bash '
    config_init_defaults
    state_done() { :; }
    state_is_done() { return 1; }
    step_10_preflight() { return 1; }
    step_20_disk()      { printf "ERASED\n"; return 0; }
    STEP_MAP=([10]=step_10_preflight [20]=step_20_disk)
    run_steps 10 20
  '
  [ "$status" -ne 0 ]
  [[ "$output" != *"ERASED"* ]]
  [[ "$stderr" == *"stopped at step 10"* ]]
  [[ "$stderr" == *"were not run"* ]]
}

@test "every other failure is still accumulated, and every step still runs" {
  # The other half of DESIGN.md §4: a failed bootloader does not stop the
  # accounts from being created, and the summary names what went wrong.
  gi_bash '
    config_init_defaults
    state_done() { :; }
    state_is_done() { return 1; }
    step_80_boot()   { return 1; }
    step_90_system() { printf "RAN 90\n"; return 0; }
    step_95_finalize() { printf "RAN 95\n"; return 0; }
    STEP_MAP=([80]=step_80_boot [90]=step_90_system [95]=step_95_finalize)
    run_steps 80 90 95
  '
  [ "$status" -ne 0 ]
  [[ "$output" == *"RAN 90"* ]]
  [[ "$output" == *"RAN 95"* ]]
  [[ "$stderr" == *"1 of 3 step(s) failed"* ]]
  [[ "$stderr" != *"stopped at step"* ]]
}

@test "the halting table names a step the registry actually has" {
  # A number in STEP_HALTS that no step answers to would be a rule nothing can
  # ever apply.
  gi_bash '
    for n in "${!STEP_HALTS[@]}"; do
      [[ -n "${STEP_MAP[$n]:-}" ]] || { printf "%s\n" "$n"; exit 1; }
    done
    exit 0
  '
  [ "$status" -eq 0 ]
}

@test "the chroot readiness probe names what is missing" {
  # step 60's precondition ran /bin/true inside the target and called that
  # proof that step 50 had mounted the pseudo-filesystems. /bin/true needs
  # none of them: it passed on a target with no /proc, no /sys and no /dev,
  # and the step then wrote make.conf, watched emerge --info fail on "Failed
  # to validate a sane '/dev'", and blamed the file.
  gi_bash 'CHROOT_ROOT=/nowhere; _chroot_require_attached() { return 0; }
    chroot_run_quiet() {
      case "$*" in
        *"/proc/self/mounts"*) return 1 ;;
        *"/dev/fd/0"*) return 1 ;;
        *) return 0 ;;
      esac
    }
    chroot_pseudo_ready'
  [ "$status" -ne 0 ]
  [[ "$stderr" == *"missing: /proc"* ]]
  [[ "$stderr" == *"/dev/fd"* ]]
  [[ "$stderr" != *"missing: /sys"* ]]
  [[ "$stderr" == *"--steps 50,60"* ]]
}

@test "a chroot with everything mounted is called ready" {
  gi_bash 'CHROOT_ROOT=/nowhere; _chroot_require_attached() { return 0; }
    chroot_run_quiet() { return 0; }
    chroot_pseudo_ready'
  [ "$status" -eq 0 ]
  [ -z "$stderr" ]
}

@test "step 60 asks whether the chroot is ready, not whether /bin/true runs" {
  local body
  body="$(sed -n '/^step_60_portage/,/^}/p' "${GI_ROOT}/steps/60_portage.sh")"
  [[ "$body" == *"chroot_pseudo_ready"* ]]
}

@test "a make.conf refusal reports Portage's own words" {
  # The caller used to guess: "one unbalanced quote is enough" about a file
  # emerge had refused to look at for a reason it stated plainly.
  gi_bash 'CHROOT_ROOT=/nowhere; _chroot_require_attached() { return 0; }
    chroot_run_quiet() { return 1; }
    chroot() { printf "Failed to validate a sane '"'"'/dev'"'"'.\n"; return 1; }
    portage_validate_make_conf || true
    printf "%s\n" "$PORTAGE_EMERGE_REFUSAL"'
  [ "$status" -eq 0 ]
  [[ "$output" == *"sane"* ]]
}

@test "the two hardware-derived values say where they came from" {
  # VIDEO_CARDS is read off the PCI bus of the machine running the installer
  # and written into the machine being installed. On a live medium booted on
  # the target those are the same machine and it is right; with --root they are
  # not. The generated file carried a comment saying "Detected from lspci"; the
  # operator watching the run was told nothing at all.
  gi_bash 'config_init_defaults >/dev/null 2>&1
    portage_init_defaults
    portage_video_cards() { printf "intel i965 iris\n"; }
    portage_grub_platforms() { printf "efi-64\n"; }
    portage_say_hardware_source'
  [ "$status" -eq 0 ]
  [[ "$stderr" == *"GRUB_PLATFORMS efi-64, from how the installer itself booted"* ]]
  [[ "$stderr" == *"VIDEO_CARDS intel i965 iris"* ]]
  [[ "$stderr" == *"PCI bus of the machine running"* ]]
  [[ "$stderr" == *"portage_video_cards = "* ]]
}

@test "a value that was asked for is not explained as a detection" {
  gi_bash 'config_init_defaults >/dev/null 2>&1
    portage_init_defaults
    CFG[portage_video_cards]="amdgpu radeonsi"
    CFG[portage_grub_platforms]="pc"
    portage_say_hardware_source'
  [ "$status" -eq 0 ]
  [[ "$stderr" == *"GRUB_PLATFORMS pc, as asked"* ]]
  [[ "$stderr" == *"VIDEO_CARDS amdgpu radeonsi, as asked"* ]]
  [[ "$stderr" != *"PCI bus"* ]]
}

@test "nothing matching the table is said out loud, not left blank" {
  gi_bash 'config_init_defaults >/dev/null 2>&1
    portage_init_defaults
    portage_video_cards() { return 1; }
    portage_grub_platforms() { printf "efi-64\n"; }
    portage_say_hardware_source'
  [ "$status" -eq 0 ]
  [[ "$stderr" == *"VIDEO_CARDS left out"* ]]
  [[ "$stderr" == *"profile's own default stands"* ]]
}

@test "step 60 says it before it writes make.conf" {
  local body
  body="$(sed -n '/^portage_write_make_conf/,/^}/p' "${GI_ROOT}/steps/60_portage.sh")"
  [[ "$body" == *"portage_say_hardware_source"* ]]
}

@test "a target without dracut is not told its machine will not boot" {
  # dracut is not in a stage3, so on a fresh target its module directory does
  # not exist and every module it provides is "missing". The check said so
  # anyway and ended on "the machine will not open its container" — on every
  # encrypted install, a minute before emerging the package that brings them.
  local dir
  dir="$(gi_tmp)/nodracut"
  mkdir -p "$dir"
  gi_bash 'config_init_defaults >/dev/null 2>&1
    CFG[crypt]=luks-passphrase; CFG[disk_lvm]=no
    kernel_check_dracut_modules "$1"' "$dir"
  [ "$status" -eq 0 ]
  [[ "$stderr" == *"not in the target yet"* ]]
  [[ "$stderr" != *"will not open its container"* ]]
}

@test "a target with dracut and no crypt module is told exactly that" {
  local dir
  dir="$(gi_tmp)/halfdracut"
  mkdir -p "${dir}/usr/lib/dracut/modules.d/90dm"
  gi_bash 'config_init_defaults >/dev/null 2>&1
    CFG[crypt]=luks-passphrase; CFG[disk_lvm]=no
    kernel_check_dracut_modules "$1"' "$dir"
  [ "$status" -eq 0 ]
  [[ "$stderr" == *"crypt"* ]]
  [[ "$stderr" == *"will not open its container"* ]]
}

@test "a target carrying every module it was asked for says so" {
  local dir
  dir="$(gi_tmp)/fulldracut"
  mkdir -p "${dir}/usr/lib/dracut/modules.d/90crypt" \
    "${dir}/usr/lib/dracut/modules.d/90dm"
  gi_bash 'config_init_defaults >/dev/null 2>&1
    CFG[crypt]=luks-passphrase; CFG[disk_lvm]=no
    kernel_check_dracut_modules "$1"' "$dir"
  [ "$status" -eq 0 ]
  [[ "$stderr" == *"modules present in the target"* ]]
  [[ "$stderr" != *"will not open its container"* ]]
}
