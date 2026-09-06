#!/usr/bin/env bash
#
# gentoo-install — the CPU governor for the duration of the build
# ----------------------------------------------------------------------------
# A Gentoo install is one long compile. The machine doing it is usually a live
# medium, whose governor nobody chose: most of them boot on `powersave` or
# `schedutil`, which is the right default for a laptop reading a web page and
# the wrong one for four hours of gcc. Setting it to `performance` for the
# duration is what the handbook-following operator does by hand.
#
# Two rules shape this file. What it changes belongs to the machine running the
# installer, not to the target — so it is announced, recorded and put back.
# And it is put back from three places: step 95, cleanup() on any exit, and the
# state journal, which is the only one that survives a machine losing power in
# the middle of stage 3.
#
# Usage:  source lib/cpu.sh   (needs lib/core.sh)
#
set -euo pipefail

# Guarded so that sourcing it twice is harmless.
[[ -n "${_GI_CPU_LOADED:-}" ]] && return 0
_GI_CPU_LOADED=1

# Overridable so the suite can drive this against a directory instead of the
# machine it runs on. Every path below is built from it.
CPU_SYSFS="${GI_CPU_SYSFS:-/sys/devices/system/cpu}"

# What this run changed, for cleanup(). Empty when nothing was.
_GI_CPU_GOVERNOR_BEFORE=""

cpu_init_defaults() {
  # performance, and not "leave it alone", because leaving it alone means
  # taking whatever the live medium happened to boot with. `keep` opts out and
  # is always accepted, on machines that expose no governor at all included.
  set_default cpu_governor "performance"
}

cpu_governor_files() {
  # One path per line, empty when this machine exposes no cpufreq at all —
  # which is what a VM without a cpufreq driver looks like, and is not an
  # error.
  local f
  for f in "$CPU_SYSFS"/cpu[0-9]*/cpufreq/scaling_governor; do
    [[ -f "$f" ]] && printf '%s\n' "$f"
  done
  return 0
}

cpu_has_governor() { [[ -n "$(cpu_governor_files)" ]]; }

cpu_governor_now() {
  # The governor of the first CPU. A returned value, so stdout; empty when
  # there is nothing to read.
  local f
  f="$(cpu_governor_files | head -n 1)"
  [[ -n "$f" && -r "$f" ]] || return 1
  tr -d ' \n' <"$f"
}

cpu_governors_available() {
  # Asked of the machine, never from a table: the list depends on the cpufreq
  # driver. intel_pstate offers performance and powersave and nothing else,
  # while acpi-cpufreq adds ondemand, conservative and schedutil.
  local f
  f="$(cpu_governor_files | head -n 1)"
  f="${f%/scaling_governor}/scaling_available_governors"
  [[ -r "$f" ]] || return 1
  tr -s ' \n' ' ' <"$f" | sed 's/^ //; s/ $//'
}

cpu_validate_governor() {
  # Called at parse time, like every other validation, so a name this machine
  # does not have is refused before step 20 erases anything.
  local want="${1:-}" have
  [[ "$want" == "keep" ]] && return 0
  cpu_has_governor || return 0 # nothing to validate against; apply says so
  have=" $(cpu_governors_available) "
  [[ "$have" == *" $want "* ]] && return 0
  die_usage "This machine has no ${want} governor" \
    "it offers:${have%" "}" \
    "example:  cpu_governor = keep"
}

cpu_apply_governor() {
  # Args: none. Reads CFG[cpu_governor]. Returns 0 when there is nothing to do.
  local want="${CFG[cpu_governor]:-keep}" now
  local -a files=()

  [[ "$want" == "keep" ]] && return 0

  if ! cpu_has_governor; then
    skip "no cpufreq governor on this machine; nothing to set"
    return 0
  fi

  now="$(cpu_governor_now)" || now=""
  if [[ "$now" == "$want" ]]; then
    log "cpu governor already ${want}"
    return 0
  fi

  mapfile -t files < <(cpu_governor_files)
  log "cpu governor ${now:-unknown} -> ${want} on ${#files[@]} cpu(s)"
  log "       this is the machine running the installer, not the target;"
  log "       step 95 and any exit put ${now:-it} back"

  # One command and not one per CPU. tee takes every file at once, so the
  # journal carries one entry and --dry-run one line that names every file
  # that will be written. The first version called run_cmd in a loop and put
  # sixteen identical lines in the plan on this machine, which on a two-socket
  # server would be a hundred and twenty-eight.
  if ! run_cmd tee "${files[@]}" <<<"$want" >/dev/null; then
    warn "could not set every governor; the build runs on ${now:-what is there}"
    return 0
  fi

  # Recorded after the change and not before it: a journal entry naming a
  # governor that was never left is a restore that undoes nothing on the next
  # run. Both places, because they answer different failures — the variable
  # covers a Ctrl-C, the journal covers a machine that lost power.
  _GI_CPU_GOVERNOR_BEFORE="$now"
  # Guarded on STATE_FILE the way step 95 guards its own writes: state_set
  # dies when there is no journal, and `|| true` does not catch an exit. A run
  # driven with --steps 40 on a machine whose /var is read-only would have
  # ended here, one line after turning the governor up.
  if [[ -n "$now" && "$DRY_RUN" != "yes" && -n "${STATE_FILE:-}" ]]; then
    state_set cpu.governor_before "$now" 2>/dev/null || true
  fi
  return 0
}

_cpu_forget_record() {
  # The journal entry means "this run turned the governor up, and here is what
  # it was". Once it is back, that claim is false, and the journal outlives the
  # run: a later one reaching step 95 read it and set the machine back to the
  # governor of the day of the install — undoing, in silence, a choice the
  # operator had made since. A record of something that has been undone is not
  # a record, it is a trap.
  #
  # Guarded on STATE_FILE the way step 95 guards its own writes: state_unset
  # dies without a journal, and this runs from cleanup() on every exit,
  # including the ones that never opened one.
  [[ -n "${STATE_FILE:-}" && "$DRY_RUN" != "yes" ]] || return 0
  state_unset cpu.governor_before 2>/dev/null || true
}

cpu_restore_governor() {
  # Args: $1 = optional governor to go back to; the journal answers otherwise.
  # Silent and successful when nothing was changed: it is called from cleanup()
  # on every exit, including the ones that never got as far as step 40.
  local back="${1:-}" f
  local -a files=()

  [[ -n "$back" ]] || back="$_GI_CPU_GOVERNOR_BEFORE"
  [[ -n "$back" ]] || back="$(state_get cpu.governor_before 2>/dev/null || true)"
  [[ -n "$back" ]] || return 0
  cpu_has_governor || return 0

  if [[ "$(cpu_governor_now)" != "$back" ]]; then
    mapfile -t files < <(cpu_governor_files)
    for f in "${files[@]}"; do
      printf '%s\n' "$back" >"$f" 2>/dev/null || true
    done
  fi

  # Read back before forgetting. The writes above are silent on failure — a
  # governor can be refused by the driver — and dropping the record then would
  # lose the only note of what this machine is owed. A record kept is a job a
  # later run can finish; a record dropped is a machine left turned up.
  if [[ "$(cpu_governor_now)" != "$back" ]]; then
    warn "the cpu governor is still $(cpu_governor_now), not ${back}"
    warn "       the journal keeps what it was, so a later run can put it back"
    return 0
  fi

  _GI_CPU_GOVERNOR_BEFORE=""
  _cpu_forget_record
  return 0
}
