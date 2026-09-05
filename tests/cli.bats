#!/usr/bin/env bats
#
# gentoo-install — the command line: what it refuses, and what it puts on stdout
# ----------------------------------------------------------------------------
# DESIGN.md §3 reserves standard output for values a function returns and for
# --json. A helper that printed there would poison every $( ) that wraps a
# callee, and the damage would land in a device name or a kernel command line.
# §5 and §6 require every refusal to happen at parse time, to exit 2, and to
# name the way out.
#

bats_require_minimum_version 1.5.0

load helper

# --------------------------------------------------------------------------- #
#  Standard output belongs to values (DESIGN.md §3)                           #
# --------------------------------------------------------------------------- #
@test "--dry-run must write nothing at all on stdout" {
  # The whole run, every step, with the log and the journal inside $BATS_TMPDIR.
  # Steps are expected to fail here — a container is not a target machine — and
  # that is beside the point: whatever happens, stdout stays empty.
  gi_run --dry-run
  [ "$output" = "" ] || {
    printf 'a dry run wrote on stdout:\n%s\n' "$output" >&2
    return 1
  }
  [ -n "$stderr" ] # and it did say what it was doing, on stderr
}

@test "the output helpers must all write on stderr, whatever the level" {
  gi_bash 'log l; ok o; warn w; err e; skip s'
  [ "$status" -eq 0 ]
  [ "$output" = "" ] || {
    printf 'an output helper wrote on stdout:\n%s\n' "$output" >&2
    return 1
  }
  [[ "$stderr" == *"[*] l"* ]]
  [[ "$stderr" == *"[+] o"* ]]
  [[ "$stderr" == *"[!] w"* ]]
  [[ "$stderr" == *"[x] e"* ]]
  [[ "$stderr" == *"[=] s"* ]]
}

@test "--version prints the version alone, so a script can read it" {
  gi_run --version
  [ "$status" -eq 0 ]
  [[ "$output" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]
  [ "$stderr" = "" ]
}

@test "--json puts the plan on stdout and keeps the diagnostics on stderr" {
  gi_run --json
  [ "$status" -eq 0 ]
  [[ "$output" == "{"* ]]
  [[ "$output" == *"}" ]]
  [[ "$output" == *'"version"'* ]]
  [[ "$output" == *'"steps"'* ]]
  # Balanced braces, which is as far as a container with no json parser can go.
  local opened closed
  opened="$(printf '%s' "$output" | tr -cd '{' | wc -c)"
  closed="$(printf '%s' "$output" | tr -cd '}' | wc -c)"
  [ "$opened" -eq "$closed" ]
}

# --------------------------------------------------------------------------- #
#  The refusals that matter (DESIGN.md §5, §6, §13)                           #
# --------------------------------------------------------------------------- #
@test "--flavour splitusr --init systemd must be refused: no stage3 is published for the pair" {
  # The combination is spellable, each half is valid, and upstream publishes
  # splitusr for OpenRC only. A selector that does not know that walks the
  # operator into a 404 halfway through an install, after the disks are wiped.
  gi_run --flavour splitusr --init systemd --dry-run
  [ "$status" -eq 2 ]
  [[ "$stderr" == *"splitusr"* ]]
  [[ "$stderr" == *"openrc"* ]] # what it does exist for
  [[ "$stderr" == *"example:"* ]]
}

@test "an unknown init system must exit 2 and name the two that exist" {
  gi_run --init sysvinit
  [ "$status" -eq 2 ]
  [[ "$stderr" == *"Unknown init system: sysvinit"* ]]
  [[ "$stderr" == *"openrc"* ]]
  [[ "$stderr" == *"systemd"* ]]
  [[ "$stderr" == *"example:  --init openrc"* ]]
}

@test "an unknown --on-conflict mode must exit 2 and name all four" {
  gi_run --on-conflict clobber
  [ "$status" -eq 2 ]
  [[ "$stderr" == *"overwrite"* ]]
  [[ "$stderr" == *"skip"* ]]
  [[ "$stderr" == *"prompt"* ]]
  [[ "$stderr" == *"backup"* ]]
}

@test "an unknown option must exit 2 and point at the list" {
  gi_run --frobnicate
  [ "$status" -eq 2 ]
  [[ "$stderr" == *"Unknown option: --frobnicate"* ]]
  [[ "$stderr" == *"--help"* ]]
}

@test "an option name containing -h must not be mistaken for --help" {
  # DESIGN.md §13: `[[ "$*" == *"-h"* ]]` swallows every flag whose name happens
  # to contain -h. --no-color does. If this run printed the help screen it would
  # exit 0 with a usage banner on stdout instead of doing anything.
  gi_run --no-color --list-steps
  [ "$status" -eq 0 ]
  [[ "$output" != *"Usage:"* ]]
  [[ "$output" == *"step_10_preflight"* ]]
}

@test "a flag that needs a value and is given none must exit 2, not swallow the next flag" {
  gi_run --steps
  [ "$status" -eq 2 ]
  [[ "$stderr" == *"requires a value"* ]]
}

@test "a bare argument is not an option and must be refused" {
  gi_run /dev/sda
  [ "$status" -eq 2 ]
  [[ "$stderr" == *"options only"* ]]
}

@test "an unknown profile must exit 2 and describe every profile there is" {
  gi_run --profile paranoid
  [ "$status" -eq 2 ]
  [[ "$stderr" == *"Unknown profile: paranoid"* ]]
  [[ "$stderr" == *"minimal"* ]]
  [[ "$stderr" == *"desktop"* ]]
  [[ "$stderr" == *"server"* ]]
  [[ "$stderr" == *"hardened"* ]]
}

@test "--help must exit 0 and show the steps, which are the table of contents" {
  gi_run --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage:"* ]]
  [[ "$output" == *"step_10_preflight"* ]]
  [[ "$output" == *"built-in default  <  profile  <  configuration file  <  explicit flag"* ]]
}
