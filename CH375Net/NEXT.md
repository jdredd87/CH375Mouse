# Picking this up next

Written 2026-09-09, at the end of the session that got CH375Net working, for
whoever continues it — including a fresh Claude Code instance.

## Read these first, in this order

1. **`INSTALL.md`** — what the thing does and how to use it. Short.
2. **This file** — where the work stopped and what is worth doing next.
3. **`README.md`** — the engineering notebook. 750 lines, newest thinking at
   the top. Read it when you need to know *why* something is the shape it is,
   not before.
4. **`CHANGELOG.md`** — the same story in the order it happened, including the
   things that were tried and thrown away. Several entries are retractions;
   they are the useful ones.

## Where to work from

**Use `C:\dosbridgeDEV`, not `C:\dosbridge`.**

- `C:\dosbridgeDEV` is the git repo (`jdredd87/DOSBridgeDEV`), it has the real
  `CLAUDE.md` (~245 KB of project context), and as of 2026-09-09 the `dosd`
  daemon runs from it.
- `C:\dosbridge` is an old runtime copy. Its `CLAUDE.md` is **zero bytes**, so
  an assistant working there starts with no context at all, and it is littered
  with test artefacts. Do not sync "the newer file" between the two in that
  direction — it would destroy the real `CLAUDE.md`.

The DOS box is driven with `python C:\dosbridgeDEV\dosctl.py ...` by absolute
path. `MSYS_NO_PATHCONV=1` before any command that passes a DOS switch like
`/I=65`, or Git Bash mangles it.

## State: it works

`USBPKT.COM` 1.0.0 is a Crynwr packet driver for a USB Ethernet adapter on a
CH375 ISA card. One command, like `NE2000.COM`. It loads from `AUTOEXEC.BAT`,
mTCP runs over it at `packetint 0x65`, and DOSBridge stays on the NE2000 at
60h throughout.

Verified: ping 8.8.8.8, DNS, web pages over HTTP, FTP and telnet banners, and
64 KB / 512 KB / 1 MB / 5 MB / 10 MB downloads all checksummed on the DOS box
and byte-exact. Two physically different AX88179 adapters. Every error counter
in `USBPKT /S` reads zero.

## The next job, and it is well defined

### A `REP INSB` / `REP OUTSB` fast path gated on `Has186`

Three loops move bytes one at a time through port I/O:

| loop, in `src/usbpkt.asm` | now | with the 186 instruction |
|---|---|---|
| `ch_read_fast` — pull a packet out of the chip | `in`/`stosb`/`loop`, ~42 clocks a byte | ~10-14 |
| `ch_read_ovl` — drain a burst that cannot be used | `in`/`loop`, ~31 | ~10-14 |
| `bulk_out_loop` — transmit | `lodsb` + `call ch_wr` + `dec`/`jne`, ~160 | ~10-14 |

Transmit is the biggest per byte: the read loop was inlined and the write loop
never was, so it still pays a call, two settling reads and a push/pop for
every byte.

**Why it is available.** `INS`/`OUTS` are 186-class and the assembler targets
8086, so they cannot be written as source — but the development machine is a
**NEC V30, which has the 186 instruction set**. DOSBridge already has the
convention: probe `Has186` at run time (`starter/cpu.pas`), keep the portable
loop, emit the fast one as `db` bytes, never delete the slow one.
`starter/bench.pas` is the worked example.

**What it will and will not buy.** It will *not* make the default faster. At
`/R=1` this driver is round-trip-bound at ~55 ms, not read-bound, and there is
direct evidence: inlining the read loop made reads 3.6x faster and moved 1 MB
from 73s to 71s. What it buys is a **shorter interrupt** — a full burst read is
~10 ms of a 55 ms tick, 19% of the machine while traffic flows, and this would
take it to ~3 ms. That matters because `/R=8` wedged MS-DOS `EDIT` by stealing
too much of the machine. A quieter driver is the goal, not a bigger number.

**The one risk, and how to settle it.** `REP INSB` issues reads far closer
together than the current loop, and the CH375 may not keep up — the settling
delays exist for a reason. This is measurable rather than arguable: fetch 1 MB,
CRC it on the box, compare. A wrong answer shows up as a bad checksum, loudly.

```
USBPKT
HTGET -o C:\M1.BIN http://<a server>/1mb
C:\TOOLS\HD.EXE C:\M1.BIN 0 1        <- prints a CRC-32 matching Python's zlib
```

### After that

- **A second chipset.** Everything below the bring-up is already generic. See
  `ADAPTERS.md`; the order that makes sense is AX88772, then RTL8152/8153,
  then CDC-ECM as a class driver covering many adapters at once.
- The last 2x against an ISA NE2000 is structural — polling versus interrupts,
  one byte per bus cycle versus two — and probably not reachable on this
  hardware.

## Things that will bite you

**Power, not reboot.** A warm reboot leaves the CH375 and the adapter exactly
as the last program left them, so a failed bring-up poisons the next boot. Use
`dosctl power cycle` between attempts, and never conclude "this fails every
time" from a run of warm reboots.

**Measure to `NUL`, not to disk.** A benchmark written to the PicoMEM disk hid
a poll-rate effect completely and produced a confident, wrong conclusion that
had to be retracted.

**Do not trust mTCP's timings.** `PING` reports ~50 ms over this adapter; the
real round trip is 6 ms at `/R=8`. That is mTCP's granularity. `PKTTEST /N=200`
times it properly by doing the exchange itself.

**Do not raise `/R` in `AUTOEXEC.BAT`.** It reprograms the PIT, and anything
that hooks INT 08h after the driver then runs eight times fast. `EDIT` wedges
the machine. `/R=8` for a big transfer is fine; leaving it there is not.

**`AXPROBE`/`USBLINK` is not a prerequisite** and running it first actively
gets in the way — it leaves the device enumerated, which is the state `USBPKT`
then has to fight. Run `USBPKT` first, always.

**Never install on INT 60h.** That is the network this machine is administered
over. The driver refuses it in code and that is not overridable.

## Tools you will want

| | |
|---|---|
| `USBPKT /S` | the driver's own counters. Every error line should read 0 |
| `PKTTEST /I=65 /M=<free ip> /T=<router> /N=200` | real round-trip time |
| `PKTTEST /I=65 /M=<free ip> /L` | show every frame that arrives |
| `USBLINK /V` | bring-up narrated, chip status at every register access |
| `USBRECV /A /S=8` | read the adapter directly, no packet driver involved |
| `PKTTICK` | run the reference receive code from a timer interrupt |
| `TICKCHK` | INT 08h and INT 1Ch rates — tells you if the PIT is disturbed |

`PKTTICK` exists because "it only breaks inside the ISR" was a theory that
needed killing. It killed it. Reach for it if something similar comes up.
