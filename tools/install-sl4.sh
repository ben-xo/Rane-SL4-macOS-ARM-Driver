#!/bin/bash
# Install a freshly built driver (SL4Device) into the installed HAL plug-in bundle and restart
# CoreAudio; with --api, also install a freshly built SL4Api into the installed SL4Api.framework
# (what Serato and Rane's control panel load); --restore-api puts back the framework binary that
# was there before the first --api install.
#
# Prerequisite: the driver and framework bundles must already be installed, by the release package
# (Installer/RaneSL4-macOS-Universal.pkg). This script only replaces the binaries inside them, and the
# driver's Info.plist (plugin/Device-Info.plist, as the package has it), so the bundle's version, which
# the control panel shows, is the installed binary's.
#
# usage: sudo tools/install-sl4.sh [--api] [driver-binary]
#        sudo tools/install-sl4.sh --restore-api
#   default driver: SL4Device built by `make plugin` in this checkout; --api: SL4Api built by `make api`
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
DRV=/Library/Audio/Plug-Ins/HAL/SL4Device.driver
FW=/Library/Frameworks/SL4Api.framework
BACKUP=/Library/Frameworks/SL4Api.before-install   # beside the framework, not inside it (that would break its signature)

# Write beside the old binary and rename over it: a process that has it loaded keeps its mapped
# (old) file, instead of having its code pages rewritten under it (which gets it killed: Code
# Signature Invalid). Then re-sign the bundle.
install_binary() {   # <source> <bundle> <path of the binary inside the bundle>
    cp "$1" "$2/$3.new"
    mv -f "$2/$3.new" "$2/$3"
    codesign --force --sign - "$2"
}

need_bundle() {   # <bundle>
    if [ ! -d "$1" ]; then
        echo "$1 is not installed. Install the release package first (Installer/RaneSL4-macOS-Universal.pkg);" >&2
        echo "this script only replaces the binaries inside the installed bundles." >&2
        exit 1
    fi
}

# --restore-api: the framework binary saved by the first --api install goes back.
if [ "${1:-}" = "--restore-api" ]; then
    need_bundle "$FW"
    [ -f "$BACKUP" ] || { echo "no saved framework binary at $BACKUP" >&2; exit 1; }
    install_binary "$BACKUP" "$FW" Versions/A/SL4Api
    echo "restored SL4Api from $BACKUP: restart Serato to load it"
    exit 0
fi

API=0
if [ "${1:-}" = "--api" ]; then API=1; shift; fi
SRC=${1:-$ROOT/SL4Device}

# --api: save the framework binary the first time, then install the built one.
if [ "$API" = 1 ]; then
    need_bundle "$FW"
    if [ ! -e "$BACKUP" ]; then
        cp "$FW/Versions/A/SL4Api" "$BACKUP"
        echo "saved the previous SL4Api as $BACKUP (put it back with --restore-api)"
    fi
    echo "installing $ROOT/SL4Api"
    install_binary "$ROOT/SL4Api" "$FW" Versions/A/SL4Api
    echo "installed SL4Api $(shasum -a 256 "$FW/Versions/A/SL4Api" | cut -c1-16): restart Serato to load it"
fi

# The driver, then restart CoreAudio and the processes that go stale when it restarts.
need_bundle "$DRV"
echo "installing $SRC"
cp "$ROOT/plugin/Device-Info.plist" "$DRV/Contents/Info.plist.new"
mv -f "$DRV/Contents/Info.plist.new" "$DRV/Contents/Info.plist"
install_binary "$SRC" "$DRV" Contents/MacOS/SL4Device
killall coreaudiod || true
killall -9 AirPlayXPCHelper 2>/dev/null || true   # can loop re-registering with the new coreaudiod; ignores SIGTERM
# Apps holding the old coreaudiod's device list drop the SL 4 and don't re-add it: refresh them.
sleep 2
killall ControlCenter 2>/dev/null || true
killall -9 QuickLookUIService 2>/dev/null || true   # ignores SIGTERM
echo "installed $(shasum -a 256 "$DRV/Contents/MacOS/SL4Device" | cut -c1-16) and restarted coreaudiod"
