#!/usr/bin/env bats
# The three small things: an inventory that needs no pre-flight, a keymap said
# before a passphrase is typed, and an initramfs list that is closed on purpose.

load helper

@test "--list-disks must answer without resolving a stage or touching the network" {
  gi_run --list-disks
  [ "$status" -eq 0 ]
  [[ "$stderr" == *"disks on this machine"* ]]
}

@test "--list-disks must not need a target, a stage or any privilege" {
  gi_run --list-disks
  [ "$status" -eq 0 ]
  [[ "$stderr" != *"must run as root"* ]]
}

@test "initramfs must be a closed list: an unproven generator cannot be asked for" {
  gi_run --initramfs booster --dry-run --yes
  [ "$status" -eq 2 ]
  [[ "$stderr" == *"Invalid value for initramfs"* ]]
  [[ "$stderr" == *"dracut"* ]]
}

@test "both generators the project actually builds must be accepted" {
  local gen
  for gen in dracut genkernel; do
    gi_run --initramfs "$gen" --dump-config
    [ "$status" -eq 0 ] || {
      printf 'generator refused: %s\n' "$gen" >&2
      return 1
    }
  done
}

@test "the keymap must be said once, not on every passphrase" {
  gi_bash 'config_init_defaults
           crypt_say_keymap >/dev/null 2>&1
           crypt_say_keymap 2>&1 | wc -l'
  [ "$status" -eq 0 ]
  [ "$output" = "0" ]
}
