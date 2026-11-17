// SPDX-License-Identifier: GPL-3.0-or-later
/*
 * sl4flash — write the Rane SL 4's firmware into its ARM's flash over USB, with Rane's own update
 * sequence.
 *
 *   sl4flash [--firmware PATH] [--check] [--force] [--yes] [--wait SECONDS]
 *   sl4flash --leave-updater [--check] [--yes] [--wait SECONDS]
 *     --firmware PATH  the firmware image, or a directory holding it (*.bin, recognised by its
 *                      header); default: /Library/Audio/Plug-Ins/HAL/SL4Device.firmware
 *     --check          check the image and the box and say what would be done; change nothing.
 *                      A running box is only asked 0x01, 0x13, 0x45, 0x0a and 0x4A; a box already
 *                      in its updater is also read its summary table (0x15)
 *     --force          write an image that is not newer than the firmware the box runs, or that
 *                      is not Rane's known 1.02 build (it must still pass every check Rane makes)
 *     --yes            don't ask before changing the box
 *     --wait SECONDS   wait up to this long for a box to be connected
 *     --leave-updater  UNTESTED. For a box left in its updater by 0x17 alone (an update that
 *                      stopped before writing anything): repair the summary table's own CRC and
 *                      restart the box into the firmware it already holds, without a reflash
 *
 *   Exit status: 0 done, or nothing to do; 1 failed or refused; 2 bad arguments; 3 (--check only)
 *   the box would be written.
 *
 * The box. The SL 4's ARM (an LPC2148-class ARM7, 512 KiB of flash) holds a protected boot program
 * at 0x0000-0x3FFF, a summary table at 0x4000 (one {address, length, CRC} entry per section, entry
 * 0 for the table itself), a copy of the boot program at 0x5000, the application at 0x8000, the
 * FPGA bitstream at 0x68000 and the FX2 (USB controller) firmware at 0x7A000. At every reset the
 * boot program checks the table's own CRC and every section's CRC; only if all match does it start
 * the application (the box enumerates as 1CC5:000F, bcdDevice 0x0100). Otherwise it stays in its
 * firmware updater (bcdDevice 0x9900, HID only), which accepts:
 *   0x15  read up to 54 bytes of the table sector (0x4000-0x4FFF only)
 *   0x14  write 32 bytes; eight blocks in address order make a 256-byte page, programmed when the
 *         eighth (address ...E0) arrives, which is the only one answered. The first page written
 *         to a sector erases the whole sector. Pages below 0x4000 are refused (0xFE). The first
 *         0x14 claims the updater for its USB port; the other port then gets 0xFD
 *   0x16  finish: the box resets, and the boot program checks every CRC again
 * The running application accepts 0x17, which corrupts the table's own CRC (adds 1 to its byte 0x0A)
 * and resets the box, so that it comes up in the updater, and stays there at every power-up until
 * the table and sections are valid again.
 *
 * The sequence is Rane's (ASL4ApiState::UpdateFirmware in SL4Api 2.0.1f1), from docs/SL4-COMMANDS.md
 * ("Firmware storage and update"): 0x13 says whether the box is in its updater already; if it is
 * running, 0x17 and wait for the updater to enumerate; 0x15 reads the box's table; each section
 * is written in table order, the table first, skipping a section only if the box was running before
 * and its CRC in the box's table equals the image's; then 0x16, and wait for the box to come back.
 * sl4flash adds: the downgrade check (Rane's panel only offers newer firmware), a refusal while the
 * box streams audio or has a second computer on its other USB port, a backup of the box's table,
 * a read-back of the written table before 0x16, and the check of the result (Rane checks none).
 *
 * What can be verified, and what can't. The protocol has no way to read the flash back outside the
 * table sector, so sl4flash cannot compare what it wrote with the image, except the table. Each
 * written page is acknowledged by the box only as programmed. The final check is the box's own: at
 * the reset after 0x16 its boot program compares every section's CRC with the table, and starts the
 * firmware only if all match; sl4flash then reads the version (0x01) and the updater flag (0x13). A
 * section that was written wrongly, or an update interrupted at any point after 0x17 (USB unplugged,
 * power lost), leaves the box in its updater, where it can be reflashed over USB: the boot program
 * and its own USB firmware are below 0x4000, which the updater refuses to write. All of this is
 * according to the analysis of Rane's code, and untested: nobody working on this has had an SL 4.
 *
 * Transport. A running box is reached through the HAL driver's 'sl4h' passthrough
 * (tools/SL4Passthrough.h), so the driver must be installed and no other 'sl4h' client (sl4panel,
 * the control panel, Serato) may run during an update. The driver doesn't open a box in its updater,
 * so sl4flash opens that one directly with IOUSBHost (its HID-class interface; no root needed).
 * tools/sl4dump.m includes this file, with SL4FLASH_NO_MAIN, for its image and updater helpers.
 *
 * The image comes from the user's own copy of Rane's driver (tools/firmware/extract-sl4-firmware.py);
 * it is not distributed with this project.
 */
#import <Foundation/Foundation.h>
#import <IOKit/IOKitLib.h>
#import <IOKit/usb/IOUSBLib.h>
#import <IOUSBHost/IOUSBHost.h>
#import <CommonCrypto/CommonDigest.h>
#include <stdatomic.h>
#include <stdio.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
#import "SL4Passthrough.h"

#define SL4_VID          0x1cc5
#define SL4_PID          0x000f
#define SL4_PID_ALT      0x0010   /* the identity 0x1a selects until a power cycle or 0x1b */
#define BCD_RUNNING      0x0100   /* running firmware */
#define BCD_UPDATER      0x9900   /* the boot program's firmware updater */

/* Update commands (wire layout: [0] opcode, [1..4] tag, [5..] arguments). */
#define SL4_CMD_FLASH_WRITE   0x14     /* updater: [5..8] BE flash address (32-aligned), [9..40] 32 bytes.
                                     Answered only for the page's last block (address ...E0): [0] 0x14,
                                     [5..8] the address; 0xFE refused, 0xFD the other port owns the update */
#define SL4_CMD_FLASH_READ    0x15     /* updater: [5..8] BE address, [9] count <= 54, within 0x4000-0x4FFF.
                                     Reply [5..8] address, [9] count, [10..] data; 0xFE out of range */
#define SL4_CMD_FINISH        0x16     /* updater: reply 0x16, then the box resets; 0xFD the other port owns it */
#define SL4_CMD_ENTER_UPDATER 0x17     /* running firmware: corrupts the table's CRC and resets into the updater.
                                     Reply 0x17; 0xFE the flash operation failed */
#define REPLY_UNKNOWN    0xFF
#define REPLY_REFUSED    0xFE
#define REPLY_OTHER_PORT 0xFD

#define REPLY_TIMEOUT    5.0      /* seconds, as Rane's API */
#define FLASH_READ_MAX   54
#define BLOCK            32
#define PAGE             256
#define TABLE_FLASH      0x4000
#define TABLE_SECTOR_END 0x5000
#define FLASH_END        0x7D000
#define ENTRY_LEN        12
#define MAX_ENTRIES      (PAGE / ENTRY_LEN)
#define HDR_LEN          0x40
#define SELF_CRC_BYTE    0x0A     /* the table byte 0x17 adds 1 to (entry 0's CRC, byte 2) */

#define EXIT_WOULD_WRITE 3

static const char *kDefaultFirmware = "/Library/Audio/Plug-Ins/HAL/SL4Device.firmware";
/* Rane's 1.02 image (SL4Api 2.0.1f1), as extract-sl4-firmware.py writes it. */
static const char *kKnownImageSHA256 = "93f22e8e241e1ad273f250a3fecd0684b36acd6b33bf2113a27b1f3266312aa1";

/* ---- CRCs ---- */

/* The CRC-32 register over p (reflected, poly 0x04C11DB7, from 0xFFFFFFFF), before any final xor. */
static uint32_t crc32_reg(const uint8_t *p, size_t n) {
    uint32_t c = 0xFFFFFFFFu;
    for (size_t i = 0; i < n; i++) { c ^= p[i]; for (int k = 0; k < 8; k++) c = (c >> 1) ^ (0xEDB88320u & (0u - (c & 1u))); }
    return c;
}

/* Standard CRC-32 (zlib's): the image header's CRC of the body. */
static uint32_t crc32_std(const uint8_t *p, size_t n) { return crc32_reg(p, n) ^ 0xFFFFFFFFu; }

/* The summary table's CRC: the register bit-reversed, with no final xor (Rane's CalcChecksum(...,
   false); the boot program computes the same). */
static uint32_t crc_raw(const uint8_t *p, size_t n) {
    uint32_t c = crc32_reg(p, n), r = 0;
    for (int i = 0; i < 32; i++) { r = (r << 1) | (c & 1u); c >>= 1; }
    return r;
}

static uint32_t be32(const uint8_t *p) { return (uint32_t)p[0] << 24 | (uint32_t)p[1] << 16 | (uint32_t)p[2] << 8 | p[3]; }
static uint32_t le32(const uint8_t *p) { return (uint32_t)p[3] << 24 | (uint32_t)p[2] << 16 | (uint32_t)p[1] << 8 | p[0]; }
static void put_be32(uint8_t *p, uint32_t v) { p[0] = v >> 24; p[1] = v >> 16; p[2] = v >> 8; p[3] = (uint8_t)v; }

/* ---- the firmware image ---- */

typedef struct { uint32_t addr, len, crc, off; } section_t;   /* off: where its data is in the image */
typedef struct {
    NSData *data;
    NSString *path;
    section_t sec[MAX_ENTRIES];
    int nsec;
    uint8_t maj, min;
    bool known;                 /* Rane's 1.02 build, by SHA-256 */
} image_t;

static const uint8_t kCopyright[32] = "Copyright 20?? Rane Corporation";
static const uint8_t kTestBytes[7] = { 0x02, 0x1C, 0xC5, 0x00, 0x0F, 0x01, 0x00 };   /* type, VID, PID, 01 00 */

/* A file that starts like an SL 4 image (the copyright's fixed start and the test bytes). */
static bool looks_like_image(NSData *d) {
    return d.length >= HDR_LEN && memcmp(d.bytes, kCopyright, 12) == 0 && memcmp((const uint8_t *)d.bytes + 0x20, kTestBytes, 7) == 0;
}

/* Check the image exactly as Rane's IsValidFirmwareImage does, then the layout the boot program
   and the write protocol rely on (as extract-sl4-firmware.py). Fills im->sec. */
static bool validate_image(image_t *im) {
    const uint8_t *img = im->data.bytes;
    size_t size = im->data.length;
    const char *name = im->path.UTF8String;

    /* IsValidFirmwareImage: size, copyright (the year, bytes 12-13, not compared), test bytes,
       body length, body CRC-32. */
    if (size < 0x4C) { printf("%s: too short for an SL 4 image\n", name); return false; }
    for (int i = 0; i < 32; i++)
        if ((i & ~1) != 0x0C && img[i] != kCopyright[i]) { printf("%s: no Rane copyright header\n", name); return false; }
    if (memcmp(img + 0x20, kTestBytes, sizeof kTestBytes) != 0) { printf("%s: not an SL 4 image (header bytes 0x20-0x26)\n", name); return false; }
    uint32_t body = be32(img + 0x38);
    if ((uint64_t)body + HDR_LEN != size) { printf("%s: header says 0x%x body bytes, the file has 0x%zx\n", name, body, size - HDR_LEN); return false; }
    uint32_t crc = crc32_std(img + HDR_LEN, body);
    if (crc != be32(img + 0x3C)) { printf("%s: body CRC-32 %08x does not match the header's %08x\n", name, crc, be32(img + 0x3C)); return false; }

    /* IsValidFirmwareImage: the summary table. Entries up to the first with address 0; each
       section's data follows the previous one and fits in the file; entry 0's CRC covers the table
       after itself, each other entry's its section. */
    uint32_t tlen = le32(img + HDR_LEN + 4);
    if (tlen < ENTRY_LEN || HDR_LEN + (uint64_t)tlen > size) { printf("%s: summary table length 0x%x doesn't fit\n", name, tlen); return false; }
    uint32_t off = HDR_LEN;
    bool terminated = false;
    im->nsec = 0;
    for (uint32_t i = 0; i < tlen / ENTRY_LEN && i < MAX_ENTRIES; i++) {
        const uint8_t *e = img + HDR_LEN + i * ENTRY_LEN;
        section_t s = { le32(e), le32(e + 4), le32(e + 8), off };
        if (s.addr == 0) { terminated = true; break; }
        if ((uint64_t)off + s.len > size) { printf("%s: section %u runs past the end of the file\n", name, i); return false; }
        uint32_t c = i == 0 ? crc_raw(img + HDR_LEN + ENTRY_LEN, tlen - ENTRY_LEN) : crc_raw(img + off, s.len);
        if (c != s.crc) { printf("%s: section %u (flash 0x%05x) CRC %08x, table says %08x\n", name, i, s.addr, c, s.crc); return false; }
        im->sec[im->nsec++] = s;
        off += s.len;
    }

    /* Not Rane's checks: a terminator (the boot program requires one); the table at 0x4000 within
       its page; whole pages; nothing below 0x4000 or past the flash; sections in order; the body
       exactly the sections. */
    if (!terminated) { printf("%s: the summary table has no terminating entry\n", name); return false; }
    if (im->sec[0].addr != TABLE_FLASH || tlen > PAGE) { printf("%s: the summary table is not one page at 0x4000\n", name); return false; }
    uint32_t prev_end = 0;
    for (int i = 0; i < im->nsec; i++) {
        section_t *s = &im->sec[i];
        if (!s->len || s->len % PAGE || s->addr % PAGE || s->addr < TABLE_FLASH || s->addr + s->len > FLASH_END || s->addr < prev_end) {
            printf("%s: section %d (flash 0x%05x, 0x%x bytes) is not a page-aligned area of 0x4000-0x7CFFF after the previous one\n",
                   name, i, s->addr, s->len);
            return false;
        }
        prev_end = s->addr + s->len;
    }
    if (off != size) { printf("%s: the sections don't fill the image\n", name); return false; }

    /* The version and whether this is Rane's build. */
    im->maj = img[0x27];
    im->min = img[0x28];
    uint8_t sha[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(img, (CC_LONG)size, sha);
    char hex[2 * CC_SHA256_DIGEST_LENGTH + 1];
    for (int i = 0; i < CC_SHA256_DIGEST_LENGTH; i++) snprintf(hex + 2 * i, 3, "%02x", sha[i]);
    im->known = strcmp(hex, kKnownImageSHA256) == 0;
    return true;
}

/* The image: PATH itself, or the one SL 4 image in the directory PATH. */
static bool load_image(const char *path, image_t *im) {
    NSString *p = [NSString stringWithUTF8String:path];
    BOOL dir = NO;
    if (![[NSFileManager defaultManager] fileExistsAtPath:p isDirectory:&dir]) { printf("no firmware at %s\n", path); return false; }
    if (dir) {
        NSArray *files = [[[NSFileManager defaultManager] contentsOfDirectoryAtPath:p error:nil] sortedArrayUsingSelector:@selector(compare:)];
        for (NSString *f in files) {
            if (![f.pathExtension isEqualToString:@"bin"]) continue;
            NSString *full = [p stringByAppendingPathComponent:f];
            NSData *x = [NSData dataWithContentsOfFile:full];
            if (!x || !looks_like_image(x)) continue;
            if (im->data && ![im->data isEqualToData:x]) {
                printf("both %s and %s are SL 4 images; leave only one, or name it with --firmware\n", im->path.UTF8String, full.UTF8String);
                return false;
            }
            if (!im->data) { im->data = x; im->path = full; }
        }
        if (!im->data) { printf("no SL 4 firmware image in %s (see tools/firmware/README.md)\n", path); return false; }
    } else {
        im->data = [NSData dataWithContentsOfFile:p];
        im->path = p;
        if (!im->data) { printf("cannot read %s\n", path); return false; }
    }
    if (!validate_image(im)) return false;
    printf("image %s: firmware %u.%02u, %d sections, %s\n", im->path.UTF8String, im->maj, im->min, im->nsec,
           im->known ? "Rane's 1.02 build" : "NOT Rane's known build (it passes Rane's checks)");
    return true;
}

/* ---- finding the box ---- */

typedef struct { io_service_t svc; int pid; int bcd; uint64_t id; } box_t;

static int svc_int(io_service_t s, CFStringRef key) {
    CFTypeRef v = IORegistryEntryCreateCFProperty(s, key, kCFAllocatorDefault, 0);
    int r = -1;
    if (v && CFGetTypeID(v) == CFNumberGetTypeID()) CFNumberGetValue(v, kCFNumberIntType, &r);
    if (v) CFRelease(v);
    return r;
}

static int find_pid(int pid, box_t *out, int n, int max) {
    CFMutableDictionaryRef m = IOServiceMatching(kIOUSBDeviceClassName);
    int vid = SL4_VID;
    CFNumberRef vn = CFNumberCreate(NULL, kCFNumberIntType, &vid), pn = CFNumberCreate(NULL, kCFNumberIntType, &pid);
    CFDictionarySetValue(m, CFSTR(kUSBVendorID), vn);
    CFDictionarySetValue(m, CFSTR(kUSBProductID), pn);
    CFRelease(vn); CFRelease(pn);
    io_iterator_t it = 0;
    if (IOServiceGetMatchingServices(kIOMainPortDefault, m, &it) != KERN_SUCCESS) return n;
    io_service_t s;
    while ((s = IOIteratorNext(it))) {
        if (n == max) { IOObjectRelease(s); continue; }
        out[n] = (box_t){ s, pid, svc_int(s, CFSTR(kUSBDeviceReleaseNumber)), 0 };
        IORegistryEntryGetRegistryEntryID(s, &out[n].id);
        n++;
    }
    IOObjectRelease(it);
    return n;
}

/* Every attached SL 4, under either product ID. */
static int find_boxes(box_t *out, int max) { return find_pid(SL4_PID_ALT, out, find_pid(SL4_PID, out, 0, max), max); }
static void release_boxes(box_t *b, int n) { for (int i = 0; i < n; i++) IOObjectRelease(b[i].svc); }

/* ---- the box in its updater, opened directly ---- */

static IOUSBHostDevice    *g_dev;
static IOUSBHostInterface *g_intf;
static IOUSBHostPipe      *g_in, *g_out;
static dispatch_queue_t    g_q;
static NSMutableArray     *g_reports;     /* IN reports not yet claimed, oldest first */
static dispatch_semaphore_t g_report_sem;
static _Atomic bool        g_closing;
static uint32_t            g_tag = 0x53340000;

/* Keep one read queued on the interrupt IN pipe, as Rane's kext does, and collect every report: a
   reply nobody waits for then never holds up the box's next one. */
static void read_next(void) {
    NSMutableData *buf = [NSMutableData dataWithLength:SL4_REPORT];
    NSError *e = nil;
    [g_in enqueueIORequestWithData:buf completionTimeout:0 error:&e completionHandler:^(IOReturn st, NSUInteger n) {
        if (st == kIOReturnSuccess && n > 0) {
            @synchronized (g_reports) { [g_reports addObject:[NSData dataWithBytes:buf.bytes length:n]]; }
            dispatch_semaphore_signal(g_report_sem);
        }
        if (atomic_load(&g_closing) || st == kIOReturnAborted || st == kIOReturnNoDevice || st == kIOReturnNotResponding) return;
        if (st != kIOReturnSuccess) { [g_in clearStallWithError:nil]; usleep(10000); }
        read_next();
    }];
}

/* The box's HID-class interface (interface 3 at high speed, 0 at full speed), opened, or nil.
   *holder gets the name of a driver holding it, if one does. */
static IOUSBHostInterface *open_hid_interface(NSString **holder, NSError **err) {
    IOUSBHostInterface *found = nil;
    *holder = nil;
    io_iterator_t it = 0;
    IORegistryEntryGetChildIterator(g_dev.ioService, kIOServicePlane, &it);
    io_service_t ch;
    while ((ch = IOIteratorNext(it))) {
        if (!found && svc_int(ch, CFSTR("bInterfaceClass")) == kUSBHIDInterfaceClass) {
            found = [[IOUSBHostInterface alloc] initWithIOService:ch options:IOUSBHostObjectInitOptionsNone queue:g_q error:err interestHandler:nil];
            if (!found) {
                CFTypeRef o = IORegistryEntryCreateCFProperty(ch, CFSTR("UsbExclusiveOwner"), kCFAllocatorDefault, 0);
                if (o && CFGetTypeID(o) == CFStringGetTypeID()) *holder = (__bridge_transfer NSString *)o;
                else if (o) CFRelease(o);
            }
        }
        IOObjectRelease(ch);
    }
    IOObjectRelease(it);
    return found;
}

/* The interface's first interrupt endpoint in direction dir, else the SL 4's usual address. */
static IOUSBHostPipe *interrupt_pipe(uint8_t dir, uint8_t fallback) {
    const IOUSBConfigurationDescriptor *cfg = g_intf.configurationDescriptor;
    const IOUSBInterfaceDescriptor *ifd = g_intf.interfaceDescriptor;
    NSError *e = nil;
    if (cfg && ifd) {
        const IOUSBEndpointDescriptor *ep = NULL;
        while ((ep = IOUSBGetNextEndpointDescriptor(cfg, ifd, (const IOUSBDescriptorHeader *)ep)) != NULL)
            if (IOUSBGetEndpointDirection(ep) == dir && IOUSBGetEndpointType(ep) == kIOUSBEndpointTypeInterrupt)
                return [g_intf copyPipeWithAddress:ep->bEndpointAddress error:&e];
    }
    return [g_intf copyPipeWithAddress:fallback error:&e];
}

static void updater_close(void) {
    atomic_store(&g_closing, true);
    if (g_in) [g_in abortWithError:nil];
    if (g_intf) [g_intf destroy];
    if (g_dev) [g_dev destroy];
    g_in = g_out = nil; g_intf = nil; g_dev = nil;
}

/* Open the box in its updater: the device, configured with its interfaces not offered to other
   drivers; its HID interface; the two interrupt pipes. Retries for a few seconds, since the
   interfaces appear only after the device has been configured. */
static bool updater_open(io_service_t svc) {
    if (!g_q) g_q = dispatch_queue_create("sl4flash.usb", DISPATCH_QUEUE_SERIAL);
    if (!g_report_sem) g_report_sem = dispatch_semaphore_create(0);
    g_reports = [NSMutableArray array];
    atomic_store(&g_closing, false);
    NSError *e = nil;
    for (int attempt = 0; attempt < 20 && !g_dev; attempt++) {
        g_dev = [[IOUSBHostDevice alloc] initWithIOService:svc options:IOUSBHostObjectInitOptionsNone queue:g_q error:&e interestHandler:nil];
        if (!g_dev) usleep(250000);
    }
    if (!g_dev) { printf("cannot open the box: %s\n", e.localizedDescription.UTF8String); return false; }
    if (!g_dev.configurationDescriptor) [g_dev configureWithValue:1 matchInterfaces:NO error:&e];

    /* The HID interface. If macOS's HID driver took it (the box was configured with its interfaces
       offered for matching), set the configuration again once: that ends the interface and its
       driver, and the new one is offered to nobody. */
    bool reconfigured = false;
    NSString *holder = nil;
    for (int attempt = 0; attempt < 20 && !g_intf; attempt++) {
        g_intf = open_hid_interface(&holder, &e);
        if (!g_intf && holder && !reconfigured) {
            printf("the box's HID interface is held by %s: setting the box's configuration again\n", holder.UTF8String);
            [g_dev configureWithValue:0 matchInterfaces:NO error:&e];
            [g_dev configureWithValue:1 matchInterfaces:NO error:&e];
            reconfigured = true;
        }
        if (!g_intf) usleep(250000);
    }
    if (!g_intf) {
        printf("cannot open the box's HID interface: %s\n", e ? e.localizedDescription.UTF8String : "it has none");
        updater_close();
        return false;
    }

    /* The pipes, reset (a previous client may have left the endpoints' data toggles out of step),
       and the first read queued. */
    g_out = interrupt_pipe(kIOUSBEndpointDirectionOut, 0x01);
    g_in  = interrupt_pipe(kIOUSBEndpointDirectionIn, 0x81);
    if (!g_out || !g_in) { printf("the box's HID interface has no interrupt pipes\n"); updater_close(); return false; }
    [g_out clearStallWithError:nil];
    [g_in clearStallWithError:nil];
    read_next();
    return true;
}

/* Send one report: [0] opcode, [1..4] a fresh tag, [5..] req's arguments. Returns the tag, or 0 if
   the box did not take the report. */
static uint32_t updater_send(uint8_t req[SL4_REPORT]) {
    uint32_t tag = ++g_tag;
    memcpy(req + 1, &tag, 4);
    NSMutableData *d = [NSMutableData dataWithBytes:req length:SL4_REPORT];
    NSUInteger sent = 0;
    NSError *e = nil;
    if (![g_out sendIORequestWithData:d bytesTransferred:&sent completionTimeout:REPLY_TIMEOUT error:&e] || sent != SL4_REPORT) {
        printf("\nsending command 0x%02x failed: %s\n", req[0], e ? e.localizedDescription.UTF8String : "short transfer");
        return 0;
    }
    return tag;
}

/* Send a command and wait for the report carrying its tag. True if the reply echoes the opcode;
   reply holds whatever came back (all zero on a timeout). */
static bool updater_command(uint8_t req[SL4_REPORT], uint8_t reply[SL4_REPORT]) {
    memset(reply, 0, SL4_REPORT);
    uint32_t tag = updater_send(req);
    if (!tag) return false;
    dispatch_time_t deadline = dispatch_time(DISPATCH_TIME_NOW, (int64_t)(REPLY_TIMEOUT * NSEC_PER_SEC));
    for (;;) {
        /* Take the reply if it has come; drop anything else (replies to earlier commands). */
        NSData *match = nil;
        @synchronized (g_reports) {
            while (g_reports.count && !match) {
                NSData *r = g_reports[0];
                [g_reports removeObjectAtIndex:0];
                if (r.length >= 5 && memcmp((const uint8_t *)r.bytes + 1, &tag, 4) == 0) match = r;
            }
        }
        if (match) {
            memcpy(reply, match.bytes, match.length < SL4_REPORT ? match.length : SL4_REPORT);
            return reply[0] == req[0];
        }
        if (dispatch_semaphore_wait(g_report_sem, deadline) != 0) return false;
    }
}

static const char *reply_meaning(uint8_t op) {
    switch (op) {
        case REPLY_UNKNOWN:    return "unknown command (0xFF)";
        case REPLY_REFUSED:    return "refused (0xFE)";
        case REPLY_OTHER_PORT: return "the update belongs to the box's other USB port (0xFD)";
        case 0:                return "no reply within 5 s";
        default:               return "unexpected reply";
    }
}

/* 0x15: count (<= 54) bytes of the table sector at addr. */
static bool flash_read(uint32_t addr, uint8_t count, uint8_t *out) {
    uint8_t req[SL4_REPORT] = { SL4_CMD_FLASH_READ }, reply[SL4_REPORT];
    put_be32(req + 5, addr);
    req[9] = count;
    if (!updater_command(req, reply)) { printf("reading flash 0x%05x: %s\n", addr, reply_meaning(reply[0])); return false; }
    if (be32(reply + 5) != addr || reply[9] != count) { printf("reading flash 0x%05x: the reply is for another address or length\n", addr); return false; }
    memcpy(out, reply + 10, count);
    return true;
}

static bool flash_read_range(uint32_t addr, uint32_t len, uint8_t *out) {
    for (uint32_t done = 0; done < len; ) {
        uint8_t n = (uint8_t)(len - done < FLASH_READ_MAX ? len - done : FLASH_READ_MAX);
        if (!flash_read(addr + done, n, out + done)) return false;
        done += n;
    }
    return true;
}

/* 0x14 x 8: one 256-byte page. Blocks 0-6 are posted (the box doesn't answer them), block 7 makes
   the box program the page and answer. The first page of a sector erases the sector first. */
static bool flash_write_page(uint32_t addr, const uint8_t *data) {
    for (int j = 0; j < PAGE / BLOCK; j++) {
        uint8_t req[SL4_REPORT] = { SL4_CMD_FLASH_WRITE }, reply[SL4_REPORT];
        put_be32(req + 5, addr + j * BLOCK);
        memcpy(req + 9, data + j * BLOCK, BLOCK);
        if (j < PAGE / BLOCK - 1) {
            if (!updater_send(req)) return false;
            continue;
        }
        if (!updater_command(req, reply)) {
            printf("\nwriting the page at flash 0x%05x: %s\n", addr, reply_meaning(reply[0]));
            return false;
        }
        /* Rane checks only the opcode; the address echo is expected too, but its layout is inferred. */
        static bool warned;
        if (be32(reply + 5) != addr + j * BLOCK && !warned) {
            printf("\n(note: the box's acknowledgement doesn't echo the block's address as expected: %02x %02x %02x %02x)\n",
                   reply[5], reply[6], reply[7], reply[8]);
            warned = true;
        }
    }
    return true;
}

/* ---- the box's summary table ---- */

typedef struct { uint8_t raw[PAGE]; uint32_t len; bool valid_crc; } devtable_t;

/* Read the first page of the box's table sector: the table and its length (entry 0). */
static bool read_device_table(devtable_t *t) {
    if (!flash_read_range(TABLE_FLASH, PAGE, t->raw)) return false;
    t->len = le32(t->raw + 4);
    t->valid_crc = le32(t->raw) == TABLE_FLASH && t->len >= ENTRY_LEN && t->len <= PAGE &&
                   crc_raw(t->raw + ENTRY_LEN, t->len - ENTRY_LEN) == le32(t->raw + 8);
    return true;
}

/* The box's table with entry 0's CRC put back as it was before 0x17 (its byte 0x0A less 1), if that
   makes its CRC valid; that is the state 0x17 leaves an otherwise intact box in. */
static bool table_only_marked_by_0x17(const devtable_t *t, uint8_t fixed[PAGE]) {
    if (t->valid_crc || le32(t->raw) != TABLE_FLASH || t->len < ENTRY_LEN || t->len > PAGE) return false;
    memcpy(fixed, t->raw, PAGE);
    fixed[SELF_CRC_BYTE]--;
    return crc_raw(fixed + ENTRY_LEN, t->len - ENTRY_LEN) == le32(fixed + 8);
}

static void print_device_table(const devtable_t *t, const image_t *im) {
    printf("the box's summary table (flash 0x4000): entry 0 CRC %s\n",
           t->valid_crc ? "valid" : "INVALID (the box stays in its updater; 0x17 leaves it like this)");
    for (int i = 0; i < MAX_ENTRIES; i++) {
        const uint8_t *e = t->raw + i * ENTRY_LEN;
        if (le32(e) == 0 || (uint32_t)(i + 1) * ENTRY_LEN > (t->len <= PAGE ? t->len : PAGE)) break;
        printf("  %d: flash 0x%05x, 0x%05x bytes, CRC %08x", i, le32(e), le32(e + 4), le32(e + 8));
        if (im && im->data && i < im->nsec)
            printf("  %s", le32(e) == im->sec[i].addr && le32(e + 4) == im->sec[i].len && le32(e + 8) == im->sec[i].crc
                           ? "= image" : "differs from the image");
        printf("\n");
    }
}

/* Save the box's table sector page to sl4-table-backup-<date>.bin here. It is the only part of the
   flash the protocol can read. */
static void save_table_backup(const devtable_t *t) {
    char name[64];
    time_t now = time(NULL);
    strftime(name, sizeof name, "sl4-table-backup-%Y%m%d-%H%M%S.bin", localtime(&now));
    FILE *f = fopen(name, "wb");
    if (f && fwrite(t->raw, 1, PAGE, f) == PAGE) printf("saved the box's summary table as it was to %s\n", name);
    else printf("(could not save the box's summary table to %s; continuing: it is informational only)\n", name);
    if (f) fclose(f);
}

/* ---- the running box, through the driver ---- */

typedef struct { uint8_t maj, min, boot, port, other, usb; uint32_t rate; bool have_ports, have_usb, have_rate; } running_t;

/* Read-only queries: version, updater flag, USB port status, USB state, sample rate. */
static bool query_running(AudioObjectID hal, running_t *r) {
    uint8_t req[SL4_REPORT], reply[SL4_REPORT];
    memset(r, 0, sizeof *r);
    if (!sl4h_version(hal, &r->maj, &r->min)) return false;
    memset(req, 0, sizeof req); req[0] = SL4_CMD_BOOT_DEV;
    if (!sl4h_command(hal, req, reply)) return false;
    r->boot = reply[5];
    memset(req, 0, sizeof req); req[0] = SL4_CMD_PORTS;
    if ((r->have_ports = sl4h_command(hal, req, reply))) { r->port = reply[5]; r->other = reply[6]; }
    memset(req, 0, sizeof req); req[0] = SL4_CMD_USB_STATE;
    if ((r->have_usb = sl4h_command(hal, req, reply))) r->usb = reply[5];
    r->have_rate = sl4h_rate(hal, &r->rate);
    return true;
}

/* Poll until the driver lists a box that answers 0x01. */
static AudioObjectID wait_for_driver(double seconds, uint8_t *maj, uint8_t *min) {
    for (int i = 0; i < (int)(seconds * 4); i++) {
        AudioObjectID hal = sl4h_find_device();
        if (hal != kAudioObjectUnknown && sl4h_version(hal, maj, min)) return hal;
        usleep(250000);
    }
    return kAudioObjectUnknown;
}

/* Wait for the box (registry entry old_id) to leave the bus, then for an SL 4 to enumerate with
   bcdDevice want_bcd (or any, with -1). Returns its bcdDevice, or -1 if none came; *svc (retained)
   and *id, if given, get the box. */
static int wait_for_reenumeration(uint64_t old_id, int want_bcd, double seconds, io_service_t *svc, uint64_t *id) {
    box_t b[4];
    for (int i = 0; i < (int)(seconds * 10); i++) {
        usleep(100000);
        int n = find_boxes(b, 4);
        int got = -1;
        for (int k = 0; k < n && got < 0; k++) {
            if (b[k].id == old_id) continue;
            if (want_bcd < 0 || b[k].bcd == want_bcd) {
                got = b[k].bcd;
                if (id) *id = b[k].id;
                if (svc) { *svc = b[k].svc; IOObjectRetain(*svc); }
            }
        }
        release_boxes(b, n);
        if (got >= 0) return got;
    }
    return -1;
}

/* ---- the steps ---- */

static bool confirm(bool yes) {
    if (yes) return true;
    if (!isatty(STDIN_FILENO)) { printf("not asking without a terminal: run again with --yes to go ahead\n"); return false; }
    printf("type yes to go ahead: ");
    fflush(stdout);
    char line[16] = {0};
    if (!fgets(line, sizeof line, stdin)) return false;
    return strncmp(line, "yes", 3) == 0;
}

/* Write every section that needs it, table first, as Rane does: all of them if the box was already
   in its updater (or its table can't be read); otherwise skip section i >= 1 if the box's table
   gives it the image's CRC, unless an earlier entry of the box's table ended its table. */
static bool write_sections(const image_t *im, const devtable_t *dev, bool was_updater) {
    const uint8_t *img = im->data.bytes;
    uint32_t total = 0, done = 0;
    bool skip[MAX_ENTRIES] = { false };
    bool dev_ended = false;
    for (int i = 0; i < im->nsec; i++) {
        if (dev && le32(dev->raw + i * ENTRY_LEN) == 0) dev_ended = true;
        skip[i] = i > 0 && !was_updater && dev && !dev_ended && le32(dev->raw + i * ENTRY_LEN + 8) == im->sec[i].crc;
        if (!skip[i]) total += im->sec[i].len;
    }
    printf("writing 0x%x bytes in %u pages\n", total, total / PAGE);
    for (int i = 0; i < im->nsec; i++) {
        const section_t *s = &im->sec[i];
        if (skip[i]) { printf("  section %d (flash 0x%05x): the box already has it (same CRC); skipped\n", i, s->addr); continue; }
        printf("  section %d (flash 0x%05x, 0x%05x bytes) ", i, s->addr, s->len);
        fflush(stdout);
        for (uint32_t p = 0; p < s->len; p += PAGE) {
            if (!flash_write_page(s->addr + p, img + s->off + p)) return false;
            done += PAGE;
            if ((p & 0xFFF) == 0) { printf("."); fflush(stdout); }
        }
        printf(" %u%%\n", total ? done * 100 / total : 100);
    }
    return true;
}

/* Read the written table back and compare it with the image's (the only part of the flash that can
   be read). */
static bool verify_table(const image_t *im) {
    uint8_t buf[PAGE];
    uint32_t len = im->sec[0].len;
    if (!flash_read_range(TABLE_FLASH, len, buf)) return false;
    if (memcmp(buf, (const uint8_t *)im->data.bytes + im->sec[0].off, len) != 0) {
        printf("the summary table read back from the box differs from the image's\n");
        return false;
    }
    printf("the summary table read back from the box matches the image\n");
    return true;
}

/* 0x16, then wait for the result: the firmware running (and, through the driver, its version), or
   the box still in its updater. */
static bool finish_and_check(uint64_t updater_id, const image_t *im) {
    uint8_t req[SL4_REPORT] = { SL4_CMD_FINISH }, reply[SL4_REPORT];
    bool ok = updater_command(req, reply);
    updater_close();
    if (ok) printf("finished (0x16): the box restarts, and its boot program checks every section's CRC\n");
    else printf("finish (0x16): %s; waiting to see whether the box restarts anyway\n", reply_meaning(reply[0]));

    /* Rane waits 8 s and then up to 30 s for the box. */
    int bcd = wait_for_reenumeration(updater_id, -1, 45, NULL, NULL);
    if (bcd < 0) { printf("the box did not come back within 45 s; unplug it, plug it in again and run sl4flash --check\n"); return false; }
    if (bcd == BCD_UPDATER) {
        printf("the box came back in its updater: its boot program found a section whose CRC doesn't match the table.\n"
               "Nothing is lost: it stays in its updater, which can be written again; run sl4flash again.\n");
        return false;
    }
    printf("the box is back running its firmware (bcdDevice 0x%04x)\n", bcd);

    /* The version, through the driver. */
    uint8_t maj = 0, min = 0;
    AudioObjectID hal = wait_for_driver(20, &maj, &min);
    if (hal == kAudioObjectUnknown) {
        /* Running at all means the boot program accepted every section; only the version is unread. */
        printf("the driver doesn't answer for it, so its version can't be read here; check with sl4dump\n");
        return true;
    }
    uint8_t q[SL4_REPORT] = { SL4_CMD_BOOT_DEV }, r[SL4_REPORT];
    bool updater = sl4h_command(hal, q, r) && r[5] != 0;
    printf("the box runs firmware %u.%02u%s\n", maj, min, updater ? ", but says it is in its updater (0x13)" : "");
    if (updater) return false;
    if (im && (maj != im->maj || min != im->min)) { printf("expected %u.%02u from the image\n", im->maj, im->min); return false; }
    return true;
}

/* --leave-updater: write back the box's own table with 0x17's mark undone, then 0x16. Untested. */
static int leave_updater(uint64_t updater_id, const devtable_t *dev, bool check, bool yes) {
    uint8_t fixed[PAGE];
    if (dev->valid_crc) {
        printf("the box's summary table is valid, so it is in its updater because a section fails its CRC check\n"
               "(an update that did not finish): only writing the firmware brings it back. Run sl4flash without --leave-updater.\n");
        return 1;
    }
    if (!table_only_marked_by_0x17(dev, fixed)) {
        printf("the box's summary table is damaged in a way 0x17 alone doesn't explain: only writing the firmware brings it back\n");
        return 1;
    }
    /* The rest of the table sector must be blank, since writing the table erases the whole sector. */
    uint8_t rest[TABLE_SECTOR_END - TABLE_FLASH - PAGE];
    if (!flash_read_range(TABLE_FLASH + PAGE, sizeof rest, rest)) return 1;
    for (size_t i = 0; i < sizeof rest; i++)
        if (rest[i] != 0xFF) { printf("the table sector holds data after the table (at 0x%05zx), which rewriting the table would erase; not doing it\n", TABLE_FLASH + PAGE + i); return 1; }

    printf("the box's table differs from a valid one only by the mark 0x17 leaves (byte 0x0A one higher).\n"
           "UNTESTED: sl4flash can rewrite the table page with that byte put back (erasing and writing flash\n"
           "sector 4, 0x4000-0x4FFF) and restart the box (0x16). If its other sections are intact it then runs\n"
           "the firmware it already has; if not, it stays in its updater, as now.\n");
    if (check) return EXIT_WOULD_WRITE;
    if (!confirm(yes)) { printf("nothing changed\n"); return 1; }
    if (!flash_write_page(TABLE_FLASH, fixed)) { printf("the table write failed; the box stays in its updater\n"); return 1; }
    uint8_t back[PAGE];
    if (!flash_read_range(TABLE_FLASH, PAGE, back) || memcmp(back, fixed, PAGE) != 0) {
        printf("the table read back differs from what was written; not restarting the box (it stays in its updater)\n");
        return 1;
    }
    printf("table rewritten and read back\n");
    return finish_and_check(updater_id, NULL) ? 0 : 1;
}

/* ---- main ---- */

/* tools/sl4dump.m includes this file for the image, USB and updater helpers above, without main. */
#ifndef SL4FLASH_NO_MAIN
static void usage(const char *argv0) {
    fprintf(stderr, "usage: %s [--firmware PATH] [--check] [--force] [--yes] [--wait SECONDS]\n"
                    "       %s --leave-updater [--check] [--yes] [--wait SECONDS]   (untested)\n", argv0, argv0);
}

int main(int argc, char **argv) {
  @autoreleasepool {
    const char *fw = kDefaultFirmware;
    bool check = false, force = false, yes = false, leave = false;
    int waitsecs = 0;
    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--check") || !strcmp(argv[i], "--dry-run")) check = true;
        else if (!strcmp(argv[i], "--force")) force = true;
        else if (!strcmp(argv[i], "--yes")) yes = true;
        else if (!strcmp(argv[i], "--leave-updater")) leave = true;
        else if (!strcmp(argv[i], "--firmware") && i + 1 < argc) fw = argv[++i];
        else if (!strcmp(argv[i], "--wait") && i + 1 < argc) waitsecs = atoi(argv[++i]);
        else { usage(argv[0]); return 2; }
    }

    /* The image (--leave-updater writes none, but compares with one if there is one). */
    image_t im = {0};
    bool have_image = load_image(fw, &im);
    if (!have_image && !leave) return 1;
    if (have_image && !im.known && !force && !leave && !check) {
        printf("not writing an image that isn't Rane's known build without --force\n");
        return 1;
    }

    /* Find the box: exactly one SL 4, running its firmware (reached through the driver) or in its
       updater (opened directly). */
    box_t b[4];
    int n = 0;
    AudioObjectID hal = kAudioObjectUnknown;
    for (int i = 0; ; i++) {
        n = find_boxes(b, 4);
        if (n > 1) { printf("%d SL 4 USB devices are connected (both of the box's USB ports, or two boxes); connect only one\n", n); release_boxes(b, n); return 1; }
        if (n == 1 && b[0].pid == SL4_PID_ALT) { printf("the SL 4 is using its alternate USB identity (product ID 0x0010, set by command 0x1a): power-cycle it first\n"); release_boxes(b, n); return 1; }
        if (n == 1 && b[0].bcd == BCD_UPDATER) break;
        if (n == 1 && b[0].bcd != BCD_RUNNING) { printf("the SL 4 reports bcdDevice 0x%04x, neither running firmware (0x0100) nor its updater (0x9900); not touching it\n", b[0].bcd); release_boxes(b, n); return 1; }
        uint8_t maj, min;
        hal = sl4h_find_device();
        if (n == 1 && hal != kAudioObjectUnknown && sl4h_version(hal, &maj, &min)) break;
        int seen = n;
        release_boxes(b, n);
        n = 0;
        if (i >= waitsecs * 4) {
            if (seen == 0) printf("no SL 4 found\n");
            else if (hal == kAudioObjectUnknown) printf("the SL 4 is connected, but the SL 4 driver, which sl4flash talks to a running box through, has no device for it (is it installed?)\n");
            else printf("the SL 4 doesn't answer through the driver (is another program using it?)\n");
            return 1;
        }
        if (i == 0) printf("waiting up to %d s for an SL 4...\n", waitsecs);
        usleep(250000);
    }
    bool was_updater = b[0].bcd == BCD_UPDATER;
    uint64_t box_id = b[0].id;
    io_service_t updater_svc = IO_OBJECT_NULL;
    if (was_updater) { updater_svc = b[0].svc; IOObjectRetain(updater_svc); }
    release_boxes(b, n);

    if (!was_updater) {
        /* A running box: what it runs, and whether anything stands in the way. */
        if (leave) { printf("the SL 4 is running its firmware, not its updater: nothing to leave\n"); return 0; }
        running_t r;
        if (!query_running(hal, &r)) { printf("the SL 4 doesn't answer its version and updater flag (0x01, 0x13)\n"); return 1; }
        printf("SL 4 running firmware %u.%02u", r.maj, r.min);
        if (r.have_ports) printf(", on its USB port %c, %s on the other", r.port ? 'B' : 'A', r.other ? "a computer" : "nothing");
        if (r.have_usb) printf(", %s", r.usb == 2 ? "high speed" : r.usb == 1 ? "full speed" : "USB not configured");
        if (r.have_rate) printf(", %u Hz", r.rate);
        printf("\n");
        if (r.boot) { printf("but it answers 0x13 as if it were in its updater (0x%02x): not touching it\n", r.boot); return 1; }

        /* Not over newer or equal firmware, unless forced. */
        int cmp = (im.maj << 8 | im.min) - (r.maj << 8 | r.min);
        if (cmp < 0 && !force) {
            printf("the box runs %u.%02u, newer than the image's %u.%02u: not writing it (--force writes it anyway)\n", r.maj, r.min, im.maj, im.min);
            return 0;
        }
        if (cmp == 0 && !force) {
            printf("the box already runs %u.%02u: nothing to do. (Its boot program checked every section against its table at its\n"
                   "last reset. Comparing that table with the image's needs the updater; --force updates anyway.)\n", r.maj, r.min);
            return 0;
        }

        /* Nothing may be using it. */
        if (sl4h_is_streaming(hal)) { printf("the SL 4 is in use for audio; stop playback (or quit the app using it) and try again\n"); return 1; }
        if (r.have_ports && r.other) { printf("a computer is connected to the box's other USB port; disconnect it first (the updater takes writes from one port only)\n"); return 1; }

        printf("\nTo update, sl4flash will:\n"
               "  1. send 0x17: the box marks its firmware invalid (rewriting flash sector 4) and restarts in its\n"
               "     updater. From here until step 4 succeeds, the box has no audio, at every power-up;\n"
               "  2. open the updater, read the box's summary table and save it to a file here;\n"
               "  3. write the summary table and each section whose CRC differs from the image's;\n"
               "  4. read the table back, send 0x16 (the box restarts; its boot program checks every section's CRC)\n"
               "     and check the box comes back running %u.%02u.\n"
               "If anything fails after step 1 (or the cable is pulled), the box stays in its updater and sl4flash\n"
               "can be run again: the updater itself can't be overwritten. This is from the analysis of Rane's\n"
               "code and has not been tested on an SL 4.\n", im.maj, im.min);
        if (check) { printf("check: would update %u.%02u -> %u.%02u\n", r.maj, r.min, im.maj, im.min); return EXIT_WOULD_WRITE; }
        if (!confirm(yes)) { printf("nothing changed\n"); return 1; }

        /* 1: into the updater. */
        uint8_t req[SL4_REPORT] = { SL4_CMD_ENTER_UPDATER }, reply[SL4_REPORT];
        bool ok = sl4h_command(hal, req, reply);
        if (!ok && reply[0] == REPLY_REFUSED) printf("the box refused 0x17 (its flash operation failed); waiting to see whether it restarts\n");
        else if (!ok) printf("0x17: %s; waiting to see whether the box restarts\n", reply_meaning(reply[0]));
        else printf("0x17 acknowledged: the box is restarting in its updater\n");
        if (wait_for_reenumeration(box_id, BCD_UPDATER, 45, &updater_svc, &box_id) < 0) {
            AudioObjectID h = sl4h_find_device();
            uint8_t maj, min;
            if (h != kAudioObjectUnknown && sl4h_version(h, &maj, &min))
                printf("the box did not enter its updater and is still running %u.%02u; nothing was written\n", maj, min);
            else
                printf("the box did not come back in its updater within 45 s. Unplug it, plug it in again, and run\n"
                       "sl4flash again (if 0x17 took effect it comes up in its updater, and sl4flash continues from there)\n");
            return 1;
        }
        printf("the box is in its updater (bcdDevice 0x9900)\n");
    } else {
        printf("SL 4 in its firmware updater (bcdDevice 0x9900): no firmware is running");
        printf(leave ? "\n" : "; sl4flash writes every section (the version it would replace can't be read)\n");
    }

    /* 2: open the updater; its flag and version (informational: the updater answers its own). */
    bool opened = updater_open(updater_svc);
    IOObjectRelease(updater_svc);
    if (!opened) {
        printf("the box stays in its updater; run sl4flash again%s\n", was_updater ? "" : " (it continues from there)");
        return 1;
    }
    uint8_t req[SL4_REPORT] = { SL4_CMD_BOOT_DEV }, reply[SL4_REPORT];
    if (updater_command(req, reply)) printf("updater flag (0x13): %u\n", reply[5]);
    else printf("updater flag (0x13): %s\n", reply_meaning(reply[0]));
    memset(req, 0, sizeof req); req[0] = SL4_CMD_VERSION;
    if (updater_command(req, reply)) printf("the updater reports version %u.%02u (its own)\n", reply[5], reply[6]);

    /* The box's table: the backup, and what decides which sections are written. */
    devtable_t dev;
    bool have_dev = read_device_table(&dev);
    if (have_dev) print_device_table(&dev, have_image ? &im : NULL);
    else printf("could not read the box's summary table%s\n", leave ? "" : "; every section will be written");

    if (leave) {
        int rc = have_dev ? leave_updater(box_id, &dev, check, yes) : 1;
        updater_close();
        return rc;
    }
    if (check) {
        printf("check: would write the firmware %u.%02u (every section) and restart the box\n", im.maj, im.min);
        uint8_t fixed[PAGE];
        if (have_dev && table_only_marked_by_0x17(&dev, fixed))
            printf("(its table carries only 0x17's mark: --leave-updater, untested, could restart it without writing the firmware)\n");
        updater_close();
        return EXIT_WOULD_WRITE;
    }
    if (have_dev) save_table_backup(&dev);
    if (was_updater) {
        printf("\nsl4flash will write every section of %u.%02u, table first, read the table back, send 0x16 and check the\n"
               "box comes back running it. If anything fails it stays in its updater and sl4flash can be run again.\n"
               "This is from the analysis of Rane's code and has not been tested on an SL 4.\n", im.maj, im.min);
        if (!confirm(yes)) { updater_close(); printf("nothing changed\n"); return 1; }
    }

    /* 3: the sections; 4: the table read back, 0x16, the result. */
    if (!write_sections(&im, have_dev && !was_updater ? &dev : NULL, was_updater) || !verify_table(&im)) {
        updater_close();
        printf("FAILED. The box stays in its updater (it has no audio until updated); run sl4flash again.\n");
        return 1;
    }
    if (!finish_and_check(box_id, &im)) return 1;
    printf("done: the box runs %u.%02u. What was checked: every written page was acknowledged, the table read back\n"
           "matched, and the box's boot program accepted every section's CRC. The sections themselves can't be read back.\n",
           im.maj, im.min);
    return 0;
  }
}
#endif
