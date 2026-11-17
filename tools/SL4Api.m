// SPDX-License-Identifier: GPL-3.0-or-later
/*
 * SL4Api.m — Universal (arm64 + x86_64) replacement for /Library/Frameworks/SL4Api.framework
 *
 * Rane's SL4Api (2.0.1f1) is the library Serato DJ Pro 2.5.5 and Rane's "SL 4 Audio Control Panel"
 * load to talk to an SL 4. This one exports the same SL4_* and RH_* functions, with the same
 * arguments, structures, results, return codes and callbacks as Rane's (compared with its
 * disassembly; see docs/SL4-COMMANDS.md, "SL4Api exported API"), on top of the
 * SL4Device CoreAudio HAL plug-in's custom properties:
 *   'sl4h'  write a 64-byte HID command; the next read returns the box's reply
 *   'sl4s'  read the driver's status (SL4StatusPacket, plugin/SL4Status.h)
 *   'sl4q'  read this process's queued unsolicited reports (the box's 0x40 0x43 0x46 0x49 0x4B)
 * Without the plug-in there is no path to the box: every call that needs it returns "not connected".
 *
 * Serato DJ Pro 2.5.5 looks up ten functions: SL4_open, SL4_close, SL4_driver_timer,
 * SL4_get_usb_port_status, SL4_send_bridge_packet, SL4_set_bridgepacket_callback,
 * SL4_set_usb_port_status_callback, SL4_get_all_controls, SL4_send_hidimsg and
 * SL4_set_hidimsg_callback. Those behave as Rane's in every case.
 *
 * Return codes, as Rane's: 0 = done, 4 = no reply from the box (or the request could not be made),
 * 8 = bad handle or argument, 9 = the Hidi message does not fit, 10 = empty Hidi message, 11 = the
 * box answered with another opcode (0xFF unknown, 0xFE refused, 0xFD update busy), 12 = not
 * connected. Handles are opaque counters from 1, each with its own callbacks. Callbacks are called
 * on this library's own serial queue, as Rane's are on its monitor thread.
 *
 * Not done here, deliberately: firmware update (the box's updater runs in boot mode, which the
 * driver never opens, so it can't be reached through 'sl4h'; tools/firmware/sl4flash does it) and
 * the alternate product ID (0x1a makes the box re-enumerate as a device the driver does not match).
 */

#import <Foundation/Foundation.h>
#import <CoreAudio/CoreAudio.h>
#import <IOKit/IOKitLib.h>
#import <IOKit/usb/IOUSBLib.h>
#include <pthread.h>
#include <stdatomic.h>
#include <os/log.h>

#ifndef SL4_VERSION
#define SL4_VERSION "0.0.0"
#endif

#define VID              0x1cc5
#define PID              0x000f
#define BCD_RUNNING      0x0100   /* bcdDevice of the running firmware; 0x9900 = boot mode (no driver) */

#define kSL4PropHIDCommand  'sl4h'
#define kSL4PropStatus      'sl4s'
#define kSL4PropUnsolQueue  'sl4q'

enum {
    RH_OK                = 0,
    RH_ERR_NO_REPLY      = 4,    /* Rane's: IOKit error, or no reply within 5 s */
    RH_ERR_BAD_ARG       = 8,
    RH_ERR_HIDI_FULL     = 9,    /* the message does not fit one Hidi report */
    RH_ERR_HIDI_EMPTY    = 10,
    RH_ERR_WRONG_REPLY   = 11,   /* the reply's opcode is not the request's */
    RH_ERR_NOT_CONNECTED = 12,
};

/* The box's HID protocol (docs/SL4-COMMANDS.md): one 64-byte report per command and
   reply, [0] = opcode, [1..4] = tag, [5..] = arguments / results. */
enum {
    HID_REPORT_LEN          = 64,
    HID_MAX_ARGS            = HID_REPORT_LEN - 5,
    HIDI_MAX_LEN            = 58,    /* bytes of Hidi messages one 0x41 / 0x40 report carries */
    BRIDGE_PACKET_LEN       = 59,    /* bytes of a bridge packet, [5..63] of 0x42 / 0x43 */
    CHALLENGE_LEN           = 8,
    SL4_CMD_VERSION         = 0x01,  /* reply [5] major, [6] minor, [7..10] build stamp (BE) */
    SL4_CMD_PORT_SPEED      = 0x0a,  /* reply [5] USB state: 0 unconfigured, 1 full, 2 high speed */
    SL4_CMD_BOOT_DEVICE     = 0x13,  /* reply [5] != 0: the box runs its firmware updater */
    SL4_CMD_CHALLENGE       = 0x37,  /* [5..12] challenge; reply [5..12] answer (computed by the FX2) */
    SL4_CMD_HIDI            = 0x41,  /* [5] length <= 58, [6..] MIDI-style messages; reply 0x41 or 0xFE */
    SL4_CMD_BRIDGE          = 0x42,  /* [5..63] packet for the other port; reply 0x42, or 0xFE without one */
    SL4_CMD_PORT_STATUS     = 0x45,  /* reply [5] this port's index (0/1), [6] 1 = other port connected */
    SL4_CMD_GET_RATE        = 0x4A,  /* reply [5..7] sample rate, 24-bit BE (48000 or 96000) */
    SL4_REPORT_HIDI         = 0x40,  /* [5] length, [6..] messages (channel 2: 81/91 nn 40) */
    SL4_REPORT_BRIDGE       = 0x43,  /* [5..63] the other port's 0x42 packet */
    SL4_REPORT_OTHER_GONE   = 0x46,  /* [5] the other port's index: its computer disconnected */
    SL4_REPORT_OTHER_CAME   = 0x49,  /* [5] the other port's index: a computer connected there */
    SL4_REPORT_RATE         = 0x4B,  /* [5..7] the box's new sample rate, 24-bit BE */
};

/* Hidi (MIDI-style) bytes, as Rane's AHidiStringWriter builds them */
enum {
    MIDI_NOTE_OFF       = 0x80,
    MIDI_NOTE_ON        = 0x90,
    MIDI_CONTROL_CHANGE = 0xB0,
    SYSEX_START         = 0xF0,
    SYSEX_RANE          = 0x17,
    SYSEX_END           = 0xF7,
    SYSEX_STATE_DUMP    = 0x04,  /* F0 17 04 F7: the box reports notes 5C 5D 5E 5F 60 as 0x40 */
    SYSEX_CONTROL_POINT = 0x52,  /* F0 17 52 <1|2> F7: a Sixty-Eight message; the SL 4 refuses it */
};

/* The driver's status ('sl4s'), defined once in plugin/SL4Status.h */
#include "SL4Status.h"

/* Rane's API types (sizes from Rane's copies of them) */
typedef struct {
    uint8_t length;                     /* bytes of data, 1..HIDI_MAX_LEN */
    uint8_t data[HIDI_MAX_LEN];
} RH_hidimsg_data_t;

typedef struct {
    uint8_t data[BRIDGE_PACKET_LEN];
} RH_bridgepacket_data_t;

typedef struct {
    int this_port;                      /* this computer's port: 1 or 2, 0 = not connected */
    int other_port;                     /* the other port's number, 0 = no computer there */
} RH_usb_port_status_t;

typedef struct {
    int rate;
} SL4_samplerate_t;

typedef struct {
    int a, b;
} RH_midi_ch_data_t;

typedef struct {
    int major, minor, rev, build;
} SL4_version_t;

typedef struct {
    uint8_t percent;                    /* 0-100 */
} RH_firmware_status_data_t;

_Static_assert(sizeof(RH_hidimsg_data_t) == 59, "Rane's RH_hidimsg_data_t is 59 bytes");
_Static_assert(sizeof(RH_bridgepacket_data_t) == 59, "Rane's RH_bridgepacket_data_t is 59 bytes");
_Static_assert(sizeof(SL4_version_t) == 16, "Rane's SL4_version_t is 16 bytes");

typedef void (*hidi_cb_t)(RH_hidimsg_data_t *);
typedef void (*bridge_cb_t)(RH_bridgepacket_data_t *);
typedef void (*port_cb_t)(RH_usb_port_status_t *);
typedef void (*midi_cb_t)(RH_midi_ch_data_t *);
typedef void (*rate_cb_t)(SL4_samplerate_t *);

/* One open handle and its callbacks */
typedef struct {
    uintptr_t   id;
    hidi_cb_t   hidi;
    bridge_cb_t bridge;
    port_cb_t   port;
    midi_cb_t   midi;
    rate_cb_t   rate;
} Client;

static pthread_mutex_t g_cmd_lock = PTHREAD_MUTEX_INITIALIZER;     /* one command at a time per process */
static uint32_t g_seq = 1;                                          /* request tags (under g_cmd_lock) */

static pthread_mutex_t g_state_lock = PTHREAD_MUTEX_INITIALIZER;   /* the fields below */
static Client   *g_clients;              /* open handles */
static int       g_nclients, g_cap_clients;
static uintptr_t g_next_handle = 1;      /* Rane's counter starts at 1 and never reuses a value */
static bool      g_ever_opened;          /* RH_open has been called in this process */
static int       g_buffer_ms = 5;        /* the control panel's latency setting; see RH_set_buffer_millisecs */
static RH_midi_ch_data_t g_midi;         /* RH_set_midi_channels' value */

static dispatch_queue_t  g_poll_q;
static dispatch_source_t g_poll_timer;
static bool g_was_connected;             /* box connected at the last poll (g_poll_q) */
static int  g_this_port;                 /* this computer's port number, from 0x45 at connect (g_poll_q) */

/* Every exported call is logged at debug level with its result, plus what was sent to and received
   from the box, so a client's use of the API can be followed without a debugger:
     log stream --level debug --predicate 'subsystem == "com.rane.sl4api"'
   Debug-level messages cost almost nothing unless a log stream asks for them. The SL4_* functions
   forward to RH_*, so they log under the RH_* name. */
static os_log_t api_log(void) {
    static os_log_t log;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ log = os_log_create("com.rane.sl4api", "api"); });
    return log;
}
#define TRACE(fmt, ...) os_log_debug(api_log(), "%{public}s" fmt, __func__, ##__VA_ARGS__)
#define RET(e) ({ int ret_ = (e); TRACE(" -> %d", ret_); ret_; })

/* ============================================================================
 * Handles
 * ============================================================================ */

/* The client for handle h, or NULL (call with g_state_lock held). */
static Client *client_locked(void *h) {
    for (int i = 0; i < g_nclients; i++)
        if (g_clients[i].id == (uintptr_t)h) return &g_clients[i];
    return NULL;
}

static bool handle_ok(void *h) {
    pthread_mutex_lock(&g_state_lock);
    bool ok = h != NULL && client_locked(h) != NULL;
    pthread_mutex_unlock(&g_state_lock);
    return ok;
}

/* A copy of every open client, for calling their callbacks without holding the lock (a callback
   may call back into the API). The caller frees it. */
static Client *clients_snapshot(int *n) {
    pthread_mutex_lock(&g_state_lock);
    *n = g_nclients;
    Client *copy = NULL;
    if (g_nclients > 0 && (copy = malloc(sizeof(Client) * (size_t)g_nclients)))
        memcpy(copy, g_clients, sizeof(Client) * (size_t)g_nclients);
    else
        *n = 0;
    pthread_mutex_unlock(&g_state_lock);
    return copy;
}

/* ============================================================================
 * The driver: its device, status and properties
 * ============================================================================ */

/* The SL 4's CoreAudio device, cached; the cache is dropped whenever the system's device list
   changes (the device only exists while a box is attached). */
static _Atomic AudioObjectID g_dev = kAudioObjectUnknown;
static OSStatus devices_changed(AudioObjectID o, UInt32 n, const AudioObjectPropertyAddress *a, void *c) {
    atomic_store(&g_dev, kAudioObjectUnknown);
    return 0;
}

static AudioObjectID find_hal_device(void) {
    /* Once per process: listen for changes to the device list, which drop the cache. */
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        AudioObjectPropertyAddress da = { kAudioHardwarePropertyDevices, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
        AudioObjectAddPropertyListener(kAudioObjectSystemObject, &da, devices_changed, NULL);
    });
    /* Use the cached device while there is one. */
    AudioObjectID dev = atomic_load(&g_dev);
    if (dev != kAudioObjectUnknown) return dev;
    /* Otherwise look it up by the HAL plug-in's device UID, and cache it. */
    AudioObjectPropertyAddress a = {
        kAudioHardwarePropertyTranslateUIDToDevice,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain
    };
    CFStringRef uid = CFSTR("com.rane.sl4.hal.device");
    UInt32 sz = sizeof(dev);
    if (AudioObjectGetPropertyData(kAudioObjectSystemObject, &a, sizeof(uid), &uid, &sz, &dev) != noErr) return kAudioObjectUnknown;
    atomic_store(&g_dev, dev);
    return dev;
}

static bool hal_get_status(SL4StatusPacket *outSt) {
    /* Without the driver's device there is no status. */
    AudioObjectID dev = find_hal_device();
    if (dev == kAudioObjectUnknown) return false;
    /* Read the status property, which the driver returns as a CFData. */
    AudioObjectPropertyAddress a = { kSL4PropStatus, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
    CFDataRef d = NULL;
    UInt32 sz = sizeof(d);
    bool ok = false;
    if (AudioObjectGetPropertyData(dev, &a, 0, NULL, &sz, &d) == noErr && d) {
        /* Copy what the driver sent (zero-filling the rest if it is shorter); it counts as a status
           if it holds every field before boot_mode. */
        memset(outSt, 0, sizeof *outSt);
        CFIndex n = CFDataGetLength(d);
        memcpy(outSt, CFDataGetBytePtr(d), (size_t)(n < (CFIndex)sizeof *outSt ? n : (CFIndex)sizeof *outSt));
        ok = n >= (CFIndex)offsetof(SL4StatusPacket, boot_mode);
        CFRelease(d);
    }
    return ok;
}

/* An SL 4 running its firmware (not in boot mode, which the driver never opens) is in the USB
   registry. */
static bool in_usb_registry(void) {
    CFMutableDictionaryRef m = IOServiceMatching(kIOUSBDeviceClassName);
    if (!m) return false;
    int v = VID, p = PID, bcd = BCD_RUNNING;
    CFNumberRef vn = CFNumberCreate(NULL, kCFNumberIntType, &v);
    CFNumberRef pn = CFNumberCreate(NULL, kCFNumberIntType, &p);
    CFNumberRef bn = CFNumberCreate(NULL, kCFNumberIntType, &bcd);
    CFDictionarySetValue(m, CFSTR(kUSBVendorID), vn);
    CFDictionarySetValue(m, CFSTR(kUSBProductID), pn);
    CFDictionarySetValue(m, CFSTR(kUSBDeviceReleaseNumber), bn);
    CFRelease(vn); CFRelease(pn); CFRelease(bn);
    /* Any match means a box is attached. */
    io_service_t s = IOServiceGetMatchingService(kIOMainPortDefault, m);
    if (s) { IOObjectRelease(s); return true; }
    return false;
}

/* The SL 4 HAL plug-in is loaded in coreaudiod. */
static bool driver_loaded(void) {
    AudioObjectPropertyAddress a = { kAudioHardwarePropertyTranslateBundleIDToPlugIn, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
    CFStringRef bundle = CFSTR("io.github.pepeleedj.sl4device");
    AudioObjectID plugin = kAudioObjectUnknown;
    UInt32 sz = sizeof plugin;
    return AudioObjectGetPropertyData(kAudioObjectSystemObject, &a, sizeof bundle, &bundle, &sz, &plugin) == noErr &&
           plugin != kAudioObjectUnknown;
}

/* The driver's device, ready for commands (it has opened the box): what Rane's library calls
   connected. Just after the box is plugged in, it is in the USB registry before the driver has
   opened it and listed its device: usually tens of milliseconds, about a second if macOS refuses
   the first open. A client that watches USB itself can call in that window (Serato DJ Pro 2.5.5
   sends its hardware check about 25 ms after an SL 2 appears, and does not retry), so while the box
   is in the registry and the driver is loaded, wait for the device, up to READY_WAIT_MS. */
#define READY_WAIT_MS 2000
#define READY_POLL_MS 20
static AudioObjectID ready_hal_device(void) {
    for (int waited = 0; ; waited += READY_POLL_MS) {
        /* Ready: the device is listed and the driver reports the box open. */
        AudioObjectID dev = find_hal_device();
        SL4StatusPacket st;
        bool have_st = dev != kAudioObjectUnknown && hal_get_status(&st);
        if (have_st && st.connected) return dev;
        /* Not ready, and not about to be (no box, a box in boot mode, which the driver never opens,
           or no driver to open it), or waited long enough. */
        if (waited >= READY_WAIT_MS || (have_st && st.boot_mode) || !in_usb_registry() || !driver_loaded())
            return kAudioObjectUnknown;
        if (waited == 0) TRACE(": the box is attached but the driver has not opened it yet: waiting");
        usleep(READY_POLL_MS * 1000);
    }
}

static bool is_connected(void) { return ready_hal_device() != kAudioObjectUnknown; }

/* Send one HID command through the driver and get the box's reply, whatever its opcode. RH_OK
   (reply_out holds the reply), RH_ERR_NOT_CONNECTED or RH_ERR_NO_REPLY. */
static int hid_request(uint8_t cmd, const uint8_t *args, size_t nargs, uint8_t *reply_out) {
    /* No driver device (after waiting for one that is on its way) means no box; otherwise take the
       lock so each command gets its own reply. */
    AudioObjectID dev = ready_hal_device();
    if (dev == kAudioObjectUnknown) return RH_ERR_NOT_CONNECTED;
    pthread_mutex_lock(&g_cmd_lock);

    /* Build the request: the driver sends it when it is written, and the next read returns the
       reply with our tag. */
    uint8_t req[HID_REPORT_LEN] = {0};
    req[0] = cmd;
    uint32_t seq = g_seq++;
    memcpy(req + 1, &seq, 4);
    if (args && nargs > 0) memcpy(req + 5, args, nargs > HID_MAX_ARGS ? HID_MAX_ARGS : nargs);
    AudioObjectPropertyAddress a = { kSL4PropHIDCommand, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
    CFDataRef in = CFDataCreate(kCFAllocatorDefault, req, HID_REPORT_LEN);
    OSStatus st = AudioObjectSetPropertyData(dev, &a, 0, NULL, sizeof(CFDataRef), &in);
    CFRelease(in);

    /* Read the reply back (the driver keeps it even when the write failed, so always take it). */
    int result = RH_ERR_NO_REPLY;
    CFDataRef out = NULL;
    UInt32 sz = sizeof(CFDataRef);
    if (AudioObjectGetPropertyData(dev, &a, 0, NULL, &sz, &out) == noErr && out) {
        /* Copy at most one report, and accept it only if the write succeeded and it carries our tag. */
        uint8_t reply[HID_REPORT_LEN] = {0};
        CFIndex n = CFDataGetLength(out);
        memcpy(reply, CFDataGetBytePtr(out), (size_t)(n < HID_REPORT_LEN ? n : HID_REPORT_LEN));
        CFRelease(out);
        if (st == noErr && memcmp(reply + 1, req + 1, 4) == 0) {
            if (reply_out) memcpy(reply_out, reply, HID_REPORT_LEN);
            result = RH_OK;
        }
    }
    pthread_mutex_unlock(&g_cmd_lock);
    if (result == RH_OK && reply_out && reply_out[0] != cmd)
        TRACE(": command 0x%02x answered 0x%02x", cmd, reply_out[0]);
    return result;
}

/* As Rane's SendHidRequest: a reply with another opcode (0xFF, 0xFE, 0xFD) is RH_ERR_WRONG_REPLY. */
static int hid_command(uint8_t cmd, const uint8_t *args, size_t nargs, uint8_t reply[HID_REPORT_LEN]) {
    int e = hid_request(cmd, args, nargs, reply);
    if (e) return e;
    return reply[0] == cmd ? RH_OK : RH_ERR_WRONG_REPLY;
}

/* Send Hidi messages (0x41). Rane's hands them to its kernel extension, which writes them to the box
   without waiting for the answer, so the result only says whether they were sent: RH_OK for any
   reply (0x41 accepted, 0xFE refused: the box acts only on Note On / Note Off of notes 0x5C-0x5F and
   on F0 17 04 F7), RH_ERR_NO_REPLY if none came. */
static int send_hidi(const uint8_t *msg, uint8_t len) {
    TRACE(": %{public}.*P", (int)len, msg);
    uint8_t args[1 + HIDI_MAX_LEN];
    args[0] = len;
    memcpy(args + 1, msg, len);
    uint8_t r[HID_REPORT_LEN];
    int e = hid_request(SL4_CMD_HIDI, args, 1u + len, r);
    if (e == RH_OK && r[0] != SL4_CMD_HIDI) TRACE(": the box refused the message (0x%02x)", r[0]);
    return e;
}

/* ============================================================================
 * Reports and events, polled from the driver and passed to the client's callbacks
 * ============================================================================ */

/* The port-status callback of every handle that has one. */
static void notify_port_status(int this_port, int other_port) {
    TRACE(": port-status callback {%d, %d}", this_port, other_port);
    int n;
    Client *cs = clients_snapshot(&n);
    for (int i = 0; i < n; i++) {
        if (!cs[i].port) continue;
        RH_usb_port_status_t ps = { this_port, other_port };
        cs[i].port(&ps);
    }
    free(cs);
}

/* The box has become reachable (Rane's HandleDeviceConnected): learn this computer's port and tell
   the clients, as Rane's does with 0x13 then 0x45. A box in boot mode (0x13 [5] != 0) is reported as
   port 1 without asking; a failed command reports {0, 0}. */
static void device_connected(void) {
    uint8_t r[HID_REPORT_LEN];
    /* Boot device or not. */
    if (hid_command(SL4_CMD_BOOT_DEVICE, NULL, 0, r) != RH_OK) {
        g_this_port = 0;
        notify_port_status(0, 0);
        return;
    }
    if (r[5] != 0) {
        g_this_port = 1;
        notify_port_status(1, r[6] ? 2 : 0);
        return;
    }
    /* This computer's port (index 0/1 -> 1/2), and the other port's if a computer is there. */
    if (hid_command(SL4_CMD_PORT_STATUS, NULL, 0, r) != RH_OK) {
        g_this_port = 0;
        notify_port_status(0, 0);
        return;
    }
    g_this_port = r[5] ? 2 : 1;
    notify_port_status(g_this_port, r[6] ? (g_this_port == 1 ? 2 : 1) : 0);
}

/* One report from 'sl4q' to the callbacks, as Rane's HandleUnsolicitedData. */
static void dispatch_report(const uint8_t pkt[HID_REPORT_LEN]) {
    int n;
    Client *cs = clients_snapshot(&n);
    switch (pkt[0]) {
    case SL4_REPORT_HIDI:
        /* Thru changes, the state dump, note 0x60: [5] length (a longer one is dropped), [6..] the
           messages. */
        if (pkt[5] > HIDI_MAX_LEN) break;
        TRACE(": hidimsg callback %{public}.*P", (int)pkt[5], pkt + 6);
        for (int i = 0; i < n; i++) {
            if (!cs[i].hidi) continue;
            RH_hidimsg_data_t m = { .length = pkt[5] };
            memcpy(m.data, pkt + 6, pkt[5]);
            cs[i].hidi(&m);
        }
        break;
    case SL4_REPORT_BRIDGE:
        /* The other computer's bridge packet: the 59 bytes from [5]. */
        TRACE(": bridge callback");
        for (int i = 0; i < n; i++) {
            if (!cs[i].bridge) continue;
            RH_bridgepacket_data_t b;
            memcpy(b.data, pkt + 5, BRIDGE_PACKET_LEN);
            cs[i].bridge(&b);
        }
        break;
    case SL4_REPORT_OTHER_GONE:
        /* The computer on the other port went: {this port, 0}. */
        notify_port_status(g_this_port, 0);
        break;
    case SL4_REPORT_OTHER_CAME:
        /* A computer connected to the other port: [5] is its index (0/1 -> port 1/2). */
        notify_port_status(g_this_port, pkt[5] ? 2 : 1);
        break;
    case SL4_REPORT_RATE: {
        /* The box changed its sample rate: [5..7], big-endian. */
        int rate = (pkt[5] << 16) | (pkt[6] << 8) | pkt[7];
        TRACE(": sample-rate callback %d", rate);
        for (int i = 0; i < n; i++) {
            if (!cs[i].rate) continue;
            SL4_samplerate_t s = { rate };
            cs[i].rate(&s);
        }
        break;
    }
    default:
        break;
    }
    free(cs);
}

/* This process's queued reports, as a CFData of 64-byte reports (NULL if none). */
static CFDataRef read_queue(AudioObjectID dev) {
    AudioObjectPropertyAddress a = { kSL4PropUnsolQueue, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
    CFDataRef d = NULL;
    UInt32 sz = sizeof(d);
    if (AudioObjectGetPropertyData(dev, &a, 0, NULL, &sz, &d) != noErr) return NULL;
    return d;
}

/* Every 15 ms on g_poll_q: notice the box coming and going (the port-status callback: 0x13 and 0x45
   when it appears, {0, 0} when it goes, as Rane's), then pass on this process's queued reports. */
static void poll_driver(void) {
    /* Connected or not. */
    AudioObjectID dev = find_hal_device();
    SL4StatusPacket st;
    bool connected = dev != kAudioObjectUnknown && hal_get_status(&st) && st.connected;
    /* The box went: tell the clients. */
    if (!connected) {
        if (g_was_connected) notify_port_status(0, 0);
        g_was_connected = false;
        return;
    }
    /* The box came (or this is the first poll since the first open): drop reports queued before,
       which Rane's clients never see, then learn the port and tell the clients. */
    if (!g_was_connected) {
        g_was_connected = true;
        CFDataRef old = read_queue(dev);
        if (old) CFRelease(old);
        device_connected();
        return;
    }

    /* The reports since the last poll: a run of 64-byte reports, each passed on. */
    CFDataRef d = read_queue(dev);
    if (!d) return;
    CFIndex len = CFDataGetLength(d);
    const uint8_t *bytes = CFDataGetBytePtr(d);
    for (CFIndex off = 0; off + HID_REPORT_LEN <= len; off += HID_REPORT_LEN) dispatch_report(bytes + off);
    CFRelease(d);
}

/* Start polling (from the first open handle); closing the last handle stops it again. Called with
   g_state_lock held. */
static void poll_start_locked(void) {
    /* Already polling: nothing to do. */
    if (g_poll_timer) return;
    /* Create the serial queue once; a new run of polls starts as Rane's new monitor thread does,
       with the box not yet seen. */
    if (!g_poll_q) g_poll_q = dispatch_queue_create("com.rane.sl4api.poll", DISPATCH_QUEUE_SERIAL);
    dispatch_async(g_poll_q, ^{ g_was_connected = false; });
    /* Poll every 15 ms (5 ms leeway). The first poll comes 20 ms after the open, so a client that
       sets its callbacks right after SL4_open gets the port status at open, as with Rane's (whose
       monitor thread takes about as long to open the box). */
    g_poll_timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, g_poll_q);
    dispatch_source_set_timer(g_poll_timer, dispatch_time(DISPATCH_TIME_NOW, 20 * NSEC_PER_MSEC),
                              15 * NSEC_PER_MSEC, 5 * NSEC_PER_MSEC);
    dispatch_source_set_event_handler(g_poll_timer, ^{ poll_driver(); });
    dispatch_resume(g_poll_timer);
}

static void poll_stop_locked(void) {
    if (!g_poll_timer) return;
    dispatch_source_cancel(g_poll_timer);
    g_poll_timer = nil;
}

/* ============================================================================
 * Exported RH_* functions, as Rane's
 * ============================================================================ */

#define EXPORT __attribute__((visibility("default")))

/* A new handle; the first one starts the polling. bufferMs is RH_open_private's initial buffer
   size (0 = keep the current one). */
static void *open_handle(int bufferMs) {
    pthread_mutex_lock(&g_state_lock);
    /* Make room for the new client. */
    if (g_nclients == g_cap_clients) {
        int cap = g_cap_clients ? g_cap_clients * 2 : 8;
        Client *grown = realloc(g_clients, sizeof(Client) * (size_t)cap);
        if (!grown) { pthread_mutex_unlock(&g_state_lock); return NULL; }
        g_clients = grown;
        g_cap_clients = cap;
    }
    /* Give it the next handle, with no callbacks. */
    uintptr_t id = g_next_handle++;
    g_clients[g_nclients++] = (Client){ .id = id };
    g_ever_opened = true;
    if (bufferMs >= 1 && bufferMs <= 50) g_buffer_ms = bufferMs;
    TRACE(": handle %lu, open handles %d", (unsigned long)id, g_nclients);
    /* Start polling the driver if this is the only handle. */
    poll_start_locked();
    pthread_mutex_unlock(&g_state_lock);
    return (void *)id;
}

EXPORT void *RH_open(void) { return open_handle(0); }

EXPORT void RH_close(void *h) {
    pthread_mutex_lock(&g_state_lock);
    /* Forget the handle (an unknown one is ignored, as Rane's), and stop polling with the last. */
    Client *c = client_locked(h);
    if (c) {
        *c = g_clients[--g_nclients];
        if (g_nclients == 0) poll_stop_locked();
    }
    TRACE(": handle %lu %{public}s, open handles %d", (unsigned long)(uintptr_t)h, c ? "closed" : "unknown", g_nclients);
    pthread_mutex_unlock(&g_state_lock);
}

EXPORT int RH_get_vendor_id(void *h, int *v) {
    if (!handle_ok(h) || !v) return RET(RH_ERR_BAD_ARG);
    if (!is_connected()) return RET(RH_ERR_NOT_CONNECTED);
    *v = VID;
    return RET(RH_OK);
}

EXPORT int RH_get_product_id(void *h, int *p) {
    if (!handle_ok(h) || !p) return RET(RH_ERR_BAD_ARG);
    if (!is_connected()) return RET(RH_ERR_NOT_CONNECTED);
    *p = PID;
    return RET(RH_OK);
}

/* No handle; Rane's constant {2, 0, 0, 3}. */
EXPORT int RH_get_api_version(SL4_version_t *v) {
    if (!v) return RET(RH_ERR_BAD_ARG);
    *v = (SL4_version_t){ 2, 0, 0, 3 };
    return RET(RH_OK);
}

/* Rane's reports its kernel extension's version ({2, 0, 1, 1}). There is no kernel extension here:
   report this driver's version (SL4_VERSION, major.minor.patch, build 0). */
EXPORT int RH_get_driver_version(void *h, SL4_version_t *v) {
    if (!handle_ok(h) || !v) return RET(RH_ERR_BAD_ARG);
    if (!is_connected()) return RET(RH_ERR_NOT_CONNECTED);
    int maj = 0, min = 0, rev = 0;
    sscanf(SL4_VERSION, "%d.%d.%d", &maj, &min, &rev);
    *v = (SL4_version_t){ maj, min, rev, 0 };
    return RET(RH_OK);
}

/* The latency slider in Rane's "SL 4 Audio Control Panel". Rane's kernel extension used it as the
   USB buffer size; the HAL plug-in's playback latency does not depend on a buffer size, so a value
   is validated (1-50 ms) and kept, and reading it back gives the plug-in's real output latency plus
   safety offset, rounded up. Serato DJ Pro 2.5.5 doesn't call these: its own "USB buffer size" sets
   the CoreAudio IO buffer size, which the HAL owns. */
EXPORT int RH_set_buffer_millisecs(void *h, int ms) {
    if (!h || ms < 1 || ms > 50 || !handle_ok(h)) return RET(RH_ERR_BAD_ARG);
    if (!is_connected()) return RET(RH_ERR_NOT_CONNECTED);
    pthread_mutex_lock(&g_state_lock);
    g_buffer_ms = ms;
    pthread_mutex_unlock(&g_state_lock);
    return RET(RH_OK);
}

EXPORT int RH_get_buffer_millisecs(void *h, int *ms) {
    if (!h || !ms || !handle_ok(h)) return RET(RH_ERR_BAD_ARG);
    AudioObjectID dev = ready_hal_device();
    if (dev == kAudioObjectUnknown) return RET(RH_ERR_NOT_CONNECTED);
    /* Read the output latency and safety offset (in frames). */
    UInt32 lat = 0, safety = 0, sz = sizeof(UInt32);
    Float64 sr = 0;
    AudioObjectPropertyAddress la = { kAudioDevicePropertyLatency, kAudioObjectPropertyScopeOutput, kAudioObjectPropertyElementMain };
    AudioObjectPropertyAddress sa = { kAudioDevicePropertySafetyOffset, kAudioObjectPropertyScopeOutput, kAudioObjectPropertyElementMain };
    AudioObjectPropertyAddress ra = { kAudioDevicePropertyNominalSampleRate, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
    AudioObjectGetPropertyData(dev, &la, 0, NULL, &sz, &lat);
    sz = sizeof(UInt32);
    AudioObjectGetPropertyData(dev, &sa, 0, NULL, &sz, &safety);
    /* Read the sample rate and convert the frames to ms, rounded up; without a usable rate, give
       back the stored setting. */
    sz = sizeof(Float64);
    if (AudioObjectGetPropertyData(dev, &ra, 0, NULL, &sz, &sr) != noErr || sr <= 0) {
        pthread_mutex_lock(&g_state_lock);
        *ms = g_buffer_ms;
        pthread_mutex_unlock(&g_state_lock);
        return RET(RH_OK);
    }
    *ms = (int)ceil((double)(lat + safety) * 1000.0 / sr);
    return RET(RH_OK);
}

/* {this port, other port}, from 0x45: this = 1 or 2 (the box's port index 0 or 1), other = the
   other number if a computer is connected there, else 0. Serato DJ Pro 2.5.5 takes this != 0 as
   "box present". */
EXPORT int RH_get_usb_port_status(void *h, RH_usb_port_status_t *st) {
    if (!st || !handle_ok(h)) return RET(RH_ERR_BAD_ARG);
    uint8_t r[HID_REPORT_LEN];
    int e = hid_command(SL4_CMD_PORT_STATUS, NULL, 0, r);
    if (e) return RET(e);
    st->this_port = r[5] ? 2 : 1;
    st->other_port = r[6] ? (r[5] ? 1 : 2) : 0;
    TRACE(": {%d, %d}", st->this_port, st->other_port);
    return RET(RH_OK);
}

/* The box's USB link (0x0a): 0 unconfigured, 1 full speed (no audio), 2 high speed. */
EXPORT int RH_get_port_speed(void *h, int *speed) {
    if (!speed || !handle_ok(h)) return RET(RH_ERR_BAD_ARG);
    uint8_t r[HID_REPORT_LEN];
    int e = hid_command(SL4_CMD_PORT_SPEED, NULL, 0, r);
    if (e) return RET(e);
    *speed = r[5];
    return RET(RH_OK);
}

/* A Sixty-Eight message Rane's library still sends (F0 17 52 <point> F7, point 1 or 2); the SL 4
   refuses it. Nothing uses it on the SL 4. */
EXPORT int RH_set_control_point(void *h, const int *point) {
    if (!point || !handle_ok(h) || *point < 1 || *point > 2) return RET(RH_ERR_BAD_ARG);
    if (!is_connected()) return RET(RH_ERR_NOT_CONNECTED);
    uint8_t msg[5] = { SYSEX_START, SYSEX_RANE, SYSEX_CONTROL_POINT, (uint8_t)*point, SYSEX_END };
    return RET(send_hidi(msg, sizeof msg));
}

/* The challenge Serato uses to check it is talking to genuine Rane hardware: send the 8-byte
   challenge with 0x37 and return the box's 8-byte answer. Both lengths must be 8. */
EXPORT int RH_driver_timer(void *h, const uint8_t *in, int inlen, uint8_t *out, int outlen) {
    TRACE(": challenge %{public}.*P (%d bytes, answer buffer %d)", in && inlen == CHALLENGE_LEN ? CHALLENGE_LEN : 0, in, inlen, outlen);
    if (!handle_ok(h) || outlen != CHALLENGE_LEN || inlen != CHALLENGE_LEN || !in || !out) return RET(RH_ERR_BAD_ARG);
    uint8_t r[HID_REPORT_LEN];
    int e = hid_command(SL4_CMD_CHALLENGE, in, CHALLENGE_LEN, r);
    if (e) return RET(e);
    memcpy(out, r + 5, CHALLENGE_LEN);
    TRACE(": answer %{public}.*P", CHALLENGE_LEN, out);
    return RET(RH_OK);
}

/* Ask the box (0x01): {major, minor, 0, the 32-bit build stamp from [7..10], big-endian}. */
EXPORT int RH_get_firmware_version(void *h, SL4_version_t *v) {
    if (!handle_ok(h)) return RET(RH_ERR_BAD_ARG);
    if (!is_connected()) return RET(RH_ERR_NOT_CONNECTED);
    if (!v) return RET(RH_ERR_BAD_ARG);
    uint8_t r[HID_REPORT_LEN];
    int e = hid_command(SL4_CMD_VERSION, NULL, 0, r);
    if (e) return RET(e);
    v->major = r[5];
    v->minor = r[6];
    v->rev = 0;
    v->build = (int)(((uint32_t)r[7] << 24) | ((uint32_t)r[8] << 16) | ((uint32_t)r[9] << 8) | r[10]);
    return RET(RH_OK);
}

/* The firmware Rane's library embeds is 1.02: two values {major, minor}, Rane's constant. This
   library embeds no firmware; the constant is kept so Rane's control panel offers an update only
   where Rane's would (a box older than 1.02), and the update itself then fails (see
   RH_set_update_firmware). */
EXPORT int RH_get_firmware_embedded_version(void *h, int v[2]) {
    if (!v || !handle_ok(h)) return RET(RH_ERR_BAD_ARG);
    v[0] = 1;
    v[1] = 2;
    return RET(RH_OK);
}

/* Ask the box for a state dump (F0 17 04 F7), as Rane's does. The box answers with 0x40 reports of
   notes 0x5C-0x5F (deck 1-4 thru) and 0x60, which reach the hidimsg callback like any other report. */
EXPORT int RH_get_all_controls(void *h) {
    if (!handle_ok(h)) return RET(RH_ERR_BAD_ARG);
    if (!is_connected()) return RET(RH_ERR_NOT_CONNECTED);
    uint8_t msg[4] = { SYSEX_START, SYSEX_RANE, SYSEX_STATE_DUMP, SYSEX_END };
    return RET(send_hidi(msg, sizeof msg));
}

/* Send MIDI-style messages to the box with 0x41: m->length bytes (1-58) from m->data. Serato switches
   deck n's thru with {3, 0x90 | 0x80, 0x5C + n - 1, 0x00}: Note On = analog thru, Note Off = USB
   audio; the box confirms each change with a 0x40 report (channel 2) to both computers. */
EXPORT int RH_send_hidimsg(void *h, const RH_hidimsg_data_t *m) {
    if (!m || !handle_ok(h) || m->length == 0) return RET(RH_ERR_BAD_ARG);
    if (!is_connected()) return RET(RH_ERR_NOT_CONNECTED);
    if (m->length > HIDI_MAX_LEN) return RET(RH_ERR_BAD_ARG);
    return RET(send_hidi(m->data, m->length));
}

/* One three-byte message, as Rane's note and control-change functions build it. */
static int send_three(void *h, uint8_t a, uint8_t b, uint8_t c) {
    if (!handle_ok(h)) return RH_ERR_BAD_ARG;
    if (!is_connected()) return RH_ERR_NOT_CONNECTED;
    uint8_t msg[3] = { a, b, c };
    return send_hidi(msg, sizeof msg);
}

/* Rane's control panel calls SL4_send_note_on(h, 0x5C + deck, 0) for thru on and
   SL4_send_note_off(h, 0x5C + deck) for off. */
EXPORT int RH_send_note_on(void *h, uint8_t note, uint8_t vel) { return RET(send_three(h, MIDI_NOTE_ON, note, vel)); }
EXPORT int RH_send_note_off(void *h, uint8_t note)             { return RET(send_three(h, MIDI_NOTE_OFF, note, 0x00)); }

/* Sends B0 <cc> <val> as Rane's does; the SL 4's firmware ignores control changes. */
EXPORT int RH_send_control_change(void *h, uint8_t cc, uint8_t val) { return RET(send_three(h, MIDI_CONTROL_CHANGE, cc, val)); }

/* SysEx: Rane's wraps the bytes as F0 17 <bytes> F7, which must fit one report (9 if not). */
EXPORT int RH_send_sys_ex(void *h, const void *d, uint8_t len) {
    if (!d || !handle_ok(h) || len == 0) return RET(RH_ERR_BAD_ARG);
    if (!is_connected()) return RET(RH_ERR_NOT_CONNECTED);
    if (len + 3u > HIDI_MAX_LEN) return RET(RH_ERR_HIDI_FULL);
    /* Build F0 17 <bytes> F7 and send it as one Hidi message. */
    uint8_t msg[HIDI_MAX_LEN];
    msg[0] = SYSEX_START;
    msg[1] = SYSEX_RANE;
    memcpy(msg + 2, d, len);
    msg[2 + len] = SYSEX_END;
    return RET(send_hidi(msg, (uint8_t)(len + 3)));
}

/* Store a callback for handle h: 8 for a handle not open, else 0. */
#define SET_CALLBACK(h, field, cb) ({                                   \
        pthread_mutex_lock(&g_state_lock);                              \
        Client *c_ = (h) ? client_locked(h) : NULL;                     \
        if (c_) c_->field = (cb);                                       \
        pthread_mutex_unlock(&g_state_lock);                            \
        c_ ? RH_OK : RH_ERR_BAD_ARG; })

EXPORT int RH_set_hidimsg_callback(void *h, hidi_cb_t cb) { return RET(SET_CALLBACK(h, hidi, cb)); }

/* Bridge packets: a 59-byte mailbox between the computers on the box's two USB ports. 0x42 queues
   the packet for the other port, which receives it as 0x43; the box refuses it (0xFE: 11) unless a
   computer is connected to each port. */
EXPORT int RH_send_bridge_packet(void *h, const RH_bridgepacket_data_t *p) {
    if (!p || !handle_ok(h)) return RET(RH_ERR_BAD_ARG);
    uint8_t r[HID_REPORT_LEN];
    return RET(hid_command(SL4_CMD_BRIDGE, p->data, BRIDGE_PACKET_LEN, r));
}

EXPORT int RH_set_bridgepacket_callback(void *h, bridge_cb_t cb) { return RET(SET_CALLBACK(h, bridge, cb)); }

/* Called with {this, other} when the box becomes reachable (from 0x13 and 0x45), {0, 0} when it goes,
   {this, 0} when the other port's computer goes (0x46) and {this, other} when one comes (0x49). */
EXPORT int RH_set_usb_port_status_callback(void *h, port_cb_t cb) { return RET(SET_CALLBACK(h, port, cb)); }

/* Firmware update. Rane's sends 0x17 (the box invalidates its image and restarts in its firmware
   updater, bcdDevice 0x9900), reopens the box, then writes the image with 0x15 / 0x14 and finishes
   with 0x16. The driver never opens a box in boot mode, so after 0x17 nothing in this library could
   reach it: the box would be left in its updater until reflashed. These never send anything and
   return 12 (not connected: the updater cannot be reached from here); tools/firmware/sl4flash does
   the update, with a box in either mode. This library embeds no firmware. */
EXPORT int RH_set_update_firmware(void *h, const uint8_t *img, unsigned int len, void (*cb)(RH_firmware_status_data_t *)) {
    if (!handle_ok(h)) return RET(RH_ERR_BAD_ARG);
    TRACE(": not available here: use sl4flash");
    return RET(RH_ERR_NOT_CONNECTED);
}
EXPORT int RH_set_update_firmware_from_embedded(void *h, void (*cb)(RH_firmware_status_data_t *)) {
    if (!handle_ok(h)) return RET(RH_ERR_BAD_ARG);
    TRACE(": no firmware is embedded: use sl4flash");
    return RET(RH_ERR_NOT_CONNECTED);
}

/* Rane's sends 0x1a: the box disconnects and comes back as product ID 0x0010, which neither Rane's
   driver nor this one opens, until it is power-cycled. Never sent here: returns 4 (not done). */
EXPORT int RH_set_alt_product_id(void *h) {
    if (!handle_ok(h)) return RET(RH_ERR_BAD_ARG);
    if (!is_connected()) return RET(RH_ERR_NOT_CONNECTED);
    TRACE(": 0x1a is not sent");
    return RET(RH_ERR_NO_REPLY);
}

/* Ask the box (0x13): [5] != 0 means it runs its firmware updater. The driver never opens a box in
   boot mode, so through it this is always 0. */
EXPORT int RH_is_boot_device(void *h, int *b) {
    if (!b || !handle_ok(h)) return RET(RH_ERR_BAD_ARG);
    uint8_t r[HID_REPORT_LEN];
    int e = hid_command(SL4_CMD_BOOT_DEVICE, NULL, 0, r);
    if (e) return RET(e);
    *b = r[5];
    return RET(RH_OK);
}

/* The Sixty-Eight panel's MIDI-channel setting, which Rane's kernel extension keeps and broadcasts to
   its clients; nothing on the SL 4 uses it. Kept for this process, and passed to every handle's
   callback when set. */
EXPORT int RH_get_midi_channels(void *h, RH_midi_ch_data_t *ch) {
    if (!ch || !handle_ok(h)) return RET(RH_ERR_BAD_ARG);
    if (!is_connected()) return RET(RH_ERR_NOT_CONNECTED);
    pthread_mutex_lock(&g_state_lock);
    *ch = g_midi;
    pthread_mutex_unlock(&g_state_lock);
    return RET(RH_OK);
}

EXPORT int RH_set_midi_channels(void *h, const RH_midi_ch_data_t *ch) {
    if (!ch || !handle_ok(h)) return RET(RH_ERR_BAD_ARG);
    if (!is_connected()) return RET(RH_ERR_NOT_CONNECTED);
    pthread_mutex_lock(&g_state_lock);
    g_midi = *ch;
    pthread_mutex_unlock(&g_state_lock);
    /* Every handle's callback, on the callback queue, as Rane's (from its kernel extension's
       notification), with the value as it is stored: {a, b & 0xFF}. */
    RH_midi_ch_data_t v = { ch->a & 0xFF, ch->b & 0xFF };
    dispatch_async(g_poll_q, ^{
        int n;
        Client *cs = clients_snapshot(&n);
        for (int i = 0; i < n; i++) {
            if (!cs[i].midi) continue;
            RH_midi_ch_data_t copy = v;
            cs[i].midi(&copy);
        }
        free(cs);
    });
    return RET(RH_OK);
}

EXPORT int RH_set_midi_ch_callback(void *h, midi_cb_t cb) { return RET(SET_CALLBACK(h, midi, cb)); }

/* Rane's flushes its kernel extension's queue of outgoing Hidi messages; every message here is sent
   at once. As Rane's: 4 without a box (no kernel connection to ask). */
EXPORT int RH_flush_hidi_queue(void *h) {
    if (!handle_ok(h)) return RET(RH_ERR_BAD_ARG);
    return RET(is_connected() ? RH_OK : RH_ERR_NO_REPLY);
}

/* ============================================================================
 * Exported SL4_* functions: Rane's forward to the RH_* ones, except the sample-rate functions
 * ============================================================================ */

EXPORT void *SL4_open(void)                                         { return RH_open(); }
EXPORT void SL4_close(void *h)                                      { RH_close(h); }
EXPORT int SL4_get_vendor_id(void *h, int *v)                       { return RH_get_vendor_id(h, v); }
EXPORT int SL4_get_product_id(void *h, int *p)                      { return RH_get_product_id(h, p); }
EXPORT int SL4_get_api_version(SL4_version_t *v)                    { return RH_get_api_version(v); }
EXPORT int SL4_get_driver_version(void *h, SL4_version_t *v)        { return RH_get_driver_version(h, v); }
EXPORT int SL4_get_buffer_millisecs(void *h, int *ms)               { return RH_get_buffer_millisecs(h, ms); }
EXPORT int SL4_set_buffer_millisecs(void *h, int ms)                { return RH_set_buffer_millisecs(h, ms); }
EXPORT int SL4_get_usb_port_status(void *h, RH_usb_port_status_t *st) { return RH_get_usb_port_status(h, st); }
EXPORT int SL4_get_port_speed(void *h, int *speed)                  { return RH_get_port_speed(h, speed); }
EXPORT int SL4_driver_timer(void *h, const uint8_t *in, int inlen, uint8_t *out, int outlen) {
    return RH_driver_timer(h, in, inlen, out, outlen);
}
EXPORT int SL4_get_firmware_version(void *h, SL4_version_t *v)      { return RH_get_firmware_version(h, v); }
EXPORT int SL4_get_firmware_embedded_version(void *h, int v[2])     { return RH_get_firmware_embedded_version(h, v); }
EXPORT int SL4_get_all_controls(void *h)                            { return RH_get_all_controls(h); }
EXPORT int SL4_send_hidimsg(void *h, const RH_hidimsg_data_t *m)    { return RH_send_hidimsg(h, m); }
EXPORT int SL4_send_note_on(void *h, uint8_t note, uint8_t vel)     { return RH_send_note_on(h, note, vel); }
EXPORT int SL4_send_note_off(void *h, uint8_t note)                 { return RH_send_note_off(h, note); }
EXPORT int SL4_send_sys_ex(void *h, const void *d, uint8_t len)     { return RH_send_sys_ex(h, d, len); }
EXPORT int SL4_send_bridge_packet(void *h, const RH_bridgepacket_data_t *p) { return RH_send_bridge_packet(h, p); }
EXPORT int SL4_set_bridgepacket_callback(void *h, bridge_cb_t cb)   { return RH_set_bridgepacket_callback(h, cb); }
EXPORT int SL4_set_hidimsg_callback(void *h, hidi_cb_t cb)          { return RH_set_hidimsg_callback(h, cb); }
EXPORT int SL4_set_usb_port_status_callback(void *h, port_cb_t cb)  { return RH_set_usb_port_status_callback(h, cb); }
EXPORT int SL4_set_update_firmware(void *h, const uint8_t *img, unsigned int len, void (*cb)(RH_firmware_status_data_t *)) {
    return RH_set_update_firmware(h, img, len, cb);
}
EXPORT int SL4_set_update_firmware_from_embedded(void *h, void (*cb)(RH_firmware_status_data_t *)) {
    return RH_set_update_firmware_from_embedded(h, cb);
}
EXPORT int SL4_set_alt_product_id(void *h)                          { return RH_set_alt_product_id(h); }
EXPORT int SL4_is_boot_device(void *h, int *b)                      { return RH_is_boot_device(h, b); }
EXPORT int SL4_flush_hidi_queue(void *h)                            { return RH_flush_hidi_queue(h); }

/* The box's sample rate (0x4A): [5..7], big-endian, 48000 or 96000. The box chooses it; the host
   cannot set it. */
EXPORT int SL4_get_sample_rate(void *h, int *rate) {
    if (!rate || !handle_ok(h)) return RET(RH_ERR_BAD_ARG);
    uint8_t r[HID_REPORT_LEN];
    int e = hid_command(SL4_CMD_GET_RATE, NULL, 0, r);
    if (e) return RET(e);
    *rate = (r[5] << 16) | (r[6] << 8) | r[7];
    return RET(RH_OK);
}

/* Called with the box's new rate when it changes it (0x4B). */
EXPORT int SL4_set_samplerate_callback(void *h, rate_cb_t cb) { return RET(SET_CALLBACK(h, rate, cb)); }

/* ============================================================================
 * C++ entry points Rane's library also exports (mangled names, C linkage here)
 * ============================================================================ */

EXPORT void *_Z8RaneOpenv(void)              { return RH_open(); }
EXPORT void *_Z15RaneOpenPrivatei(int ms)    { return open_handle(ms); }
EXPORT void *_Z15RH_open_privatei(int ms)    { return open_handle(ms); }

/* The result of the last attempt to open Rane's kernel extension (its control panel warns on
   kIOReturnNotReady). There is no kernel extension to open here: always kIOReturnSuccess. */
EXPORT kern_return_t _Z32RH_private_last_connection_errorv(void) { return KERN_SUCCESS; }

/* SL4_set_samplerate(int), no handle: Rane's tells its kernel extension to reformat its audio engine
   to the box's rate (its settings service calls it with SL4_get_sample_rate's answer at connect).
   The HAL plug-in follows the box's rate by itself (0x4A at connect, 0x4B on a change), so there is
   nothing to do: 0, or 4 before any handle was opened, as Rane's (no kernel connection yet). */
EXPORT int _Z18SL4_set_sampleratei(int rate) {
    TRACE(": %d (the driver follows the box itself)", rate);
    pthread_mutex_lock(&g_state_lock);
    bool opened = g_ever_opened;
    pthread_mutex_unlock(&g_state_lock);
    return RET(opened ? RH_OK : RH_ERR_NO_REPLY);
}
