#!/usr/bin/env bats
# Secure Boot signing — the path nothing had ever run.
#
# It was reasoned about carefully: sbsign appends rather than replaces, so the
# image is stripped before an in-place signature; `sbverify --list` exits 0 on
# an unsigned binary, so the verdict is read from its text and not its status.
# Both of those were right. Running it against the real tools on a real PE
# binary — a grubx64.efi step 80 had installed in a previous run — found two
# things reading could not: a refusal that contradicted itself, and the one
# write in this project that was never read back.
#
# The suite stubs sbsign and sbverify: the container has neither, and what is
# under test here is what step 80 does with their answers. The answers
# themselves are quoted in docs/TESTING.md, from the run that produced them.

load helper

_sb() {
  # A directory with a key, a certificate and an image in it.
  local dir
  dir="$(gi_tmp)/sb"
  mkdir -p "$dir"
  : >"${dir}/db.key"
  : >"${dir}/db.crt"
  printf 'MZ-not-really-a-PE\n' >"${dir}/src.efi"
  printf '%s\n' "$dir"
}

@test "a signature that does not verify against its certificate is refused" {
  # sbverify --list only says a signature table is present, which is also true
  # of an image whose signature covers different bytes than the ones on disk —
  # an ESP that filled up mid-write gives exactly that. Measured: truncating a
  # signed grubx64.efi by 2000 bytes left --list saying nothing was wrong and
  # --cert saying "Signature verification failed".
  local dir
  dir="$(_sb)"
  run --separate-stderr bash -c '
    source "$GI_ENTRY"; set +e
    config_init_defaults >/dev/null 2>&1
    DRY_RUN=no
    CFG[secureboot_keyfile]="$1/db.key"; CFG[secureboot_cert]="$1/db.crt"
    sbsign() { : >"${!#}.out"; return 0; }
    sbverify() {
      [[ "$1" == "--cert" ]] && { printf "Signature verification failed\n"; return 1; }
      printf "signature 1\n"; return 0
    }
    boot_install_efi "$1/src.efi" "$1/dest.efi"' bash "$dir"
  [ "$status" -ne 0 ]
  [[ "$stderr" == *"does not verify against"* ]]
  [[ "$stderr" == *"not the image that was signed"* ]]
  [[ "$stderr" == *"full ESP"* ]]
  # And it does not claim success on the way out.
  [[ "$stderr" != *"signed ${dir}/src.efi"* ]]
}

@test "a signature that does verify is reported as signed" {
  local dir
  dir="$(_sb)"
  run --separate-stderr bash -c '
    source "$GI_ENTRY"; set +e
    config_init_defaults >/dev/null 2>&1
    DRY_RUN=no
    CFG[secureboot_keyfile]="$1/db.key"; CFG[secureboot_cert]="$1/db.crt"
    sbsign() { return 0; }
    sbverify() {
      [[ "$1" == "--cert" ]] && { printf "Signature verification OK\n"; return 0; }
      printf "signature 1\n"; return 0
    }
    boot_install_efi "$1/src.efi" "$1/dest.efi"' bash "$dir"
  [ "$status" -eq 0 ]
  [[ "$stderr" == *"signed ${dir}/src.efi -> ${dir}/dest.efi"* ]]
}

@test "no sbverify is a warning, not a refusal" {
  # A live medium without app-crypt/sbsigntools can still sign — sbsign is what
  # signing needs. Refusing the install because the check cannot be made would
  # trade a machine that boots for a check.
  local dir
  dir="$(_sb)"
  run --separate-stderr bash -c '
    source "$GI_ENTRY"; set +e
    config_init_defaults >/dev/null 2>&1
    DRY_RUN=no
    CFG[secureboot_keyfile]="$1/db.key"; CFG[secureboot_cert]="$1/db.crt"
    sbsign() { return 0; }
    have() { [[ "$1" != "sbverify" ]]; }
    boot_install_efi "$1/src.efi" "$1/dest.efi"' bash "$dir"
  [ "$status" -eq 0 ]
  [[ "$stderr" == *"signed but not read back"* ]]
  [[ "$stderr" == *"sbsigntools"* ]]
}

@test "a key path with a typo in it is not blamed on the other setting" {
  # Both halves were given and one file is not there. The refusal used to add
  # "secureboot_keyfile and secureboot_cert are both required" underneath, which
  # sends the operator to check the two settings that are the part already
  # correct.
  local dir
  dir="$(_sb)"
  run --separate-stderr bash -c '
    source "$GI_ENTRY"; set +e
    config_init_defaults >/dev/null 2>&1
    DRY_RUN=no
    CFG[secureboot_keyfile]="$1/db.kye"; CFG[secureboot_cert]="$1/db.crt"
    boot_install_efi "$1/src.efi" "$1/dest.efi"' bash "$dir"
  [ "$status" -ne 0 ]
  [[ "$stderr" == *"Secure Boot key not readable"* ]]
  [[ "$stderr" == *"the reason is above"* ]]
  [[ "$stderr" != *"secureboot_keyfile and secureboot_cert are both required"* ]]
  [ ! -e "${dir}/dest.efi" ]
}

@test "half a pair names the half that is missing" {
  local dir
  dir="$(_sb)"
  run --separate-stderr bash -c '
    source "$GI_ENTRY"; set +e
    config_init_defaults >/dev/null 2>&1
    DRY_RUN=no
    CFG[secureboot_keyfile]="$1/db.key"; CFG[secureboot_cert]=""
    boot_install_efi "$1/src.efi" "$1/dest.efi"' bash "$dir"
  [ "$status" -ne 0 ]
  [[ "$stderr" == *"secureboot_keyfile and secureboot_cert are both required"* ]]
  [[ "$stderr" == *"the certificate is the one that was not given"* ]]

  run --separate-stderr bash -c '
    source "$GI_ENTRY"; set +e
    config_init_defaults >/dev/null 2>&1
    DRY_RUN=no
    CFG[secureboot_keyfile]=""; CFG[secureboot_cert]="$1/db.crt"
    boot_install_efi "$1/src.efi" "$1/dest.efi"' bash "$dir"
  [ "$status" -ne 0 ]
  [[ "$stderr" == *"the key is the one that was not given"* ]]
}

@test "no key pair at all installs unsigned and says what that costs" {
  local dir
  dir="$(_sb)"
  run --separate-stderr bash -c '
    source "$GI_ENTRY"; set +e
    config_init_defaults >/dev/null 2>&1
    DRY_RUN=no
    CFG[secureboot_keyfile]=""; CFG[secureboot_cert]=""
    sbverify() { printf "No signature table present\n"; return 0; }
    boot_install_efi "$1/src.efi" "$1/dest.efi"' bash "$dir"
  [ "$status" -eq 0 ]
  [ -f "${dir}/dest.efi" ]
  [[ "$stderr" == *"installed unsigned"* ]]
  [[ "$stderr" == *"will not start this image"* ]]
}

@test "the read-back is skipped in a dry run" {
  # Nothing was written, so there is nothing to read back, and sbverify would
  # be asked about a file that does not exist.
  local dir
  dir="$(_sb)"
  run --separate-stderr bash -c '
    source "$GI_ENTRY"; set +e
    config_init_defaults >/dev/null 2>&1
    DRY_RUN=yes
    sbverify() { printf "Signature verification failed\n"; return 1; }
    boot_verify_signature "$1/nothing.efi" "$1/db.crt"' bash "$dir"
  [ "$status" -eq 0 ]
  [[ "$stderr" != *"does not verify"* ]]
}
