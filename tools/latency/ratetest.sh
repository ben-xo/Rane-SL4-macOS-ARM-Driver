#!/bin/bash
# ratetest.sh <device-name> [seconds]
# The SL 4 chooses its rate on the box (48 or 96 kHz), so this test can't switch it: it speaks a long
# sentence on the device at whatever rate the box is at, and times it (a sentence of ~6 s that takes
# much longer, or sounds wrong, means the device isn't playing at the rate it reports). With a time
# given, it then watches the device's rate for that long, so the box's 48/96 kHz control can be
# flipped during it (optional: someone at the box), and speaks again at the new rate.
S=$(dirname "$0")
DEV="${1:?usage: ratetest.sh <device-name> [seconds]}"; WATCH="${2:-0}"
T="this is a rate test, one two three four five six seven eight nine ten eleven twelve"
rate() { "$S/bin/setrate" "$DEV" | grep -oE '[0-9]+ Hz' | head -1; }
speak() {   # on the device (or the default output, if SAY_DEFAULT is set), timed
    local t0
    t0=$(date +%s)
    if [ -n "${SAY_DEFAULT:-}" ]; then say "$T"; else say -a "$DEV" "$T"; fi
    echo "$DEV at $(rate): say took $(( $(date +%s) - t0 ))s"
}
speak
[ "$WATCH" -gt 0 ] 2>/dev/null || exit 0
# Watch for the box's rate to change (someone flips its 48/96 kHz control), then speak again.
r0=$(rate)
echo ">>> Flip the box's 48/96 kHz control now (watching for ${WATCH}s; the device is at $r0)."
for _ in $(seq 1 $((WATCH * 2))); do
    sleep 0.5
    r=$(rate)
    if [ -n "$r" ] && [ "$r" != "$r0" ]; then echo "the device followed the box: $r0 -> $r"; sleep 1; speak; exit 0; fi
done
echo "no rate change seen within ${WATCH}s (still $r0)"
exit 1
