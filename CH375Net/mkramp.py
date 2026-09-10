#!/usr/bin/env python3
"""Generate the ramp fixtures RAMPCHK is tested and used with.

CH375Net, StevenC.  Public domain (the Unlicense).

    python mkramp.py [--out DIR] [--stage DIR]

The test server serves files whose byte at offset N is N mod 256, so the
correct content of a download is knowable without having the source file --
which is what lets RAMPCHK say WHERE and HOW a transfer went wrong instead
of only that it did.

Three of these are the instrument's own test cases, and they are the reason
this script exists rather than four binaries in the repository.  A checker
that has never been shown able to FAIL is not evidence, so RAMPCHK is
validated against a clean file, a file with bytes dropped, and a file with
bytes altered -- and it has to name all three correctly, including which
kind of fault it is looking at.  Keeping them as a generator means the
fixtures and the definition of what they contain cannot drift apart.

    RAMPOK.BIN   64 KB, exactly the ramp                  -> rc 0
    RAMPSH.BIN   64 KB, 3 bytes dropped at offset 20000   -> rc 2, SHIFTED
    RAMPAL.BIN   64 KB, 3 bytes altered in place          -> rc 1, ALTERED
    BIG5M.BIN    5 MB, exactly the ramp

RAMPSH is the one worth understanding.  A dropped-byte fault does not stop
at the seam: everything after it is still a clean ramp, just one that no
longer lines up with its own address, so the transfer still delivers the
full length and the tail is the NEXT bytes of the source rather than a tidy
correct ending.  Building it any other way -- padding the tail with the
bytes that BELONG there, say -- makes the run end early and the tool report
ALTERED instead of SHIFTED, which is a false negative in a case designed to
be a true positive.  That mistake was made first.

BIG5M.BIN is the fixture for the mTCP-free test: USBGET fetches it over
DOSBridge's own TFTP through the CH375 adapter, so a corrupt result accuses
the driver with no TCP anywhere in the path.  Stage it where dosd serves
from:

    python mkramp.py --stage C:\\dosbridgeDEV\\files\\local
"""

import argparse
import os
import zlib

N64 = 64 * 1024
N5M = 5 * 1024 * 1024


def ramp(n, start=0):
    """n bytes of the source stream, beginning at absolute offset `start`."""
    return bytes((start + i) & 255 for i in range(n))


def cases():
    src = ramp(N64 + 16)                      # a little past the end, for the
    yield "RAMPOK.BIN", src[:N64]             # dropped-byte tail below

    # Three bytes dropped at 20000, and the transfer still delivers N64
    # bytes -- so the tail is the next three SOURCE bytes, not a correct
    # ending.  See the note above: this is what a real drop looks like.
    yield "RAMPSH.BIN", src[:20000] + src[20003:20003 + (N64 - 20000)]

    alt = bytearray(src[:N64])
    for off in (1000, 30000, 50000):
        alt[off] ^= 0xFF
    yield "RAMPAL.BIN", bytes(alt)

    yield "BIG5M.BIN", ramp(N5M)


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--out", default=".", help="where to write them")
    ap.add_argument("--stage", default=None,
                    help="also copy BIG5M.BIN here, for dosd to serve")
    a = ap.parse_args()

    os.makedirs(a.out, exist_ok=True)
    for name, blob in cases():
        p = os.path.join(a.out, name)
        with open(p, "wb") as fh:
            fh.write(blob)
        print("%-12s %9d bytes  CRC-32 %08X" % (name, len(blob),
                                                zlib.crc32(blob)))
        if a.stage and name == "BIG5M.BIN":
            os.makedirs(a.stage, exist_ok=True)
            q = os.path.join(a.stage, name)
            with open(q, "wb") as fh:
                fh.write(blob)
            print("%-12s staged to %s" % ("", q))

    print()
    print("The 1 MB / 5 MB / 10 MB files the HTTP server serves are the same")
    print("ramp, so their checksums are fixed and comparable:")
    print("  1 MB   04D0E435")
    print("  5 MB   BDBF684D")
    print(" 10 MB   2B11D791")


if __name__ == "__main__":
    main()
