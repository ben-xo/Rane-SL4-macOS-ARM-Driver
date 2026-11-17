/*
 * SL4Status.h — the driver's status packet ('sl4s'): the one definition, used by the driver
 * (plugin/SL4Device.m), SL4Api, sl4panel and the control panel (a C struct, so Swift sees the same
 * layout the driver writes). The fields up to usb_link are laid out as the SL 2's; new fields go at
 * the end, so an older client reads a newer packet (clients zero-fill a shorter one).
 */
#ifndef SL4_STATUS_H
#define SL4_STATUS_H
#include <stdint.h>

typedef struct {
    uint32_t connected;
    uint32_t streaming;
    uint32_t sample_rate;    /* the device's sample rate: the box's own (the box chooses it) */
    uint32_t version_maj;
    uint32_t version_min;
    uint8_t  serial[32];
    uint8_t  phono[4];       /* always 0: the SL 4 does not report its LINE/PHONO switches */
    uint8_t  thru[4];        /* decks 1-4: 1 = Analog Thru, 0 = USB Audio */
    uint8_t  port_a;         /* this Mac's USB port on the box (0x45): 1 = A, 2 = B, 0 = not known */
    uint8_t  port_b;         /* the box's other USB port: 1 = A, 2 = B, 0 = no computer there */
    uint64_t cap_frames;
    uint64_t play_frames;
    uint32_t boot_mode;      /* 1 = the box is in its firmware updater (bcdDevice 0x9900): no audio until
                                its firmware is written again */
    uint32_t debug_build;    /* 1 = this driver was built with SL4_DEBUG (make plugin DEBUG=1) */
    /* Input health (see "Early read" and the input safety offset) */
    uint32_t in_safety_us;          /* the input safety offset the HAL is using, in us */
    uint32_t early_read;            /* 0 = not judged yet on this connection, 1 = working, 2 = not working */
    uint32_t hub_depth;             /* USB hubs between the box and the Mac: 0 = connected directly */
    uint64_t in_dropouts;           /* IO cycles in which input wasn't captured in time, since the device was
                                       set up (the box connected, or the input safety offset changed) */
    uint32_t usb_link;              /* the box's USB link (0x0a): 2 = high speed, 1 = full speed (no audio),
                                       0 = not known */
    /* SL 4 only, after the fields shared with the SL 2's status */
    uint32_t box_rate;              /* the box's sample rate (0x4A, 0x4B): 48000 or 96000, 0 = not known */
    uint8_t  note60;                /* the box's note 0x60 (its input P0.20): 1 = on, 0 = off, 0xFF = not known */
    uint8_t  reserved[3];
} SL4StatusPacket;

#endif
