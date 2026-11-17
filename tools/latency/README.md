# Latency and glitch test tools

These tools measure what a DJ feels: the round trip from a deck input, through the computer, back out to
the deck output, and whether that audio ever breaks up. They come from the SL 2 driver, where they took
the estimated DVS round trip from ~105 ms to 12.2 ms measured at a 128-frame IO buffer and 9.3 ms at a
64-frame one, with no glitches under load. The SL 4 driver shares that engine; its own figures are still
to be measured on an SL 4 (see "Expected results"). See `docs/SL4-AUDIO-ENGINE.md`.

The measurement tools work with any CoreAudio device. `dptest.sh`, `restartcheck.sh` and `logq.sh` take
the device name, the driver's log subsystem and the looped-back channel from environment variables (the
other tools take the device name and channels as arguments):

```
SL_DEVICE="SL 4" SL_LOG_SUBSYSTEM=com.rane.sl4 SL_LOOP_CH=1 tools/latency/restartcheck.sh
```

The log lines the scripts look for are the SL 4 driver's (the same as the SL 2 driver's), so they need
adapting for another driver.

## The SL 4's sample rate and channels

- **The rate is chosen on the box**, 48 or 96 kHz, with its rate control; the driver publishes whatever
  rate the box is at and refuses any other. So the tools can't switch rates: `setrate` only shows the
  rate, and the tests run at the rate the box is at. To test the other rate, flip the box's 48/96 kHz
  control and run them again (`ratetest.sh <device> <seconds>` and `make hwtest` can watch for the
  change while someone flips it).
- **The channel order is not verified on hardware.** The driver assumes channels 1-2, 3-4, 5-6 and 7-8
  are decks 1-4 (left, right) and 9-10 Aux, in and out. The tests default to channel 1 (Deck 1 Out L →
  Deck 1 In L). If the clicks are not found on channel 1, find the channel the cable is on (play
  `bin/chtone "SL 4" 5 <ch>` on each output in turn, and record with `bin/chrec`) and set `SL_LOOP_CH`
  for the scripts and `make hwtest`.

## Setup

1. Build the tools: `make latency` (into `tools/latency/bin/`).
2. Connect a **loopback cable** from Deck 1 Out L to Deck 1 In L: channel 1, if the channel order above
   holds. Use nothing else on that output: the tools send clicks and a loud tone into it.
3. Set Deck 1's LINE/PHONO switch to **LINE**. A line-level signal into the phono preamp clips, and the
   glitch test then reports a glitch at its first analysed sample. The SL 4 does not report its
   LINE/PHONO switches, so no tool can check this: look at the switch.

   Unplug the cable when the tests are done. With nothing streaming the decks are on analogue thru, which
   connects each deck's input to its output inside the box: with the cable in, that is a feedback loop.
4. Install the driver build under test: `make install` (add `DEBUG=1` for the driver's counters and
   `sl4dbg`), which builds it and runs `sudo tools/install-sl4.sh`. The script replaces the binary inside
   the installed driver, so the release package (`Installer/RaneSL4-macOS-Universal.pkg`) must be
   installed first. Run the script directly for its other options: `--api` also installs a built SL4Api
   (`make api`), saving the previous one; `--restore-api` puts that back.

## Running everything

`make hwtest` runs the SL 4's hardware tests in one go (`tools/hwtest.sh`) and ends with a PASS / FAIL /
SKIP summary; the full output goes to a log file it names. It runs them in the order that needs the
fewest physical steps:

1. with only the box attached: the driver's status (including the box's USB port and that it is not in
   its firmware updater), SL4Api as Serato DJ Pro 2.5.5 calls it (`sl4apitest`, both slices), the
   device's rate being the box's and a host rate change being refused, the input safety offset setting,
   and the early capture read working;
2. with `ARGS="--loopback"`, which says the loopback cable is in (the tests play clicks and a loud tone
   into Deck 1 Out L): `restartcheck.sh`, a 30 s glitch test (with no 0x37 heartbeat sent), IO buffer
   sizes, the output volume and mute (it puts your volume and mute back afterwards), the level meters,
   and with a debug build `dptest.sh`, the capture packet sizes and the `sl4dbg` fault hooks (a USB
   stall, errored capture packets), all at the box's rate;
3. steps for someone at the box: flipping the box's 48/96 kHz control (the device must follow it, both
   ways), sleeping and waking the Mac, and unplugging and replugging while idle and while a (silent)
   stream runs. The script prints each step and waits until it sees the change, so nothing needs
   typing. `ARGS="--no-physical"` skips them.

Run it in a Terminal window, so the steps show as they come up. A release build skips the tests that
need the debug build's counters and hooks; run it again with a debug build to cover those. To cover both
rates, run the loopback tests once at each: flip the box's rate control between the runs.

## Tools

| Tool | What it does | Pass |
|---|---|---|
| `bin/rtlat <device> <out-ch> <in-ch> [clicks] [buffer]` | Round-trip latency. Plays clicks, finds them in the input, and reports the latency the HAL's timestamps don't account for ("hidden") and the estimated DVS round trip | every click found; hidden latency close to the driver's reported total |
| `bin/sinetest <device> <out-ch> <in-ch> <seconds> [buffer]` | Glitch test. Plays a continuous 997 Hz sine and checks every captured sample against the sine recurrence: any dropout, repeat, skip or click breaks it. Analysis starts after the first second | "0 glitches, 0 level drops" |
| `dptest.sh <seconds>` | `sinetest` idle, then with every core busy, plus the driver's counters from its log (debug build) | prints PASS |
| `restartcheck.sh` | Three streams in a row: each must start cleanly and find all its clicks | prints PASS |
| `bin/sl4dbg stall <ms> \| errpkts <n> \| noearly 1\|0` | Debug build only: test hooks (debug commands `0xF3`-`0xF5` through the driver's `sl4h` property, never sent to the box) that stall the driver's USB queue, error capture packets, or switch the early capture read off. (The input safety offset is a setting in every build: `sl4panel safety <ms>`.) | — |
| `bin/chtone <device> <seconds> <ch...>` | A 440 Hz tone on chosen output channels, the way Audio MIDI Setup's test tone plays it | heard on each channel |
| `bin/chrec <device> <seconds> <out.wav>` | Starts IO from cold and records the input, reporting when signal first appears and any dropouts | no dropouts |
| `envelope.py <wav>` | Peak level of a `chrec` recording in 100 ms windows | — |
| `bin/devprobe <device>` | Dumps the HAL properties that output-device pickers check | — |
| `bin/setrate <device> [rate \| try <rate>]` | Prints a device's sample rate and the rates it lists. Given a rate, says whether the device is at it, and otherwise refuses (the SL 4's rate is set on the box); `try` asks the driver anyway and passes if the driver refuses | — |
| `bin/volctl <device> [get \| <dB> [channel] \| main <0..1> \| mute \| unmute]` | Prints or sets a device's output volume and mute through the properties Audio MIDI Setup uses: `<dB>` sets the main volume, or with a channel number that channel's; `main` sets the virtual main volume the way the volume keys do. Note that `rtlat` reads quieter clicks one to three frames later (its fixed threshold catches the converters' pre-ringing sooner on a loud click), so compare latency at the same click level | — |
| `bin/meters <device> [seconds]` | Reads the SL 4 driver's level meters (`sl4m`, what the control panel shows: inputs 1-10, then outputs 1-10) for a while and prints each channel's highest peak in dB. They move only while an app is streaming | — |
| `ratetest.sh <device> [seconds]` | Speaks a sentence on the device at the box's rate and times it; with a time, then waits that long for someone to flip the box's 48/96 kHz control and speaks again at the new rate | speech at the right pitch both times; the device follows the box |
| `logq.sh [minutes] [lines]` | The driver's log, with coreaudiod's and Audio MIDI Setup's relevant lines | — |

Also in `tools/`: `install-sl4.sh` installs a driver build and restarts coreaudiod and the processes that
go stale when it restarts; `restart-audio.sh` does the restart alone.

## Expected results

Nothing here has been measured on an SL 4 yet. What to expect, from the engine and the box's USB format:

- `restartcheck.sh`: three streams, each with "(4/4 clicks)", then PASS.
- `dptest.sh 30` (debug build): "0 glitches" idle and loaded, then PASS.
- `DBG capture packet sizes`: 6 frames per microframe at 48 kHz and 12 at 96 kHz, with the odd 5 or 7
  (11 or 13) where the box corrects its clock (the SL 3 showed about 0.5%).
- The round trip in milliseconds should come out lower at 96 kHz for the same IO buffer in frames.

The SL 2 driver (the same engine) at 44.1 kHz, for comparison:

- `restartcheck.sh`: three streams, each "DVS round trip est. 12.2 ms (4/4 clicks)" at a 128-frame
  buffer, then PASS.
- `rtlat "SL 2" 1 1 20 64` (a 64-frame buffer): "DVS round trip est. 9.3 ms".
- `dptest.sh 60` (debug build): "0 glitches" idle and loaded, then PASS.
- The debug build's `DBG dp` counters (`logq.sh`): late 0, unscheduled flat after start-up, enqueue refused
  0, resyncs 0, sent − captured within ±2, rewritten samples 0. Its `DBG early read` lines: completion
  found 0 different, SILENCE (not captured yet) 0, least margin above 0.5 ms.
- `sl2dbg stall 100` during a `sinetest`: one gap, shorter than the stall (the 64 one-millisecond capture
  transfers already queued keep receiving audio, so only the rest is lost: about 40 ms for a 100 ms stall),
  the driver logs "Capture: N ms not captured", and the stream carries on. `sl2dbg stall 20`: no gap (the
  early capture read covers it). `sl2dbg errpkts 20`: a gap of about 3 ms, sent − captured within ±2.
  `sl4dbg` gives the same hooks on the SL 4.
