#!/usr/bin/env bats
#
# gentoo-install — the settings table and the enumeration registry
# ----------------------------------------------------------------------------
# CFG_ENUM is kept by hand, and a hand-kept registry drifts: a setting gains an
# enumeration in its declaration comment, nobody adds the row, and from then on
# the value out of a .conf reaches the machine unchecked. This repository has
# already lived through five of those. The first test in this file catches the
# class, not the instance.
#

bats_require_minimum_version 1.5.0

load helper

# --------------------------------------------------------------------------- #
#  The enumeration registry                                                   #
# --------------------------------------------------------------------------- #
@test "a setting declared with an enumeration must be in CFG_ENUM, or nothing checks it" {
  local registry file key values missing=""

  registry="$(gi_capture 'config_init_defaults; printf "%s\n" "${!CFG_ENUM[@]}"')"

  while IFS=$'\t' read -r file key values; do
    gi_enum_is_exempt "$key" && continue
    if ! printf '%s\n' "$registry" | grep -qx -- "$key"; then
      missing+="  ${file#"${GI_ROOT}/"}: ${key}  (${values})"$'\n'
    fi
  done < <(gi_enum_comments)

  if [[ -n "$missing" ]]; then
    printf 'declared with an enumeration, absent from CFG_ENUM:\n%s' "$missing" >&2
    printf 'config_validate_enums() cannot see these, so a value out of a .conf\n' >&2
    printf 'is accepted at parse time and only fails hours later, inside a step.\n' >&2
    return 1
  fi
}

@test "the enumeration in a comment and the one in CFG_ENUM must be the same list" {
  # A drift in the values is the same defect as a missing row, only quieter:
  # the comment promises four spellings and the registry accepts three.
  local registry file key values declared mismatched=""

  registry="$(gi_capture \
    'config_init_defaults; for k in "${!CFG_ENUM[@]}"; do printf "%s\t%s\n" "$k" "${CFG_ENUM[$k]}"; done')"

  while IFS=$'\t' read -r file key values; do
    gi_enum_is_exempt "$key" && continue
    declared="$(printf '%s\n' "$registry" | awk -F'\t' -v k="$key" '$1 == k { print $2 }')"
    [[ -n "$declared" ]] || continue # the test above already reports this one
    if [[ "$declared" != "$values" ]]; then
      mismatched+="  ${key}: comment says ${values}, CFG_ENUM says ${declared}"$'\n'
    fi
  done < <(gi_enum_comments)

  if [[ -n "$mismatched" ]]; then
    printf 'the declaration and the registry disagree:\n%s' "$mismatched" >&2
    return 1
  fi
}

@test "disk_swap has no closed set, and its declaration must keep saying so" {
  # disk_swap is the one exemption in gi_enum_is_exempt that is about the value
  # space rather than about reachability: it takes auto, none, or a size such as
  # 8G. The proof is the placeholder in its own comment. The day that comment
  # becomes a list of literals, the exemption is wrong and this test says so.
  local row values

  row="$(gi_enum_comments | awk -F'\t' '$2 == "disk_swap" { print; exit }')"
  [[ -n "$row" ]] || {
    printf 'disk_swap no longer declares an enumeration at all; the exemption\n' >&2
    printf 'in tests/helper.bash describes a declaration that is gone.\n' >&2
    return 1
  }

  values="$(printf '%s\n' "$row" | cut -f3)"
  [[ "$values" == *"<"* ]] || {
    printf 'disk_swap now reads %s: a closed set, so it belongs in CFG_ENUM\n' "$values" >&2
    printf 'and the exemption in tests/helper.bash must go.\n' >&2
    return 1
  }
}

@test "every module that declares settings must be called by config_init_defaults" {
  # A module declaring set_default in its own *_init_defaults is only useful if
  # that function runs before a .conf is read: cfg_known() answers from CFG, so
  # a key declared later is refused outright and the setting is unreachable.
  # This happened twice — the disk, crypt and stage modules, then portage, whose
  # seventeen settings were declared and unspellable for four cycles.
  #
  # The dispatch loop is read on its own, not the whole file: the comment above
  # it names the same functions, and matching that made an earlier version of
  # this test pass while the loop had been emptied.
  local dispatched declared fn
  dispatched="$(sed -n '/for fn in .*_defaults/,/; do/p' "${GI_ROOT}/lib/config.sh")"
  declared="$(grep -rhoE '^[a-z_]+_(init|config)_defaults\(\)' \
    "${GI_ROOT}/lib" "${GI_ROOT}/steps" 2>/dev/null |
    sed 's/()$//' | grep -v '^config_init_defaults$' | sort -u)"

  local missing_fns=()
  for fn in $declared; do
    printf '%s' "$dispatched" | grep -qw -- "$fn" || missing_fns+=("$fn")
  done

  if [ "${#missing_fns[@]}" -ne 0 ]; then
    printf 'declares settings, absent from the config_init_defaults loop:\n' >&2
    printf '  %s\n' "${missing_fns[@]}" >&2
  fi
  [ "${#missing_fns[@]}" -eq 0 ]
}

@test "every CFG_ENUM key must name a setting the project actually declares" {
  # The drift runs both ways. A row for a key nothing declares is a check that
  # can never fire, and it reads like coverage that is not there.
  gi_bash '
    config_init_defaults
    orphans=""
    for k in "${!CFG_ENUM[@]}"; do
      cfg_known "$k" || orphans="${orphans} ${k}"
    done
    [[ -z "$orphans" ]] || { printf "CFG_ENUM rows nothing declares:%s\n" "$orphans"; exit 1; }
  '
  [ "$status" -eq 0 ] || {
    printf '%s\n' "$output" >&2
    return 1
  }
}

@test "a built-in default must satisfy its own enumeration" {
  # A default outside its own list turns every run into a usage error, and the
  # operator has typed nothing yet.
  gi_bash 'config_init_defaults; config_validate_enums'
  [ "$status" -eq 0 ] || {
    printf 'the shipped defaults do not pass their own validation:\n%s\n' "$stderr" >&2
    return 1
  }
}

# --------------------------------------------------------------------------- #
#  Validation, stage 1: refuse at parse time (DESIGN.md §5)                   #
# --------------------------------------------------------------------------- #
@test "an invalid enumeration value in a .conf must die at parse time and name the valid values" {
  local conf
  conf="$(gi_conf 'bootloader = frobnicate')"

  gi_run --config "$conf" --dry-run
  [ "$status" -eq 2 ]
  [[ "$stderr" == *"Invalid value for bootloader: frobnicate"* ]]
  # The error voice of §6: the message must carry the way out, not just the
  # complaint. All three spellings, and a copyable example.
  [[ "$stderr" == *"grub"* ]]
  [[ "$stderr" == *"efistub"* ]]
  [[ "$stderr" == *"systemd-boot"* ]]
  [[ "$stderr" == *"example:"* ]]
}

@test "an unknown setting name in a .conf must be refused, not silently ignored" {
  local conf
  conf="$(gi_conf 'frobnicator = 3')"

  gi_run --config "$conf" --dry-run
  [ "$status" -eq 2 ]
  [[ "$stderr" == *"Unknown setting"* ]]
  [[ "$stderr" == *"frobnicator"* ]]
}

# --------------------------------------------------------------------------- #
#  Precedence: default < profile < file < flag (DESIGN.md §5)                 #
# --------------------------------------------------------------------------- #
@test "an explicit flag must beat a profile, whatever the order on the command line" {
  # --profile desktop sets flavour=desktop through set_default. The flag comes
  # first on the line and the profile is applied afterwards, so the mechanism,
  # not the ordering, is what has to protect the intention.
  gi_run --flavour base --profile desktop --dump-config
  [ "$status" -eq 0 ]
  [ "$(gi_setting flavour "$output")" = "base" ]
  [ "$(gi_origin flavour "$output")" = "explicit" ]
}

@test "a configuration file must beat a profile and lose to a flag" {
  local conf
  conf="$(gi_conf 'init = systemd' 'flavour = desktop')"

  # --profile server would set init=openrc and flavour=nomultilib. The file
  # beats it, and the flag beats the file.
  gi_run --config "$conf" --profile server --init openrc --dump-config
  [ "$status" -eq 0 ]
  [ "$(gi_setting flavour "$output")" = "desktop" ]
  [ "$(gi_setting init "$output")" = "openrc" ]
}

@test "every step resolves the target root to the same directory" {
  # Four names have pointed at this one directory: root, disk_root, chroot_dir
  # and target_root. Measured, not read: --root moved four of the seven
  # resolvers, --chroot-dir moved exactly one — the chroot, away from the disk
  # the run had just mounted — and --target-root moved none at all while being
  # accepted in silence.
  local snippet='
    config_init_defaults >/dev/null 2>&1
    parse_args --dry-run --root /mnt/probe >/dev/null 2>&1
    # Whatever else is in CFG, root is the answer: a resolver that prefers
    # another key is the defect, not the spelling of the key.
    CFG[chroot_dir]=/mnt/other; CFG[target_root]=/mnt/other; CFG[disk_root]=/mnt/other
    printf "%s\n" "$(disk_mount_root)" "$(stage_root)" "$(chroot_target)" \
      "$(_portage_root)" "$(target_root)" "$(_sys_root)" "$(_fin_root)"'
  run --separate-stderr bash -c 'source "$GI_ENTRY"; '"$snippet"
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | sort -u)" = "/mnt/probe" ]
  [ "$(printf '%s\n' "$output" | wc -l)" -eq 7 ]
}

@test "no second name for the target root is accepted" {
  # Silence is the worst answer to --target-root: the run installs into
  # /mnt/gentoo and never says the flag did nothing.
  local flag
  for flag in --chroot-dir --target-root --disk-root; do
    run --separate-stderr "$GI_ENTRY" --dry-run "$flag" /mnt/probe --steps 95
    [[ "$stderr" == *"Unknown option: ${flag}"* ]] || {
      printf '%s was accepted\n' "$flag" >&2
      return 1
    }
  done
}

@test "the governor is put back to what the machine had" {
  # An install is one long compile, and a live medium boots on whatever
  # governor its image happened to ship. What this changes belongs to the
  # machine running the installer, so it is announced, recorded and restored.
  local dir c
  dir="$(gi_tmp)/cpu"
  for c in 0 1; do
    mkdir -p "${dir}/cpu${c}/cpufreq"
    printf 'powersave\n' >"${dir}/cpu${c}/cpufreq/scaling_governor"
    printf 'performance powersave\n' >"${dir}/cpu${c}/cpufreq/scaling_available_governors"
  done

  gi_bash 'CPU_SYSFS="$1"; config_init_defaults >/dev/null 2>&1
    DRY_RUN=no; STATE_FILE=""
    cpu_apply_governor
    printf "applied=%s\n" "$(cpu_governor_now)"
    cpu_restore_governor
    printf "restored=%s\n" "$(cpu_governor_now)"' "$dir"
  [ "$status" -eq 0 ]
  [[ "$output" == *"applied=performance"* ]]
  [[ "$output" == *"restored=powersave"* ]]
}

@test "a dry run never touches the governor" {
  local dir
  dir="$(gi_tmp)/cpudry"
  mkdir -p "${dir}/cpu0/cpufreq"
  printf 'powersave\n' >"${dir}/cpu0/cpufreq/scaling_governor"
  printf 'performance powersave\n' >"${dir}/cpu0/cpufreq/scaling_available_governors"

  gi_bash 'CPU_SYSFS="$1"; config_init_defaults >/dev/null 2>&1
    DRY_RUN=yes; STATE_FILE=""
    cpu_apply_governor
    printf "%s\n" "$(cpu_governor_now)"' "$dir"
  [ "$status" -eq 0 ]
  [ "$output" = "powersave" ]
}

@test "cpu_governor = keep changes nothing, and a machine with no cpufreq says so" {
  local dir
  dir="$(gi_tmp)/cpukeep"
  mkdir -p "${dir}/cpu0/cpufreq"
  printf 'schedutil\n' >"${dir}/cpu0/cpufreq/scaling_governor"
  printf 'performance schedutil\n' >"${dir}/cpu0/cpufreq/scaling_available_governors"

  gi_bash 'CPU_SYSFS="$1"; config_init_defaults >/dev/null 2>&1
    DRY_RUN=no; STATE_FILE=""; CFG[cpu_governor]=keep
    cpu_apply_governor
    printf "%s\n" "$(cpu_governor_now)"' "$dir"
  [ "$output" = "schedutil" ]

  gi_bash 'CPU_SYSFS="$1/nothing-here"; config_init_defaults >/dev/null 2>&1
    DRY_RUN=no; STATE_FILE=""
    cpu_apply_governor' "$dir"
  [ "$status" -eq 0 ]
  [[ "$stderr" == *"no cpufreq governor"* ]]
}

@test "a governor this machine does not have is refused before anything is erased" {
  local dir
  dir="$(gi_tmp)/cpubad"
  mkdir -p "${dir}/cpu0/cpufreq"
  printf 'powersave\n' >"${dir}/cpu0/cpufreq/scaling_governor"
  printf 'performance powersave\n' >"${dir}/cpu0/cpufreq/scaling_available_governors"

  gi_bash 'CPU_SYSFS="$1"; config_init_defaults >/dev/null 2>&1
    cpu_validate_governor ondemand' "$dir"
  [ "$status" -ne 0 ]
  [[ "$stderr" == *"no ondemand governor"* ]]
  [[ "$stderr" == *"performance powersave"* ]]
}

@test "a PCR policy can be named, and the name becomes its numbers once" {
  # There is not one PCR policy. Naming the ones that get used means an
  # operator picks a policy instead of copying numbers whose meaning is
  # somewhere else.
  local pair
  for pair in "firmware:0,2,3,6" "secureboot:7" \
    "firmware+secureboot:0,2,3,6,7" "strict:0,1,2,3,4,5,6,7" "0,7:0,7"; do
    gi_bash 'config_init_defaults >/dev/null 2>&1
      CFG[crypt_pcrs]="$1"; crypt_expand_pcrs >/dev/null 2>&1
      printf "%s\n" "${CFG[crypt_pcrs]}"' "${pair%%:*}"
    [ "$output" = "${pair#*:}" ] || {
      printf '%s expanded to %s\n' "${pair%%:*}" "$output" >&2
      return 1
    }
  done
}

@test "the whole crypt surface is judged before step 20 erases anything" {
  # crypt_validate_config says of itself "ten milliseconds, before a single
  # sector is touched", and it was called from step 30 alone: --crypt-pcrs
  # bogus was taken at the prompt and refused after the disk was gone.
  run --separate-stderr "$GI_ENTRY" --dry-run --crypt luks-tpm \
    --crypt-pcrs bogus --steps 20,30
  [ "$status" -ne 0 ]
  [[ "$stderr" == *"Invalid PCR list: bogus"* ]]
  [[ "$stderr" != *"step 20"* ]]
}

@test "the settings step 90 reads can all be spelled on the command line" {
  # locales, domain and ssh_key were read through candidate lists in which no
  # name was declared: every one of them came back "Unknown option", so a
  # system in more than one language, a DNS domain, and an authorized key were
  # all unreachable. The ssh one cost the most — the branch that turns
  # password authentication off could never be taken, and the warning that
  # fires instead named `ssh_key = ...` as the remedy.
  local flag
  for flag in locales domain ssh-key locale keymap timezone; do
    run --separate-stderr "$GI_ENTRY" --dry-run "--${flag}" x --steps 95
    [[ "$stderr" != *"Unknown option: --${flag}"* ]] || {
      printf -- '--%s is not a flag\n' "$flag" >&2
      return 1
    }
  done
}
