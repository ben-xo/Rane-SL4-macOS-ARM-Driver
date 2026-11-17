#!/bin/bash
# hwtest.sh [--loopback] [--no-physical] — the SL 4 hardware tests in one run, with a PASS / FAIL /
# SKIP summary. Run by `make hwtest` (ARGS="--loopback ..."), which builds what it needs first.
#
# The SL 4 chooses its sample rate on the box (48 or 96 kHz, with its rate control): the tests run at
# whatever rate the box is at, and the host only checks that the device follows the box. To cover both
# rates, run the loopback tests again after flipping the box's rate control.
#
# The tests run in the order that needs the fewest physical steps:
#   1. with the box attached, nothing else: driver status (running firmware, not the box's firmware
#      updater; a high-speed link; this Mac's USB port on the box), SL4Api as Serato calls it (both
#      slices), the device's rate being the box's and a host rate change being refused, switching
#      decks 1-4 between USB audio and analogue thru, the input safety offset setting, and the early
#      capture read working;
#   2. with --loopback (a cable from Deck 1 Out L to Deck 1 In L, channel 1 unless SL_LOOP_CH says
#      otherwise: the channel order is not verified on an SL 4; the tests play clicks and a loud tone
#      into that output, so pass it only when the cable is in): restarts, a glitch test (with no 0x37
#      heartbeat sent), IO buffer sizes, the output volume and mute, the level meters, and in a debug
#      build (installed with make install DEBUG=1) the glitch test under load, the capture packet
#      sizes, the early capture read and the fault hooks;
#   3. unless --no-physical: steps for a person at the box (flip the box's 48/96 kHz control and back,
#      sleep and wake the Mac, unplug and replug while idle and while a stream runs). The script prints
#      what to do and waits until it sees the change, so nothing needs typing.
#
# Exit status 0 = nothing failed. The full output goes to a log file, named at the end.
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
B="$ROOT/tools/latency/bin"
PANEL="$ROOT/sl4panel"
APITEST="$ROOT/sl4apitest"
DEV="SL 4"
SUBSYS=com.rane.sl4
NCH=10                              # channels each way
NDECKS=4                            # decks with analogue thru (Aux has none)
LOOP=${SL_LOOP_CH:-1}               # the looped-back channel: 1 = Deck 1 L, if the channel order holds (the latency scripts read it too)
OTHER=$(( LOOP % 2 ? LOOP + 1 : LOOP - 1 ))   # the other side of the same deck, which nothing plays to
WAIT_S=${HWTEST_WAIT:-120}          # how long to wait for a physical step

LOOPBACK=0; PHYSICAL=1
for a in "$@"; do
    case "$a" in
        --loopback) LOOPBACK=1 ;;
        --no-physical) PHYSICAL=0 ;;
        *) echo "usage: hwtest.sh [--loopback] [--no-physical]"; exit 2 ;;
    esac
done

LOG="${TMPDIR:-/tmp}"; LOG="${LOG%/}/sl4-hwtest-$(date +%Y%m%d-%H%M%S).log"
exec > >(tee "$LOG") 2>&1

# ---------------------------------------------------------------------------- helpers

RESULTS=()
record() {   # <PASS|FAIL|SKIP> <test> [detail]
    RESULTS+=("$1|$2|${3:-}")
    printf '%-4s  %s%s\n' "$1" "$2" "${3:+  ($3)}"
}

status() { "$PANEL" status 2>&1; }
connected() { [ "$(field 'USB Connected')" = YES ]; }
field() {    # the value of an sl4panel status line, e.g. field 'Sample Rate'
    status | sed -nE "s/^  $1 *: *//p" | head -1
}

wait_until() {   # <description> <command...>: poll every half second, up to WAIT_S
    local what=$1; shift
    local t=0
    while ! "$@" >/dev/null 2>&1; do
        sleep 0.5; t=$((t + 1))
        if [ $t -ge $((WAIT_S * 2)) ]; then echo "      timed out after ${WAIT_S} s waiting for: $what"; return 1; fi
    done
}
not() { ! "$@"; }
running() { echo "      ... $1"; }   # before a test that takes a while, so the script never looks stuck

driver_log_since() {   # <start time> <grep pattern>: the driver's log lines since then
    sleep 1
    /usr/bin/log show --start "$1" --style compact --predicate "subsystem == \"$SUBSYS\"" 2>/dev/null \
        | grep -E "$2" | sed -E 's/.*\] \[SL4\] //'
}
now() { date '+%Y-%m-%d %H:%M:%S'; }

# The user's output volume (the main volume and each channel's) and mute, saved before a test
# changes them and put back afterwards (by a trap if the script is interrupted). save_volume fails if
# the driver has no volume controls.
save_volume() {
    local v
    v=$("$B/volctl" "$DEV") || return 1
    SAVED_DB=$(echo "$v" | sed -nE 's/^volume (-?[0-9.e+-]+) dB.*/\1/p')
    SAVED_CH=$(echo "$v" | sed -nE 's/.*, channels (.*) dB, mute [01]$/\1/p')
    SAVED_MUTE=$(echo "$v" | sed -nE 's/.*mute ([01])$/\1/p')
    [ -n "$SAVED_DB" ] && [ -n "$SAVED_MUTE" ] || return 1
    trap 'EXITING=1; restore_volume' EXIT
    trap 'exit 130' INT TERM
}
neutral_volume() {   # the main volume and every channel at 0 dB, unmuted; fails if any setting does
    local ch ok=0
    "$B/volctl" "$DEV" unmute >/dev/null || ok=1
    "$B/volctl" "$DEV" 0 >/dev/null || ok=1
    for ch in $(seq 1 $NCH); do "$B/volctl" "$DEV" 0 "$ch" >/dev/null || ok=1; done
    return $ok
}
restore_volume() {
    trap - EXIT INT TERM
    [ -n "${SAVED_DB:-}" ] || return 0   # nothing was saved
    local m=unmute ch=0 db ok=1
    [ "$SAVED_MUTE" = 1 ] && m=mute
    "$B/volctl" "$DEV" "$SAVED_DB" >/dev/null || ok=0
    for db in $SAVED_CH; do
        ch=$((ch + 1))
        "$B/volctl" "$DEV" "$db" $ch >/dev/null || ok=0
    done
    "$B/volctl" "$DEV" $m >/dev/null || ok=0
    if [ $ok = 1 ]; then SAVED_DB=; return 0; fi
    # Failed (the box may be unplugged): try once more when the script ends, then give up.
    if [ -z "${RESTORE_RETRY:-}" ] && [ -z "${EXITING:-}" ]; then
        RESTORE_RETRY=1
        trap 'EXITING=1; restore_volume' EXIT
        echo "      could not put the output volume back yet: will try again when the tests end"
    else
        echo "      could not put the output volume back ($SAVED_DB dB, channels $SAVED_CH dB, mute $SAVED_MUTE): set it by hand"
        SAVED_DB=
    fi
    return 1
}

# "volume <dB> dB, channels 0 ... 0 dB" with every channel at 0 dB, as volctl prints it
ZEROS=$(printf '0 %.0s' $(seq 1 $NCH)); ZEROS=${ZEROS% }

thru_count() { status | grep -cE '^  Deck [1-4] *: ANALOG THRU'; }
usb_count() { status | grep -cE '^  Deck [1-4] *: USB AUDIO'; }
all_thru() { [ "$(thru_count)" = $NDECKS ]; }
all_usb() { [ "$(usb_count)" = $NDECKS ]; }
rate_now() { field 'Sample Rate' | grep -oE '^[0-9]+'; }
box_rate() { field 'Box Rate' | grep -oE '^[0-9]+'; }
rate_is() { [ "$(rate_now)" = "$1" ] && [ "$(box_rate)" = "$1" ]; }   # the device and the box both at <Hz>

# The box in its firmware updater (bcdDevice 0x9900): as the driver reports it, or, if the driver
# doesn't publish a device for it, as the USB registry shows it (1CC5 = 7365, 0x9900 = 39168).
boot_mode() {
    status | grep -qE 'NOT RUNNING|in its firmware updater' && return 0
    ioreg -p IOUSB -l -w0 2>/dev/null | awk '/\+-o /{ v = 0; b = -1 } /"idVendor" = /{ v = $NF } /"bcdDevice" = /{ b = $NF }
        v == 7365 && b == 39168 { f = 1 } END { exit !f }'
}

# ---------------------------------------------------------------------------- 0. preconditions

echo "SL 4 hardware tests, $(date)"
for tool in "$PANEL" "$APITEST" "$B/rtlat" "$B/sinetest" "$B/setrate" "$B/sl4dbg" "$B/chrec" "$B/volctl" "$B/meters"; do
    [ -x "$tool" ] || { echo "missing $tool: run make hwtest (it builds the tools)"; exit 2; }
done
# A box in its firmware updater has no audio: nothing here can run until its firmware is written again.
if boot_mode; then
    echo "The SL 4 is in its firmware updater (USB bcdDevice 0x9900): it has no audio until its firmware is"
    echo "written again (tools/firmware). Not running the tests."
    "$PANEL" status
    exit 2
fi
if ! connected; then
    echo "No SL 4 connected (or the driver isn't loaded): connect the box and run again."
    "$PANEL" status
    exit 2
fi
# A debug build accepts the driver's debug commands; errpkts 0 changes nothing.
if "$B/sl4dbg" errpkts 0 >/dev/null 2>&1; then BUILD=debug; else BUILD=release; fi
RATE=$(rate_now)
echo "driver: $BUILD build; firmware $(field 'Firmware Ver'); serial $(field 'Serial Number'); ${RATE:-?} Hz (set on the box)"
[ $BUILD = release ] && echo "(the debug-only tests will be skipped: make install DEBUG=1 installs a debug build)"
echo

# ---------------------------------------------------------------------------- 1. the box only

echo "== 1. box attached, nothing else"

# The status: connected, running firmware with a version (the box's firmware updater is caught
# above), a serial number (every SL 4 reports the same one, RH.01.00), a high-speed link (full speed
# carries no audio), and this Mac's USB port on the box (A or B, from 0x45).
fw=$(field 'Firmware Ver'); serial=$(field 'Serial Number'); link=$(field 'USB Link'); port=$(field 'USB Port')
if [ -n "$fw" ] && [ "$fw" != "0.00" ] && [ -n "$serial" ] && [ "$serial" != "N/A" ] &&
   [ "$link" = "high speed" ] && echo "$port" | grep -qE '^[AB]([^A-Za-z]|$)'; then
    record PASS "status" "firmware $fw, serial $serial, $link, port $port"
else
    record FAIL "status" "firmware '$fw', serial '$serial', link '$link', port '$port'"
fi

# SL4Api the way Serato DJ Pro 2.5.5 calls it: natively, and the x86_64 slice Serato loads.
if "$APITEST" > /dev/null 2>&1; then record PASS "SL4Api, arm64"; else record FAIL "SL4Api, arm64" "run ./sl4apitest"; fi
if arch -x86_64 /usr/bin/true 2>/dev/null; then
    if arch -x86_64 "$APITEST" > /dev/null 2>&1; then record PASS "SL4Api, x86_64 (Rosetta)"
    else record FAIL "SL4Api, x86_64 (Rosetta)" "run arch -x86_64 ./sl4apitest"; fi
else
    record SKIP "SL4Api, x86_64 (Rosetta)" "Rosetta not installed"
fi

# The sample rate: the device's is the box's own (0x4A), one of the two the box has, and the driver
# refuses a host change to the other one, leaving the rate as it was.
other=$([ "${RATE:-}" = 96000 ] && echo 48000 || echo 96000)
box=$(box_rate)
try=$("$B/setrate" "$DEV" try "$other" 2>&1); refused=$?
after=$(rate_now)
if { [ "$RATE" = 48000 ] || [ "$RATE" = 96000 ]; } && [ "$box" = "$RATE" ] && [ $refused = 0 ] && [ "$after" = "$RATE" ]; then
    record PASS "sample rate is the box's" "$RATE Hz; a switch to $other Hz refused"
else
    record FAIL "sample rate is the box's" "device ${RATE:-?} Hz, box ${box:-?} Hz, then ${after:-?} Hz; $try"
fi

# Decks 1-4 between USB audio and analogue thru (Hidi notes 0x5C-0x5F: Note Off = USB audio, Note On =
# thru), the status following the box's confirmations each way. It ends on thru, as the box is left
# with nothing streaming.
ok=1
"$PANEL" usb >/dev/null || ok=0
WAIT_S=5 wait_until "decks 1-4 on USB audio" all_usb || ok=0
nusb=$(usb_count)
"$PANEL" thru >/dev/null || ok=0
WAIT_S=5 wait_until "decks 1-4 on thru" all_thru || ok=0
[ $ok = 1 ] && record PASS "thru switching, decks 1-4" "USB audio on $nusb, then thru on $(thru_count)" \
            || record FAIL "thru switching, decks 1-4" "USB audio on $nusb/$NDECKS, then thru on $(thru_count)/$NDECKS"

# The input safety offset setting: set 2 ms with nothing streaming, and the driver must set the device
# up again with it (the status reports what CoreAudio is using); then put the setting back.
# sl4panel prints the setting exactly (to the microsecond), so it is put back exactly.
orig_ms=$("$PANEL" safety | grep -oE '[0-9]+(\.[0-9]+)? ms' | head -1 | cut -d' ' -f1)
if [ -z "$orig_ms" ]; then
    record FAIL "input safety offset setting" "sl4panel safety: no setting"
else
    ok=1
    "$PANEL" safety 2 >/dev/null || ok=0
    WAIT_S=5 wait_until "the driver to use 2 ms" sh -c "'$PANEL' status | grep -qE '^  Input Safety +: 2 ms'" || ok=0
    "$PANEL" safety "$orig_ms" >/dev/null || ok=0
    WAIT_S=5 wait_until "the driver to use $orig_ms ms again" sh -c "'$PANEL' status | grep -qE '^  Input Safety +: $orig_ms ms'" || ok=0
    [ $ok = 1 ] && record PASS "input safety offset setting" "2 ms, then back to $orig_ms ms" \
                || record FAIL "input safety offset setting" "status: $(field 'Input Safety')"
fi

# The early capture read: after a few seconds of capture (any input, no cable needed), the driver
# must judge it working, and no input must have dropped out during it (the dropout count runs from
# when the box connected, so compare before and after).
drops0=$(field 'Input Dropouts')
"$B/chrec" "$DEV" 3 "${TMPDIR:-/tmp}/sl4-hwtest-chrec.wav" >/dev/null 2>&1
er=$(field 'Early Read'); drops1=$(field 'Input Dropouts')
drops=$(( ${drops1:-0} - ${drops0:-0} ))
if [ "$er" = "working" ] && [ -n "$drops1" ] && [ "$drops" = 0 ]; then
    record PASS "early capture read working" "USB hubs: $(field 'USB Hubs')"
else
    record FAIL "early capture read working" "early read '$er', input dropouts '$drops'"
fi
echo

# ---------------------------------------------------------------------------- 2. loopback

echo "== 2. loopback cable (at the box's ${RATE:-?} Hz)"
if [ $LOOPBACK = 0 ]; then
    for t in "restarts" "glitch test, 30 s, no heartbeat" "glitch test idle + loaded (dptest)" "IO buffer sizes" "output volume and mute" "level meters" "capture packet sizes" "early capture read" "early read reported not working" "fault hook: USB stall" "fault hook: errored capture packets"; do
        record SKIP "$t" "no --loopback"
    done
else
    # The line-level loopback signal clips the phono preamp. The SL 4 doesn't report its LINE/PHONO
    # switches, so this can't be checked: say so, and point at it if the first test fails.
    echo "   (Deck 1's LINE/PHONO switch must be on LINE: the SL 4 doesn't report it, so it isn't checked)"
    echo "   (loopback on channel $LOOP: the SL 4's channel order is not verified; set SL_LOOP_CH if the cable is on another)"

    # Every test here plays at full level: the user's output volume and mute are saved, set to 0 dB
    # and unmuted for the section, and put back at its end (by a trap if the script is interrupted).
    if save_volume; then have_volume=1; else have_volume=0; fi
    if [ $have_volume = 0 ] || ! neutral_volume; then
        echo "   (could not set the output to 0 dB, unmuted: the loopback tests may fail for that reason)"
    fi

    # Three streams in a row, each starting cleanly and finding all its clicks.
    running "restarts (about 15 s)"
    if "$ROOT/tools/latency/restartcheck.sh" > /dev/null 2>&1; then record PASS "restarts"
    else record FAIL "restarts" "run tools/latency/restartcheck.sh; no clicks found: is the cable on channel $LOOP, Deck 1 on LINE?"; fi

    # A 30 s glitch test with the Mac idle. The driver sends the box no 0x37 heartbeat (nothing on the
    # box enforces one): the deck must play USB audio throughout, at full level, without one.
    running "glitch test (30 s)"
    out=$("$B/sinetest" "$DEV" $LOOP $LOOP 30 128 | grep RESULT)
    echo "$out" | grep -q 'RESULT: 0 glitches, 0 level drops' && record PASS "glitch test, 30 s, no heartbeat" \
        || record FAIL "glitch test, 30 s, no heartbeat" "$out"

    # Idle and with every core loaded, with the driver's counters: a debug build only.
    if [ $BUILD = debug ]; then
        running "glitch test idle and with every core busy (about 70 s)"
        if "$ROOT/tools/latency/dptest.sh" 30 > /dev/null 2>&1; then record PASS "glitch test idle + loaded (dptest)"
        else record FAIL "glitch test idle + loaded (dptest)" "run tools/latency/dptest.sh 30"; fi
    else
        record SKIP "glitch test idle + loaded (dptest)" "release build (make install DEBUG=1)"
    fi

    # IO buffer sizes, at the box's rate: every click found at each, and the round trip measured (48
    # is 1 ms at 48 kHz, 96 1 ms at 96 kHz). Records what each size gives.
    running "IO buffer sizes, 7 sizes (about 1 min)"
    ok=1; detail=""
    for buf in 32 48 64 96 128 256 512; do
        lat=$("$B/rtlat" "$DEV" $LOOP $LOOP 4 $buf | grep -E 'mean|not found' | head -1)
        rt=$(echo "$lat" | grep -oE 'DVS round trip est\. [0-9.]+' | grep -oE '[0-9.]+$')
        echo "$lat" | grep -q '(4/4 clicks)' || { ok=0; rt="FAIL"; }
        detail="$detail $buf:${rt:-?}"
    done
    [ $ok = 1 ] && record PASS "IO buffer sizes" "$((RATE / 1000)) kHz, round trip ms:$detail" \
                || record FAIL "IO buffer sizes" "$((RATE / 1000)) kHz, round trip ms:$detail"

    # Output volume. With everything at 0 dB every click is found at full level; the looped-back channel at
    # -20 dB brings them down 20 dB; the other channel of its deck at -20 dB leaves it alone; the virtual main volume (the
    # volume keys) at the slider position for -20 dB (0.6875 squared, by CoreAudio's standard volume
    # curve) sets the main volume to -20 dB, leaving the channels' own levels, and brings the clicks
    # down 20 dB; mute silences them. (rtlat reads quieter clicks a
    # frame or two later: it finds a click at a fixed threshold, which the converters' pre-ringing
    # crosses sooner on a loud click. So only levels are checked here; the restart test above covers
    # the round trip.)
    if [ $have_volume = 1 ]; then
        running "output volume and mute (about 30 s)"
        peak() { grep -oE 'peak [0-9.]+' | tail -1 | grep -oE '[0-9.]+$'; }
        db() { awk -v r="$1" -v a="$2" 'BEGIN { if (r > 0 && a > 0) printf "%.1f", 20 * log(a / r) / log(10); else print "none" }'; }
        full=$("$B/rtlat" "$DEV" $LOOP $LOOP 3 128); ref=$(echo "$full" | peak)
        "$B/volctl" "$DEV" -20 $LOOP >/dev/null
        ch1=$(db "$ref" "$("$B/rtlat" "$DEV" $LOOP $LOOP 3 128 | peak)")
        "$B/volctl" "$DEV" 0 $LOOP >/dev/null; "$B/volctl" "$DEV" -20 $OTHER >/dev/null
        ch2=$(db "$ref" "$("$B/rtlat" "$DEV" $LOOP $LOOP 3 128 | peak)")
        "$B/volctl" "$DEV" 0 $OTHER >/dev/null
        keys=$("$B/volctl" "$DEV" main 0.47265625)
        main=$(db "$ref" "$("$B/rtlat" "$DEV" $LOOP $LOOP 3 128 | peak)")
        "$B/volctl" "$DEV" 0 >/dev/null; "$B/volctl" "$DEV" mute >/dev/null
        muted=$("$B/rtlat" "$DEV" $LOOP $LOOP 3 128 | grep -c 'not found')
        neutral_volume
        detail="channel $LOOP at -20 dB: $ch1 dB; channel $OTHER at -20 dB: channel $LOOP $ch2 dB; volume keys: $main dB ($keys); muted: $muted/3 clicks gone"
        if echo "$full" | grep -q '(3/3 clicks)' && [ "$muted" = 3 ] &&
           awk -v a="$ch1" -v b="$ch2" -v c="$main" 'BEGIN { exit !(a > -21 && a < -19 && b > -0.5 && b < 0.5 && c > -21 && c < -19) }' &&
           echo "$keys" | grep -qE "^volume -20(\.[0-9]*)? dB, channels $ZEROS dB"; then
            record PASS "output volume and mute" "$detail"
        else
            record FAIL "output volume and mute" "$detail"
        fi
    else
        record FAIL "output volume and mute" "the driver has no output volume controls (volctl)"
    fi

    # The level meters ('sl4m', which the control panel shows: inputs 1-10, then outputs 1-10): while
    # sinetest plays its 0.4 tone (-8 dB) on the looped-back output, that output must read -8 dB +-1,
    # its input must clearly get it (the loopback), and the other outputs, which nothing plays to, must
    # be silent.
    "$B/sinetest" "$DEV" $LOOP $LOOP 4 128 >/dev/null 2>&1 &
    sine=$!
    sleep 1.5
    m=$("$B/meters" "$DEV" 1.5)
    wait $sine
    if awk -v m="$m" -v lp=$LOOP -v n_ch=$NCH 'BEGIN {
            gsub(/in |, out | dB/, " ", m); n = split(m, v, " ")
            if (n != 2 * n_ch) exit 1
            for (i = n_ch + 1; i <= 2 * n_ch; i++) if (i != n_ch + lp && v[i] != "-inf" && v[i] + 0 > -60) exit 1
            exit !(v[n_ch + lp] + 0 > -9 && v[n_ch + lp] + 0 < -7 && v[lp] != "-inf" && v[lp] + 0 > -20) }'; then
        record PASS "level meters" "$m"
    else
        record FAIL "level meters" "${m:-no reading}"
    fi

    # The box's capture packet sizes (debug build), at its rate: how many frames each microframe's
    # packet carries. The playback packet sizes are steered to match them (implicit feedback), so they
    # must be the ones expected: 6 at 48 kHz and 12 at 96 kHz, allowing the odd one either side where
    # the box corrects its clock (seen on an SL 3: about 0.5%), up to 1% of them.
    if [ $BUILD = debug ]; then
        running "capture packet sizes (about 5 s)"
        start=$(now)
        "$B/sinetest" "$DEV" $LOOP $LOOP 3 128 >/dev/null 2>&1
        h=$(driver_log_since "$start" 'DBG capture packet sizes' | head -1 | sed -E 's/.*\): *//')
        nom=$(( RATE / 8000 ))
        if awk -v h="$h" -v nom=$nom 'BEGIN { n = split(h, kv, " "); mid = 0; other = 0
                for (i = 1; i <= n; i++) { split(kv[i], p, ":")
                    if (p[1] == nom) mid += p[2]; else if (p[1] == nom - 1 || p[1] == nom + 1) other += p[2]; else exit 1 }
                exit !(mid > 0 && other <= (mid + other) / 100) }'; then
            record PASS "capture packet sizes" "$((RATE / 1000)) kHz: $h"
        else
            record FAIL "capture packet sizes" "$((RATE / 1000)) kHz: ${h:-none} (expected $nom frames)"
        fi
    fi

    # The early capture read (debug build): a 20 ms stall in USB completion delivery, 3 s into a 10 s
    # glitch test at a 64-frame buffer, must make no gap (ReadInput takes the packets from the queued
    # buffers, not from the late completions), and the driver's early-read counters must show no frame
    # placed differently from the completion and none missing when ReadInput asked for it.
    if [ $BUILD = debug ]; then
        running "early capture read under a 20 ms stall (about 12 s)"
        start=$(now)
        ( sleep 3; "$B/sl4dbg" stall 20 >/dev/null ) &
        sine=$("$B/sinetest" "$DEV" $LOOP $LOOP 10 64 | grep RESULT); wait
        er=$(driver_log_since "$start" 'DBG early read result' | head -1)
        gap=$(driver_log_since "$start" 'Capture: [0-9]+ ms not captured' | head -1)
        diff=$(echo "$er" | grep -oE 'completion found [0-9]+ different' | grep -oE '[0-9]+')
        short=$(echo "$er" | grep -oE 'SILENCE \(not captured yet\) [0-9]+' | grep -oE '[0-9]+$')
        margin=$(echo "$er" | grep -oE 'least margin -?[0-9.]+ ms')
        if echo "$sine" | grep -q ' 0 glitches' && [ -z "$gap" ] && [ "${diff:-x}" = 0 ] && [ "${short:-x}" = 0 ]; then
            record PASS "early capture read" "20 ms stall, no gap; $margin"
        else
            record FAIL "early capture read" "result '$sine', different ${diff:-?}, missing ${short:-?}, ${gap:-no gap logged}"
        fi
    fi

    # The early read reported not working (debug build): with the early reader switched off (as on a
    # Mac where it can't work), a stream must judge it not working, and leave the input safety offset
    # alone; setting the setting again has the next stream judge it afresh.
    if [ $BUILD = debug ]; then
        set_ms=$("$PANEL" safety | grep -oE '[0-9]+(\.[0-9]+)? ms' | head -1 | cut -d' ' -f1)
        "$B/sl4dbg" noearly 1 >/dev/null
        "$B/sinetest" "$DEV" $LOOP $LOOP 3 64 >/dev/null 2>&1
        "$B/sl4dbg" noearly 0 >/dev/null
        er=$(field 'Early Read'); safety=$(field 'Input Safety')
        "$PANEL" safety "$set_ms" >/dev/null
        WAIT_S=5 wait_until "the judgement cleared" sh -c "'$PANEL' status | grep -qE '^  Early Read +: not judged yet'"; cleared=$?
        if [ "${er#NOT WORKING}" != "$er" ] && [ "$safety" = "$(field 'Input Safety')" ] && [ $cleared = 0 ]; then
            record PASS "early read reported not working" "offset left at $safety; judged afresh after setting it"
        else
            record FAIL "early read reported not working" "early read '$er', offset '$safety', cleared $([ $cleared = 0 ] && echo yes || echo no)"
        fi
    fi

    # The fault hooks (debug build), each injected 3 s into a 10 s glitch test: a 100 ms stall in USB
    # completion delivery (the driver must fill the gap with silence and log it) and 20 errored
    # capture packets (the driver must take them, and playback must stay matched to capture: sent -
    # captured within +-2 frames at the end). Either way the stream runs to the end, never restarted.
    if [ $BUILD = debug ]; then
        running "fault hooks: a USB stall, errored capture packets (about 25 s)"
        for hook in "stall 100" "errpkts 20"; do
            start=$(now)
            ( sleep 3; "$B/sl4dbg" $hook >/dev/null ) &
            sine=$("$B/sinetest" "$DEV" $LOOP $LOOP 10 128 | grep RESULT); wait
            starts=$(driver_log_since "$start" 'Streaming started' | wc -l | tr -d ' ')
            if [ "$hook" = "stall 100" ]; then
                name="fault hook: USB stall"
                seen=$(driver_log_since "$start" 'Capture: [0-9]+ ms not captured' | head -1)
                balanced=1
            else
                name="fault hook: errored capture packets"
                seen=$(driver_log_since "$start" 'capture packets treated as errored' | head -1)
                sc=$(driver_log_since "$start" 'dp result' | grep -oE 'sent-captured now -?[0-9.]+' | head -1 | grep -oE '[-0-9.]+$')
                balanced=$(awk -v v="${sc:-99}" 'BEGIN { print (v >= -2 && v <= 2) ? 1 : 0 }')
                seen="$seen; sent-captured ${sc:-?}"
            fi
            if [ -n "$sine" ] && [ -n "${seen%%;*}" ] && [ "$balanced" = 1 ] && [ "$starts" -le 1 ]; then
                record PASS "$name" "$seen"
            else
                record FAIL "$name" "result '$sine', log '$seen', $starts stream starts"
            fi
        done
    else
        record SKIP "capture packet sizes" "release build (make install DEBUG=1)"
        record SKIP "early capture read" "release build (make install DEBUG=1)"
        record SKIP "early read reported not working" "release build (make install DEBUG=1)"
        record SKIP "fault hook: USB stall" "release build (make install DEBUG=1)"
        record SKIP "fault hook: errored capture packets" "release build (make install DEBUG=1)"
    fi
    [ $have_volume = 1 ] && restore_volume
    # With nothing streaming the decks are on analogue thru, which connects each deck's input to its
    # output inside the box: with the loopback cable still in, that is a feedback loop.
    echo "   >>> Unplug the loopback cable now: with the deck on thru it makes a feedback loop."
fi
echo

# ---------------------------------------------------------------------------- 3. physical steps

echo "== 3. steps at the box"
if [ $PHYSICAL = 0 ]; then
    for t in "box's rate control followed" "thru and rate after the Mac sleeps" "unplug and replug, idle" "volume and mute survive a replug" "unplug and replug, mid-stream"; do
        record SKIP "$t" "--no-physical"
    done
else
    # The box's 48/96 kHz control: the box reports the change (0x4B) and switches its clock, and the
    # device must follow it both ways, the status showing the device and the box at the new rate. It
    # ends where it started. (An optional step: the rest of the tests don't depend on it.)
    first=$([ "$(rate_now)" = 96000 ] && echo 48000 || echo 96000)
    second=$([ $first = 96000 ] && echo 48000 || echo 96000)
    start=$(now)
    echo "   >>> Set the box's 48/96 kHz control to $((first / 1000)) kHz."
    if wait_until "the device at $first Hz" rate_is $first; then
        echo "   >>> Set it back to $((second / 1000)) kHz."
        if wait_until "the device at $second Hz" rate_is $second; then
            changes=$(driver_log_since "$start" 'Sample rate changed to' | wc -l | tr -d ' ')
            record PASS "box's rate control followed" "$second -> $first -> $second Hz; $changes rate changes logged"
        else
            record FAIL "box's rate control followed" "not seen back at $second Hz (device $(rate_now), box $(box_rate))"
        fi
    else
        record FAIL "box's rate control followed" "not seen at $first Hz (device $(rate_now), box $(box_rate))"
    fi

    # The Mac sleeping and waking, with nothing playing: the box is suspended with the Mac and resumed
    # after it. A few seconds after the wake every deck must be on thru and the device's rate the box's
    # own (0x4A, sl4panel's Box Rate): the driver's settle check puts the decks back if the box lost
    # them (and logs it). The sleep and the full wake are read from the power management log (pmset -g
    # log): a short sleep can't be told from the wall clock, as the Mac runs processes again in a
    # DarkWake a few seconds in, before the user wakes it.
    if pmset -g assertions 2>/dev/null | grep -qE '^ *PreventSystemSleep +1'; then
        record SKIP "thru and rate after the Mac sleeps" "something holds a PreventSystemSleep assertion (pmset -g assertions; Internet Sharing does)"
    else
        pm_events() { pmset -g log | grep -E '^[0-9-]+ [0-9:]+ [+-][0-9]{4} (Sleep|Wake) {2,}' | cut -c27-31; }
        sleeps0=$(pm_events | grep -c Sleep)
        start=$(now)
        echo "   >>> Put the Mac to sleep (Apple menu > Sleep). Wait about 15 s, then wake it."
        slept=0
        for i in $(seq 1 $((WAIT_S / 2))); do
            sleep 2; ev=$(pm_events)
            # A sleep since the prompt, and the last event since then a full wake.
            if [ "$(echo "$ev" | grep -c Sleep)" -gt "$sleeps0" ] && [ "$(echo "$ev" | tail -1)" = "Wake " ]; then slept=1; break; fi
        done
        if [ $slept = 0 ]; then
            record FAIL "thru and rate after the Mac sleeps" "no sleep seen within ${WAIT_S} s"
        else
            sleep 8   # the driver's settle check runs 4 s after the wake
            want=$(rate_now); box=$(box_rate)
            fixed=$(driver_log_since "$start" 'After the Mac woke' | head -2 | tr '\n' ';')
            if all_thru && [ -n "$box" ] && [ "$box" = "$want" ]; then
                record PASS "thru and rate after the Mac sleeps" "every deck on thru, box and device at $box Hz; ${fixed:-the box kept its decks}"
            else
                record FAIL "thru and rate after the Mac sleeps" "thru on $(thru_count)/$NDECKS decks, box at ${box:-?} Hz, device at ${want:-?} Hz"
            fi
        fi
    fi

    # Unplug and replug with nothing playing: the device goes, comes back, and puts every deck on
    # analogue thru. The output volume, set to -20 dB (channels at 0 dB) and muted first, comes back
    # the same. (That shows the settings survive a replug; it can't show who kept them, since the
    # driver's own copy outlives the unplug too. The HAL restores a device's controls whenever it is
    # published.) The user's own setting is put back afterwards.
    if save_volume; then
        have_volume=1
        neutral_volume; "$B/volctl" "$DEV" -20 >/dev/null; "$B/volctl" "$DEV" mute >/dev/null
    else
        have_volume=0
    fi
    echo "   >>> Unplug the SL 4's USB cable."
    if wait_until "the box to go" not connected; then
        echo "   >>> Plug it back in (into the same port on the box)."
        if wait_until "the box to return" connected && wait_until "every deck on thru" all_thru; then
            record PASS "unplug and replug, idle"
            if [ $have_volume = 1 ]; then
                vol=$("$B/volctl" "$DEV")
                [ "$vol" = "volume -20 dB, channels $ZEROS dB, mute 1" ] && record PASS "volume and mute survive a replug" \
                    || record FAIL "volume and mute survive a replug" "$vol"
            else
                record SKIP "volume and mute survive a replug" "the driver has no output volume controls"
            fi
        else
            record FAIL "unplug and replug, idle"
            record SKIP "volume and mute survive a replug" "the box did not come back"
        fi
    else
        record FAIL "unplug and replug, idle" "unplug not seen"
        record SKIP "volume and mute survive a replug" "unplug not seen"
    fi
    [ $have_volume = 1 ] && restore_volume

    # Unplug while a stream runs (a silent, input-only one) and replug: coreaudiod survives, the
    # driver ends the stream cleanly, routes the decks as they were during the stream (USB audio) while
    # it waits for the client to come back, puts them back on thru when none does within 5 s, and a new
    # stream starts after the replug.
    caud=$(pgrep -x coreaudiod)
    start=$(now)
    "$B/chrec" "$DEV" 60 "${TMPDIR:-/tmp}/sl4-hwtest-chrec.wav" >/dev/null 2>&1 &
    rec=$!
    sleep 2
    echo "   >>> A stream is running: unplug the SL 4's USB cable."
    if wait_until "the box to go" not connected; then
        kill $rec 2>/dev/null; wait $rec 2>/dev/null
        echo "   >>> Plug it back in (into the same port on the box)."
        wait_until "the box to return" connected && wait_until "every deck on thru" all_thru
        back=$?
        # A new stream after the replug.
        "$B/chrec" "$DEV" 2 "${TMPDIR:-/tmp}/sl4-hwtest-chrec.wav" >/dev/null 2>&1
        ended=$(driver_log_since "$start" 'Streaming stopped \(box disconnected\)' | head -1)
        started=$(driver_log_since "$start" 'Streaming started' | wc -l | tr -d ' ')
        kept=$(driver_log_since "$start" 'Decks routed as before the unplug' | head -1)
        fell=$(driver_log_since "$start" 'No stream restarted within' | head -1)
        if [ $back = 0 ] && [ "$(pgrep -x coreaudiod)" = "$caud" ] && [ -n "$ended" ] && [ "$started" -ge 2 ] &&
           [ -n "$kept" ] && [ -n "$fell" ]; then
            record PASS "unplug and replug, mid-stream" "routing kept, then thru with no client back"
        else
            record FAIL "unplug and replug, mid-stream" "returned $([ $back = 0 ] && echo yes || echo no), coreaudiod pid $caud -> $(pgrep -x coreaudiod), stream end logged: ${ended:-no}, streams started $started, routing kept: ${kept:+yes}, thru after 5 s: ${fell:+yes}"
        fi
    else
        kill $rec 2>/dev/null; wait $rec 2>/dev/null
        record FAIL "unplug and replug, mid-stream" "unplug not seen"
    fi
fi
echo

# ---------------------------------------------------------------------------- summary

pass=0; fail=0; skip=0
echo "== summary ($BUILD build, box at ${RATE:-?} Hz)"
for r in "${RESULTS[@]}"; do
    IFS='|' read -r s name detail <<< "$r"
    printf '%-4s  %s\n' "$s" "$name"
    case $s in PASS) pass=$((pass + 1)) ;; FAIL) fail=$((fail + 1)) ;; SKIP) skip=$((skip + 1)) ;; esac
done
echo "$pass passed, $fail failed, $skip skipped. Log: $LOG"
[ $LOOPBACK = 1 ] && echo "(loopback tests ran at ${RATE:-?} Hz: flip the box's 48/96 kHz control and run again to cover the other rate)"
[ $fail = 0 ] && echo "PASS" || echo "FAIL"
exit $([ $fail = 0 ] && echo 0 || echo 1)
