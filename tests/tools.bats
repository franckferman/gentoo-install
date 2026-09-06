#!/usr/bin/env bats
# The ten rescue tools, as a set.
#
# They are deliberately standalone — none of them sources lib/, so any one can be
# copied alone onto a USB stick and run on a machine that no longer boots. That
# independence is the point, and it is also why nothing was checking them: the
# suite loads the installer, and the tools share none of it.
#
# So these tests treat each tool as a black box and assert only what every one of
# them promises regardless of what it does: it explains itself, it refuses what
# it does not understand with the exit code the contract names, and it keeps
# stdout for values. A tool that fails here is broken for the person who reached
# for it at the worst possible moment.

load helper

gi_tools() {
  # Every executable tool, one path per line.
  local f
  for f in "${GI_ROOT}"/tools/*.sh; do
    [[ -e "$f" ]] || continue
    printf '%s\n' "$f"
  done
}

@test "there are tools to check at all" {
  # A glob that matches nothing would make every test below pass silently.
  local n
  n="$(gi_tools | wc -l)"
  [ "$n" -ge 10 ]
}

@test "every tool explains itself and exits zero doing it" {
  local tool out failures=""
  while read -r tool; do
    if ! out="$(bash "$tool" --help 2>&1)"; then
      failures+="  ${tool##*/}: --help exited non-zero"$'\n'
      continue
    fi
    # Twenty lines is not a style rule, it is the difference between a usage
    # block and a one-line "see the README".
    if [[ "$(printf '%s\n' "$out" | wc -l)" -lt 20 ]]; then
      failures+="  ${tool##*/}: --help printed almost nothing"$'\n'
    fi
    if [[ "$out" != *"${tool##*/}"* ]]; then
      failures+="  ${tool##*/}: --help never names the tool"$'\n'
    fi
  done < <(gi_tools)
  if [[ -n "$failures" ]]; then
    printf '%s' "$failures" >&2
    return 1
  fi
}

@test "every tool refuses an unknown flag with the usage exit code" {
  # DESIGN.md §3 fixes it at 2, and it is the difference a caller uses to tell
  # "you asked wrongly" from "it went wrong": a script that retries on 1 and
  # gives up on 2 needs both to mean what they say.
  local tool rc failures=""
  while read -r tool; do
    rc=0
    bash "$tool" --not-a-real-flag >/dev/null 2>&1 || rc=$?
    if [[ "$rc" -ne 2 ]]; then
      failures+="  ${tool##*/}: exited ${rc}, expected 2"$'\n'
    fi
  done < <(gi_tools)
  if [[ -n "$failures" ]]; then
    printf '%s' "$failures" >&2
    return 1
  fi
}

@test "no tool writes to stdout while refusing" {
  # stdout carries values — a device name, a UUID, a slot number — and a caller
  # reads it through $( ). A diagnostic printed there becomes part of whatever
  # the caller thought it was reading.
  local tool bytes failures=""
  while read -r tool; do
    bytes="$(bash "$tool" --not-a-real-flag 2>/dev/null | wc -c)"
    if [[ "$bytes" -ne 0 ]]; then
      failures+="  ${tool##*/}: ${bytes} byte(s) on stdout while refusing"$'\n'
    fi
  done < <(gi_tools)
  if [[ -n "$failures" ]]; then
    printf '%s' "$failures" >&2
    return 1
  fi
}

@test "every tool that writes a secret to disk puts it on a tmpfs, under a trap" {
  # A decrypted key in a temporary file is the one thing these tools must not
  # leave behind. secure_tmpdir() asks the filesystem which directory is in RAM
  # rather than assuming /tmp is — inside a chroot it usually is not — and a
  # trap removes the file however the tool ends.
  local tool failures=""
  while read -r tool; do
    grep -q 'mktemp' "$tool" || continue
    grep -q 'secure_tmpdir' "$tool" || {
      # A temporary file that holds no secret needs neither; say which it is.
      grep -qE 'mktemp [^)]*(pass|key|cred|secret)' "$tool" \
        && failures+="  ${tool##*/}: mktemps a secret outside secure_tmpdir"$'\n'
      continue
    }
    grep -qE '^\s*trap ' "$tool" \
      || failures+="  ${tool##*/}: mktemps a secret and installs no trap"$'\n'
  done < <(gi_tools)
  if [[ -n "$failures" ]]; then
    printf '%s' "$failures" >&2
    return 1
  fi
}

@test "a tool that documents a -- command mode actually parses --" {
  # rescue-chroot.sh enter -- CMD runs one command inside the rescued system
  # instead of an interactive shell. Before it existed the only way to run one
  # thing inside was to bypass the tool — prepare, then chroot by hand — which
  # is the sequence the tool exists to get right, and a recovery script or an
  # ssh check has nobody at a keyboard to type into a shell.
  #
  # Run as an ordinary user this stops on the root check or the target check.
  # What it must never say is "Unknown option: --".
  local tool out
  while read -r tool; do
    grep -q -- '-- CMD' "$tool" || continue
    out="$(bash "$tool" enter --target /nonexistent-target -- /bin/true 2>&1 || true)"
    if [[ "$out" == *"Unknown option: --"* ]]; then
      printf '%s documents -- and its parser refuses it\n' "${tool##*/}" >&2
      return 1
    fi
  done < <(gi_tools)
}
