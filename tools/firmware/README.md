# Rane SL 4 firmware tools

Everything for getting firmware onto a Rane SL 4. **None of it has been tried on an SL 4**: the protocol
and the image format come from the analysis of Rane's driver, API and firmware
(`docs/SL4-COMMANDS.md`, "Firmware storage and update").

The SL 4's firmware lives in the flash of its main processor (an ARM7, LPC2148-class): a protected boot
program at 0x0000–0x3FFF, a summary table at 0x4000 (address, length and CRC of every section), a copy of
the boot program, the application, the FPGA bitstream and the USB controllers' (FX2) firmware. At every
reset the boot program checks the table and every section's CRC. Only if all match does it start the
firmware, and the box comes up as "Rane SL 4" (`1CC5:000F`, bcdDevice `0x0100`), answering version 1.02.
Otherwise it stays in its **firmware updater** (bcdDevice `0x9900`): no audio, only the commands that
read the table and write flash.

The firmware is Rane's and is **not** included here. You extract it from **your own** copy of Rane's SL 4
driver, `RaneSL4_2.0.1f1.pkg`, with `extract-sl4-firmware.py`; `.gitignore` keeps the extracted image out of
the repository. (Serato DJ Pro 2.5.5 carries that package among its resources and offers to install it
when an SL 4 is connected; it is also in Rane's and Serato's driver archives.)

## Writing it over USB, with `sl4flash`

`sl4flash` follows Rane's own update sequence (`UpdateFirmware` in SL4Api 2.0.1f1):

1. Is the box running, or already in its updater (`0x13`, and bcdDevice)?
2. A running box gets **`0x17`**: it marks its firmware invalid (adds 1 to a byte of the table's own CRC,
   rewriting flash sector 4) and restarts in its updater. From then until the update succeeds, the box
   has no audio, at every power-up.
3. `sl4flash` opens the updater directly (the driver leaves a box in that state alone), reads the box's
   table with `0x15` and saves it to `sl4-table-backup-<date>.bin` in the current directory.
4. It writes the image's table first, then each section, in 256-byte pages: per page, seven `0x14` blocks
   posted and an eighth answered when the box has programmed the page. The first page of a flash sector
   erases that sector. As Rane does, a section is skipped only if the box was running before and its
   table already gives that section the image's CRC; a box that was already in its updater gets every
   section.
5. It reads the table back and compares it with the image's, sends **`0x16`** (the box restarts and its
   boot program checks every CRC), waits for the box, and checks it runs the image's version and is no
   longer in its updater.

**What is verified, and what isn't.** The protocol cannot read the flash back, except the table sector
and only in the updater, so `sl4flash` cannot compare the written sections with the image. What it checks:
the image passes every check Rane's `IsValidFirmwareImage` makes (header, length, CRC-32, every table
entry's CRC) plus the layout the box relies on; every page is acknowledged as programmed; the table reads
back as written; and the box's boot program accepts every section's CRC at the restart (the firmware runs
only if it does), after which `sl4flash` reads the version.

**If it fails.** According to the analysis of Rane's code (untested), an update interrupted at any point
after `0x17`, or a section written wrongly, leaves the box in its updater: the boot program and the
updater's own USB firmware are below 0x4000, which the updater refuses to write, and the boot program
won't start firmware whose CRCs don't match. Run `sl4flash` again; it rewrites every section. There is no
SOIC-clip fallback as for the SL 2 and SL 3, whose firmware is in an EEPROM: the SL 4's is inside the
processor, which could only otherwise be reached through its own serial programming port on the board.

Its other guarantees:

- It doesn't write firmware older than, or the same as, what the box runs, nor an image other than
  Rane's known 1.02 build, unless given `--force` (Rane's control panel only ever offered a newer one).
  In the updater no firmware version can be read (the updater answers its own), so this check applies
  only to a running box.
- It refuses while the box streams audio, while a computer is on the box's other USB port (the updater
  takes writes from one port only), and with more than one SL 4 USB device attached.
- It says what it will do and asks before changing the box (`--yes` skips the question).

`--leave-updater` (**untested**) is for a box left in its updater by `0x17` alone (an update that stopped
before writing anything): if the box's table differs from a valid one only by `0x17`'s mark, and the rest
of the table sector is blank, it rewrites the table page with the byte put back and restarts the box. If
the other sections are intact, the box then runs the firmware it already had; if not, it stays in its
updater, as before. It never writes a section.

## Usage

```
tools/firmware/extract-sl4-firmware.py RaneSL4_2.0.1f1.pkg          # into sl4-fw-out/
sudo tools/firmware/sl4-firmware-install.sh sl4-fw-out/sl4_firmware_1.02.bin
make flash dump
./sl4dump                           # version, updater flag, ports, USB state, rate; change nothing
./sl4flash --check                  # check the image and the box, say what would be done; change nothing
./sl4flash                          # update the box if the image is newer than what it runs
./sl4flash --leave-updater --check  # (box in its updater) would the untested shortcut apply?
```

`sl4flash` reads the image from `/Library/Audio/Plug-Ins/HAL/SL4Device.firmware` (where
`sl4-firmware-install.sh` puts it), or from `--firmware PATH` (the image, or a folder holding it). It needs
no root. A running box is reached through this project's HAL driver, so the driver must be installed;
stop any audio on the SL 4 and quit sl4panel, the SL 4 Control Panel and Serato first, since they talk to
the box through the same driver channel. Exit status: 0 done or nothing to do, 1 failed or refused, 2 bad
arguments, 3 (`--check`) the box would be written.

`--check` sends only safe commands: `0x01`, `0x13`, `0x45`, `0x0a` and `0x4A` to a running box; `0x13`,
`0x01` and `0x15` (table read) to a box already in its updater.

## Files

- `extract-sl4-firmware.py` — de-obfuscate the firmware image out of your own copy of Rane's SL4Api (from
  the package, which it expands with `pkgutil --expand-full` into a temporary folder, from an expanded
  package, or from the binary, universal or thin x86_64). It finds the XOR key by its SHA-256 and the image
  by its decrypted header (no fixed offsets), checks it as Rane's `IsValidFirmwareImage` does, and checks
  its SHA-256 against Rane's 1.02 build. Python 3 standard library only.
- `sl4flash.m` — the flasher.
- `sl4-firmware-install.sh` — install the image next to the HAL driver for `sl4flash`.

Outside this folder: `tools/sl4dump.m` reads what can be read safely (through the driver for a running box;
the table, directly, for a box in its updater, compared with an image given with `--image`; it never sends
`0x17`), and `tools/SL4Passthrough.{h,m}` sends commands to a running box through the HAL driver.

## Licensing

The firmware is proprietary Rane / Serato code, extracted only for interoperability with hardware you
own. Do not commit the extracted image or the table backups, or redistribute them; supply your own copy
of the official driver.
