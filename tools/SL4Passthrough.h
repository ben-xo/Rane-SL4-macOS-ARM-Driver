// SPDX-License-Identifier: GPL-3.0-or-later
/*
 * SL4Passthrough — send commands to a Rane SL 4 through the HAL driver's 'sl4h' property.
 *
 * While the HAL plug-in (plugin/SL4Device.m) runs, it holds the box's USB interfaces, so a tool
 * cannot open the command endpoints itself. Instead it writes a 64-byte command report to the
 * driver's 'sl4h' property and then reads the property back: the read sends the command on EP1
 * and returns the box's 64-byte reply. The report layout and the command set are in
 * docs/SL4-COMMANDS.md.
 *
 * The write/read pair is not atomic across processes: with two 'sl4h' clients running at once
 * (sl4panel, Serato through SL4Api), one can end up sending the other's command.
 *
 * A box in its firmware updater (bcdDevice 0x9900) is not opened by the driver: the firmware tools
 * open it directly (tools/firmware/sl4flash.m).
 */
#import <CoreAudio/CoreAudio.h>
#include <stdbool.h>
#include <stdint.h>

#define SL4_REPORT        64
#define SL4_CMD_VERSION   0x01    /* reply [5] major, [6] minor, [7..10] build stamp, big-endian */
#define SL4_CMD_USB_STATE 0x0a    /* reply [5]: 0 unconfigured, 1 full speed, 2 high speed */
#define SL4_CMD_BOOT_DEV  0x13    /* reply [5]: 0 = running firmware, non-zero = the firmware updater */
#define SL4_CMD_PORTS     0x45    /* reply [5] this port's index (0 = A, 1 = B), [6] 1 = other port connected */
#define SL4_CMD_GET_RATE  0x4A    /* reply [5..7] the box's sample rate, 24-bit big-endian */
#define SL4_FIRMWARE_CURRENT_MAJOR 1   /* the newest firmware Rane released, in its 2.0.1f1 driver: 1.02 */
#define SL4_FIRMWARE_CURRENT_MINOR 2

/* The SL 4's HAL device, or kAudioObjectUnknown if there is none. The driver lists its device only
   while a box is attached, so a box that restarts or is replugged takes the device out of the list
   and back: look it up again rather than keep its ID across that. */
AudioObjectID sl4h_find_device(void);

/* Send one command report and fetch its reply. Fills in the tag (req[1..4]) itself. True if the
   reply echoes the opcode and tag; the driver returns an all-zero reply when the box does not
   answer in time, so a timeout reads as false too, and so does a refusal (0xFF, 0xFE). */
bool sl4h_command(AudioObjectID dev, uint8_t req[SL4_REPORT], uint8_t reply[SL4_REPORT]);

/* Command 0x01: the firmware version (01 02 = 1.02). */
bool sl4h_version(AudioObjectID dev, uint8_t *major, uint8_t *minor);

/* Command 0x4A: the box's sample rate (48000 or 96000), chosen on the box. */
bool sl4h_rate(AudioObjectID dev, uint32_t *rate);

/* True if any process is doing audio I/O on the SL 4. */
bool sl4h_is_streaming(AudioObjectID dev);
