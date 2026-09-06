#!/usr/bin/env bash
#
# gentoo-install — layout variant: desktop
# ----------------------------------------------------------------------------
# LVM, and /home takes everything the system does not need. On a workstation
# the data is in /home and the system is replaceable, so /home is the volume
# that gets the room and the one that can be kept across a reinstall.
#
# /var is separate: on a desktop it holds the portage tree, the distfiles, the
# binary package cache — all re-fetchable — and /var/tmp/portage, where every
# package is actually built. Keeping it off the root volume means a long emerge
# that fills the cache does not also fill the filesystem the desktop session is
# running from.
#
# That last directory is why the floor is 6 GiB and not the 3 GiB it was. On a
# 24 GiB disk the share works out at 2.9 GiB, and sys-kernel/linux-firmware
# unpacks 2.5 GiB into /var/tmp/portage on top of a 1.4 GiB ebuild repository:
# an install written this way reached step 60 and died there with "No space
# left on device", four minutes into an emerge. A floor is the right shape for
# it — the share is correct on a disk large enough for the share to matter.
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
var:/var:12%/6G/80G:@fs@
home:/home:rest:@fs@
EOF
}
