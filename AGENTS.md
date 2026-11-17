# Contributing to the Rane SL 4 macOS driver

Guidance for anyone changing this repository, human or AI agent. It records the coding standards the
code follows and the lessons that cost real time to learn, so that later work stays consistent with it.
The design and the bug history are in `docs/SL4-AUDIO-ENGINE.md`; the box's command protocol is in
`docs/SL4-COMMANDS.md`. Read both before changing the driver. The driver shares its engine with the SL 2
and SL 3 drivers (pepeleedj/Rane-SL2-Macos-ARM-Driver and Rane-SL3-Macos-ARM-Driver), whose
`docs/SL2-AUDIO-ENGINE.md` holds the engine's own bug catalogue; keep the drivers' shared code the same
where the hardware allows, so they can later share one code base.

**No SL 4 has been connected to this driver yet.** Everything about the box comes from Rane's driver,
API and firmware (`docs/SL4-COMMANDS.md`, which says what is "read" from code and what is "inferred");
`docs/SL4-AUDIO-ENGINE.md` "Still open" lists what to check first on hardware. Treat every SL 4 fact as
unconfirmed until it has been checked on a box, and say in the docs when it has.

## What is here

| Path | What it is |
|---|---|
| `plugin/SL4Device.m` | The driver: a CoreAudio HAL plug-in (runs inside `coreaudiod`) that drives the box over IOUSBHost |
| `plugin/SL4Status.h` | The driver's status packet (`'sl4s'`), shared by the driver and every client |
| `tools/SL4Api.m` | A replacement for Rane's `SL4Api.framework`, used by Serato DJ Pro 2.5.x and Rane's control panel |
| `tools/sl4panel.m` | Command-line status and control |
| `tools/controlpanel/` | The SL 4 Control Panel app (SwiftUI) |
| `tools/SL4Passthrough.{h,m}` | Shared client for the driver's HID passthrough (`sl4h`) |
| `tools/sl4dump.m`, `tools/firmware/` | Read-only status and flash-table dump, the firmware extractor and the flasher |
| `tools/latency/` | Loopback latency and glitch tests (`make latency`), with a README |
| `tools/hwtest.sh` | The hardware tests in one run (`make hwtest`) |
| `tools/sl4apitest.c` | SL4Api checked as Serato DJ Pro 2.5.5 calls it (`make apitest`) |
| `tools/install-sl4.sh` | Installs a local build over an installed package and restarts what goes stale |
| `Installer/` | The end-user scripts shipped in the package (Spanish) and the package builder |

`make` builds everything; `make plugin` is the release driver and `make plugin DEBUG=1` adds the
diagnostics and debug commands.

## Safety first

- **Some HID commands rewrite the box's flash or change how it enumerates** (marked ⚠ in
  `docs/SL4-COMMANDS.md`). `0x17` is **not** a query: it invalidates the firmware's summary table, and the
  box restarts in its firmware updater (bcdDevice `0x9900`) and stays there, at every power-up, until it is
  reflashed. `0x14` writes flash (erasing a whole sector at its first page), `0x16` finishes an update and
  restarts the box, `0x1a` reconnects it under another product ID (`0x0010`). Never send them to a working
  box to "see what happens".
- **Recovery is over USB, according to the analysis of Rane's code**: the updater lives in flash sectors it
  refuses to write, and checks every section's CRC at each reset, so an interrupted update leaves the box in
  the updater, where `sl4flash` can write it again. This has not been tried on a box. `sl4flash` keeps
  Rane's sequence; keep its checks in any change to it.
- **There is no way to read the firmware back**: `0x15` reads only the summary table, and only in the
  updater. Don't write tools that pretend to verify more than that.
- **Don't add gates the official software doesn't have.** The passthrough forwards these commands as
  Rane's driver does; protection belongs in documentation and in the tools, not in a driver-side filter.
- **Never commit Rane's firmware or binaries**: extracted images, disassembly, `SL4Api` binaries. They
  stay in git-ignored or local directories.
- **Connect the box directly or through one hub.** Isochronous streaming through nested hubs has
  kernel-panicked a Mac inside Apple's XHCI driver.

## Facts about the box

From Rane's binaries; none confirmed on a box yet (`docs/SL4-COMMANDS.md` gives the evidence for each).

- An ARM7 main processor (NXP LPC2148-class) with an FPGA, and a Cypress FX2 on each of the box's two USB
  ports (A and B, for two computers). The FX2 answers a few commands itself and passes the rest to the ARM,
  a few ms each.
- Isochronous endpoints `0x06` OUT and `0x82` IN (implicit feedback), **520-byte** packets: up to 13 frames
  × 10 channels × 4 bytes (24-bit samples in the top three bytes). 5–7 frames per microframe at 48 kHz,
  11–13 at 96 kHz.
- **The box chooses its rate, 48 or 96 kHz** (an input on the ARM; what drives it is not known). There is
  no 44.1 kHz and no command to set the rate: `0x30`/`0x31` answer `0xFF`. Read it with `0x4A`; the box
  reports a change with `0x4B`. The device follows the box.
- Thru for decks 1–4 is notes `0x5C`–`0x5F` through `0x41` (Note On = thru), confirmed by `0x40` reports;
  `F0 17 04 F7` dumps their state and note `0x60`. Aux has no thru. Reports need `0x36` with `[5]` exactly 1.
- The LINE/PHONO switches are not reported.
- The channel order is not known: the descriptors say only "CH1".."CH10". The code assumes decks 1–4 on
  channels 1–8 and Aux on 9–10.
- The firmware version comes from HID `0x01` (1.02 is current); bcdDevice says running firmware (`0x0100`)
  or the updater (`0x9900`). The serial string `"RH.01.00"` is the same on every box.
- The box doesn't check the `0x37` challenge (the FX2 answers it alone). The driver doesn't send it.
- Rane's own `SL4Api.framework` and control panel are the reference for what clients expect: match their
  function signatures and behaviour (from their disassembly), not what seems reasonable.

## Platform lessons (CoreAudio HAL and IOUSBHost)

The full list is under "Platform facts worth knowing" in `docs/SL4-AUDIO-ENGINE.md`. The ones that shape
the design:

- **Real-time completion handling is not available from user space**, and USB completion delivery stalls
  for 5–30 ms regardless of priority. Never design so that audio depends on a completion arriving on
  time: playback keeps a deep schedule of queued transfers and writes audio into them late.
- **Clean up on the USB queue.** Teardown runs on the driver's serial queue (`dispatch_sync`), and work
  from a stopped stream checks the stream generation before touching anything. Release
  `ioDataWithCapacity:` buffers before the next stream claims the interface.
- **Respect the HAL's contracts**: clamp every property write to the caller's `inDataSize`; declare custom
  properties in `kAudioObjectPropertyCustomPropertyInfoList`; keep the zero-timestamp period at or above
  the documented minimum; change the sample rate through the configuration-change handshake; send
  `PropertiesChanged` when the device list or owned objects change.
- **Report latency you have measured** with `tools/latency/rtlat`, not latency you have calculated.
- **The HAL reads safety offsets only at device setup**, so test changes to them after restarting
  `coreaudiod`.
- After `killall coreaudiod`, Control Center, QuickLookUIService and AirPlayXPCHelper keep stale state;
  `tools/install-sl4.sh` restarts them. Judge a change only after that.

## Coding standards

**Structure**
- Group code by subsystem with a prefix: `clk_` (timeline clock), `cap_` (capture), `dp_` (playback deep
  schedule), `usb_`, `hid_`, `dbg_`. Globals start with `g_`.
- Name protocol values: `SL4_CMD_*`, `SL4_NOTE_*`, `HID_REPORT_LEN` and friends, each with a comment
  giving the request and reply layout. No bare command numbers in code.
- Debug-only code goes behind `SL4_DEBUG` (`DBG_LOG`, `DBG_DO`, the `dbg_` block). The release build must
  stay quiet: log connect, disconnect, stream start and stop, rate changes, retries, refusals and errors,
  nothing per-cycle. The release build refuses debug commands (`0xF0` and above).
- Code that is replaced is removed from the tip in its own commit, so it stays findable in history. Don't
  leave dead paths or switches for old behaviour in the tip.
- Shared helpers live in one place (`SL4Passthrough`, `tools/latency/common.h`); don't copy them.

**Comments**
- Describe what the code does now and why. No code archaeology: not "the original code used…", "used to",
  "an early version…". Where a contrast helps, use a neutral cross-reference ("c.f. the SL 2, which uses
  `0x0100`"). Commit messages are where the history goes.
- Write for a first-time reader who wasn't part of the debugging: no "your box", no references to our own
  failed experiments, standard terms ("bootloader mode", "EP1 interrupt").
- In any function that reads as a procedure, put a one-line comment before each step saying what the next
  lines do. Lookup tables (the property switch statements) get one separator per section, not per case.
- Keep comments and docs true when the code changes; a stale comment is a bug.

**Docs**
- `docs/SL4-AUDIO-ENGINE.md` is the design record. A fix to the audio engine, connect/status handling or
  the client interfaces adds an entry to its bug catalogue (symptom → cause → fix → test → commit). A fix to
  the engine the SL 2 and SL 3 drivers share belongs in those drivers too.
- When moving content between documents, move it verbatim and check nothing was lost.

**Tools**
- Test scripts print a clear PASS or FAIL. Match log lines on text that can't also appear in a counter
  line.
- Tools that only read the box go through the driver's passthrough, so they work while the driver runs.

## Commits and pull requests

- **One bug per commit.** The message gives the symptom, the cause, how it was found and how to test for
  it again. The history is used for regression hunting and as the guide for porting fixes between the
  SL 2, SL 3 and SL 4 drivers.
- **Sign every commit** (GPG). History rewrites with `git filter-branch` drop signatures; after any
  rewrite, check `git log --format=%G? main..HEAD` shows `G` for every commit.
- AI-assisted commits keep a `Co-Authored-By:` line but no session links.
- Stage explicit paths, not `git add -A`; local debug material must not slip in.
- Finish a branch locally (code, comments, build, diff review) before pushing. Once a branch is pushed,
  add follow-up commits rather than force-pushing.
- Keep PRs focused. README restructures go in their own PR. Don't rebuild the committed `.pkg`/`.zip`
  installers or change the version in a PR; the maintainer does that in a release (`docs/RELEASING.md`).
- A PR description says what was tested on hardware, on what, and what was **not** tested.

## Testing

- Build both `make plugin` and `make plugin DEBUG=1`; build every tool you touched.
- Install with `tools/install-sl4.sh` (needs `sudo`).
- `make hwtest` runs the hardware tests in one go; read `tools/latency/README.md` for the setup.
- Audio changes: a loopback cable from Deck 1 Out L to Deck 1 In L (channel 1, if the channel order is as
  assumed; see `docs/SL4-COMMANDS.md`), with deck 1's input switch on LINE (PHONO's preamp clips the test
  tones). Test at both of the box's rates, 48 and 96 kHz (set on the box). Then `tools/latency/dptest.sh` and
  `tools/latency/restartcheck.sh`, both PASS, and `rtlat` if latency could have changed. Use the debug
  hooks (`sl4dbg stall`, `sl4dbg errpkts`) to reproduce stalls and errors instead of waiting for them.
- Connect and status changes: unplug and replug while idle and while streaming; check Audio MIDI Setup
  and `sl4panel`.
- Client changes: `sl4apitest` (both slices), Rane's SL 4 control panel (Intel Macs only), and Serato DJ Pro where possible.
  Serato DJ Pro 4.x / 5.x use the driver directly; only 2.5.x loads `SL4Api`.
- When testing with someone at the hardware, ask for each physical step explicitly (connect the
  loopback, flip a switch, replug), and order the tests so they need the fewest of those steps.
