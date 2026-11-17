#!/bin/bash
# Install the SL 4 firmware image into the default directory sl4flash reads it from, so the
# flasher can be run later without pointing it at the image.
#
# The image goes to /Library/Audio/Plug-Ins/HAL/SL4Device.firmware, next to the HAL driver:
# a plain folder that coreaudiod ignores and that survives reinstalling the driver. The
# driver itself never reads it — it only reports a box in its firmware updater; writing
# firmware is done by sl4flash (`sl4flash --firmware PATH` reads from elsewhere).
#
# The image is taken from your own copy of Rane's official driver (see
# tools/firmware/extract-sl4-firmware.py); it is not distributed with this project.
#
#   sudo tools/firmware/sl4-firmware-install.sh IMAGE.bin
set -e
FW=/Library/Audio/Plug-Ins/HAL/SL4Device.firmware
[ $# -ge 1 ] || { echo "usage: sudo $0 IMAGE.bin"; exit 2; }
[ "$(id -u)" = 0 ] || { echo "run with sudo"; exit 1; }
mkdir -p "$FW"
for f in "$@"; do cp "$f" "$FW/"; done
chown -R root:wheel "$FW"
chmod 755 "$FW"; chmod 644 "$FW"/*
xattr -cr "$FW"
echo "installed in $FW: $(ls "$FW" | tr '\n' ' ')"
