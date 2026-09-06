#!/usr/bin/env bats
# The layout record set, judged as a set and not one record at a time.
#
# Every check in _disk_parse_records judged a single record — its name, its
# mountpoint, its size spec — and the message it prints when the list is empty
# promised something none of them tested: "at least a root volume is needed".
# A hand-written layout with no "/" was accepted, the disk was erased and
# partitioned for it, and the install failed three steps later. Finding that
# out after the erase is the one thing this project refuses to do.
#
# variants/layout/custom.sh had never been run when these were written.

load helper

_layout() {
  # Print the plan-time verdict for a set of records. Args: $@ = records.
  gi_bash '_DISK_N=(); _DISK_M=(); _DISK_K=(); _DISK_P=()
    _DISK_MIN=(); _DISK_MAX=(); _DISK_F=()
    config_init_defaults >/dev/null 2>&1
    _disk_parse_records custom "$@"' "$@"
}

@test "a layout with no root volume is refused" {
  _layout 'home:/home:rest:ext4' 'var:/var:20%/6G/80G:ext4'
  [ "$status" -ne 0 ]
  [[ "$stderr" == *"declares no root volume"* ]]
  [[ "$stderr" == *"none of them mounts /"* ]]
}

@test "two volumes mounting / are refused" {
  _layout 'root:/:40%/8G/:ext4' 'other:/:rest:ext4'
  [ "$status" -ne 0 ]
  [[ "$stderr" == *"2 volumes mounting /"* ]]
}

@test "two volumes asking for the rest are refused" {
  _layout 'root:/:rest:ext4' 'home:/home:rest:ext4'
  [ "$status" -ne 0 ]
  [[ "$stderr" == *"'rest' to 2 volumes"* ]]
}

@test "a sound set is accepted" {
  _layout 'root:/:rest:ext4' 'home:/home:30%/8G/200G:ext4' 'swap:swap:4G::'
  [ "$status" -eq 0 ]
}

@test "the three built-in layouts still pass the set checks" {
  local name
  for name in minimal server desktop; do
    gi_bash 'config_init_defaults >/dev/null 2>&1
      _DISK_N=(); _DISK_M=(); _DISK_K=(); _DISK_P=()
      _DISK_MIN=(); _DISK_MAX=(); _DISK_F=()
      mapfile -t rows < <(disk_load_layout "$1")
      _disk_parse_records "$1" "${rows[@]}"' "$name"
    [ "$status" -eq 0 ] || {
      printf '%s no longer parses:\n%s\n' "$name" "$stderr" >&2
      return 1
    }
  done
}

@test "disk_volumes and disk_volumes_file together are refused, not merged" {
  # They used to be printed one after the other: two layouts concatenated, two
  # volumes able to claim `rest`, and the plan's own one-line description
  # naming whichever source came second.
  local dir
  dir="$(gi_tmp)"
  printf 'home:/home:rest:ext4\n' >"${dir}/vols.txt"
  gi_bash 'config_init_defaults >/dev/null 2>&1
    CFG[disk_volumes]="root:/:rest:ext4"
    CFG[disk_volumes_file]="$1/vols.txt"
    disk_load_layout custom' "$dir"
  [ "$status" -ne 0 ]
  [[ "$stderr" == *"both name a layout"* ]]
  [[ "$stderr" == *"not merged"* ]]
}

@test "comments and blank lines in a volumes file are dropped" {
  local dir
  dir="$(gi_tmp)"
  printf '# a layout\nroot:/:rest:ext4\n\n   \nhome:/home:20%%:ext4\n' >"${dir}/v.txt"
  gi_bash 'config_init_defaults >/dev/null 2>&1
    CFG[disk_volumes]=""; CFG[disk_volumes_file]="$1/v.txt"
    disk_load_layout custom' "$dir"
  [ "$status" -eq 0 ]
  [[ "$output" != *"# a layout"* ]]
  [[ "$output" == *"root:/:rest:ext4"* ]]
  [[ "$output" == *"home:/home:20%:ext4"* ]]
}

@test "no layout variant names a flag that does not exist" {
  # variants/layout/custom.sh pointed at `--layout desktop` twice, in a
  # comment and in an error message. The flag is --disk-layout; the hygiene
  # test that catches this class only reads lines beginning "example:".
  local hits
  hits="$(grep -rn -- '--layout ' "${GI_ROOT}/variants" || true)"
  [ -z "$hits" ] || {
    printf 'a flag that does not exist:\n%s\n' "$hits" >&2
    return 1
  }
}

@test "no layout's description claims a topology the plan can override" {
  # disk_lvm overrides what a layout asks for. server and desktop said "LVM;"
  # in their about: line, and with --disk-lvm no the report printed that
  # sentence one line above "no LVM: plain GPT partitions" — in the one
  # sentence an operator reads before typing the device path to confirm the
  # erase.
  local hits
  hits="$(grep -rn '^# about:.*\b\(LVM\|lvm\)\b' "${GI_ROOT}/variants/layout" || true)"
  [ -z "$hits" ] || {
    printf 'a description that names a topology:\n%s\n' "$hits" >&2
    return 1
  }
}

@test "the topology is stated by the plan, whatever the layout asked for" {
  local name
  for name in server desktop; do
    gi_capture 'config_init_defaults >/dev/null 2>&1
      _DISK_LVM=""; _DISK_ABOUT=""
      _DISK_N=(); _DISK_M=(); _DISK_K=(); _DISK_P=()
      _DISK_MIN=(); _DISK_MAX=(); _DISK_F=()
      mapfile -t rows < <(disk_load_layout "$1")
      _disk_parse_records "$1" "${rows[@]}" >/dev/null 2>&1
      printf "%s|%s\n" "$_DISK_LVM" "$_DISK_ABOUT"' "$name" >"${BATS_TEST_TMPDIR}/${name}"
    grep -q '^yes|' "${BATS_TEST_TMPDIR}/${name}"
    ! grep -qi 'lvm' <(cut -d'|' -f2 "${BATS_TEST_TMPDIR}/${name}")
  done
}

@test "minimal asks for no LVM and says so in the record, not in prose" {
  gi_capture 'config_init_defaults >/dev/null 2>&1
    _DISK_LVM=""; _DISK_ABOUT=""
    _DISK_N=(); _DISK_M=(); _DISK_K=(); _DISK_P=()
    _DISK_MIN=(); _DISK_MAX=(); _DISK_F=()
    mapfile -t rows < <(disk_load_layout minimal)
    _disk_parse_records minimal "${rows[@]}" >/dev/null 2>&1
    printf "%s\n" "$_DISK_LVM"' >"${BATS_TEST_TMPDIR}/m"
  [ "$(cat "${BATS_TEST_TMPDIR}/m")" = "no" ]
}
