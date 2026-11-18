#!/bin/bash
# ES-DE "Install to the Internal Disk" entry, seeded into /storage/roms/install by firstboot.
#
# ES-DE runs a system's command in the background, with no terminal, and cannot draw a confirmation
# dialog. Whether the VT behind ES-DE could show the plan is unanswered: in a QEMU guest text written
# to tty1 or tty2 never reaches the panel, with or without the frontend running (evidence/
# m4-vt-visible.log), so there is no way here to show a plan and a countdown whose plan nobody can see
# would wipe a disk unseen. This entry therefore never writes: emunix-install prints the plan, refuses
# because there is no console to type `yes` on, and names the command that installs. The console is
# the supported path (INSTALL.md, "Install to the internal disk").
# stdin is /dev/null on purpose: ES-DE's own stdin is the VT it draws on, and handing that to the
# installer would turn a stray keypress into an unattended install of the whole disk.
exec sudo -n /usr/local/bin/emunix-install </dev/null
