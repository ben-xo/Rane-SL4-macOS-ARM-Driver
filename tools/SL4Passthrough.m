// SPDX-License-Identifier: GPL-3.0-or-later
/* SL4Passthrough.m — see SL4Passthrough.h. */
#import "SL4Passthrough.h"
#import <Foundation/Foundation.h>
#include <string.h>

#define kSL4PropHIDCommand  'sl4h'

AudioObjectID sl4h_find_device(void) {
    AudioObjectPropertyAddress a = {
        kAudioHardwarePropertyTranslateUIDToDevice,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain
    };
    CFStringRef uid = CFSTR("com.rane.sl4.hal.device");
    AudioObjectID dev = kAudioObjectUnknown;
    UInt32 sz = sizeof(dev);
    OSStatus st = AudioObjectGetPropertyData(kAudioObjectSystemObject, &a, sizeof(uid), &uid, &sz, &dev);
    return (st == noErr) ? dev : kAudioObjectUnknown;
}

bool sl4h_command(AudioObjectID dev, uint8_t req[SL4_REPORT], uint8_t reply[SL4_REPORT]) {
    /* A non-zero tag: the driver matches the box's reply to it (with 0 it uses its own). */
    static uint32_t tag = 0;
    if (++tag == 0) tag = 1;
    memcpy(req + 1, &tag, 4);

    AudioObjectPropertyAddress a = { kSL4PropHIDCommand, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
    CFDataRef in = CFDataCreate(kCFAllocatorDefault, req, SL4_REPORT);
    OSStatus st = AudioObjectSetPropertyData(dev, &a, 0, NULL, sizeof(CFDataRef), &in);
    CFRelease(in);
    if (st != noErr) return false;

    CFDataRef out = NULL;
    UInt32 sz = sizeof(out);
    if (AudioObjectGetPropertyData(dev, &a, 0, NULL, &sz, &out) != noErr || !out) return false;
    memset(reply, 0, SL4_REPORT);
    CFIndex n = CFDataGetLength(out);
    memcpy(reply, CFDataGetBytePtr(out), (size_t)(n < SL4_REPORT ? n : SL4_REPORT));
    CFRelease(out);
    return reply[0] == req[0] && memcmp(reply + 1, req + 1, 4) == 0;
}

bool sl4h_version(AudioObjectID dev, uint8_t *major, uint8_t *minor) {
    uint8_t req[SL4_REPORT] = { SL4_CMD_VERSION }, reply[SL4_REPORT];
    if (!sl4h_command(dev, req, reply)) return false;
    *major = reply[5];
    *minor = reply[6];
    return true;
}

bool sl4h_rate(AudioObjectID dev, uint32_t *rate) {
    uint8_t req[SL4_REPORT] = { SL4_CMD_GET_RATE }, reply[SL4_REPORT];
    if (!sl4h_command(dev, req, reply)) return false;
    *rate = (uint32_t)reply[5] << 16 | (uint32_t)reply[6] << 8 | reply[7];
    return true;
}

bool sl4h_is_streaming(AudioObjectID dev) {
    AudioObjectPropertyAddress a = {
        kAudioDevicePropertyDeviceIsRunningSomewhere,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain
    };
    UInt32 running = 0, sz = sizeof(running);
    return AudioObjectGetPropertyData(dev, &a, 0, NULL, &sz, &running) == noErr && running;
}
