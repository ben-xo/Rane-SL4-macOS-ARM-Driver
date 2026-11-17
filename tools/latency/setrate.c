// setrate <device-name-substring> [rate | try <rate>]  — show a CoreAudio device's sample rate
//
// The SL 4 chooses its sample rate itself, 48 or 96 kHz, with the rate control on the box, and the
// driver publishes whatever rate the box is at: the host cannot change it. So this tool only shows
// the rate (and the rates the device lists). Given a rate, it says whether the device is already at
// it and, if not, refuses: flip the box's 48/96 kHz control instead.
//   setrate "SL 4"              prints "<name>: 48000 Hz (available: 48000)"
//   setrate "SL 4" 96000        exit 0 if the device is at 96000 Hz, otherwise explains and exits 1
//   setrate "SL 4" try 96000    asks the device to switch anyway, to check that it refuses: exit 0 if
//                               the rate stayed as it was (or the device is already at that rate)
#include <CoreAudio/CoreAudio.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include "common.h"

static int usage(void) {
    fprintf(stderr, "usage: setrate <name-substring> [rate | try <rate>]\n");
    return 2;
}

int main(int argc, char **argv) {
    if (argc < 2 || argc > 4) return usage();
    bool try = argc == 4 && !strcmp(argv[2], "try");
    if (argc == 4 && !try) return usage();
    const char *want_s = argc >= 3 ? argv[argc - 1] : NULL;
    char *end = NULL;
    Float64 want = want_s ? strtod(want_s, &end) : 0;
    if (want_s && (end == want_s || *end || want <= 0)) { fprintf(stderr, "not a sample rate: '%s'\n", want_s); return 2; }

    AudioObjectID d = find(argv[1]);
    if (!d) { fprintf(stderr, "no device matching '%s'\n", argv[1]); return 1; }
    char name[256] = "?";
    CFStringRef nm = NULL; UInt32 s = sizeof nm;
    AudioObjectPropertyAddress na = { kAudioObjectPropertyName, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
    if (!AudioObjectGetPropertyData(d, &na, 0, NULL, &s, &nm) && nm) { CFStringGetCString(nm, name, sizeof name, kCFStringEncodingUTF8); CFRelease(nm); }

    // The device's rate now.
    AudioObjectPropertyAddress ra = { kAudioDevicePropertyNominalSampleRate, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
    Float64 r = 0; s = sizeof r;
    if (AudioObjectGetPropertyData(d, &ra, 0, NULL, &s, &r)) { fprintf(stderr, "%s: cannot read the sample rate\n", name); return 1; }

    // No rate given: print it and the rates the device lists.
    if (!want_s) {
        printf("%s: %.0f Hz (available:", name, r);
        AudioObjectPropertyAddress aa = { kAudioDevicePropertyAvailableNominalSampleRates, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
        AudioValueRange av[16]; UInt32 sz = sizeof av;
        if (!AudioObjectGetPropertyData(d, &aa, 0, NULL, &sz, av))
            for (UInt32 i = 0; i < sz / sizeof av[0]; i++) printf(" %.0f", av[i].mMinimum);
        printf(")\n");
        return 0;
    }

    // Already at the rate asked for.
    if (want == r) { printf("%s: %.0f Hz already\n", name, r); return 0; }

    // try: ask the driver anyway; it must refuse, since the box chooses the rate. The HAL may refuse
    // the request itself (the device lists only its current rate), so what counts is the rate after.
    if (try) {
        Float64 before = r;
        OSStatus e = AudioObjectSetPropertyData(d, &ra, 0, NULL, sizeof want, &want);
        usleep(500000);
        s = sizeof r; AudioObjectGetPropertyData(d, &ra, 0, NULL, &s, &r);
        if (r == before) { printf("%s: switching to %.0f Hz refused (error %d), still %.0f Hz\n", name, want, (int)e, r); return 0; }
        printf("%s: switched to %.0f Hz (error %d), now %.0f Hz: it should have been refused\n", name, want, (int)e, r);
        return 1;
    }

    // Any other rate: refuse, and say how to change it.
    printf("%s: %.0f Hz, not %.0f Hz. The SL 4's rate is chosen on the box, not by the computer: set\n"
           "the box's 48/96 kHz control to the rate you want and the driver follows it.\n", name, r, want);
    return 1;
}
