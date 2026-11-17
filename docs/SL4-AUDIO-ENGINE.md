# SL 4 audio engine: low-latency streaming design, measurements and bug catalogue

This document describes how the SL 4 HAL plug-in (`plugin/SL4Device.m`) moves audio between CoreAudio and the
box, and how it handles the box coming and going and talking to clients (Serato, the control panel). The
driver is the SL 2 driver's engine (pepeleedj/Rane-SL2-Macos-ARM-Driver, `docs/SL2-AUDIO-ENGINE.md` there),
as the SL 3 driver is, with the SL 4's hardware in its place: the design, the reasoning and the SL 2's bug
catalogue apply as they stand, and this document gives the SL 4's differences and its own catalogue. The
SL 4's protocol is in `docs/SL4-COMMANDS.md`.

> **Nothing here has been run on an SL 4 yet.** The SL 4's facts come from Rane's driver, API and firmware
> (static analysis, `docs/SL4-COMMANDS.md`); the engine is the one measured on the SL 2 and SL 3. "Still
> open" at the end lists what the first session with a box has to check, in order.

> **Fixing a playback or capture bug? Start here.**
> 1. Build and install a debug driver: `make install DEBUG=1`, and the test tools: `make latency`.
> 2. Connect a loopback cable from Deck 1 Out L to Deck 1 In L (channel 1, if the channel order is as
>    assumed: see "Channel order" in `docs/SL4-COMMANDS.md`), with deck 1's input switch on LINE
>    (`tools/latency/README.md`).
> 3. Run `tools/latency/restartcheck.sh` and `tools/latency/dptest.sh 60`. Both print PASS or FAIL.
> 4. Reproduce stalls and errors on demand with `tools/latency/bin/sl4dbg` (stall the USB queue, error capture
>    packets), and read the driver's log with `tools/latency/logq.sh`.
> 5. The SL 2's [bug catalogue](#bug-catalogue) gives each past bug's symptom and regression test for the
>    shared engine; the SL 4's own entries are below.

## Results

None yet: no SL 4 has been connected to this driver. The SL 2 and SL 3 on the same engine measure a
round trip of 8.5–9.3 ms at a 48–64-frame IO buffer at 48 kHz (`docs/SL2-AUDIO-ENGINE.md`,
`docs/SL3-AUDIO-ENGINE.md` in those repositories). The SL 4's own figures, at 48 and 96 kHz, go here
once measured with `make hwtest ARGS="--loopback"`.

## What differs from the SL 2

| | SL 2 | SL 4 | Where |
|---|---|---|---|
| USB | `1CC5:0013`, one FX2 with an FPGA | `1CC5:000F`, an ARM7 (LPC2148-class) main processor with an FPGA and **two FX2s, one per USB port** (A and B, for two computers) | `docs/SL4-COMMANDS.md` "Hardware" |
| Channels | 4 in / 4 out, 16-byte frames, 112-byte packets | **10 in / 10 out**, 40-byte frames, **520-byte packets** (13 frames: 96 kHz) | `NCH`, `FRAME_BYTES`, `PKT_MAX` |
| Sample rate | 44.1 or 48 kHz, set by the host (`0x31`) | **48 or 96 kHz, chosen on the box** (its input P0.29); no command sets it. Read with `0x4A`, reported when it changes with `0x4B` | §5 |
| Thru | 2 decks, notes `0x5C`/`0x5D` | **4 decks**, notes `0x5C`–`0x5F`; the fifth stereo pair (Aux) has no thru | `set_thru` |
| LINE/PHONO | one switch, reported as note `0x61` | not reported at all (the switches are not visible to software) | — |
| Firmware | FX2 + FPGA in an I2C EEPROM; USB bootloader at bcdDevice `0x0000`; RAM-loaded bootstrap | ARM flash behind a protected **firmware updater**, which enumerates as bcdDevice **`0x9900`** | §6, `tools/firmware/` |
| Early capture read | the pad byte of every sample is 0, which marks arrival | not known whether the pad byte is 0: a fill template marks it instead (as on the SL 3) | §2 |
| Reports | `0x40` Hidi | `0x40` Hidi, `0x43` bridge packet, `0x46`/`0x49` the other port's computer left/came, `0x4B` rate change; `0x36 [5]` must be exactly 1 | §7 |
| Serial | the USB serial string | the same constant `"RH.01.00"` on every SL 4 | — |

## Design

The engine (timeline clock, capture with the early read, deep-scheduled playback with late writes, output
volume, teardown on the USB queue, stream generations, hot-plug, the client properties) is the SL 2's,
unchanged except where listed here. Read `docs/SL2-AUDIO-ENGINE.md` §1–§8 there for how it works and why.

### 1. Timeline clock (`clk_*`)

As the SL 2's. The box's packets carry 5–7 frames per microframe at 48 kHz and 11–13 at 96 kHz (Rane's kext
accepts exactly those); the clock tracks the box's real count from capture either way.

### 2. Capture

As the SL 2's, with the SL 3's way of seeing which frames of a queued packet have arrived (the early read):
every capture buffer is filled from a template before it is queued, and a packet's written part ends where
the template stops matching. Each 32-bit sample slot of the template holds `0xA5` in its pad byte, the
slot's position in the buffer in the next two bytes, and `0x7E`/`0x81` in its top byte, alternating by
channel and frame: it works whether the box writes 0 in the pad byte (as the SL 2 does) or not. The ring
is 131072 frames (1.36 s at 96 kHz).

When capture starts, the box's FX2 sends two packets of stale buffer contents first (240 bytes each at
48 kHz, 480 at 96 kHz; `docs/SL4-COMMANDS.md`, "Endpoint setup"): 0.25 ms of noise at the very start of a
stream, before any client is likely to be reading. Not filtered (to check on hardware whether it is
audible).

### 3. Playback: deep schedule with late writes (`dp_*`)

As the SL 2's. Packet sizes are predicted from the box's clock and steered to match capture, as the
box's playback endpoint is asynchronous with implicit feedback from capture (the same arrangement as the
SL 2's); `PKT_MAX` (520 bytes) bounds them at either rate.

### 4. Reported properties

As the SL 2's: input safety offset 1.5 ms (`'sl4i'`), output safety 2.0 ms, output latency 1.5 ms,
32 frames on the output stream. **Not measured on an SL 4**: check with `rtlat` at both rates, and change
them only to measured values.

### 4a. Output volume (`vol_*`)

Master and mute, and one volume per output channel: elements 1–10, named Deck 1–4 and Aux (order
unverified).

### 5. Sample-rate changes

The SL 4 chooses its rate itself, 48 or 96 kHz, from an input on its main processor (what drives it on
the board — a switch, a jumper — is not known yet), and the host cannot set it: `0x30`/`0x31` don't exist
(`0xFF`), and the USB Audio Class sampling-frequency SET is accepted and ignored. So the device publishes
**only the box's rate** (one nominal rate, one format), as Rane's kext does:

- At connect, `refresh_hw_status` reads it with `0x4A` and `rate_follow` takes it. The device is not in the
  HAL's list yet at that point (it is published after the box is opened), so the rate is simply set; the
  HAL reads it when it sets the device up.
- When the box changes its rate it sends `0x4B` (with reports enabled) and switches its clock once the
  FX2 on each active port has passed it on. `hid_read` hands it to `rate_follow`, which asks the HAL for a
  configuration change to the new rate (off the USB queue: the HAL may call back at once);
  `SL4_PerformDeviceConfigurationChange` stops any stream, switches the rate and the timeline, and
  restarts the stream at the new rate. The first packets at the new size can reach the driver before the
  device has switched; they are a few milliseconds of wrong-rate audio before the restart.
- The settle check (§6) reads `0x4A` again 2 s after connecting and after a wake, in case a `0x4B` was
  missed.
- A client asking for another rate (Audio MIDI Setup, an app's format) is refused, and the log says the
  rate is set on the box.
- The last rate seen is kept in the plug-in's storage, so after a restart of coreaudiod the device comes up
  at it (48 kHz until a box has been read).

### 6. Connect, disconnect and status

As the SL 2's, with:

- **Boot mode**: a box in its firmware updater enumerates with bcdDevice `0x9900` (Rane's kext tells it
  apart the same way). The driver never opens it, so `sl4flash` can, and lists the device with
  `boot_mode` set so clients can say the box needs its firmware. There is no RAM-loaded bootstrap to
  detect by version (c.f. the SL 2's 1.02 and the SL 3's 2.25).
- **At connect**: firmware version (`0x01`), USB link (`0x0a`), the serial string, the port status
  (`0x45`: which of the box's ports this Mac is on, and whether a computer is on the other one), reports
  enabled (`0x36`, exactly 1) and a state dump (`F0 17 04 F7`: the four decks' thru and note `0x60`), the
  rate (`0x4A`). Then every deck on thru (or as before a replug mid-stream).
- **The settle check** (2 s after connecting, 4 s after a wake): with nothing streaming, the decks'
  routing from a state dump is put back if the box lost it (the box itself forces every deck to thru
  while its input P0.20 is high and no USB port is active); the rate as above.
- **The routing across a replug mid-stream** is kept for all four decks, as on the SL 2 (entry 53 there).
- **Two computers**: each of the box's USB ports is a separate USB device, both `1CC5:000F` with the same
  serial. The driver opens the first one it finds; a Mac connected to both ports gets one SL 4 device.
  The other computer's coming and going reaches clients as `0x46`/`0x49` reports and updates `port_b`
  in the status.

### 7. The HID path for clients (`sl4h`, `sl4s`, `sl4q`, `sl4m`, `sl4i`)

As the SL 2's: `'sl4h'` passes any command to the box and gives the reply back to the process that sent
it (refusals `0xFF`, `0xFE` and `0xFD` included); `'sl4q'` gives every client process the box's
unsolicited reports (`0x40`, `0x43`, `0x46`, `0x49`, `0x4B`), unchanged; `'sl4s'` is `SL4StatusPacket`
(`plugin/SL4Status.h`: the SL 2's layout, then the box's rate and note `0x60`); `'sl4m'` is 20 peak
levels (inputs 1–10, outputs 1–10). The driver adds no reports of its own (c.f. the SL 2's `0x4F` rate
event: the SL 4's own `0x4B` serves).

### 8. SL4Api (`tools/SL4Api.m`)

A replacement for Rane's `SL4Api.framework` 2.0.1f1 (Rane's "Sixty-Eight" API), on top of §7, with the same
exports, signatures and return codes. Serato DJ Pro 2.5.5 uses ten of them (`docs/SL4-COMMANDS.md`, "What
Serato DJ Pro 2.5.5 uses"); `tools/sl4apitest.c` checks them as Serato calls them.

## Platform facts worth knowing

As the SL 2's (`docs/SL2-AUDIO-ENGINE.md` there).

## Bug catalogue

Each entry: symptom → cause → fix → how to test for it again → commit. Tests marked *(debug)* need a debug
build; *(hook)* uses `tools/latency/bin/sl4dbg`.

**The shared engine.** The SL 2 driver's catalogue (`docs/SL2-AUDIO-ENGINE.md` there) covers the engine
this driver shares: the timeline, capture, the deep schedule, teardown, connect and status handling, the
passthrough, the early read, the rate kept across restarts, the settle check, the routing across a replug,
and the interfaces kept from other drivers. All of it came to the SL 4 in the commit that rebuilt the
driver on that engine; each of its regression tests applies here, with channel 1 for the loopback. Its
"Porting to the SL 3 / SL 4" table lists which entries needed checking against the SL 4: they are the
entries below.

**Before that commit** the SL 4 driver (a port of an earlier SL 3 driver, written without the SL 4's own
firmware or Rane's SL 4 binaries) had, among the SL 2 catalogue's bugs, the following SL 4-specific ones.

### SL 4

1. **No audio at 96 kHz, and broken audio at 48 kHz whenever the box sends 7-frame packets near its limit.**
   - Cause: packet buffers of 280 bytes (7 frames of 40); the SL 4's endpoints are 520 bytes (13 frames, for
     96 kHz).
   - Fix: `PKT_MAX` 520, from the descriptors.
   - Test: `make hwtest ARGS="--loopback"` at 48 and at 96 kHz (flip the box's rate control between runs).
   - In the commit that rebuilt the driver.
2. **The device offered 44.1 kHz and set the rate with `0x31`; the box ignored both.**
   - Cause: the SL 2's rate handling. The SL 4 has no 44.1 kHz and no rate command (`0xFF`): the box chooses
     48 or 96 kHz itself. A device at 44.1 kHz (or at 48 kHz with the box at 96) plays at the wrong speed.
   - Fix: the device follows the box (§5): `0x4A` at connect and in the settle check, `0x4B` when it changes;
     only the box's rate is offered.
   - Test: `sl4panel` shows Device rate = Box rate; Audio MIDI Setup lists one rate; flip the box's rate
     with a stream running and the stream continues at the new rate.
   - In the commit that rebuilt the driver.
3. **Firmware version and serial always unknown.**
   - Cause: commands `0x10` (version) and `0x04` (serial) from other Rane boxes: the SL 4 answers `0xFF`.
   - Fix: `0x01` for the version, as Rane's SL4Api; the serial from the USB string (the same on every SL 4).
   - Test: `sl4panel` shows Firmware 1.02.
   - In the commit that rebuilt the driver.
4. **A `0x37` heartbeat, thought to be needed for USB audio.**
   - Cause: carried over from the SL 3 driver's earlier belief. On the SL 4 the FX2 answers `0x37` by itself
     and touches nothing else; Rane's kext never sends it.
   - Fix: no heartbeat, as on the SL 2 (its entry 29) and SL 3.
   - Test: `make hwtest ARGS="--loopback"`: the glitch test runs with no heartbeat.
   - In the commit that rebuilt the driver.
5. **A box in its firmware updater would have been streamed from.**
   - Cause: no boot-mode check; the updater enumerates with the same IDs (bcdDevice `0x9900`).
   - Fix: only bcdDevice `0x0100` is opened; `0x9900` sets boot mode (§6).
   - Test: `sl4flash` (with a box): while it runs, `sl4panel` reports boot mode and the driver's log says
     the box is in its firmware updater.
   - In the commit that rebuilt the driver.

## Testing

As the SL 2's (`docs/SL2-AUDIO-ENGINE.md` there, "Testing"), with `tools/hwtest.sh` for the SL 4: the
loopback on channel 1, the rate tests at whatever rate the box is set to (and, as a physical step, after
flipping it), thru on decks 1–4, and the port status.

## Still open

Everything below needs an SL 4. In the order a first session should take them:

1. **Does it stream at all?** Install a debug build, connect the box (directly, one USB port), check the
   log (`tools/latency/logq.sh`): firmware 1.02, port A or B, rate 48000 or 96000. Then `restartcheck.sh`.
2. **Channel order.** With a loopback from each deck output in turn, find which channel each jack is.
   The driver, the control panel and the docs assume decks 1–4 on channels 1–8 and Aux on 9–10 (the
   descriptors only say "CH1".."CH10"; the SL 3 put Aux first). Fix `inNames`/`outNames`, the volume names,
   the control panel's labels and `hwtest.sh` if not.
3. **Thru polarity and deck order**: Note On `0x5C` = deck 1 thru, as Rane's panel labels it.
4. **The early read** (`'sl4s'` early_read = working after a stream), and whether the pad byte is 0
   (it doesn't matter to the driver; worth recording).
5. **Latency**: `rtlat` at both rates; set the reported latency to measured values.
6. **The rate input**: what changes it on the box, and a change mid-stream (item 2 above in the catalogue).
7. **Two computers on ports A and B**: the port status, `0x46`/`0x49`, and Serato's bridge packets.
8. **Firmware tools**: `sl4dump` on a running box; `sl4flash --check`; only then a real update (the box
   should stay recoverable over USB, per the analysis of Rane's code).
9. **Serato DJ Pro 2.5.5** with `SL4Api`, then Serato DJ Pro 4.x / 5.x on the driver directly.
