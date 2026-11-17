// SPDX-License-Identifier: GPL-3.0-or-later
// sl4apitest: check SL4Api the way Serato DJ Pro 2.5.5 uses it. Serato loads the framework from the
// path below and looks up ten functions; this loads it the same way, makes the same calls with
// Rane's signatures, and prints PASS or FAIL for each check.
//
//   make apitest
//   arch -x86_64 ./sl4apitest     Serato 2.5.5 is Intel-only, so this is the slice it loads
//   ./sl4apitest [path]           the arm64 slice, or another build of the framework
//
// Needs the driver installed and a box attached, with no audio playing: the test switches each of
// the four decks between analog thru and USB audio, and puts it back as it found it. Without a box
// it stops with FAIL after the port-status check.
#include <dlfcn.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

#define SERATO_PATH "/Library/Frameworks/SL4Api.framework/SL4Api"

enum { RH_OK = 0, RH_ERR_BAD_ARG = 8, RH_ERR_WRONG_REPLY = 11, RH_ERR_NOT_CONNECTED = 12 };
enum { NOTE_THRU_1 = 0x5C, NOTE_60 = 0x60, DECKS = 4 };
// The box's 0x40 reports are on MIDI channel 2: 0x91 = thru on (analog), 0x81 = off (USB audio).
enum { REPORT_ON = 0x91, REPORT_OFF = 0x81 };

typedef struct { uint8_t length; uint8_t data[58]; } RH_hidimsg_data_t;
typedef struct { uint8_t data[59]; } RH_bridgepacket_data_t;
typedef struct { int this_port, other_port; } RH_usb_port_status_t;

static void *(*SL4_open)(void);
static void (*SL4_close)(void *);
static int (*SL4_driver_timer)(void *, const uint8_t *, int, uint8_t *, int);
static int (*SL4_get_usb_port_status)(void *, RH_usb_port_status_t *);
static int (*SL4_send_bridge_packet)(void *, const RH_bridgepacket_data_t *);
static int (*SL4_set_bridgepacket_callback)(void *, void (*)(RH_bridgepacket_data_t *));
static int (*SL4_set_usb_port_status_callback)(void *, void (*)(RH_usb_port_status_t *));
static int (*SL4_get_all_controls)(void *);
static int (*SL4_send_hidimsg)(void *, const RH_hidimsg_data_t *);
static int (*SL4_set_hidimsg_callback)(void *, void (*)(RH_hidimsg_data_t *));

// What the callbacks delivered: the last report status for each note, and the port statuses.
static pthread_mutex_t g_mtx = PTHREAD_MUTEX_INITIALIZER;
static uint8_t g_note_status[128];
static int g_port_calls;
static RH_usb_port_status_t g_last_port;

static int g_failed;
static void check(int ok, const char *what) {
    printf("%s  %s\n", ok ? "PASS" : "FAIL", what);
    fflush(stdout);
    if (!ok) g_failed = 1;
}

// The hidimsg callback: a run of three-byte messages. Keep each note's status, as Serato reads them.
static void on_hidimsg(RH_hidimsg_data_t *m) {
    pthread_mutex_lock(&g_mtx);
    for (int i = 0; i + 2 < m->length; i += 3) {
        uint8_t st = m->data[i];
        if ((st & 0xE0) != 0x80) break;   // not a note message: the rest is not read
        g_note_status[m->data[i + 1] & 0x7F] = st;
    }
    pthread_mutex_unlock(&g_mtx);
}

static void on_port_status(RH_usb_port_status_t *ps) {
    pthread_mutex_lock(&g_mtx);
    g_port_calls++;
    g_last_port = *ps;
    pthread_mutex_unlock(&g_mtx);
}

static void on_bridge(RH_bridgepacket_data_t *b) { (void)b; }

static void forget_note(int note) {
    pthread_mutex_lock(&g_mtx);
    g_note_status[note] = 0;
    pthread_mutex_unlock(&g_mtx);
}

// Wait up to a second for a report of the note (the library polls the driver every 15 ms); its
// status, or 0 if none came.
static int wait_note(int note) {
    for (int i = 0; i < 100; i++) {
        usleep(10000);
        pthread_mutex_lock(&g_mtx);
        int st = g_note_status[note];
        pthread_mutex_unlock(&g_mtx);
        if (st) return st;
    }
    return 0;
}

// Ask for a state dump and return the note's reported status, or 0.
static int dump_note(void *h, int note) {
    forget_note(note);
    if (SL4_get_all_controls(h) != RH_OK) return 0;
    return wait_note(note);
}

// Send one thru message as Serato does ({3, 0x90 | 0x80, note, 0}) and return the box's 0x40
// confirmation for the note, or 0; *e gets send_hidimsg's result.
static int switch_thru(void *h, int note, int on, int *e) {
    forget_note(note);
    RH_hidimsg_data_t m = { .length = 3, .data = { on ? 0x90 : 0x80, (uint8_t)note, 0x00 } };
    *e = SL4_send_hidimsg(h, &m);
    return wait_note(note);
}

// Switch a deck to the other setting and back, each change confirmed by the box with a 0x40 report,
// which leaves the deck as it was.
static void check_thru(void *h, int deck) {
    char what[160];
    int note = NOTE_THRU_1 + deck - 1;
    int before = dump_note(h, note);
    snprintf(what, sizeof what, "deck %d: the state dump reports its thru note 0x%02X (status %02x)", deck, note, before);
    check(before == REPORT_ON || before == REPORT_OFF, what);
    if (before != REPORT_ON && before != REPORT_OFF) return;
    int was_on = before == REPORT_ON;
    // The other setting, then back.
    int e1, e2;
    int conf1 = switch_thru(h, note, !was_on, &e1);
    int conf2 = switch_thru(h, note, was_on, &e2);
    snprintf(what, sizeof what, "deck %d: send_hidimsg %s / %s accepted (%d, %d)", deck,
             was_on ? "Note Off" : "Note On", was_on ? "Note On" : "Note Off", e1, e2);
    check(e1 == RH_OK && e2 == RH_OK, what);
    snprintf(what, sizeof what, "deck %d: the box confirms each change with 0x40 (%02x, then %02x)", deck, conf1, conf2);
    check(conf1 == (was_on ? REPORT_OFF : REPORT_ON) && conf2 == before, what);
    snprintf(what, sizeof what, "deck %d: restored (%s)", deck, was_on ? "analog thru" : "USB audio");
    check(dump_note(h, note) == before, what);
}

int main(int argc, char **argv) {
    // Load the framework as Serato does, and look up the ten functions it uses.
    const char *path = argc > 1 ? argv[1] : SERATO_PATH;
#if defined(__x86_64__)
    printf("loading %s (x86_64)\n", path);
#else
    printf("loading %s (arm64)\n", path);
#endif
    void *lib = dlopen(path, RTLD_NOW);
    if (!lib) { printf("FAIL  dlopen: %s\n", dlerror()); return 1; }
    SL4_open = dlsym(lib, "SL4_open");
    SL4_close = dlsym(lib, "SL4_close");
    SL4_driver_timer = dlsym(lib, "SL4_driver_timer");
    SL4_get_usb_port_status = dlsym(lib, "SL4_get_usb_port_status");
    SL4_send_bridge_packet = dlsym(lib, "SL4_send_bridge_packet");
    SL4_set_bridgepacket_callback = dlsym(lib, "SL4_set_bridgepacket_callback");
    SL4_set_usb_port_status_callback = dlsym(lib, "SL4_set_usb_port_status_callback");
    SL4_get_all_controls = dlsym(lib, "SL4_get_all_controls");
    SL4_send_hidimsg = dlsym(lib, "SL4_send_hidimsg");
    SL4_set_hidimsg_callback = dlsym(lib, "SL4_set_hidimsg_callback");
    check(SL4_open && SL4_close && SL4_driver_timer && SL4_get_usb_port_status && SL4_send_bridge_packet &&
          SL4_set_bridgepacket_callback && SL4_set_usb_port_status_callback && SL4_get_all_controls &&
          SL4_send_hidimsg && SL4_set_hidimsg_callback, "all ten functions Serato uses are exported");
    if (g_failed) return 1;

    // Open and set the three callbacks straight away, as Serato does.
    char what[200];
    void *h = SL4_open();
    check(h != NULL, "SL4_open returns a handle");
    int e_h = SL4_set_hidimsg_callback(h, on_hidimsg);
    int e_p = SL4_set_usb_port_status_callback(h, on_port_status);
    int e_b = SL4_set_bridgepacket_callback(h, on_bridge);
    snprintf(what, sizeof what, "SL4_set_hidimsg / usb_port_status / bridgepacket_callback (%d, %d, %d)", e_h, e_p, e_b);
    check(e_h == RH_OK && e_p == RH_OK && e_b == RH_OK, what);
    check(SL4_set_hidimsg_callback((void *)0x7777, on_hidimsg) == RH_ERR_BAD_ARG, "a handle never opened is refused (8)");

    // The box is reported connected: this port 1 or 2, the other 0 (no computer) or the other number.
    RH_usb_port_status_t ps = { -1, -1 };
    int e = SL4_get_usb_port_status(h, &ps);
    snprintf(what, sizeof what, "SL4_get_usb_port_status -> %d {%d, %d} (expect 0 {1 or 2, 0 or the other})", e, ps.this_port, ps.other_port);
    int ports_ok = e == RH_OK && (ps.this_port == 1 || ps.this_port == 2) &&
                   (ps.other_port == 0 || ps.other_port == 3 - ps.this_port);
    check(ports_ok, what);
    if (e != RH_OK) {
        printf("%s: stopping\n", e == RH_ERR_NOT_CONNECTED ? "no box connected (or the driver has not opened it)" : "the box did not answer");
        printf("FAIL\n");
        return 1;
    }

    // The port-status callback was called at open with the same status.
    usleep(200000);
    pthread_mutex_lock(&g_mtx);
    int calls = g_port_calls;
    RH_usb_port_status_t cb = g_last_port;
    pthread_mutex_unlock(&g_mtx);
    snprintf(what, sizeof what, "the port-status callback was called at open (%d calls, last {%d, %d})", calls, cb.this_port, cb.other_port);
    check(calls >= 1 && cb.this_port == ps.this_port && cb.other_port == ps.other_port, what);

    // The genuine-hardware check: the box's 8-byte answer is a function of the 8-byte challenge.
    uint8_t c1[8] = { 0x01, 0x23, 0x45, 0x67, 0x89, 0xAB, 0xCD, 0xEF }, c2[8] = { 0xFE, 0xDC, 0xBA, 0x98, 0x76, 0x54, 0x32, 0x10 };
    uint8_t a1[8] = {0}, a1b[8] = {0}, a2[8] = {0}, zero[8] = {0};
    int e1 = SL4_driver_timer(h, c1, 8, a1, 8), e1b = SL4_driver_timer(h, c1, 8, a1b, 8), e2 = SL4_driver_timer(h, c2, 8, a2, 8);
    snprintf(what, sizeof what, "SL4_driver_timer (0x37) -> %d, %d, %d; answer %02x%02x%02x%02x%02x%02x%02x%02x", e1, e1b, e2,
             a1[0], a1[1], a1[2], a1[3], a1[4], a1[5], a1[6], a1[7]);
    check(e1 == RH_OK && e1b == RH_OK && e2 == RH_OK, what);
    check(memcmp(a1, zero, 8) != 0 && memcmp(a1, c1, 8) != 0, "SL4_driver_timer: the answer is non-zero and not the challenge echoed");
    check(memcmp(a1, a1b, 8) == 0, "SL4_driver_timer: the same challenge gives the same answer");
    check(memcmp(a1, a2, 8) != 0, "SL4_driver_timer: a different challenge gives a different answer");
    check(SL4_driver_timer(h, c1, 7, a1, 8) == RH_ERR_BAD_ARG, "SL4_driver_timer: a 7-byte challenge is refused (8)");

    // The state dump: the four thru notes and note 0x60 arrive through the hidimsg callback.
    int n60 = dump_note(h, NOTE_60);
    snprintf(what, sizeof what, "SL4_get_all_controls: the callback reports note 0x60 (status %02x)", n60);
    check(n60 == REPORT_ON || n60 == REPORT_OFF, what);

    // Per-deck thru, as Serato switches it.
    RH_hidimsg_data_t empty = { 0 };
    check(SL4_send_hidimsg(h, &empty) == RH_ERR_BAD_ARG, "SL4_send_hidimsg: an empty message is refused (8)");
    for (int d = 1; d <= DECKS; d++) check_thru(h, d);

    // A bridge packet: the box refuses it (11) unless a computer is connected to each port.
    RH_bridgepacket_data_t bp = { { 0 } };
    int eb = SL4_send_bridge_packet(h, &bp);
    int eb_expected = ps.other_port ? RH_OK : RH_ERR_WRONG_REPLY;
    snprintf(what, sizeof what, "SL4_send_bridge_packet -> %d (expect %d: %s)", eb, eb_expected,
             ps.other_port ? "a computer on the other port" : "no computer on the other port");
    check(eb == eb_expected, what);

    // Close; the handle is then refused.
    SL4_close(h);
    check(SL4_send_hidimsg(h, &empty) == RH_ERR_BAD_ARG && SL4_get_all_controls(h) == RH_ERR_BAD_ARG,
          "SL4_close: the handle is no longer accepted (8)");
    printf("%s\n", g_failed ? "FAIL" : "PASS: all checks");
    return g_failed;
}
