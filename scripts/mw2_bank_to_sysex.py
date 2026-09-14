#!/usr/bin/env python3
"""Convert a raw Microwave II/XT sound bank image into XT Single dumps.

Waldorf's factory bank ships as a raw 64 KB memory image ("Factory.<micro>sb"),
NOT as sysex -- there is not a single 0xf0 in it -- so it cannot simply be
renamed to .syx or .mid. Each sound is a 256-byte record; the image holds 256 of
them, which is the XT's two banks of 128.

Each record is wrapped in the XT's own Single dump framing, giving the 265-byte
message xtState declares (Dumps[Single].dumpSize == 265):

    f0 3e 0e <dev> 10 <bank> <prog> <256 data bytes> <checksum> f7
     0  1  2   3    4    5      6    7 .. 262          263      264

  - 0x3e   wLib::IdWaldorf          - 0x0e   xt::IdMw2
  - 0x10   SysexCommand::SingleDump
  - bank   LocationH::SingleBankA (0x00) / SingleBankB (0x01)
  - checksum: sum of bytes from IdxSingleChecksumStart (7) up to but not
    including the checksum byte itself, masked to 7 bits (wLib::State::
    updateChecksum).

The record layout needs no translation: the name sits at record offset 240,
which is the 247 that xt::mw2::g_singleNamePosition specifies for a dump
INCLUDING the 7-byte header, and every byte of the image is already <= 0x7f, so
the payload is sysex-clean as it stands.

Usage:  mw2_bank_to_sysex.py <Factory.bin> <out.syx> [device_id]
"""
import sys

RECORD_SIZE      = 256
DUMP_SIZE        = 265
NAME_OFFSET      = 240   # within the record
NAME_LENGTH      = 16
CHECKSUM_START   = 7
SOUNDS_PER_BANK  = 128

ID_WALDORF, ID_MW2, CMD_SINGLE_DUMP = 0x3e, 0x0e, 0x10


def convert(image: bytes, device_id: int = 0x00):
    if len(image) % RECORD_SIZE:
        raise SystemExit(f"not a whole number of {RECORD_SIZE}-byte records: {len(image)} bytes")

    hi = max(image)
    if hi > 0x7f:
        raise SystemExit(f"image is not 7-bit clean (max byte 0x{hi:02x}); not a raw MW2 bank")

    out, names = bytearray(), []

    for i in range(len(image) // RECORD_SIZE):
        rec  = image[i * RECORD_SIZE:(i + 1) * RECORD_SIZE]
        bank, prog = divmod(i, SOUNDS_PER_BANK)

        msg = bytearray([0xf0, ID_WALDORF, ID_MW2, device_id, CMD_SINGLE_DUMP, bank, prog])
        msg += rec
        msg.append(sum(msg[CHECKSUM_START:]) & 0x7f)
        msg.append(0xf7)

        assert len(msg) == DUMP_SIZE, len(msg)
        # the name must land where the plugin looks for it, or the list is blank
        assert msg[247:247 + NAME_LENGTH] == rec[NAME_OFFSET:NAME_OFFSET + NAME_LENGTH]

        out += msg
        names.append(rec[NAME_OFFSET:NAME_OFFSET + NAME_LENGTH].decode('latin1').rstrip())

    return bytes(out), names


def main():
    if len(sys.argv) < 3:
        raise SystemExit(__doc__)

    image = open(sys.argv[1], 'rb').read()
    data, names = convert(image, int(sys.argv[3], 0) if len(sys.argv) > 3 else 0x00)
    open(sys.argv[2], 'wb').write(data)

    print(f"{len(names)} sounds -> {len(data)} bytes ({len(names)} x {DUMP_SIZE})")
    print("first 8:", ', '.join(repr(n) for n in names[:8]))
    print("last 2 :", ', '.join(repr(n) for n in names[-2:]))


if __name__ == '__main__':
    main()
