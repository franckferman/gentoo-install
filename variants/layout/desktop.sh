#!/usr/bin/env bash
#
# gentoo-install — layout variant: desktop
# ----------------------------------------------------------------------------
# LVM, and /home takes everything the system does not need. On a workstation
# the data is in /home and the system is replaceable, so /home is the volume
# that gets the room and the one that can be kept across a reinstall.
#
# /var is separate but modest: on a desktop it is mostly the portage tree, the
# distfiles and the binary package cache, and those are re-fetchable. Keeping
# it off the root volume means a long emerge that fills the cache does not
# also fill the filesystem the desktop session is running from.
#
# See variants/layout/minimal.sh for the record grammar.
#
# Usage:  source variants/layout/desktop.sh   (called by lib/disk.sh)
#
set -euo pipefail

layout_desktop() {
  # root is capped at 80 GiB: past that a Gentoo root is not fuller, it is
  # just further from /home. The minimum of 8 GiB is what a stage3, a portage
  # tree and one kernel build actually occupy.
  cat <<'EOF'
# lvm: yes
# about: LVM; the system takes what it needs and /home takes the rest.
swap:swap:auto::
root:/:25%/8G/80G:@fs@
var:/var:12%/3G/80G:@fs@
home:/home:rest:@fs@
EOF
}
