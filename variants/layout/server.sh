#!/usr/bin/env bash
#
# gentoo-install — layout variant: server
# ----------------------------------------------------------------------------
# LVM, with /var and /var/log on volumes of their own. The reason is one
# failure mode: a log that runs away, or a package cache that grows for a
# month, fills the filesystem it sits on. When that filesystem is the root
# one, sshd stops accepting connections, the journal stops recording why, and
# the machine is fixed from a console. When it is /var/log, the machine keeps
# running and something rotates.
#
# The percentages add up to eighty. The remaining fifth is deliberately left
# unallocated in the volume group: the volume that fills first is not known in
# advance, and free extents are what makes lvextend a one-line answer instead
# of a reinstall. They also make an LVM snapshot possible before an upgrade.
#
# See variants/layout/minimal.sh for the record grammar.
#
# Usage:  source variants/layout/server.sh   (called by lib/disk.sh)
#
set -euo pipefail

# The about: line says what the shape is for, and never which topology carries
# it. disk_lvm overrides what a layout asks for, and this line said "LVM;" on a
# plan the very next line of the report called "no LVM: plain GPT partitions" —
# in the one sentence an operator reads before typing the device path to
# confirm the erase.
layout_server() {
  # /var takes the largest share: on a Gentoo server it holds the portage
  # tree, the distfiles, the binary package cache and whatever the services
  # keep. /var/log is capped at 30 GiB because a log volume larger than that
  # is a rotation problem, not a capacity problem.
  cat <<'EOF'
# lvm: yes
# about: /var and /var/log split off so a runaway log cannot fill the root.
swap:swap:auto::
root:/:20%/6G/40G:@fs@
var:/var:35%/8G/400G:@fs@
varlog:/var/log:10%/1G/30G:@fs@
home:/home:15%/2G/200G:@fs@
EOF
}
