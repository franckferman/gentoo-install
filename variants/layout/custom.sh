#!/usr/bin/env bash
#
# gentoo-install — layout variant: custom
# ----------------------------------------------------------------------------
# The layout the operator wrote, read from the configuration rather than from
# this file. Two sources, and exactly one of them per run:
#
#   disk_volumes       one line of records separated by ';'
#   disk_volumes_file  a file of records, one per line, # for comments
#
# The records are the same ones the three built-in layouts use, so a plan can
# be started from `--disk-layout desktop`, read off the plan table, adjusted
# and pasted back — see variants/layout/minimal.sh for the grammar.
#
#   disk_volumes = "swap:swap:4G::;root:/:35%/10G/60G:ext4;srv:/srv:rest:xfs"
#
# LVM is on unless disk_lvm says otherwise: a hand-written layout with more
# than one volume is exactly the case where being able to resize afterwards is
# worth a device-mapper layer. `disk_lvm = no` turns every volume into a plain
# GPT partition, and then the one taking `rest` must be the last one.
#
# Usage:  source variants/layout/custom.sh   (called by lib/disk.sh)
#
set -euo pipefail

layout_custom() {
  local spec="${CFG[disk_volumes]:-}" file="${CFG[disk_volumes_file]:-}"
  local lvm="yes" line

  if [[ "${CFG[disk_lvm]:-auto}" == "no" ]]; then
    lvm="no"
  fi

  if [[ -z "$spec" && -z "$file" ]]; then
    err "Layout 'custom' needs the volumes to be named"
    err "       disk_volumes       one line: name:mount:size:fs;name:mount:size:fs"
    err "       disk_volumes_file  a file of the same records, one per line"
    err "       --disk-layout desktop prints a plan worth starting from"
    err "       example:  disk_volumes = \"root:/:40%/8G/:ext4;home:/home:rest:ext4\""
    return 1
  fi

  # One source or the other, never both. This used to print the records of
  # each in turn: two layouts concatenated, two volumes able to claim `rest`,
  # and the plan's own one-line description naming whichever source came
  # second. It is the same refusal stage_file and stage_url get, for the same
  # reason — they name two different things and guessing which one wins is how
  # a disk gets partitioned for a layout nobody wrote.
  if [[ -n "$spec" && -n "$file" ]]; then
    err "disk_volumes and disk_volumes_file both name a layout"
    err "       disk_volumes       ${spec}"
    err "       disk_volumes_file  ${file}"
    err "       they are not merged: keep the one you mean and drop the other"
    err "       example:  disk_volumes_file = /root/layout.txt"
    return 1
  fi

  if [[ -n "$file" && ! -r "$file" ]]; then
    err "Cannot read disk_volumes_file: ${file}"
    err "       expected a readable file of name:mount:size:fs records"
    err "       # starts a comment, blank lines are ignored"
    err "       example:  disk_volumes_file = /root/layout.txt"
    return 1
  fi

  printf '# lvm: %s\n' "$lvm"
  printf '# about: The volumes named by %s.\n' \
    "$([[ -n "$file" ]] && printf 'disk_volumes_file' || printf 'disk_volumes')"

  if [[ -n "$spec" ]]; then
    # Split on ';' only. A record's own fields are separated by ':' and a
    # mountpoint holds '/', so neither may be used here.
    printf '%s\n' "${spec//;/$'\n'}"
  fi

  if [[ -n "$file" ]]; then
    # Comments and blank lines dropped here, as the header has always said
    # they were. They went through verbatim, and the record parser happened to
    # tolerate them — a layout that works because the next reader is forgiving
    # is one line away from not working.
    while IFS= read -r line || [[ -n "$line" ]]; do
      line="${line#"${line%%[![:space:]]*}"}"
      line="${line%"${line##*[![:space:]]}"}"
      [[ -n "$line" && "${line:0:1}" != "#" ]] || continue
      printf '%s\n' "$line"
    done <"$file"
  fi
}
