// SPDX-License-Identifier: GPL-3.0-or-later
/*
 * sl4dump — read what can be read safely from a Rane SL 4, and compare it with a firmware image.
 *
 *   sl4dump [--image FILE] [--save-table FILE]
 *     --image FILE       a firmware image (from tools/firmware/extract-sl4-firmware.py) to compare
 *                        the box with
 *     --save-table FILE  (a box in its updater) save the first page of its table sector to FILE
 *
 *   Exit status: 0 read (and, with --image, matching); 1 no box, a failed read, or a mismatch;
 *   2 bad arguments.
 *
 * Unlike the SL 2 and SL 3, whose firmware is in an EEPROM the running firmware can read back, the
 * SL 4's firmware is in its ARM's flash, and the protocol can read none of it from a running box,
 * and only the summary table sector (0x4000-0x4FFF) from a box in its updater
 * (docs/SL4-COMMANDS.md, "Firmware storage and update"). So sl4dump reads:
 *
 *   - a running box (bcdDevice 0x0100), through the HAL driver's 'sl4h' passthrough
 *     (tools/SL4Passthrough.h): the firmware version and build stamp (0x01), the updater flag
 *     (0x13), its USB port and the other port's state (0x45), its USB state (0x0a) and its sample
 *     rate (0x4A). A box that runs at all has passed its boot program's check of every flash section
 *     against its table at its last reset, so the version is what there is to compare;
 *   - a box in its firmware updater (bcdDevice 0x9900), opened directly (the driver leaves it
 *     alone): the updater flag (0x13), the updater's version (0x01), and the summary table (0x15),
 *     whose entries are compared with the image's, and whose own CRC says whether the box would
 *     start its firmware (an invalid one, with byte 0x0A one too high, is what 0x17 leaves).
 *
 * It never sends 0x17 (the only way from a running box into the updater, which invalidates the
 * firmware) nor any command that writes or restarts the box. Build: see tools/firmware/README.md.
 */
#define SL4FLASH_NO_MAIN
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wunused-function"
#include "firmware/sl4flash.m"   /* the image, USB and updater helpers, shared with the flasher */
#pragma clang diagnostic pop

/* A running box, through the driver: the read-only queries, printed. */
static int dump_running(const image_t *im) {
    AudioObjectID hal = sl4h_find_device();
    if (hal == kAudioObjectUnknown) { printf("the SL 4 driver has no device for the box (is it installed and loaded?)\n"); return 1; }
    uint8_t req[SL4_REPORT] = { SL4_CMD_VERSION }, reply[SL4_REPORT];
    if (!sl4h_command(hal, req, reply)) { printf("the box doesn't answer its version (0x01) through the driver\n"); return 1; }
    uint8_t maj = reply[5], min = reply[6];
    printf("firmware version  %u.%02u (build stamp %08x)\n", maj, min, be32(reply + 7));
    running_t r;
    if (!query_running(hal, &r)) { printf("the box doesn't answer its updater flag (0x13)\n"); return 1; }
    printf("updater flag      %u (%s)\n", r.boot, r.boot ? "says it is in its updater" : "running firmware");
    if (r.have_ports) printf("USB ports         this computer on %c (index %u); the other port: %s\n", r.port ? 'B' : 'A', r.port, r.other ? "a computer" : "nothing");
    else printf("USB ports         no answer to 0x45\n");
    if (r.have_usb) printf("USB state         %u (%s)\n", r.usb, r.usb == 2 ? "high speed" : r.usb == 1 ? "full speed: no audio" : "not configured");
    else printf("USB state         no answer to 0x0a\n");
    if (r.have_rate) printf("sample rate       %u Hz (set on the box)\n", r.rate);
    else printf("sample rate       no answer to 0x4A\n");
    printf("audio             %s\n", sl4h_is_streaming(hal) ? "in use" : "idle");

    if (!im) return 0;
    bool same = maj == im->maj && min == im->min;
    printf("image             %u.%02u: the box runs %s\n", im->maj, im->min, same ? "the same version" : "a different version");
    printf("(its flash itself can't be read: the box's boot program checked every section against the box's table at its\n"
           " last reset; comparing that table with the image's needs the updater, which sl4dump doesn't enter)\n");
    return same ? 0 : 1;
}

/* A box in its updater, opened directly: its flag, version and summary table. */
static int dump_updater(io_service_t svc, const image_t *im, const char *save) {
    if (!updater_open(svc)) return 1;
    uint8_t req[SL4_REPORT] = { SL4_CMD_BOOT_DEV }, reply[SL4_REPORT];
    if (updater_command(req, reply)) printf("updater flag      %u\n", reply[5]);
    else printf("updater flag      %s\n", reply_meaning(reply[0]));
    memset(req, 0, sizeof req); req[0] = SL4_CMD_VERSION;
    if (updater_command(req, reply)) printf("updater version   %u.%02u (build stamp %08x; the updater's own)\n", reply[5], reply[6], be32(reply + 7));
    else printf("updater version   %s\n", reply_meaning(reply[0]));

    devtable_t dev;
    bool ok = read_device_table(&dev);
    updater_close();
    if (!ok) { printf("could not read the summary table\n"); return 1; }
    print_device_table(&dev, im);
    uint8_t fixed[PAGE];
    if (table_only_marked_by_0x17(&dev, fixed))
        printf("the table differs from a valid one only by the mark 0x17 leaves (byte 0x0A one higher): an update that\n"
               "stopped before writing anything. `sl4flash --leave-updater` (untested) or a full sl4flash brings it back.\n");
    else if (dev.valid_crc)
        printf("the table itself is valid, so a section fails its CRC check (an update that did not finish): run sl4flash\n");

    if (save) {
        FILE *f = fopen(save, "wb");
        bool w = f && fwrite(dev.raw, 1, PAGE, f) == PAGE;
        if (f) fclose(f);
        printf(w ? "saved the table page to %s\n" : "could not write %s\n", save);
        if (!w) return 1;
    }
    if (!im) return 0;
    bool same = dev.len == im->sec[0].len && memcmp(dev.raw, (const uint8_t *)im->data.bytes + im->sec[0].off, im->sec[0].len) == 0;
    printf(same ? "the box's table is the image's\n" : "the box's table differs from the image's\n");
    return same ? 0 : 1;
}

int main(int argc, char **argv) {
  @autoreleasepool {
    const char *image = NULL, *save = NULL;
    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--image") && i + 1 < argc) image = argv[++i];
        else if (!strcmp(argv[i], "--save-table") && i + 1 < argc) save = argv[++i];
        else { fprintf(stderr, "usage: %s [--image FILE] [--save-table FILE]\n", argv[0]); return 2; }
    }
    image_t im = {0};
    if (image && !load_image(image, &im)) return 1;

    /* The box: exactly one SL 4 USB device. */
    box_t b[4];
    int n = find_boxes(b, 4);
    if (n == 0) { printf("no SL 4 found\n"); return 1; }
    if (n > 1) { printf("%d SL 4 USB devices are connected (both of the box's USB ports, or two boxes); connect only one\n", n); release_boxes(b, n); return 1; }
    printf("SL 4 on USB       %04x:%04x, bcdDevice 0x%04x (%s)\n", SL4_VID, b[0].pid, b[0].bcd,
           b[0].pid == SL4_PID_ALT ? "alternate identity, set by 0x1a" :
           b[0].bcd == BCD_RUNNING ? "running firmware" : b[0].bcd == BCD_UPDATER ? "firmware updater: no firmware running" : "unknown");
    int rc;
    if (b[0].pid == SL4_PID_ALT) { printf("(power-cycle it to return it to its normal identity)\n"); rc = 1; }
    else if (b[0].bcd == BCD_UPDATER) rc = dump_updater(b[0].svc, image ? &im : NULL, save);
    else if (b[0].bcd == BCD_RUNNING) {
        if (save) printf("(--save-table needs a box in its updater; ignored)\n");
        rc = dump_running(image ? &im : NULL);
    } else rc = 1;
    release_boxes(b, n);
    return rc;
  }
}
