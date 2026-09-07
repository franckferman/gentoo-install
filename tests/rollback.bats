#!/usr/bin/env bats
#
# gentoo-install — what a rejected write leaves behind
# ----------------------------------------------------------------------------
# write_validated exists so that a file with a checker of its own — visudo -c,
# findmnt --verify, sshd -t, grub-script-check, dracut's own sourcing — never
# reaches a machine in a state its checker refuses. It writes, asks, and rolls
# back.
#
# Rolling back a file that existed means putting the old content there. Rolling
# back a file that did not exist means removing it, and that half was missing:
# the rejected content stayed. For the files this function guards that is the
# worst of the three outcomes. A new /etc/sudoers.d drop-in that visudo refuses
# makes sudo refuse to run at all — "no valid sudoers sources found, quitting" —
# which is a machine nobody can administer, the accident this project is
# written against. A dracut.conf.d snippet that does not source breaks every
# initramfs build after it. A loader entry the firmware cannot read is a boot
# menu with a dead line in it.
#

bats_require_minimum_version 1.5.0

load helper

gi_rollback_setup() {
  cat <<'EOF'
  DRY_RUN=no; NON_INTERACTIVE=yes; ON_CONFLICT=backup
  refuses() { return 1; }
  accepts() { return 0; }
EOF
}

@test "a rejected write to a file that existed puts the old content back" {
  local dir
  dir="$(gi_tmp)/rb1"
  mkdir -p "$dir"
  printf 'the old content\n' >"${dir}/f"
  run --separate-stderr bash -c 'source "$GI_ENTRY"
'"$(gi_rollback_setup)"'
    write_validated "$1/f" refuses <<<"the new content"
  ' bash "$dir"
  [ "$status" -ne 0 ]
  [ "$(cat "${dir}/f")" = "the old content" ] || {
    printf 'the previous content must come back: %s\n' "$(cat "${dir}/f")" >&2
    return 1
  }
}

@test "a rejected write to a file that did not exist removes it" {
  local dir
  dir="$(gi_tmp)/rb2"
  mkdir -p "$dir"
  run --separate-stderr bash -c 'source "$GI_ENTRY"
'"$(gi_rollback_setup)"'
    write_validated "$1/10-gentoo-install" refuses <<<"alice ALL=(ALL:ALL) ALL"
  ' bash "$dir"
  [ "$status" -ne 0 ]
  [[ ! -e "${dir}/10-gentoo-install" ]] || {
    printf 'a sudoers drop-in visudo refuses was left in place:\n%s\n' \
      "$(cat "${dir}/10-gentoo-install")" >&2
    printf 'sudo then refuses to run at all, on every account.\n' >&2
    return 1
  }
}

@test "the removal is said out loud, not done quietly" {
  local dir
  dir="$(gi_tmp)/rb3"
  mkdir -p "$dir"
  run --separate-stderr bash -c 'source "$GI_ENTRY"
'"$(gi_rollback_setup)"'
    write_validated "$1/f" refuses <<<"whatever"
  ' bash "$dir"
  [[ "$stderr" == *"nothing was here before"* && "$stderr" == *"has been removed"* ]] || {
    printf 'an operator has to be told the file is gone: %s\n' "$stderr" >&2
    return 1
  }
}

@test "a write its checker accepts is kept, whether or not it existed" {
  local dir
  dir="$(gi_tmp)/rb4"
  mkdir -p "$dir"
  run --separate-stderr bash -c 'source "$GI_ENTRY"
'"$(gi_rollback_setup)"'
    write_validated "$1/f" accepts <<<"good content"
  ' bash "$dir"
  [ "$status" -eq 0 ]
  [ "$(cat "${dir}/f")" = "good content" ]
}
