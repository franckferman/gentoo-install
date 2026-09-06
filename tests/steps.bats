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
