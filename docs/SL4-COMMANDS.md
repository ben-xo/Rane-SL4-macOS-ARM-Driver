# Rane SL 4 — USB command protocol

> ⚠ **`0x17` makes the box boot into its firmware updater at the next start, immediately.** The ARM
> application copies the flash summary table at `0x4000`, increments its byte 10 (corrupting the image
> checksum the bootloader verifies), rewrites the sector, and the FX2 then has the ARM reset itself
> (`0x81`). Recovery is a full reflash through the bootloader (`0x14`/`0x16`). `0x16` and `0x17` also
> disconnect the box from USB; `0x1a` re-enumerates it as product ID `0x0010`, which Rane's kext does not
> match, until power-cycled or `0x1b`. `0x14` writes flash (only the bootloader acts on it).
>
> Any program on the Mac can send any command through the HAL driver's `'sl4h'` property (below): the
> driver does not filter opcodes, as Rane's software did not either. Only `tools/firmware/sl4flash`
> sends the firmware-update commands.
>
> **Nothing in this document has been checked on an SL 4 yet.** Every fact is from Rane's binaries
> (driver package `RaneSL4_2.0.1f1.pkg`, as bundled with Serato DJ Pro 2.5.5): "read" means taken from
> code at the given address, "inferred" means a conclusion from how the code uses something. The open
> questions at the end can only be settled on hardware; `make hwtest` checks the parts the driver
> relies on.

Sources (all Rane's, from `RaneSL4_2.0.1f1.pkg`; addresses are those binaries'):

| binary | what | address space used below |
|---|---|---|
| `SL4Api.framework` 2.0.1f1 (x86_64 slice) | client library (Serato 2.5.5, prefPane, settings service) | `SL4Api 0x…` |
| `SL4.10.9.kext` 2.0.1f1 | IOAudioFamily driver + user client | `kext 0x…` |
| `SL 4 Audio Control Panel.prefPane` | Rane's panel (the Sixty-Eight panel with an SL 4 mode) | `pane 0x…` |
| `SL4SettingsService` | launchd daemon | `svc 0x…` |
| SL4 firmware 1.02 (embedded in SL4Api at `0x7820`, 0x1B040 bytes, XOR key at `0x22910`) | ARM app, ARM bootloader, FPGA bitstream, FX2 image | `ARM 0x…` (flash address), `boot 0x…`, `FX2 CODE:…` |
| Serato DJ Pro 2.5.5 | how Serato uses SL4Api | `Serato 0x1…` |

SL4Api is Rane's "Sixty-Eight" API rebuilt (assertion strings name
`RedHammer/mac/Sl3Api/source/SixtyEightApiState.mm`, `SL4Api 0x6548`); the kext's sources are
`SixtyEightAudioDevice.cpp`/`SixtyEightUserClient.cpp`. The SL 2's SL2Api is the same code base.

## Hardware, as seen from the firmware

The SL 4 is **not** a single-FX2 box like the SL 2 and SL 3. The firmware image contains four parts
(section table in the image header, `0x40`; read):

| flash address | length | contents | evidence |
|---|---|---|---|
| `0x4000` | `0x100` | summary table: `{addr, len, crc}` LE triples for the sections below | read |
| `0x5000` | `0x3000` | ARM bootloader (firmware updater) | ARM vectors `ldr pc,[pc,#0x18]`; IRQ vector `ldr pc,[pc,#-0xff0]` |
| `0x8000` | `0x4500` | ARM application (linked at `0x8000`) | same; literal pools point into `0x8000–0xC500` |
| `0x68000` | `0x11C00` | Xilinx bitstream: sync `AA 99 55 66`, IDCODE write `0x01C10093` = **Spartan-3E XC3S100E** (72,668-byte bitstream) | read; loaded by `ARM 0x8414` |
| `0x7A000` | `0x1E00` | Cypress **FX2** firmware in EEPROM "C2" format: `C2 C5 1C 0F 00 00 41 00`, 14 records, code `0x0000–0x1E8C` | read |

- **ARM:** an **NXP LPC2000** (ARM7TDMI): VIC at `0xFFFFF000` (IRQ vector reads `0xFFFFF030`), fast GPIO
  at `0x3FFFC000`, SCS `0xE01FC1A0` GPIOM bit, PINSEL `0xE002C000`, I2C0 `0xE001C000`, I2C1
  `0xE005C000`, Timer0, ADC0 `0xE0034000`, SRAM at `0x40000000` (read). Flash used up to `0x7BE00` →
  512 KiB part: **LPC2138/01 or LPC214x class** (inferred; the ARM's own USB block is not used).
- **Two FX2s, one per USB port (inferred).** Every ARM handler takes a port index 0 or 1 and keeps
  separate state, buffers and I2C peripherals per port (`ARM 0x92d4`, `0x99ac`, `0xaa50`). The ARM is an
  **I2C slave at address `0x51`** (bootloader writes I2C1ADR `0xA3`, I2C1CONSET `0x44`; read), the
  address an FX2 boots from: the ARM evidently serves the FX2 its firmware as an emulated boot EEPROM, then
  keeps the same address as a command channel (inferred). The FX2 talks to `0x51` with its I2C master
  (`FX2 CODE:1d45` read, `CODE:1d67` write).
- **The FX2 owns USB; the ARM owns everything else.** The FX2 answers a few commands itself and forwards
  the rest to the ARM over I2C (below). Audio samples are not touched by either CPU's code shown here
  (presumably FX2 slave FIFO ↔ FPGA; not traced).
- USB identity (FX2 descriptors, read): device `CODE:0A00` VID `1CC5` PID `000F` bcdDevice `0x0100`;
  alternate `CODE:0A12` PID **`0x0010`**. Strings: "Rane Corporation", "Rane SL 4", serial **"RH.01.00"**
  (a constant, so the same on every box — inferred from it being in the code image), "SL 4 Audio",
  "CH1 Out"…"CH10 Out", "CH1 In"…"CH10 In".
- High-speed configuration (`CODE:0A2E`, 500 mA): IF0 vendor-class audio control (UAC2-shaped), IF1/IF2
  alt 1 = **10 channels, 4-byte subslots, 24-bit**, EP `0x06` OUT iso async and EP `0x82` IN iso async
  implicit-feedback, `wMaxPacketSize` 520 (= 13 frames of 40 bytes, enough for 96 kHz); IF3 HID
  (28-byte report descriptor, EP `0x81` IN / `0x01` OUT, 64 bytes, interval 1). Full-speed configuration
  (`CODE:0B1A`): HID interface only. (Read.)
- The kext's two personalities (read, `Info.plist`): bcdDevice `0x0100` (running) and `0x9900`
  ("bootdev"); `IsBootDevice` = bcdDevice == `0x9900` (`kext 0x6d7e`). The running FX2 image has
  `0x0100`; the boot-mode FX2 image is a separate, apparently compressed image inside the bootloader
  (`boot` image offset `0x199F`; not decoded).

## Transport

- 64-byte reports on HID interface 3: commands on **EP1 OUT `0x01`**, replies and unsolicited reports
  on **EP1 IN `0x81`** (read: descriptors; kext `InitHid 0x1c10` finds EP `0x81`/`0x01` on the class-3
  alt-0 interface).
- Rane's Mac path: SL4Api → kext user client (`IOConnectCallMethod` selector 7, 60-byte struct
  `[opcode][59 argument bytes]`) → kext `DoHidRequest` (`kext 0x25b2`) builds `[0] opcode, [1..4] a
  32-bit counter (LE) as tag, [5..63] arguments, zero padded`, async interrupt write. The kext reads EP
  `0x81` continuously (`CheckHidRead`/`ReadCallbackImpl 0x272a`) and copies every report to every open
  user client (≤ 10); it never parses replies except `0x4B` (below).
- This project's HAL driver (`plugin/SL4Device.m`) owns the interface while it runs and offers it to
  other programs through CoreAudio custom properties: writing a 64-byte command to `'sl4h'` sends it
  and keeps the reply for that process, which its next read of `'sl4h'` returns; `'sl4q'` gives each
  process the box's unsolicited reports. `tools/SL4Api.m` replaces Rane's `SL4Api.framework` on top of
  these, with the same functions; `tools/SL4Passthrough.m` is the minimal client the tools use. A box
  in its firmware updater (bcdDevice `0x9900`) is not opened by the driver; `sl4flash` opens it
  directly.

### Report layout

| byte | request | reply |
|---|---|---|
| 0 | opcode | opcode echoed; `0xFF` = unknown command (FX2 or ARM), **`0xFE` = refused by the ARM** (bad Hidi message, bridge not possible, flash op failed), `0xFD` = bootloader: update owned by the other port |
| 1–4 | host tag | the request's tag (FX2 saves it before forwarding and restores it, `FX2 CODE:17d2`). `0x00` and default (`0xFF`) replies: `0x00` does **not** copy it (`CODE:0621`); default copies it (`CODE:0959` → `CODE:1d02`) |
| 5… | arguments | results |

Unsolicited reports carry **`[1..4] = 1C C5 00 0F`** (VID/PID, inline constant after `LCALL 0x0EE6` at
`FX2 CODE:19de`; read), as on the SL 2. SL4Api tells replies from reports by that tag: it treats tags
`xx00C51C` for PIDs `04 09 0B 0D 0F 11 13 17` and `00 00 00 01/02/03` as unsolicited (`SL4Api 0x4769`),
shared code with the other Rane boxes.

### FX2 ↔ ARM framing (read)

`FX2 CODE:17d2` (`R7` = bytes to send, `0x38` = bytes to read): saves `[1..4]`, writes `[opcode][args…]`
(the host report **without the tag**) to I2C `0x51`, reads the reply `[op][results…]` into EP1 IN at
offset 4, moves it to offset 0 and restores the tag. Command forwarding waits for a holdoff: after each
ARM-bound command IRAM `0x50` = 4, decremented by the Timer-0 ISR (`CODE:1e00`, ~1 ms tick, reload
`0x821F` as on the SL 2); while non-zero, an ARM-bound command is left unanswered in EP1 OUT and retried
(`CODE:073b` etc.). The ARM raises an FX2 INT0 line when it has a report for that port (`ARM 0x9258`
pulses P0.1 / P0.9; FX2 INT0 ISR `CODE:1e60` sets bit `0x05`); the FX2 then reads `[len][op][payload]`
from `0x51` (`CODE:197d`, length capped at 61) and, **only if reports are enabled** (bit `0x06`, below),
copies it to EP1 IN with the `1C C5 00 0F` tag (`CODE:0578–05cf`).

## Commands

Dispatch: FX2 Keil sparse switch on `[0]` at `CODE:05e7`/table `CODE:05ea` (read); ARM application
dispatcher `ARM 0x92d4(port)`; bootloader dispatcher `boot 0x18c0` (bootloader linked at `0x1000`; handles
`0x01 0x14 0x15 0x16 0x4A 0x81` only). "→ARM" = forwarded; FX2 reply length in brackets.

| op | SL4Api / sender | FX2 | ARM app | request | reply / effect |
|---|---|---|---|---|---|
| `0x00` | — | `CODE:0621` | — | — | ping: `[0]=00`, tag not copied |
| `0x01` | `RH_get_firmware_version` (`SL4Api 0x2202`) | →ARM, 11 bytes (`CODE:073b`) | `0x92d4` | — | `[5]` major, `[6]` minor, `[7..10]` 32-bit BE build stamp. App: `01 02` + `4D 46 F2 AC` (word at `ARM 0x8800` = 2011-01-31; read). Bootloader answers the same layout from its own word |
| `0x06` | — | `CODE:0629` | — | — | no-op, **no reply** |
| `0x0a` | `RH_get_port_speed` (`0x1e8a`) | `CODE:062c` | — | — | `[5]` = FX2 IRAM `0x51`, the USB state (0/1/2 = unconfigured/full/high speed, inferred as SL 2/3; `0x51 == 2` drives FX2 P0.7, `CODE:196a`) |
| `0x13` | `RH_is_boot_device` (`0x2e03`); SL4Api `HandleDeviceConnected` | `CODE:072a` | — | — | `[5]` = **0** always in the running FX2 image (read). Boot-mode image presumably answers non-zero (inferred) |
| ⚠ `0x14` | `WriteFlashIfNecessary` (`0x62ea`) | `CODE:084e`: address `[8]` must be 32-aligned (else `0xFF`); if `[8] == 0xE0` →ARM 41 bytes, read 9; otherwise →ARM 41 bytes, **no reply** | not handled (`0xFF`) | `[5..8]` BE flash address, `[9..40]` 32 data bytes | bootloader only (`boot`): buffers 32 bytes; at block `0xE0` (end of a 256-byte page) programs the page (address ≥ `0x4000`) and replies `[0]=0x14` + `[1..4]` echo; `0xFE` on failure; `0xFD` if the other port owns the update |
| `0x15` | `ReadFlashBlock` (`0x618c`) | `CODE:088f`: clamps `[9]` ≤ 54, →ARM 10 bytes, read `[9]+10` | not handled (`0xFF`) | `[5..8]` BE address (SL4Api adds `0x4000` to its offset), `[9]` length ≤ 54 | bootloader: `[5..8]` address, `[9]` length, `[10..]` data; only `0x4000 ≤ addr`, `addr+len ≤ 0x5000` (summary-table area), else `0xFE` |
| ⚠ `0x16` | `UpdateFirmware` (`0x6040`) | `CODE:08b7`: →ARM 5, read 5; if the reply is `0x16`: reply to host, wait for EP1 IN to drain, disconnect, send ARM `0x81` | not handled (`0xFF`) | — | bootloader: finalize (only the owning port) → ARM resets into the application |
| ⚠ `0x17` | `UpdateFirmware` (`0x5d2f`) | `CODE:0908`: as `0x16` | `0x92d4`: invalidates the image (see warning), replies `0x17` (`0xFE` on flash error) | — | box disconnects and restarts in the bootloader (bcdDevice `0x9900`, inferred) |
| ⚠ `0x1a` / `0x1b` | `RH_set_alt_product_id` sends `0x1a` (`0x2d25`) | `CODE:0693` | gets `0x83` | — | reply, sends ARM `0x83` (port state "disconnecting"), disconnects, waits ~1.5 s, reconnects with the descriptor at `CODE:0A12` (PID `0x0010`) for `0x1a` or `CODE:0A00` (PID `0x000F`) for `0x1b`. Not stored |
| `0x30` / `0x31` | kext `ExternalSetSampleRate` (`kext 0x1fde`), `performFormatChange` (`0x5940`) send `0x31` | **not in the table → `0xFF`** (`CODE:0959`) | — | `[5..6]` BE rate | **the SL 4 has no host-settable sample rate** (see "Sample rate"). Rane's kext sends `0x31` anyway (SL 2-family code) and ignores the answer |
| `0x36` | kext `InitHid` sends `36 FF FF FF FF 01` (`kext 0x1f70`) | `CODE:0765`: →ARM 6, read 6; FX2 enables forwarding (bit `0x06`) only if the ARM's reply is `0x36` with `[5] == 1`, otherwise disables | `0x92d4`: stores `[5]` as this port's report enable | `[5]` 1 = enable, 0 = disable | `[0]=0x36`, `[5]` echoed. Note `[5]` must be exactly 1 (SL 3: any non-zero) |
| `0x37` | `RH_driver_timer` (`0x20c8`) | `CODE:063a`: copies `[5..12]` to XDATA `0x2880`, runs `CODE:0100`, copies the result back | — (never sees it) | `[5..12]` 8-byte challenge | `[5..12]` 8-byte response. Computed by the FX2: XXTEA-shaped, delta `0x9E3779B9` inline at `CODE:011f` (key not extracted) |
| `0x41` | Hidi senders (kext `SendHidiMessageInternal 0x6cce`) | `CODE:07f6`: pre-sets `0xFF`; if `[5]` ≤ 58: →ARM `[5]+6` bytes, read 5 | `0x92d4` | `[5]` length, `[6..]` MIDI bytes | `0x41` = queued; **`0xFE` unless the first byte is `0x80`, `0x90` or `0xB0`, or the message starts `F0 17 04`**. See "Hidi messages" |
| `0x42` | `RH_send_bridge_packet` (`0x2a5f`) | `CODE:082a`: →ARM all 64 bytes (60 after the tag), read 5 | `0x92d4` | `[5..63]` 59-byte packet | `0x42` = queued for the **other** port; `0xFE` if either port is not connected or the 256-byte relay ring has < 60 bytes free |
| `0x45` | `RH_get_usb_port_status` (`0x1d62`); `HandleDeviceConnected` | `CODE:0747`: →ARM 5, read 7 | `0x92d4` | — | `[5]` = **this** port's index (0 / 1), `[6]` = 1 if the other port is connected |
| `0x4A` | `SL4_get_sample_rate` (`0x73f8`) | `CODE:079b`: →ARM 5, read 8; on `0x4A` also stores the rate in IRAM `0x49..0x4c` (used for the UAC endpoint-rate GET on EP0) | `0x92d4` | — | `[5..7]` sample rate, 24-bit big-endian (48000 or 96000) |
| other | | `CODE:0959` | `0xFF` | — | `[0]=0xFF` + tag |

FX2→ARM internal opcodes (never from the host; read): `0x81` reset the ARM (`ARM 0x92d4`: watchdog
reset, after `0x16`/`0x17`), `0x83` port state := 4 (`0x1a`/`0x1b`, suspend `CODE:1cb1`), `0x84` port
state := 1 and restart its timeout (`CODE:1d89`), `0x4B` (1 byte) = acknowledge a rate-change report
(`CODE:18f4`).

Opcodes SL4Api contains senders for but the SL 4 rejects: `0x31` (kext), none else. Opcodes of the SL 2
that the SL 4 lacks: `0x02`/`0x03` (EEPROM; the SL 4 is flash-based, `0x14`/`0x15`), `0x30`/`0x31`.

### Details

- **Unknown vs refused.** `0xFF` = no handler (FX2 default or ARM default `0x995c`); `0xFE` = the ARM
  handler ran and rejected the arguments. SL4Api only checks `reply[0] == opcode` and returns **11**
  for anything else (`SL4Api 0x44c2`).
- **Holdoff.** Commands handled by the FX2 alone (`00 06 0a 13 1a 1b 37`, default) are answered at once;
  ARM-bound ones are spaced ≥ ~3–4 ms apart by the FX2 (read; timing inferred from the SL 2's identical
  timer reload).
- **`0x01` version.** The firmware embedded in SL4Api is **1.02** (`RH_get_firmware_embedded_version`
  returns the constant `{1, 2}`, `SL4Api 0x235f`; image header `0x27–0x28` = `01 02`).

## Hidi messages (`0x41`) and the thru switches

The ARM queues the bytes of an accepted `0x41` in a 256-byte ring (`0x92d4`) and the main loop parses it
as 3-byte messages (`ARM 0xa250`; read):

| message | effect |
|---|---|
| `80 5C xx` / `90 5C xx` | deck 1 analog thru **off** / **on** (FIO0CLR / FIO0SET bit 21) |
| `80/90 5D xx` | deck 2 (P0.22) |
| `80/90 5E xx` | deck 3 (P0.23) |
| `80/90 5F xx` | deck 4 (P0.25) |
| other notes with `80`/`90`, any `B0 xx yy` | ignored (3 bytes skipped) |
| `F0 17 04 F7` | state dump: notes `5C 5D 5E 5F 60` as `0x40` messages |
| any other `F0…`, or any other status byte | rest of the queue discarded |

- Velocity is ignored. **Running status is not supported**: every message needs its status byte.
  Only channel 1 is accepted (`0x80`/`0x90`).
- **On = analog thru.** Read from Rane's panel: its "FeedThru" checkbox for channel *n* calls
  `setFeedThru:forChannel:` with note `0x5C…0x5F` and sends Note On when checked, Note Off when not
  (`pane 0x7615`).
- **Four thru controls only.** There is no thru note for the fifth stereo pair (10 channels = 5 pairs;
  which pair is "aux" and whether it has a thru at all is not in the code; inferred: none).
- Each change is confirmed with an unsolicited `0x40` on **channel 2**: `81 nn 40` / `91 nn 40`
  (`ARM 0xa108` / `0xa1ac`), sent to **every** port that has reports enabled and is connected — so both
  computers see a thru change made by either (read).
- **Power-up and automatic thru (read, `ARM 0xb7cc`, `0xaa50`):** at power-up all four thru are **on** if
  input P0.20 is high, **off** if low. While P0.20 is high and *neither* USB port is active (port state 0
  or 5), all four are forced **on** again (no `0x40` is sent for that). P0.20 is also reported as note
  `0x60`, and its rising edge reloads the FPGA (`0x8414`). What P0.20 is wired to is unknown; by analogy
  with the SL 2's note `0x60` (PC7) it is probably "audio/external power present" (inferred).

### Note `0x60`, PHONO/LINE, other notes

- Note `0x60` = input P0.20 (On = high), sent on change (`0xaa50` end) and in the state dump. Read-only.
- **No PHONO/LINE report.** The application never sends any note other than `0x5C–0x60` and reads no
  other input that could be a switch (read: all `0xa108`/`0xa1ac` callers). The SL 4's PHONO/LINE
  switches are therefore not visible to software (inferred: purely analog). The panel's phono
  sensitivity, MIDI, record and effects controls belong to the Sixty-Eight and are hidden for the SL 4
  (`pane hideControlsForSLx 0x353d`).
- **`RH_set_control_point` (`SL4Api 0x1f7e`) sends `F0 17 52 <1|2> F7` — the SL 4 application replies
  `0xFE`** (only `F0 17 04` is accepted), so the call returns 11. It is not exported as `SL4_*`, and
  neither the panel nor Serato uses it (read). Sixty-Eight leftover.

## Unsolicited reports (device → host)

ARM message `[len][op][payload]` → host report `[0]=op, [1..4]=1C C5 00 0F, [5..]=payload`. Forwarded by
the FX2 only while its enable bit is set (`0x36 [5]=1`).

| report | payload | sent when (ARM, read) | SL4Api (`HandleUnsolicitedData 0x51ec`, jump table `0x53e4`) |
|---|---|---|---|
| `0x40` Hidi | `[5]` length ≤ 58, `[6..]` messages (channel 2, vel `0x40`) | a thru change, state dump, note `0x60` change; only to ports with `0x36` enable **and** connected (`0x99ac`) | hidimsg callback, `RH_hidimsg_data_t {len, bytes[58]}` |
| `0x43` bridge | `[5..63]` 59 bytes | the other port sent `0x42`; delivered only if this port is enabled and connected | bridge callback, `RH_bridgepacket_data_t` = the 59 bytes |
| `0x46` | `[5]` the other port's index | the other port disconnected (its connect line P0.8 / P0.13 fell) | port-status callback `{thisPort, 0}` |
| `0x49` | `[5]` the other port's index | the other port connected | port-status callback `{thisPort, [5] ? 2 : 1}` |
| `0x4B` rate | `[5..7]` new rate, 24-bit BE | the rate input changed (`0xa904`), to each port whose state is 2 (active) | sample-rate callback `SL4_samplerate_t {int rate}` |
| (`0x50`) | — | never from the box: SL4Api synthesises it on unplug (`0x68cc`) | port-status callback `{0, 0}` |

### USB ports A and B (`0x45`, `0x46`, `0x49`)

- The ARM keeps a per-port state machine (`ARM 0xaa50`, state at `0x40000054`/`…58`): 0 no VBUS (P0.7 /
  P0.10 low, inferred VBUS sense), 1 FX2 starting (timeout counter), 2 running, 3 lost, 4 disconnected
  by `0x1a/0x1b`, 5 FX2 failed to start (read; names inferred). "Connected" (`0x40000020`/`…24`) is set
  when a command arrives from that port and follows input P0.8 / P0.13 (inferred: each FX2's
  "configured" output, FX2 P0.7).
- **`RH_usb_port_status_t` = `{int thisPort; int otherPort;}`**, ports numbered **1 and 2** (box index
  0 → 1, 1 → 2), `otherPort` 0 = no second computer (read: `SL4Api 0x1e17`, `0x52ae`, `0x5355`). Which
  index is the jack labelled "A" is not in the code (inferred: index 0 = A).
- `RH_get_usb_port_status` sends `0x45`: `thisPort = [5] ? 2 : 1`, `otherPort = [6] ? (the other number)
  : 0`. On connect SL4Api sends `0x13`, then `0x45`, and feeds the reply through the same path, so the
  callback fires once at open (`HandleDeviceConnected 0x67fa`). A boot device (`0x13 [5] ≠ 0`) reports
  `{1, …}` without asking.
- **Serato** reads only `thisPort != 0` from `SL4_get_usb_port_status` ("box present",
  `Serato 0x1009ee1f8`); its port-status callback clamps both fields to 0/1/2 and passes them to its
  listeners (`Serato 0x1009ee6a3`) — presumably its two-computer logic (preference key
  `usb_port_active`; inferred).

### Bridge packets (`0x42` → `0x43`)

A 59-byte mailbox between the computers on ports A and B. The ARM does not interpret the payload; it
queues it tagged by source port (`0x42` / `0xC2`) and delivers it to the other port as `0x43`
(`ARM 0x92d4`, `0x99ac`; read). Refused (`0xFE` → SL4Api 11) unless both ports are connected. Serato sends
and receives them (`SL4_send_bridge_packet` wrapper `Serato 0x1009ee46f`, callback `0x1009ee512`); what
Serato puts in them was not traced.

### Sample rate

- **The box chooses the rate, not the host.** The ARM samples input **P0.29**: high → **48000**, low
  → **96000** (`ARM 0xa904`, `0xba00`); 44100 does not exist on the SL 4. Output P0.30 selects the
  clock (FIOSET = 48 k, FIOCLR = 96 k; `0xba18`/`0xba30`). What drives P0.29 (a switch, a jumper, the
  FPGA) is unknown. (Read; P0.29's origin open.)
- On a change the ARM sends `0x4B` to every active port and **switches the clock only after every active
  port has acknowledged**; each FX2 acknowledges by itself as it relays the report (`FX2 CODE:18ec`), and
  a port that is not active (state ≠ 2) counts as acknowledged (read).
- No host path sets the rate: HID `0x30`/`0x31` → `0xFF`; the UAC endpoint `SET_CUR` sampling frequency
  stalls (`FX2 CODE:1ad6`: only GET, `bmRequestType 0xA2`, `wIndex 0x82`/`0x06`, answered from the rate
  learned from `0x4A`/`0x4B`) (read).
- **Kext:** advertises one rate at a time (`SetAvailableFormats kext 0x78ac`: 10 channels, 32-bit
  container, 48000 only at init; `DoSetSampleRate 0x59f6` accepts 44100, 48000, 96000 and replaces the
  format list). It follows the box through **`0x4B`** (`ReadCallbackImpl 0x27a2` →
  `hardwareSampleRateChange`, 100 ms deferred) and through **user-client selector 15**
  (`SL4_set_samplerate`). At start it calls `ExternalSetSampleRate(48000)` (`kext 0x1bc3`), which sends
  the useless `31 BB 80` and sets 48 k regardless of the box.
- **`SL4SettingsService`** fixes that at connect: its port-status callback (`svc 0x1ae2`), on the
  transition to connected, reads `SL4_get_sample_rate` (`0x4A`) and passes it to
  `SL4_set_samplerate(rate)` (`svc 0x1b45`). The panel only displays 48/96 (`updateSampleRate:
  pane 0x8658`; its `handleSampleRateChange:` is empty).

### MIDI channel data (`RH_midi_ch_data_t`)

**Not USB traffic.** `RH_midi_ch_data_t = {int a; int b}` is a value kept in the kext (`sMidiData`,
`kext 0x740e`) and shared by all clients: selector 11 stores it and broadcasts an async notification with
message `(a << 24) | ((b & 0xFF) << 16) | 0xE0` to every user client (`kext 0x74ee`); SL4Api's
notification handler (`SL4Api 0x5428`) turns `0xE0` messages into the callback `{msg >> 24,
(msg >> 16) & 0xFF}`. Selector 12 reads it. It is the Sixty-Eight panel's MIDI-channel preference;
nothing on the SL 4 uses it (inferred: the SL 4 panel hides the MIDI controls).

## `0x37` challenge

- **Box:** answered entirely by the FX2 (`CODE:063a` → `CODE:0100`, XXTEA-shaped, delta `0x9E3779B9`).
  The handler only computes and replies; no flag or timer is touched. The FX2's only timer (Timer 0,
  `CODE:1e00`) just counts down the ARM holdoff; the ARM never receives `0x37`. **There is no watchdog
  on `0x37`** (read for both CPUs' handlers; high confidence, not hardware-tested).
- **Kext:** never sends it (no `DoHidRequest` call site other than `0x31`, `0x36`, `0x41` and selector
  7; read).
- **SL4Api:** `RH_driver_timer(handle, challenge, 8, response, 8)` sends it only when called.
- **Serato 2.5.5** (`Serato 0x1009ee132`): `srand(time(0))`, 8 `rand()` bytes, `SL4_driver_timer(h,
  chal, 8, &resp, 8)`, computes the expected answer with its XXTEA routine `0x100923864` and key at
  `0x100FA4350` (the SL 2 glue uses `0x100FA4310`), returns `resp == expected`. It ignores the return
  code. When or how often it is called, and what a mismatch does, was not traced.

## Audio streaming


| Item | Value | Tag |
|---|---|---|
| Speed | Audio only at **high speed**. Full-speed config is HID only (interface 0) | read (FX2 0x0B1A, 0x134B) |
| Play | **Interface 1**, alt 1, EP **0x06** iso OUT, **asynchronous** (`0x05`), **wMaxPacketSize 520**, bInterval 1 | read (FX2 0x0A8C–0x0AC1) |
| Capture | **Interface 2**, alt 1, EP **0x82** iso IN, async, **implicit-feedback data** (`0x25`), **wMaxPacketSize 520**, bInterval 1 | read (FX2 0x0AC2–0x0AF9) |
| Feedback | No explicit feedback endpoint. OUT packet sizes follow IN packet sizes (the kext calls `OutPrepMicroframe(len/40)` for each IN packet) | read (KEXT 0x4A0A–0x4A1C) |
| HID | Interface 3 (HS) / interface 0 (FS): EP 0x81 interrupt IN 64, EP 0x01 interrupt OUT 64, bInterval 1 | read |
| Channels | **10 in, 10 out**, interleaved, frame = **40 bytes** | read (descriptor bNrChannels 10; kext 10 ch, ×40 maths) |
| Sample | **4-byte subslot, 24-bit resolution**, little-endian int32; kext presents 32-bit `sint` full-scale (`fBitDepth` 32), so the 24 bits are in the high three bytes (left-justified) | descriptor read; justification inferred |
| Rates | **48 000 and 96 000 Hz only.** No 44.1 kHz | read (FX2, ARM, PANE); see below |
| Rate setting | **Selected on the box** (ARM reads pin P0.29: 1 = 48 k, 0 = 96 k). Host cannot set it: no HID command, UAC `SET_CUR` is accepted and ignored. Host reads it with HID `0x4A`, or endpoint `GET_CUR`; changes arrive as unsolicited HID `0x4B` | read |
| Packets/µframe | 48 k: nominal 6 frames (240 B), box varies 5–7 (200–280 B). 96 k: nominal 12 frames (480 B), 11–13 (440–520 B) | read (KEXT 0x4947–0x49EE, FX2 0x1420–0x1475) |
| PIDs | `1CC5:000F` bcdDevice `0x0100` running; `1CC5:0010` after HID `0x1A`; `1CC5:000F` bcdDevice `0x9900` = ARM bootloader ("boot device") | read / inferred |

Verdict on the community driver this project replaced (the repository's earlier `plugin/SL4Device.m`):

| Claim | Verdict |
|---|---|
| Interfaces 1/2/3, EP 0x06 / 0x82 | **Correct** (high speed) |
| 10 channels | **Correct** |
| 4-byte samples, 24-bit left-justified | Format correct; justification consistent with kext (inferred) |
| 280-byte packets (`PKT_MAX`) | **Wrong.** wMaxPacketSize is **520** (13 frames). 280 is only the 48 kHz maximum (7 frames); at 96 kHz packets are 440–520 bytes |
| 44.1 / 48 (/96) kHz | **Wrong.** 48 and 96 kHz only; 44.1 kHz is never produced by the box |
| Rate set with HID `0x31` | **Wrong.** `0x31` is not an SL 4 command: the FX2 answers `[0]=0xFF` (unknown). Rate is a box-side setting |
| Order decks 1–4 then aux | **Not verifiable** from these binaries (descriptor names are only "CH1 Out"…"CH10 Out"). See Channel order |
| HID `0x10` (version), `0x04` (serial) | Not SL 4 commands (FX2 replies `0xFF`). The SL 4 version is `0x01` |
| Thru via `0x41` note on/off 0x5C–0x5F | **Correct** (matches PANE) |

### Endpoint setup in the FX2 (SET_INTERFACE, FX2 0x1349)

**[read]**, all refused (STALL) unless IRAM `0x51` = 2, which SET_CONFIGURATION (FX2 0x16AE) sets only
when the active config pointer is the high-speed one (`0x51` = 1 at full speed, 0 unconfigured; HID
command `0x0A` returns it in `[5]`, FX2 0x062C).

| Request | Firmware action |
|---|---|
| IF1 alt 1 | `EP6CFG` = 0 then `EP6FIFOCFG` = 0x05, `EP6CFG` = **0x9A** (valid, OUT, iso, **1024-byte**, double-buffered), FIFORESET 0x80/0x06/0x00, `OUTPKTEND` = 0x86 twice, `EP6FIFOCFG` = **0x15** (AUTOOUT, 16-bit) |
| IF1 alt 0 | `EP6CFG` = 0, `EP6FIFOCFG` = 0x05 |
| IF2 alt 1 | `EP2ISOINPKTS` = **1** (one packet per microframe), `EP2CFG` = **0xDA** (valid, IN, iso, 1024, double), FIFORESET 0x80/0x02/0x00. Then, by the current rate (IRAM 0x49–0x4C): **48 000 → commits two 240-byte IN packets; 96 000 → commits two 480-byte packets**; otherwise none (FX2 0x140C–0x1475). Those first two packets carry stale buffer contents |
| IF2 alt 0 | `EP2CFG` = 0 |
| IF0 / IF3 | accepted, no action |

After that, IN packets are committed by the external FIFO master (FPGA), which decides the 5/6/7 or
11/12/13-frame pattern; the 8051 never touches sample data **[inferred, as on the SL 3]**.
`GET_INTERFACE` (FX2 0x1A43) returns the stored alt settings (IRAM 0x1D for IF1, 0x1C for IF2).

### Sample format

- **[read]** Descriptor: Type I PCM, `bSubslotSize` 4, `bBitResolution` 24, 10 channels → **40-byte frames**.
- **[read]** KEXT `com_rane_sl4_audioengine::SetAvailableFormats` (0x78AC): `fNumChannels` 10, `'lpcm'`,
  `'sint'`, `fBitDepth` 32, `fBitWidth` 32, `fAlignment` 0, `fByteOrder` 1 (little-endian), mixable,
  `fDriverTag` 0x65/0x66 (out/in). Input is converted with Apple's
  `convertFromAppleUSBAudioInputStream_NoWrap` (0x7988), i.e. as full-scale int32.
- **[inferred]** Therefore the 24 valid bits sit in bytes 1–3 of each little-endian 32-bit slot
  (left-justified), and byte 0 is padding, as on the SL 2. Whether byte 0 is always 0 on capture (the SL 2
  arrival-detection trick) is not knowable from the firmware: the FPGA fills the FIFO.
- **[read]** Every frame-size calculation that is `<<4` (16-byte frames) in the SL 2 kext is `×40` in the
  SL 4 kext (e.g. KEXT 0x3247–0x3263, 0x4A0A–0x4A13, `imull $-0x28` at 0x4172 region); this is the only
  structural difference between the two kexts' engines besides rate handling.

### Channel order

- **[read]** Descriptor channel names are only "CH1 Out"…"CH10 Out" / "CH1 In"…"CH10 In"
  (strings 5–24); `bmChannelConfig` = 0. The kext names no channels. Nothing in FX2, KEXT, API or PANE
  maps channel indices to jacks: the order is decided by the FPGA (bitstream not decoded).
- **[read]** PANE has four per-deck thru switches ("Channel 1 Thru"…"Channel 4 Thru") sent as HIDI note
  on/off **0x5C, 0x5D, 0x5E, 0x5F** (`handleCh1..4FeedThruClick`, `setFeedThru:forChannel:` 0x7615 →
  `SL4_send_note_on/off`). So the box has four decks plus (by the count of 10) one more stereo pair.
- **[inferred]** Most likely pairs 1/2 … 7/8 = decks 1–4 and 9/10 = aux, as the community driver
  assumes, but the SL 3 (aux first: 1/2 aux, 3/4 left, 5/6 right) shows Rane did not always put decks
  first. **Treat the order as unverified**; it must be checked with a loopback on real hardware.

### Sample rates and how they are set

**Supported: 48 kHz and 96 kHz only.**
- **[read] ARM** 0xA904 / 0xB7E4: rate := `FIO0PIN` bit 29 (`0x3FFFC014`, func 0xBA00) ? 48000 : 96000
  (literals at ARM 0xB76C = 0xBB80, 0xB774 = 0x17700). 44100 (`44 AC 00 00`) occurs nowhere in FW.
  It is polled; on a change the ARM sets flags (0xA958–0xA9B4) and drives P0.30 (0xBA18/0xBA30,
  presumably the clock select) **[read]**; the notification to the host is `0x4B` **[inferred from FX2/KEXT]**.
  P0.29 is a hardware input, so the rate is chosen **on the box** (switch or jumper) **[inferred]**.
- **[read] FX2** at boot (0x14E8–0x1576) asks the ARM with `0x4A`, stores the 24-bit rate in IRAM
  0x49–0x4C, and **forces 48 000 unless the answer is 48 000 or 96 000**.
- **[read] PANE** shows only 48 kHz / 96 kHz lamps (`updateSampleRate:` 0x8658 compares with 0xBB80);
  `handleSampleRateChange:` is an empty method (0x763B). It never sets the rate.
- **[read] API**: `SL4_get_sample_rate` sends HID `0x4A`, rate = reply `[5]<<16 | [6]<<8 | [7]`
  (0x748B–0x74C3). `SL4_set_samplerate` only tells the kext (user-client selector 15, 0x6C6A). No API
  call sends a rate to the box. Serato 2.5.5 imports none of the SL4 rate functions.
- **[read] KEXT**:
  - Publishes **one rate at a time**: `SetAvailableFormats` adds 48 000 only (0x7915) and selects it.
  - HID IN report with `[0]` = **0x4B** → `hardwareSampleRateChange([5]<<16|[6]<<8|[7])` (0x27A2–0x27CB),
    which 100 ms later (0x79B1) runs `hardwareSampleRateChangeThread`: stop engine, `AbortStreaming(5)`,
    `DoSetSampleRate(rate)`, restart. User-client `SetSampleRate` (selector 15) takes the same path.
  - `DoSetSampleRate` (0x59F6) accepts 44100, 48000, 96000 (shared SL 2 code), clears the formats,
    re-adds the new rate as the only one on both streams and sets it. No USB request is sent.
  - At init, `ProtectedInitHardware` calls `ExternalSetSampleRate(48000)` (0x1BC3), which sends HID
    **`0x31` [BB 80]** (SL 2 command) and then `DoSetSampleRate`. `performFormatChange` (0x5998) also
    sends `0x31` for 44.1/48 and rejects 96 k. On the SL 4, `0x31` is unknown to the FX2 (dispatch default
    FX2 0x0959 replies `[0]=0xFF`) — a leftover with no effect. `DoHidRequest` is fire-and-forget, so the
    kext never notices.
  - Packet validation in `DoInputCopy` (0x490E–0x4A04), by current rate, len = IN packet bytes:
    - 44 100 (dead code on the SL 4): 200–279 valid (5–6 frames).
    - **48 000: 200–319 valid (5–7 frames); 440–559 (11–13 frames) are skipped as stale 96 k packets.**
    - **96 000: 440–559 valid (11–13 frames); 200–319 skipped.**
    - Anything else stops the scan (packet not yet complete). Valid packets: `frames = len/40`,
      `OutPrepMicroframe(frames)` then `InCopyInputToStreams` (implicit feedback).
- **[read] UAC endpoint request** (FX2 0x1AD6): `bmRequestType` 0xA2 or 0x22, `wValue` high byte 0x01
  (SAMPLING_FREQ_CONTROL), `wIndex` 0x82 or 0x06. **0xA2 (GET) returns the current rate as 3 bytes
  little-endian** (FX2 0x1C28); **0x22 (SET) is ACKed and ignored**. `bRequest` is not checked. Any other
  class request (including UAC 2 clock-source `GET_CUR`, wIndex 0x0500) is STALLed.

**What a HAL driver should do [inferred from the above]:** read the rate with HID `0x4A` (or endpoint
`GET_CUR`), publish only that rate, enable unsolicited reports with `0x36 [5]=01` after every (re)connect,
and on an unsolicited `0x4B` stop streaming, switch the published rate, and restart. Do not offer
44.1 kHz and do not try to set the rate.

### Packet geometry

| Rate | Frames per microframe (nominal) | Range the kext accepts | Bytes per packet | Per 1 ms (8 µframes) |
|---|---|---|---|---|
| 48 kHz | 6 | 5–7 | 200 / **240** / 280 | 48 frames, 1920 B |
| 96 kHz | 12 | 11–13 | 440 / **480** / 520 | 96 frames, 3840 B |

- wMaxPacketSize 520 = 13 × 40 (max at 96 kHz); one transaction per microframe (`bInterval` 1, no
  high-bandwidth bits) **[read]**. FX2 endpoint buffers are 1024 bytes double-buffered **[read]**.
- Kext buffering (shared with SL 2, **[read]** OutInit 0x2AC3/0x2ADF, InInit 0x3D8C–0x3DB3): 80 frame
  lists of `8 × buffer-ms` microframes, a fixed 720-byte (0x2D0) slot per packet, and a 125 µs timer.
- Full speed: no audio interfaces exist; only HID **[read]**.

### Stream start / stop (kext)

**[read]** (KEXT):
- Interfaces are found by class/subclass/protocol `FF/02/20` and `bAlternateSetting` 0
  (`ProtectedInitHardware` 0x1A2B–0x1AA6): the first is playback, the second capture (interface numbers
  are not hard-coded). It is skipped entirely for a boot device (`IsBootDevice`, 0x196F).
- `OutInitHardware` / `InInitHardware` open the interface and **select alt 1 once** (`selectAlternateSetting(1)`
  at 0x2FBE / 0x41B4), then take the first iso OUT / iso IN endpoint they find. Shutdown aborts and closes
  the pipes; the kext never selects alt 0 again.
- No HID traffic at start/stop: no thru switching, no rate command, no `0x36`, no `0x37` heartbeat.
  The only HID commands the kext sends are `0x31` (above, ignored by the SL 4) and `0x41` (HIDI
  messages from the user client, 0x6D42).
- Thru is a user action: PANE sends HIDI note on/off 0x5C–0x5F (above). The FX2 forwards `0x41`
  (`[5]` = length ≤ 0x3A, then MIDI bytes) to the ARM (FX2 0x07F6–0x0828) **[read]**.
- HID `0x37` (driver timer) exists: the FX2 notifies the ARM, transforms 8 challenge bytes
  (`[5..12]`) itself and replies (FX2 0x063A–0x0690) **[read]**. Whether the ARM switches decks back to
  thru when it stops is not visible in FX2/KEXT **[open]**.

### Boot device (bcdDevice 0x9900)

- **[read]** KEXT personalities: `SL4` = 1CC5/000F bcdDevice **256 (0x0100)**, `SL4-bootdev` = 1CC5/000F
  bcdDevice **39168 (0x9900)**; both load `com_rane_sl4_audiodevice`, which skips audio when
  `IsBootDevice()`.
- **[inferred]** The 0x9900 device is the ARM bootloader's own FX2 image (compressed, embedded in the
  bootloader segment at file 0x1ADF). Its compressed descriptor stream contains `… 06 99 01 02 03 01`
  (bcdDevice 0x9900, strings 1/2/3, 1 config) and `09 02 eb 00 04 01 00 80 fa` at file 0x1F9A–0x1FB6,
  i.e. apparently the same 4-interface configuration. It is used for flash updates; it should not be
  streamed to.


The decoded descriptors are in `docs/usb-descriptors.txt`.

## SL4Api exported API

All functions return `int`: **0** ok, **4** IOKit error / no reply in 5 s (`SendHidRequestInternal
0x4200`, timeout −5.0 s at `0x22878`), **5** reconnect timeout, **6** kext did not post / flash echo
mismatch, **8** bad handle or argument, **9** Hidi buffer full, **10** empty Hidi message, **11** reply
opcode ≠ request (box answered `0xFF`/`0xFE`/`0xFD`), **12** not connected. Handles are opaque
`void*` counters from 0 (`NewClientConnection 0x5524`); callbacks are per handle. Every `SL4_*` is a tail
call to the `RH_*` of the same name except `SL4_get_sample_rate`, `SL4_set_samplerate_callback` and
`SL4_set_samplerate`, which only SL4Api has.

| function | signature (from register use) | does |
|---|---|---|
| `SL4_open` / `RH_open` | `void* (void)` | new handle; starts the monitor thread on first open |
| `RH_open_private` (C++) | `void* (int bufferMs)` | same, with the buffer size (settings service) |
| `SL4_close` | `void (void* h)` | |
| `SL4_get_vendor_id` / `_product_id` | `int (void* h, int* out)` | selector 2 / 3 |
| `SL4_get_api_version` | `int (SL4_version_t* out)` — **no handle** | constant `{2, 0, 0, 3}` |
| `SL4_get_driver_version` | `int (void* h, SL4_version_t* out)` | selector 4: `{2, 0, 1, 1}` (kext `0x74b0`) |
| `SL4_get_buffer_millisecs` / `_set_` | `int (void* h, int* ms)` / `int (void* h, int ms)` 1–50 | selectors 6 / 5 |
| `SL4_get_usb_port_status` | `int (void* h, RH_usb_port_status_t* out)` | HID `0x45` |
| `SL4_get_port_speed` | `int (void* h, int* out)` | HID `0x0a` |
| `SL4_driver_timer` | `int (void* h, const uint8_t* chal, int 8, uint8_t* resp, int 8)` | HID `0x37`; both lengths must be 8 |
| `SL4_get_firmware_version` | `int (void* h, SL4_version_t* out)` | HID `0x01` → `{[5], [6], 0, BE[7..10]}` |
| `SL4_get_firmware_embedded_version` | `int (void* h, int out[2])` | constant `{1, 2}` (writes 8 bytes) |
| `SL4_get_all_controls` | `int (void* h)` | queues `F0 17 04 F7` (selector 8); answer arrives as `0x40` |
| `SL4_send_hidimsg` | `int (void* h, const RH_hidimsg_data_t* m)` | `m->len` 1–58, sent at once (selector 9) |
| `SL4_send_note_on` | `int (void* h, uint8 note, uint8 vel)` | queues `90 note vel` (selector 8) |
| `SL4_send_note_off` | `int (void* h, uint8 note)` | queues `80 note 00` |
| `RH_send_control_change` | `int (void* h, uint8 cc, uint8 val)` | queues `B0 cc val` (box ignores) |
| `SL4_send_sys_ex` | `int (void* h, const void* data, uint8 len)` | queues `F0 17 data… F7` |
| `RH_set_control_point` | `int (void* h, const int* point)` 1–2 | `F0 17 52 point F7` at once → box `0xFE` |
| `SL4_set_hidimsg_callback` | `int (void* h, void (*)(RH_hidimsg_data_t*))` | `0x40` |
| `SL4_send_bridge_packet` | `int (void* h, const RH_bridgepacket_data_t* p)` | HID `0x42`, 59 bytes |
| `SL4_set_bridgepacket_callback` | `int (void* h, void (*)(RH_bridgepacket_data_t*))` | `0x43` |
| `SL4_set_usb_port_status_callback` | `int (void* h, void (*)(RH_usb_port_status_t*))` | `0x45/46/49`, connect/unplug |
| `SL4_get_sample_rate` | `int (void* h, int* rate)` | HID `0x4A` |
| `SL4_set_samplerate_callback` | `int (void* h, void (*)(SL4_samplerate_t*))` | `0x4B` |
| `SL4_set_samplerate` (C++, `__Z18SL4_set_sampleratei`) | `int (int rate)` — **no handle** | selector 15 → kext reformats; **no USB traffic** |
| `RH_get/set_midi_channels`, `RH_set_midi_ch_callback` | `int (void* h, RH_midi_ch_data_t*)` / callback | selectors 12 / 11, kext-only |
| `RH_flush_hidi_queue` / `SL4_` | `int (void* h)` | selector 13 |
| `SL4_is_boot_device` | `int (void* h, int* out)` | HID `0x13` |
| `SL4_set_alt_product_id` ⚠ | `int (void* h)` | HID `0x1a` |
| `SL4_set_update_firmware` ⚠ | `int (void* h, const uint8* img, uint len, void (*)(RH_firmware_status_data_t*))` | `UpdateFirmware 0x5c52` |
| `SL4_set_update_firmware_from_embedded` ⚠ | `int (void* h, void (*)(RH_firmware_status_data_t*))` | decrypts the embedded 1.02 image (XOR, 256-byte key) and updates |
| `RH_private_last_connection_error` (C++) | `kern_return_t (void)` | last open result (panel warns on `0xE00002D8`) |

Structures (sizes from the copies): `RH_hidimsg_data_t` 59 bytes `{uint8 len; uint8 data[58]}`;
`RH_bridgepacket_data_t` 59 bytes; `RH_usb_port_status_t` `{int thisPort; int otherPort}`;
`SL4_samplerate_t` `{int rate}`; `RH_midi_ch_data_t` `{int a; int b}`; `SL4_version_t`
`{int major, minor, rev, build}` (16 bytes); `RH_firmware_status_data_t` starts with a `uint8` percent
(0–100). There is no "all controls" structure: `get_all_controls` only triggers the `0x40` state dump.

**Differences from SL2Api's same-named functions** (diff of the export lists and of the functions read):
SL4Api adds `send_bridge_packet`, `set_bridgepacket_callback`, `get_sample_rate` (`0x4A`),
`set_samplerate_callback` (`0x4B`, unsolicited table extended to `0x4B`), C++ `SL4_set_samplerate`; it
renames `is_C0_device` → `is_boot_device` (`0x13`; SL2Api's `HandleDeviceConnected` uses kext selector
16 instead of `0x13`); it drops `SL2_set_sample_rate` and the FX2 EEPROM path (`UpdateBootstrapFirmware`,
`UpdateFinalFirmware`) in favour of the flash path (`UpdateFirmware`). Port status, Hidi, `0x37`,
version and buffer functions are byte-for-byte the same logic.

### Firmware update path (read, `UpdateFirmware 0x5c52`)

1. `IsValidFirmwareImage` (`0x7061`): header `"Copyright 20?? Rane Corporation"`, test bytes `02 1C C5 00
   0F 01 00` at `0x20`, BE payload length at `0x38` (+ `0x40` = file size), BE checksum at `0x3C`
   (`CalcChecksum`, a Rocksoft-model CRC, `cm_*`), every summary entry's checksum.
2. If `0x13` says not a boot device: `0x17`, close, wait, reopen (≤ 30 s).
3. `0x15` reads the box's summary table; each section whose checksum differs is written: per 256-byte
   page, 7 posted `0x14` (no reply) and an eighth with a reply; progress callback.
4. `0x16`, progress 100, close, reopen (≤ 30 s).

## Firmware storage and update

From Rane's `SL4Api` update path and the firmware's own boot program ("boot L:" = boot program link address, linked at `0x1000`; "app L:" = application, linked at `0x8000`). `tools/firmware/` implements it.

### Overview

- The SL 4's main processor is an **ARM7TDMI NXP LPC2148-class MCU** with 512 KiB of internal flash.
  Its flash holds a **protected boot program** at 0x0000–0x3FFF, a **summary table** at 0x4000, the
  ARM application at 0x8000, a **Xilinx Spartan-3E (XC3S100E) bitstream** at 0x68000, and the
  **Cypress FX2 (8051) USB firmware** at 0x7A000. USB is handled by the FX2, which passes 64-byte
  "HID" reports to the ARM over I2C.
- The update image is `0x40` header + the flash sections, concatenated. Section 0 is the summary table
  itself. Every section has a CRC-32 in the table. The boot program checks **all** of these CRCs at
  every reset and runs the application only if every one matches. Otherwise it stays in boot mode
  (bcdDevice 0x9900).
- Update sequence: `0x17` (the application corrupts the table's own CRC, then the box reboots into boot
  mode) → `0x15` reads the table at 0x4000 → `0x14` writes 32-byte blocks (8 blocks = one 256-byte
  page; the device erases a sector when the first page in it arrives) → `0x16` (the box reboots and
  the boot program checks the CRCs).
- The boot program refuses writes to sectors 0–3 (0x0000–0x3FFF). So an interrupted update leaves the
  box in boot mode, and it can be reflashed over USB. The 0x9900 FX2 firmware lives inside the boot
  program, not in the updatable 0x7A000 section.
- **There is no read-only way to dump the flash.** `0x15` exists only in boot mode and is limited to
  0x4000–0x4FFF (the table sector). **`0x17` is not read-only:** it rewrites flash sector 4.


### Image format

`IsValidFirmwareImage(img, size, &dataOff, &bodyLen)` **[read API 0x7061–0x7205]**:

| Offset | Size | Content | Checked |
|---|---|---|---|
| 0x00 | 32 | `"Copyright 20?? Rane Corporation\0"` | Yes. Compared against `kRequiredCopyright` @0x228e0, but indexes 12–13 (the year digits) are skipped (`(i & ~1) == 0xC`, API 0x70b0–0x70ba) [read] |
| 0x20 | 7 | `02 1C C5 00 0F 01 00` = type 0x02(?), VID 0x1CC5 BE, PID 0x000F BE, `01 00` | Yes, equal to `kTestBytes` @0x22900 [read API 0x70d3–0x70f8] |
| 0x27 | 2 | `01 02` = firmware version 1.02 | No [inferred; matches the hard-coded embedded version below] |
| 0x29 | 15 | zero | No |
| 0x38 | 4 | **BE** body length L = 0x1B000. `L + 0x40` must equal `size` | Yes [read API 0x70fd–0x7108] |
| 0x3C | 4 | **BE** standard CRC-32 of `img[0x40 : 0x40+L]` = 0x98E36819 | Yes, `CalcChecksum(…, true)` [read API 0x710e–0x712e] |
| 0x40 | L | body = the flash sections, concatenated in table order | Yes, below |

It needs `size ≥ 0x4C` [read API 0x707e]. On success it sets `*dataOff = 0x40` and `*bodyLen = L`,
and returns true [read API 0x71df–0x71ec].

**Summary table** = the first bytes of the body (image 0x40). It is also section 0, which is
programmed at flash 0x4000. Entries are 12 bytes of **little-endian** u32s `{flashAddr, length, crc}`
**[read API 0x7134–0x71dd]**:

- Entry 0 describes the table itself. Its `length` (0x100) sets the table size, so there are at most
  `length / 12` = 21 entries. The loop stops at the first entry with `flashAddr == 0`.
- Section *i*'s data starts at image `0x40 + Σ length[0..i-1]` and must fit inside the file.
- Entry 0's CRC covers only `table[0x0C : length]`, so it excludes itself. Entry *i* ≥ 1 covers that
  section's data. Both are `CalcChecksum(…, false)`.

| # | Flash addr | Length | CRC (raw) | Image offset | LPC2148 sectors | Contents |
|---|---|---|---|---|---|---|
| 0 | 0x04000 | 0x00100 | 0xFCDDA07D | 0x00040 | 4 | Summary table, 0xFF-padded [read] |
| 1 | 0x05000 | 0x03000 | 0xB7B740BE | 0x00140 | 5–7 | **Copy of the ARM boot program**, linked at 0x1000 (vector literals 0x1040…0x1058) [read]. Its compressed RW data holds the **FX2 boot firmware** (C2 image, VID 1CC5, PID 000F/0010, **bcdDevice 0x9900**) [read: decompressed with the boot program's own decompressor at boot L:0x10f8, descriptors at RAM 0x4000097A]. Its last 4 bytes (0xC135C562 LE) are the raw CRC of the preceding 0x2FFC bytes [read, verified] |
| 2 | 0x08000 | 0x04500 | 0xAB940EE4 | 0x03140 | 8 | **ARM application**. The boot program jumps to 0x8000 (boot L:0x2358) [read] |
| 3 | 0x68000 | 0x11C00 | 0x4B8CBD9D | 0x07640 | 20–23 | **Xilinx Spartan-3E bitstream**: sync word `AA995566`, IDCODE write `0x01C10093` = **XC3S100E** (expected bitstream 72,668 B ≈ 0x11BDC, padded to 0x11C00) [read] |
| 4 | 0x7A000 | 0x01E00 | 0x15AF2D0A | 0x19240 | 24–25 | **Cypress EZ-USB FX2 firmware**, 8051 "C2" boot-EEPROM format: `C2 C5 1C 0F 00 00 00 41`, device descriptors VID 1CC5, PID 000F and 0010, **bcdDevice 0x0100** (image 0x19b81) [read] |

The sections add up to 0x1B000 = L [read, verified with Python].

#### CRC (Ross Williams `cm_*` model)

`CalcChecksum` **[read API 0x1278–0x12f8, constant @0x7800]** sets up `cm_t` as width=32 (`0x20`
@−0x50), poly=**0x04C11DB7**, init=**0xFFFFFFFF** (16 bytes from 0x7800), refin=**true**,
refout=**true** (−0x38/−0x37), xorout=**0xFFFFFFFF** (−0x30). That is plain CRC-32/ISO-HDLC (zlib).
`cm_t` layout: +0 width, +8 poly, +0x10 init, +0x18 refin, +0x19 refout, +0x20 xorout, +0x28 reg
[read `cm_ini` 0x12f9, `cm_crc` 0x13dd].

- `CalcChecksum(p, n, true)` = `cm_crc` = **`zlib.crc32`**. The header CRC uses this.
- `CalcChecksum(p, n, false)` returns the raw register `cm.reg`, with no reflect-out and no xorout. The
  table CRCs use this. In Python: `raw = int(f"{zlib.crc32(d) ^ 0xFFFFFFFF:032b}"[::-1], 2)`
  [verified against all 5 entries].
- The device computes the same thing **[read boot L:0x15fc]**: a table-driven reflected CRC from
  ~0, then a bit reverse (boot L:0x2154), with no final xor.

#### Embedded version

- `RH_get_firmware_embedded_version` returns a hard-coded **{major 1, minor 2}** = v1.02
  [read API 0x2357 `movabs $0x200000001`]. It does not parse the image. Image bytes 0x27–0x28
  (`01 02`) agree [read].
- Device version: opcode `0x01`. reply[5] = major, reply[6] = minor, reply[7..10] = a BE u32 the API
  stores but the prefPane ignores [read API 0x22b6–0x22d0]. Both the boot program and the app answer
  `0x01` with `01 01 02 + 4 bytes` [read boot L:0x1a10, app L:0x93a4], so the boot program also
  reports 1.02.
- PrefPane: shows "Device Firmware Version: Boot" for a boot device. Otherwise it enables *Update
  Firmware* only if embedded > device (major, then minor) [read prefPane 0x6d9e–0x6de1]. The button
  runs `SL4_set_update_firmware_from_embedded` on a pthread [prefPane `handleUpdateFirmwareButton:` 0x7a5a, pthread_create 0x7aec; `doFirmwareUpdate` call 0x828d]. There is no
  downgrade path in the UI.

#### CPU / flash map

- ARM7TDMI code (ARM and Thumb), LPC2000 peripherals: FIO 0x3FFFC000, SCB 0xE01FC000, PINSEL 0xE002C000,
  I2C0 0xE001C000, I2C1 0xE005C000, ADC 0xE0034000, WDT 0xE0000000, VIC 0xFFFFF000. Vector 6 is
  `ldr pc,[pc,#-0xFF0]`. The IAP entry 0x7FFFFFF1 is built as `mvn r2,#0x8000000E` [read boot
  L:0x1668]. Calls: 50 prepare (L:0x164c), 51 copy RAM→flash (L:0x1688), 52 erase (L:0x16cc), 53 blank
  check (L:0x1708). CCLK = 60000 kHz (literal 0xEA60 at boot L:0x24fc).
- Address→sector (boot L:0x1628): `<0x8000 → a>>12`, `<0x78000 → 7+(a>>15)`, else `(a>>12)−98`, with
  sector < 27 required. That is the 512 KiB **LPC2148** layout [read; the exact part is inferred].
- Probable flash map:

| Range | Contents |
|---|---|
| 0x0000–0x0FFF | Reset stub that ends up at 0x1000. Not in the image [inferred: neither vector table in the image has a valid LPC vector checksum] |
| 0x1000–0x3FFF | **Running boot program**, protected |
| 0x4000 | Table |
| 0x5000–0x7FFF | Copy of the boot program |
| 0x8000+ | App |
| 0x68000 | FPGA bitstream |
| 0x7A000 | FX2 firmware |
| 0x7D000+ | NXP ROM bootloader |

  Whether anything ever copies 0x5000 to 0x1000 is unknown. No code that does it was found.

### Protocol: every opcode on the update path

Wire byte offsets below include the 4-byte tag.

| Op | Sent by (API) | Request payload (wire bytes 5…) | Reply | Handled by |
|---|---|---|---|---|
| `0x01` | `RH_get_firmware_version` 0x22a3 | none | [5]=major, [6]=minor, [7..10] BE u32 | app L:0x93a4, boot L:0x1a10 [read] |
| `0x13` | `RH_is_boot_device` 0x2e8e, `HandleDeviceConnected` 0x681c | none | [5] ≠ 0 → boot device | No ARM handler in either dispatcher, so probably answered by the FX2 [inferred] |
| `0x17` | `UpdateFirmware` 0x5d33 (only if not already in boot mode) | none | `0x17` (`0xFE` on IAP failure) | app L:0x9600 [read] |
| `0x15` | `ReadFlashBlock` 0x61f8 | [5..8] BE address = **0x4000 + offset**, [9] count (1..0x36) | [5..8] address echo (must match, else error 6), [9] count echo, [10..10+count) data | **Boot program only**, boot L:0x1934. Refused (reply `0xFE`) unless `addr ≥ 0x4000` and `addr + count ≤ 0x5000`. Count is clamped to 54 [read] |
| `0x14` | `WriteFlashIfNecessary` 0x640e (posted), 0x649b (waits for reply) | [5..8] BE absolute flash address, [9..40] 32 data bytes (`0x24` bytes of payload) | Only for the block whose address ends in `0xE0`: echo of `14 a3 a2 a1 a0` on success, `0xFE` on error, `0xFD` if another channel owns the flash | Boot program only, boot L:0x1a78 [read] |
| `0x16` | `UpdateFirmware` 0x6044 | none | `0x16`, or `0xFD` if the caller is not the owner | boot L:0x1bb8 [read] |
| `0x81` | not used by the API | none | none (the box resets) | app L:0x9798, boot L:0x19d4: watchdog reset [read] |

#### 0x17: enter boot mode (destructive) [read app L:0x9600–0x9724]

The application disables IRQs and copies the 256 bytes at flash 0x4000 to RAM. It then **adds 1 to
byte 0x0A** of that copy, which is byte 2 of entry 0's self-CRC. It then runs IAP prepare + erase on
sector 4 and prepare + copy of 256 bytes back to 0x4000, and replies `0x17`. On some channels it also
toggles an FIO pin (app L:0x961c/0x9644) [read; purpose inferred].

Then the FX2 sees the `0x17` (or `0x16`) reply, sets USBCS.DISCON (`E680 |= 0x08`), and sends `0x81`
to the ARM, which resets through the watchdog. This is in both FX2 images: `xrl a,#0x17` / `#0x16` at
FX2 boot 0x0902/0x0897 and FX2 run 0x090f/0x08be [read].

Result: at the next reset the boot program finds the table's self-CRC wrong and stays in boot mode.
It keeps doing so **on every power cycle**, until a correct table is written [inferred from the
validator below].

#### Boot program behaviour [read boot L:0x2178 `IsAppValid`, L:0x2348 main]

- At reset it blank-checks sector 4 (IAP 53). It requires `table[0].addr == 0x4000` and
  `table[0].len ≤ 0x1000`. It compares raw CRC(`0x400C … 0x4000+len`) with `table[0].crc`. It requires
  an `addr == 0` terminator before 0x5000. It then checks the raw CRC of every listed section in place.
  If all pass it jumps to **0x8000**.
- Otherwise it sets the "needs erase" flag for all 27 sectors (L:0x2364–0x237c) and serves the
  boot-mode FX2 firmware (bcdDevice 0x9900). It then handles only `0x01`, `0x14`, `0x15`, `0x16`,
  `0x4A` and `0x81`. Any other opcode gets reply byte `0xFF` (L:0x1bd4).

`0x14` details (L:0x1a78–0x1bb4):

1. **Ownership.** The first `0x14` claims the flash for the I2C channel it arrived on. A later `0x14`
   or `0x16` from the other channel gets `0xFD`. `0x16` releases the lock.
2. The 32 data bytes are stored at `pageBuf[addr & 0xFF]`. A block whose address ends in `0x00`
   latches the page base `addr & ~0xFF`. A block whose address ends in `0xE0` **commits the page**, as
   follows:
   - The page base must be ≥ 0x4000, else `0xFE`. IRQs are disabled.
   - The sector is computed. If it differs from the last sector written, its erase flag is set again.
   - Sector ≤ 3 → `0xFE` (**sectors 0–3 are write-protected**).
   - If the erase flag is set: IAP prepare + erase that sector, then clear the flag.
   - IAP prepare + copy 256 bytes, then reply with the 5-byte echo.
3. Consequences:
   - Pages must be sent with all 8 blocks in order. Block 0 sets the base and block 7 commits.
   - **The sector is erased when its first page in a run is written.** Going back to a sector after
     writing another one erases it again.
   - The device sends no explicit erase or verify reply, and the host does no read-back.

### Rane's update sequence (`ASL4ApiState::UpdateFirmware`, API 0x5c52–0x6185)

1. `IsValidFirmwareImage(img, size)` must pass, else return 8 [read 0x5cef].
2. `RH_is_boot_device` (`0x13`), then `wasBoot = reply[5] ≠ 0` [read 0x5d12–0x5d29].
3. If not `wasBoot`:
   - Send **`0x17`** and close the user client.
   - Run the run loop for **8 s** (0.1 s steps, consts 0x22868 = 0.1 and 0x228c0 = −8.0).
   - `SleepUntilReconnect(30)`, which re-opens the user client, polling for about 30 s; error 5 on
     timeout [read 0x5d2f–0x5e32, 0x5b24–0x5c4d].
4. `ReadFlashBlock(off=0, n=12)` → `0x15 @0x4000` gives the device's entry 0, and so the device's
   table length [read 0x5e5a–0x5ea2].
5. If not `wasBoot`: read the whole device table (`len & ~3` bytes, 54-byte `0x15` reads from 0x4000).
   If `wasBoot`: the device table is NULL (the call fails harmlessly) [read 0x5ea6–0x5f0a, 0x6260–0x62e9].
6. For each image table entry *i* until `addr == 0` [read 0x5f10–0x6018], call
   `WriteFlashIfNecessary` [read 0x62ea–0x6567]:
   - **Skip** the section only if all of these hold [read 0x632c–0x6377]:
     - *i* ≠ 0 (the table is always rewritten, and **first**);
     - not `wasBoot`;
     - not `force` (`force` is set once any device entry at index ≤ *i* has `addr == 0`);
     - `deviceTable[i].crc == imageTable[i].crc` (only the CRC is compared, not the address or length).

     A skipped section's length still counts toward progress.
   - Otherwise assert `len % 32 == 0` and `len % 256 == 0` (`!(embeddedLength % kWriteBlockSize)` and
     `!(blockCount % kBlocksPerPage)`, source `SixtyEightApiState.mm` lines 0x2EE/0x2F4).
   - Then for each 256-byte page: **post** blocks 0–6 (`0x14`, no wait) and **send** block 7 (`0x14`,
     wait for a reply with opcode 0x14). Blocks go in address order. Progress callback byte 0 =
     `bytesDone * 100 / size` [read 0x63e3–0x651e].
7. Send **`0x16`** (reply must be `0x16`). Progress = 100 [read 0x6040–0x607c].
8. Close the user client, wait 8 s, then `SleepUntilReconnect(30)` [read 0x607e–0x6143].
   **Nothing checks that the box came back in application mode.** The return value is only the
   reconnect status.

There is no read-back verification. The device's own CRC check at reset acts as the final verify.
Rane never sends `0x81`, `0x15` outside boot mode, or anything below 0x4000.

`RH_set_update_firmware_from_embedded` (API 0x2c6b–0x2d1b) copies the 0x1B040-byte blob at **0x7820**
to the stack, decrypts it there, and calls `UpdateFirmware`. `RH_set_update_firmware` (0x2bea) passes
the caller's buffer straight through, so that buffer must be plaintext.

### EncryptDecryptBytes

**[read API 0x7591–0x75b6]** `buf[i] ^= kKeyBytes[i & 0xFF]`, with the 256-byte key at **0x22910**
(identical to `xor_key_256.bin` [verified]). It is symmetric.

Its only caller is `RH_set_update_firmware_from_embedded` (API 0x2ced) [read, single xref]. It is
applied **only to the embedded image in the dylib**. Nothing on the wire is encrypted:
`SendHidRequestInternal` and the kext copy the payload as-is [read API 0x42c1–0x42cb, kext
0x26bc–0x26c7]. The device receives plaintext flash bytes. The XOR is obfuscation of the stored blob,
the same scheme as in SL2/SL3.

### Interrupted update and recovery

- The host never writes below 0x4000, and the boot program refuses sectors 0–3 [read]. The running
  boot program (0x1000–0x3FFF) and its 0x9900 FX2 firmware therefore cannot be damaged by this
  protocol.
- Every section is CRC-checked at every reset [read]. Power loss at any point between `0x17` and a
  completed `0x16` therefore leaves the box in **boot mode** (bcdDevice 0x9900, `0x13` → boot).
  Running `UpdateFirmware` again in that state takes the `wasBoot` path and rewrites every section.
  **The box should be recoverable over USB** [inferred, high confidence].
- Weak spot: the table is written first, so during an update the flash holds the new table and old
  sections. That is harmless because of the per-section CRC check [inferred].
- The FPGA and FX2-runtime sections are covered by the same check, so a bad bitstream or FX2 image also
  keeps the box in boot mode instead of running it [inferred].

### Safety classification

Running box (bcdDevice 0x0100):

| Opcode | Classification |
|---|---|
| `0x01` version | **Safe**, read |
| `0x13` boot flag | **Safe**, read |
| `0x45` USB port status (API `RH_get_usb_port_status` 0x1df9, app dispatch) | **Safe**, read |
| `0x4A` sample rate (API 0x748b) | **Safe**, read |
| `0x0A` port speed (API 0x1f16) | Probably safe |
| `0x15` | Not implemented by the app, so useless here (reply `0xFF`) [inferred from the app dispatch at app L:0x932c, which lists 0x01, 0x17, 0x36, 0x41, 0x42, 0x45, 0x4A, 0x4B, 0x81, 0x83, 0x84] |
| `0x17` | **Dangerous.** Rewrites flash sector 4 and leaves the box in boot mode until it is reflashed or the table is repaired |
| `0x81` | Reboots |
| `0x16` | Reboots (via the FX2) |
| `0x1A` (`RH_set_alt_product_id`, API 0x2da8) | Changes the USB identity |
| `0x37` (driver timer/challenge, 8-byte payload) | **Safe**: answered by the FX2 alone (see "`0x37` challenge") |
| `0x36`, `0x41`, `0x42` (bridge) | Safe: reports enable, Hidi (thru), bridge packet (see above) |
| `0x83`, `0x84` | FX2-to-ARM port-state messages, never from a host; avoid |

Boot-mode box (bcdDevice 0x9900):

| Opcode | Classification |
|---|---|
| `0x01`, `0x13`, `0x4A` | Safe |
| `0x15` | Safe, but limited to **0x4000–0x4FFF** |
| `0x14` | **Dangerous.** It erases the whole sector when the first page in it is committed |
| `0x16`, `0x81` | Reboot |

What this means for the tools (`tools/firmware/`):

- A **flash dump tool is impossible** with Rane's protocol. The most it can read is the 4 KiB table
  sector, and only in boot mode.
- A **read-only verify** of a running box is limited to `0x01` (version 1.02 plus 4 bytes) and `0x13`.
  This is still meaningful: a box that runs the application has passed the boot program's CRC check
  of every section against its table. Comparing that table with the image's table needs boot mode,
  which means `0x17`.
- If a tool enters boot mode only to inspect, it can leave without a full reflash. Read the table with
  `0x15`, write back the same 256 bytes with byte 0x0A decremented by 1 (after checking that this
  restores a valid self-CRC), then send `0x16`. That is still one sector erase-and-write
  [inferred; untested].

## Kext user-client selectors (`sMethods`, `kext 0xb180`; read)

| sel | method | scalars in / struct in → scalars out / struct out | does |
|---|---|---|---|
| 0 | `OpenUserClient` | 0 / 24 → 0 / 0 | registers the async notification port (`UnsolicitedCallbackInfo`); fails `0xE00002D8` until the engine is ready |
| 1 | `CloseUserClient` | — | |
| 2 | `GetVendorId` | → 2 (status, VID) | |
| 3 | `GetProductId` | → 2 (status, PID) | |
| 4 | `GetDriverVersion` | → 1 / 16 | `{2, 0, 1, 1}` |
| 5 | `SetBufferMilliseconds` | 1 → 1 | |
| 6 | `GetBufferMilliseconds` | → 2 | |
| 7 | `DoAsyncRead` (HID send) | 0 / 60 → 2 | `[opcode][59 bytes]` → `DoHidRequest`; out 0 = 7 if posted (5 if not), out 1 = the tag. **No opcode filtering** |
| 8 | `QueueHidiMessage` | 0 / 64 → 1 | Hidi string (`[0..57]` bytes, length at `+0x3C`); sent as `0x41` at once unless ≥ 3 HID writes are in flight, then coalesced (≤ 59 bytes) and flushed when writes complete |
| 9 | `SendHidiMessage` | 0 / 64 → 1 | as 8 but flushes the queue first and sends now; refused (9) with > 15 writes in flight |
| 10 | `ReadHidData` | → 1 / 648 | `{int count; int more; uint8 reports[10][64]}` queued for this client |
| 11 | `SetMidiData` | 0 / 8 → 1 | kext-global, broadcast `0xE0` notification |
| 12 | `GetMidiData` | → 1 / 8 | |
| 13 | `FlushHidiQueue` | → 1 | |
| 14 | `ControlRequest` | 4 / 8 → 6 / 8 | EP0 request; only in "C0 mode" (no HID interface). SL4Api never calls it |
| 15 | `SetSampleRate` | 1 → 1 | `hardwareSampleRateChange(rate)`: reformat the engine (44100/48000/96000); **no USB traffic** |

Kext HID traffic in full (read): `36 FF FF FF FF 01` and `31 BB 80` at start (`InitHid`,
`ProtectedInitHardware 0x1bc3`); `0x31` on a CoreAudio format change (`0x59d6`); `0x41` for Hidi;
whatever a client sends through selector 7. Nothing periodic, no `0x37`, nothing at stream start/stop
found.

## What Serato DJ Pro 2.5.5 uses

Loader `Serato 0x1009f697c` dlsyms ten functions from `/Library/Frameworks/SL4Api.framework/SL4Api`
(kext checked at `/Library/Extensions/SL4.10.9.kext`): `SL4_open`, `SL4_close`, `SL4_driver_timer`,
`SL4_get_usb_port_status`, `SL4_send_bridge_packet`, `SL4_set_bridgepacket_callback`,
`SL4_set_usb_port_status_callback`, `SL4_get_all_controls`, `SL4_send_hidimsg`,
`SL4_set_hidimsg_callback`. Not the sample-rate, note or firmware functions. The glue that calls them
(`Serato 0x1009ee0ba–0x1009ee7d5`, attributed to the SL 4 because it uses the hidimsg slots the
Sixty-Eight loader `0x1009f4f86` does not fill; medium confidence):

- **Thru** (`0x1009ee3ac`, deck index 0–3, bool): `SL4_send_hidimsg` with `{3, on ? 0x90 : 0x80,
  0x5C + deck, 0x00}` — one message, velocity 0, sent immediately.
- **Hidi callback** (`0x1009ee230`): walks `len / 3` messages; for notes `0x5C–0x5F` sets that deck's thru
  state to `status == 0x91`; ignores everything else (including note `0x60`).
- **State**: `SL4_get_all_controls` (`0x1009ee392`).
- `0x37` check, port status and bridge as described above.

## Open questions only hardware can answer

1. What drives **ARM P0.29** (48/96 kHz)? Is there a physical control, and does the rate really change
   only with it? Does `0x4A` answer 48000 on a stock box?
2. Which USB jack is port index 0 (`thisPort` 1) — "A"?
3. What is **P0.20** / note `0x60` (external power? audio power?) and does thru really default to on with
   it high and off with it low?
4. Thru polarity on the real box: Note On `0x5C–0x5F` = analog thru (as Rane's panel labels it) and Note
   Off = USB? Which deck is which note (1–4 left to right?), and which stereo pair of the 10 channels is
   the one without a thru (aux)? Channel order of the 10 channels is not in the code.
5. Are the PHONO/LINE switches really invisible to software (no report at all)?
6. Does the box play USB audio with no `0x37` at all (expected: yes) and with `0x36` never sent?
7. Are the `0x40` confirmations really delivered to both computers, and does a thru change by one
   computer override the other's?
8. Exact `0x0a` values, and whether `0x13` answers 1 in boot mode; what the boot-mode device looks like
   (bcdDevice `0x9900` expected).
9. Timing: the FX2's ~3–4 ms holdoff between ARM-bound commands; whether rapid `0x41` bursts lose
   messages (the ARM ring is 256 bytes).
10. Whether `0x36` is cleared on re-enumeration (FX2 bit `0x06`) so a host must resend it after every
    connect, as on the SL 3.
11. Bridge packets: what Serato sends, and whether a two-computer setup works without both hosts enabling
    reports.
12. Is the 32-bit container with 24 valid bits (descriptor) what arrives, and is any byte constant?
13. Whether capture's pad byte (byte 0 of each 32-bit sample) is always 0. The driver's early capture
    read doesn't depend on it.
14. The exact 48 kHz packet pattern (5/6/7 frames), and how the box behaves at a rate change mid-stream
    (the first packets at the new size reach the driver before the device has switched).
15. Firmware update: whether the box answers the seven posted `0x14` blocks of each page; what is at
    flash `0x0000–0x0FFF`; whether leaving the updater by rewriting the table (below) works.

