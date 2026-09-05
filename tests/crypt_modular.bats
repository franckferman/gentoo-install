#!/usr/bin/env bats
# The cipher and the key derivation are choices, and the wrong one must be
# refused before step 20 wipes a disk for it.

load helper

@test "an unknown crypt_pbkdf must die at parse time, not in step 30" {
  gi_run --crypt luks-passphrase --crypt-pbkdf scrypt --dry-run --yes
  [ "$status" -eq 2 ]
  [[ "$stderr" == *"Invalid value for crypt_pbkdf"* ]]
  [[ "$stderr" == *"argon2id"* ]]
}

@test "pbkdf2 with a memory parameter must be refused, cryptsetup rejects the pair" {
  gi_run --crypt luks-passphrase --crypt-pbkdf pbkdf2 \
    --crypt-pbkdf-memory 64 --dry-run --yes
  [ "$status" -ne 0 ]
  [[ "$stderr" == *"takes no crypt_pbkdf_memory"* ]]
}

@test "crypt_format_args must not pass --pbkdf-memory when the pbkdf is pbkdf2" {
  gi_bash 'config_init_defaults
           CFG[crypt_pbkdf]=pbkdf2; CFG[crypt_pbkdf_memory]=64
           crypt_format_args | tr "\n" " "'
  [ "$status" -eq 0 ]
  [[ "$output" != *"--pbkdf-memory"* ]]
}

@test "crypt_format_args must pass --pbkdf-memory for argon2, which takes one" {
  gi_bash 'config_init_defaults
           CFG[crypt_pbkdf]=argon2id; CFG[crypt_pbkdf_memory]=64
           crypt_format_args | tr "\n" " "'
  [ "$status" -eq 0 ]
  [[ "$output" == *"--pbkdf-memory 64"* ]]
}
