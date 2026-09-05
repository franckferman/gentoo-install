#!/usr/bin/env bash
#
# gentoo-install — layout variant: custom
# ----------------------------------------------------------------------------
# The layout the operator wrote, read from the configuration rather than from
# this file. Two sources, checked in that order:
#
#   disk_volumes       one line of records separated by ';'
#   disk_volumes_file  a file of records, one per line, # for comments
#
# The records are the same ones the three built-in layouts use, so a plan can
# be started from `--layout desktop`, read off the plan table, adjusted and
# pasted back — see variants/layout/minimal.sh for the grammar.
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
    err "       --layout desktop prints a plan worth starting from"
    err "       example:  disk_volumes = \"root:/:40%/8G/:ext4;home:/home:rest:ext4\""
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
    while IFS= read -r line || [[ -n "$line" ]]; do
      printf '%s\n' "$line"
    done <"$file"
  fi
}
