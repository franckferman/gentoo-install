#!/usr/bin/env bats
# Is there a terminal to ask a question on?
#
# This suite exists because the installer asked that question with
# `[[ -r /dev/tty ]]`, which answers a different one. /dev/tty is mode 0666 on
# every Linux system, so the test says yes to a process that has no controlling
# terminal at all — a run under `sudo` from a pipe, a cron job, a container, a
# CI job. The read that followed then failed on the redirect, and every guard
# built on it reported the wrong thing: the typed disk confirmation said
# "Nothing typed; nothing done", and the passphrase prompt returned in silence
# after a raw shell error, instead of naming the two unattended routes.
#
# The refusal was safe either way. What was lost was the message the operator
# needed, which is the whole reason those branches were written.

load helper

_gi_tty_openable() {
  # What the kernel says, not what the permission bits say.
  { : </dev/tty; } 2>/dev/null
}

@test "core_have_tty agrees with opening /dev/tty, not with its mode" {
  local want=1
  _gi_tty_openable && want=0
  gi_bash 'core_have_tty'
  [ "$status" -eq "$want" ]
}

@test "core_have_tty leaves no diagnostic behind when there is no terminal" {
  _gi_tty_openable && skip "this run has a controlling terminal"
  gi_bash 'core_have_tty || true'
  [ -z "$stderr" ]
}

@test "prompt_secret names the remedy when there is no terminal" {
  _gi_tty_openable && skip "this run has a controlling terminal"
  gi_bash 'NON_INTERACTIVE=no; prompt_secret PW "passphrase"'
  [ "$status" -ne 0 ]
  [[ "$stderr" == *"without a terminal"* ]]
  [[ "$stderr" == *"key file"* ]]
}

@test "confirm_typed says a terminal is needed, not that nothing was typed" {
  _gi_tty_openable && skip "this run has a controlling terminal"
  gi_bash 'NON_INTERACTIVE=no; confirm_typed "This erases /dev/loop9." /dev/loop9'
  [ "$status" -ne 0 ]
  [[ "$stderr" == *"needs a typed confirmation: /dev/loop9"* ]]
  [[ "$stderr" != *"Nothing typed"* ]]
}

@test "the reboot question reads the same guard as the rest" {
  # The September 5 incident was a reboot nobody asked for. The branch that
  # stops it when no one is there to answer read the broken test too.
  local line
  line="$(grep -n 'core_have_tty' "${GI_ROOT}/steps/95_finalize.sh")"
  [[ "$line" == *"ASSUME_YES"* ]]
}
