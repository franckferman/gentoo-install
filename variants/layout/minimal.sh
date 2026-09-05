#!/usr/bin/env bash
#
# gentoo-install — layout variant: minimal
# ----------------------------------------------------------------------------
# For the operator who wants to see the whole storage stack in one screen of
# lsblk. One root filesystem, no LVM, no separate /var, no swap volume. There
# is nothing here to grow into the wrong place because there is nothing here.
#
# A layout prints records on stdout, one per line, and lib/disk.sh does the
# arithmetic. Two forms:
#
#   # <directive>: <value>      lvm: yes|no, about: one line of prose
#   <name>:<mountpoint>:<size>:<filesystem>
#
# <size> is one of:
#   rest              whatever is left after the others; at most one volume
#   auto              swap only: RAM, clamped, capped at a tenth of the disk
#   <N>%              N percent of what the filesystems share
#   <N>%/<min>/<max>  the same, clamped; min is a preference, not a promise,
#                     and a disk too small to honour it shrinks every volume
#                     by the same proportion instead of refusing
#   <size>            an absolute 8G, 512M, 2T
#
# <filesystem> is a name, or @fs@ for whatever --filesystem says.
#
# Usage:  source variants/layout/minimal.sh   (called by lib/disk.sh)
#
set -euo pipefail

layout_minimal() {
  # No swap volume, and that is the choice, not an omission: a swap file on
  # the root filesystem is resized with truncate and mkswap instead of with
  # lvresize, and it is one fewer line in the partition table. Set
  # disk_layout = server or desktop if a swap volume is wanted.
  cat <<'EOF'
# lvm: no
# about: One root filesystem and nothing else. What lsblk shows is what there is.
root:/:rest:@fs@
EOF
}
