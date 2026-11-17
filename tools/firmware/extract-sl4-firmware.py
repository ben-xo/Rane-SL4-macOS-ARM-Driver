#!/usr/bin/env python3
"""Extract and de-obfuscate the Rane SL 4 firmware image from Rane's official macOS driver.

Source  : Rane's "RaneSL4_2.0.1f1.pkg" (the SL 4 driver Serato DJ Pro 2.5.5 bundles and offers to
          install; inside it, Library/Frameworks/SL4Api.framework/Versions/A/SL4Api), or that SL4Api
          binary itself (universal or thin x86_64), or a folder holding either (an expanded package,
          a mounted disk).
Output  : sl4_firmware_<maj>.<min>.bin (0x1B040 B: the 0x40-byte Rane header and the flash sections;
          what sl4flash writes and sl4dump compares against)

The image is embedded in the x86_64 slice of SL4Api, obfuscated with a 256-byte repeating XOR key
(the local symbol kKeyBytes): out[i] = in[i] ^ key[i % 256]. Neither is found by a fixed offset: the
key is the 256-byte block whose SHA-256 is KEY_SHA256, and the image is where the key turns the
bytes into the start of Rane's header ("Copyright 20"). Its length comes from the de-obfuscated
header. The result is then checked exactly as Rane's IsValidFirmwareImage checks an image (header,
length, CRC-32, every summary-table entry), plus a few checks of the table's layout that the box's
boot program relies on, and its SHA-256 is compared with the known build's. A different build, a
damaged file or a wrong match therefore stops here instead of producing an image that sl4flash
could write.

The image format is in docs/SL4-COMMANDS.md ("Firmware storage and update", "Image format"). No
vendor code is executed. Python 3 standard library only, plus macOS's pkgutil for a .pkg.

Usage:
  extract-sl4-firmware.py <RaneSL4_2.0.1f1.pkg | SL4Api | folder> [outdir]
"""
import hashlib, os, struct, subprocess, sys, tempfile, zlib

KEY_LEN = 0x100
# SHA-256 of the 256-byte XOR key (kKeyBytes in SL4Api 2.0.1f1; the same key as the SL 2's and
# SL 3's), and of each known de-obfuscated image: version → SHA-256.
KEY_SHA256 = "d47954d8038dda6cea66ddb8bd509ed66e6b4607f00d139aef8c4e03c370dc60"
KNOWN_IMAGES = {
    (1, 2): "93f22e8e241e1ad273f250a3fecd0684b36acd6b33bf2113a27b1f3266312aa1",   # SL4Api 2.0.1f1
}

# The Rane header (IsValidFirmwareImage): copyright at 0x00 (bytes 12-13, the year, not compared),
# the test bytes at 0x20 (type 02, VID 1CC5, PID 000F, 01 00), the version at 0x27/0x28, the body
# length at 0x38 and its CRC-32 at 0x3C, both big-endian.
HDR_LEN = 0x40
COPYRIGHT = b"Copyright 20?? Rane Corporation\0"
TEST_BYTES = bytes([0x02, 0x1C, 0xC5, 0x00, 0x0F, 0x01, 0x00])
# The summary table: section 0, at the start of the body, programmed at flash 0x4000. Entries are
# 12 bytes {flashAddr, length, rawCRC}, little-endian; entry 0 describes the table itself.
TABLE_FLASH = 0x4000
ENTRY_LEN = 12
PAGE = 0x100                  # the box programs whole 256-byte pages
FLASH_END = 0x7D000           # the LPC2148's flash ends where its ROM bootloader starts

CPU_TYPE_X86_64 = 0x01000007


def raw_crc(data):
    """The table's CRC: CRC-32's register with no final reflection and no final xor (Rane's
    CalcChecksum(..., false); the box's boot program computes the same)."""
    reg = zlib.crc32(data) ^ 0xFFFFFFFF
    return int(f"{reg:032b}"[::-1], 2)


def fail(msg):
    sys.exit(f"[!] {msg}")


def is_macho(path):
    """True if path is a Mach-O file (thin or universal)."""
    with open(path, "rb") as f:
        magic = f.read(4)
    return magic in (b"\xca\xfe\xba\xbe", b"\xca\xfe\xba\xbf", b"\xcf\xfa\xed\xfe", b"\xce\xfa\xed\xfe")


def find_source(p):
    """The package or the SL4Api binary: the argument itself, or the first found under it."""
    if os.path.isfile(p):
        return p
    if not os.path.isdir(p):
        fail(f"no such file or folder: {p}")
    for root, _, files in os.walk(p):
        for f in sorted(files):
            full = os.path.join(root, f)
            if f == "SL4Api" and not os.path.islink(full) and is_macho(full):
                return full
            if f.endswith(".pkg") and "SL4" in f.upper() and os.path.isfile(full):
                return full
    fail(f"could not find a RaneSL4 .pkg or an SL4Api binary under {p}")


def sl4api_from_pkg(pkg, work):
    """Expand the package fully under `work` and return the path of the SL4Api binary in it."""
    dest = os.path.join(work, "pkg")
    r = subprocess.run(["pkgutil", "--expand-full", pkg, dest], capture_output=True, text=True)
    if r.returncode != 0:
        fail(f"pkgutil could not expand {pkg}: {r.stderr.strip()}")
    for root, _, files in os.walk(dest):
        if "SL4Api" in files and root.endswith(os.path.join("SL4Api.framework", "Versions", "A")):
            full = os.path.join(root, "SL4Api")
            if not os.path.islink(full) and is_macho(full):
                return full
    fail("the package holds no SL4Api.framework: not Rane's SL 4 driver package")


def x86_64_slice(blob):
    """The x86_64 Mach-O inside blob: blob itself if it is thin, else that slice of the universal
    file (read from its fat header, so lipo isn't needed)."""
    magic = blob[:4]
    if magic == b"\xcf\xfa\xed\xfe":
        cputype = struct.unpack_from("<I", blob, 4)[0]
        if cputype != CPU_TYPE_X86_64:
            fail(f"the binary is a thin Mach-O for CPU type 0x{cputype:x}, not x86_64")
        return blob
    if magic in (b"\xca\xfe\xba\xbe", b"\xca\xfe\xba\xbf"):
        is64 = magic == b"\xca\xfe\xba\xbf"
        n = struct.unpack_from(">I", blob, 4)[0]
        pos = 8
        for _ in range(n):
            if is64:
                cputype, _, off, size, _, _ = struct.unpack_from(">IIQQII", blob, pos)
                pos += 32
            else:
                cputype, _, off, size, _ = struct.unpack_from(">IIIII", blob, pos)
                pos += 20
            if cputype == CPU_TYPE_X86_64:
                if off + size > len(blob):
                    fail("the universal binary's x86_64 slice runs past the end of the file")
                return blob[off:off + size]
        fail("the universal binary has no x86_64 slice")
    fail("not a Mach-O binary (expected SL4Api, or Rane's SL 4 .pkg)")


def find_key(sl):
    """The 256-byte XOR key: the block of the slice whose SHA-256 is the known key's."""
    for off in range(0, len(sl) - KEY_LEN + 1):
        if hashlib.sha256(sl[off:off + KEY_LEN]).hexdigest() == KEY_SHA256:
            return off, sl[off:off + KEY_LEN]
    fail("the XOR key is not in this SL4Api: not Rane's SL4Api, or a build this script doesn't know")


def deobfuscate(data, key):
    """Undo (or apply: it is symmetric) the repeating-XOR obfuscation."""
    return bytes(b ^ key[i % KEY_LEN] for i, b in enumerate(data))


def find_image(sl, key):
    """The file offset and de-obfuscated contents of the embedded image: the one place where the
    key turns the bytes into the header's fixed start, with the length the header gives."""
    known = COPYRIGHT[:12]                                   # "Copyright 20"
    needle = bytes(c ^ key[i] for i, c in enumerate(known))
    hits = []
    start = sl.find(needle)
    while start >= 0:
        hits.append(start)
        start = sl.find(needle, start + 1)
    found = []
    for off in hits:
        if off + HDR_LEN > len(sl):
            continue
        hdr = deobfuscate(sl[off:off + HDR_LEN], key)
        if hdr[0x20:0x27] != TEST_BYTES:
            continue
        length = HDR_LEN + int.from_bytes(hdr[0x38:0x3C], "big")
        if off + length > len(sl):
            continue
        found.append((off, deobfuscate(sl[off:off + length], key)))
    if not found:
        fail("no embedded SL 4 firmware image found in this SL4Api")
    if len(found) > 1:
        fail(f"{len(found)} candidate images found (at {', '.join(hex(o) for o, _ in found)}); expected one")
    return found[0]


def validate(img):
    """Check the image as Rane's IsValidFirmwareImage does, then the extra layout checks. Returns
    the table entries [(addr, length, crc, image offset)]."""
    # IsValidFirmwareImage: the minimum size, the copyright with the year skipped, the test bytes,
    # the length, and the CRC-32 of the body.
    if len(img) < 0x4C:
        fail("the image is shorter than its header")
    for i, (got, want) in enumerate(zip(img[:0x20], COPYRIGHT)):
        if (i & ~1) != 0x0C and got != want:
            fail("the image's copyright line is not Rane's")
    if img[0x20:0x27] != TEST_BYTES:
        fail("the image is not for the SL 4 (header bytes 0x20-0x26 are not 02 1C C5 00 0F 01 00)")
    body_len = int.from_bytes(img[0x38:0x3C], "big")
    if body_len + HDR_LEN != len(img):
        fail(f"the header's body length 0x{body_len:x} + 0x40 is not the image's size 0x{len(img):x}")
    want = int.from_bytes(img[0x3C:0x40], "big")
    got = zlib.crc32(img[HDR_LEN:]) & 0xFFFFFFFF
    if got != want:
        fail(f"the body's CRC-32 0x{got:08x} doesn't match the header's 0x{want:08x}")

    # IsValidFirmwareImage: the summary table. Entry 0 sets the table's size; entries run up to
    # the first with address 0; each section's data follows the previous one in the body and must
    # fit in the file; entry 0's CRC covers the table after itself, every other entry's its section.
    table_len = struct.unpack_from("<I", img, HDR_LEN + 4)[0]
    if table_len < ENTRY_LEN or HDR_LEN + table_len > len(img):
        fail(f"the summary table's length 0x{table_len:x} doesn't fit the image")
    entries, off = [], HDR_LEN
    for i in range(table_len // ENTRY_LEN):
        addr, length, crc = struct.unpack_from("<III", img, HDR_LEN + i * ENTRY_LEN)
        if addr == 0:
            break
        if off + length > len(img):
            fail(f"section {i} (flash 0x{addr:05x}, 0x{length:x} B) runs past the end of the image")
        data = img[HDR_LEN + ENTRY_LEN:HDR_LEN + table_len] if i == 0 else img[off:off + length]
        if raw_crc(data) != crc:
            fail(f"section {i} (flash 0x{addr:05x}): CRC 0x{raw_crc(data):08x}, table says 0x{crc:08x}")
        entries.append((addr, length, crc, off))
        off += length
    else:
        fail("the summary table has no terminating entry (address 0), which the box's boot program requires")

    # Not Rane's checks, but what the box's boot program and the write protocol rely on: the table
    # at 0x4000 and at most a sector long; whole pages; nothing in the protected boot program
    # (below 0x4000) or past the flash; sections in order without overlap; the body exactly the
    # sections.
    if entries[0][0] != TABLE_FLASH or table_len > 0x1000:
        fail("the summary table is not at flash 0x4000 with at most 0x1000 bytes")
    prev_end = 0
    for i, (addr, length, _, _) in enumerate(entries):
        if length == 0 or length % PAGE or addr % PAGE:
            fail(f"section {i} (flash 0x{addr:05x}, 0x{length:x} B) is not whole 256-byte pages")
        if addr < TABLE_FLASH or addr + length > FLASH_END:
            fail(f"section {i} (flash 0x{addr:05x}) is outside the writable flash 0x4000-0x7CFFF")
        if addr < prev_end:
            fail(f"section {i} (flash 0x{addr:05x}) overlaps or precedes the previous section")
        prev_end = addr + length
    if off != len(img):
        fail(f"the sections end at 0x{off:x}, not at the end of the image (0x{len(img):x})")
    return entries


def main():
    # The source and the output directory.
    if len(sys.argv) < 2 or sys.argv[1] in ("-h", "--help"):
        sys.exit(__doc__)
    src = find_source(sys.argv[1])
    out = sys.argv[2] if len(sys.argv) > 2 else "sl4-fw-out"
    print(f"[*] source: {src}")

    # Read SL4Api (from the package, expanded into a temporary folder discarded on exit, so no copy
    # of the vendor binary is left behind) and take its x86_64 slice.
    with tempfile.TemporaryDirectory(prefix="sl4fw.") as work:
        binpath = sl4api_from_pkg(src, work) if src.endswith(".pkg") else src
        with open(binpath, "rb") as f:
            blob = f.read()
    sl = x86_64_slice(blob)

    # Find the key and the image, and de-obfuscate the image.
    koff, key = find_key(sl)
    ioff, img = find_image(sl, key)
    print(f"[*] x86_64 slice: XOR key at 0x{koff:x}, image at 0x{ioff:x} (0x{len(img):x} B)")

    # Validate it, then compare it with the known build.
    entries = validate(img)
    ver = (img[0x27], img[0x28])
    sha = hashlib.sha256(img).hexdigest()
    if KNOWN_IMAGES.get(ver) != sha:
        fail(f"the image (firmware {ver[0]}.{ver[1]:02d}, SHA-256 {sha}) passes Rane's checks but is not "
             f"a known build: not writing it")
    print(f"[*] valid: firmware {ver[0]}.{ver[1]:02d}, body 0x{len(img) - HDR_LEN:x} B, "
          f"CRC-32 0x{int.from_bytes(img[0x3C:0x40], 'big'):08x}, SHA-256 matches Rane's build")
    for i, (addr, length, crc, off) in enumerate(entries):
        print(f"    section {i}: flash 0x{addr:05x}, 0x{length:05x} B, CRC 0x{crc:08x} (image 0x{off:05x})")

    # Write it (a firmware image; *.bin is git-ignored in this folder).
    os.makedirs(out, exist_ok=True)
    path = os.path.join(out, f"sl4_firmware_{ver[0]}.{ver[1]:02d}.bin")
    with open(path, "wb") as f:
        f.write(img)
    print(f"[+] wrote {path} ({len(img)} B)")


if __name__ == "__main__":
    main()
