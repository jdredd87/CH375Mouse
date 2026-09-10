# Picking this up next

Written 2026-09-09, updated 2026-09-10, for whoever continues this —
including a fresh Claude Code instance.

## Read these first, in this order

1. **`INSTALL.md`** — what the thing does and how to use it. Short.
2. **This file** — where the work stopped and what is worth doing next.
3. **`README.md`** — the engineering notebook, newest thinking at the top.
   Read it when you need to know *why* something is the shape it is, not
   before.
4. **`CHANGELOG.md`** — the same story in the order it happened, including
   the things that were tried and thrown away. Several entries are
   retractions; they are the useful ones.

## Where to work from

**Use `C:\dosbridgeDEV`, not `C:\dosbridge`.**

- `C:\dosbridgeDEV` is the git repo (`jdredd87/DOSBridgeDEV`), it has the
  real `CLAUDE.md`, and `dosd` runs from it. As of 2026-09-09 `CLAUDE.md`
  there is ~48 KB with the long-form material split into `docs/` beside it —
  `docs/network.md`, `docs/agent.md` and `docs/hardware.md` are the ones this
  project borrows from.
- `C:\dosbridge` is an old runtime copy. Its `CLAUDE.md` is **zero bytes**,
  so an assistant working there starts with no context at all. Never sync
  "the newer file" in that direction.

`build.cmd` now prefers `C:\dosbridgeDEV` on its own; `DOSBRIDGE` overrides
it. Otherwise drive the box with `python C:\dosbridgeDEV\dosctl.py ...` by
absolute path, and put `MSYS_NO_PATHCONV=1` in front of anything passing a
DOS switch like `/I=65` or Git Bash rewrites it into a path.

## State: it works, and there is one open fault

`USBPKT.COM` 1.0.0 is a Crynwr packet driver for a USB Ethernet adapter on a
CH375 ISA card. One command, like `NE2000.COM`. It loads from
`AUTOEXEC.BAT`, mTCP runs over it at `packetint 0x65`, and DOSBridge stays on
the NE2000 at 60h throughout.

Verified: ping 8.8.8.8, DNS, web pages over HTTP, FTP and telnet banners,
and downloads checksummed on the DOS box. Two physically different AX88179
adapters. Every error counter in `USBPKT /S` reads zero.

**READ THIS BEFORE TRUSTING A LARGE TRANSFER.** On 2026-09-10 a 5 MB
download came back the exact right length with the wrong bytes. Four runs
isolated it:

| 5 MB, same file, same server | time | result |
|---|---|---|
| written locally by `RAMPCHK /W`, no network | | exactly the ramp |
| over the NE2000 at INT 60h | 62.9s | exactly the ramp |
| over USBPKT, fast path | 312.0s | 162 bytes wrong |
| over USBPKT, `/8` portable loops | 309.6s | wrong, and differently |
| over the NE2000, 10 MB | 125.3s | exactly the ramp |
| over USBPKT, fast path, again | 305.6s | exactly the ramp |

**It is intermittent -- two USB runs in three -- so a clean run proves
nothing.** Budget several runs per question before believing an answer; this
is the single most important thing to know before testing here.

Solid: the disk is clean, and the `REP INSB` change did not cause this (the
`/8` row is the code that shipped before it, and the two corrupt runs differ
from each other). Well supported: the fault is in USBPKT, on 15 MB of clean
NE2000 exposure against 2-in-3 failures here. The earlier "5 MB and 10 MB
byte-exact" claim in this file and the CHANGELOG has not been reproduced and
should not be relied on.

The signature: **not** shifted -- the file never lost step -- but 162 bytes
overwritten with payload duplicated from elsewhere in the stream. Note the
displacement is only known MODULO 256, because the ramp repeats every 256
bytes; an earlier draft read it as "exactly 64 bytes" and built on that, and
it does not follow.

**The leading candidate is in `rx_deliver`.** It is handed the burst length
in `CX`, uses it to find the trailer, then reuses `CX` -- so every per-frame
bounds check afterwards is against `RXBUF_SZ` rather than against the bytes
this burst actually delivered. `rxbuf` is never cleared, so a trailer
claiming a frame past the received data hands up leftovers from an earlier
burst. That matches the signature and explains the zero counters. README,
"And then something DID CRC wrong", has the full analysis.

**Start here when you pick this up:**

1. **Get more NE2000 exposure first.** The whole case rests on it and it is
   one run. 10 MB over the NE2000 is two 5 MB runs' worth of exposure for a
   single check, and NE2000 fetches are 5x faster, so it is also the
   cheapest evidence available.
2. Reproduce on USB and collect signatures -- about 2 runs in 3 yield an
   event, ~12 minutes each. Note the offset, the length and the two deltas
   every time. If the leading fragment is always -64 that is close to
   conclusive; if it is not, the hypothesis below is wrong.
3. **Test the `rx_deliver` candidate directly.** Keep the burst length,
   check each frame's offset+length against it rather than against
   `RXBUF_SZ`, and count the rejects. If that counter fires on runs that
   corrupt and stays at zero on runs that do not, it is the bug -- and the
   check is worth having permanently either way, because nothing in the
   parser currently notices this class of fault at all.
4. If it is not that, consider a test file with a period longer than the
   file, so the displacement stops being ambiguous mod 256.

**The `REP INSB` / `REP OUTSB` job this file used to call "the next job" is
done, and is not implicated in the above.** All three byte loops take the
186 string instructions when the CPU has them, gated on a run-time `Has186`
probe, with `/8` to force the portable loops back. Measured on one binary,
same file, same server:

| | 1 MB | CRC-32 | longest poll |
|---|---|---|---|
| `REP INSB`/`OUTSB` | 63.6s | `998E4325` | **22.0 ms** |
| `/8`, 8086 loops | 65.3s | `998E4325` | 32.6 ms |

2.6% on throughput — which is what the prediction said, because at `/R=1`
this is round-trip-bound — and **33% off the interrupt**, which was the
point. `USBPKT /S` now reports `longest poll` itself, so the next person
gets the number instead of an argument. Read the README section **The byte
loops** before touching any of it; it also records that the old "~10 ms of a
55 ms tick" estimate was out by three times.

## The next job

### A second chipset

(Only after the corruption above is understood. A second bring-up on top of
a receive path with a known unexplained fault would make both harder to
diagnose.)

Everything above the bring-up is already generic — the packet driver, the
receive parser, the transmit path and the statistics block do not know what
they are talking to. `ADAPTERS.md` has the survey; the order that makes
sense is:

1. **AX88772** — same vendor, same shape of bring-up, cheapest first step
   and the best test of whether the "generic above the bring-up" claim is
   actually true or merely untested.
2. **RTL8152/8153** — a different vendor, so it exercises the parts of the
   design that assume ASIX conventions without saying so.
3. **CDC-ECM** — a class driver rather than a chip driver, so one bring-up
   covers many adapters at once. Most valuable and least like the others.

`NETID` identifies what an adapter actually contains; the box it came in is
not evidence.

### And a thing that is now cheap to ask

`longest poll` makes the `/R=8`-wedges-`EDIT` question measurable for the
first time. The poll used to cost 32.6 ms against a 6.9 ms tick at `/R=8` —
nearly five ticks — and now costs 22.0. That is still longer than the tick,
so `EDIT` probably still breaks, but it is no longer a guess: run `EDIT`
under `/R=8` with somebody at the keyboard and see. Do not do it over the
bridge alone; that failure needs the power switch.

The gap to an ISA NE2000 is structural — polling versus interrupts, one byte
per bus cycle versus two — and probably not reachable on this hardware. **It
is 5x, not the 2x this file used to claim**: the same 5 MB file from the same
server took 62.9s on the NE2000 against 312.0s here, measured while using the
NE2000 as a control for the corruption above.

## Things that will bite you

**Power, not reboot.** A warm reboot leaves the CH375 and the adapter exactly
as the last program left them, so a failed bring-up poisons the next boot.
Use `dosctl power cycle` between attempts, and never conclude "this fails
every time" from a run of warm reboots.

**A long job makes `dosctl status` say STALE, and that is not a fault.**
While a job runs the agent is inside it and does not poll, so a 10-minute
download reads exactly like a hung machine from Windows. Take a
`dosctl capture shot` before concluding anything — it shows the real screen,
and it is the difference between "still downloading" and "wedged". This cost
DOSBridge three wrong power cycles in one day before the capture card
existed.

**Measure to `NUL`, not to disk.** A benchmark written to the PicoMEM disk
hid a poll-rate effect completely and produced a confident, wrong conclusion
that had to be retracted.

**Do not trust mTCP's timings.** `PING` reports ~50 ms over this adapter; the
real round trip is 6 ms at `/R=8`. That is mTCP's granularity. `PKTTEST
/N=200` times it properly by doing the exchange itself.

**Never background a `dosctl exec` with a shell `&`.** The job is dispatched
and runs on the box to completion, but the pipe collecting its output dies
with the shell, and there is no way to get the result back: `dosd` discards
a result nobody is waiting for, and a running DOS job cannot be cancelled
-- `dosreboot` needs the box to be polling, which it is not while a job
runs, and a power cycle stops at the F1 prompt. That cost 75 minutes of box
time for nothing. Use the harness's own background facility, which keeps
the output file alive.

**A job that runs but returns ZERO BYTES means the box is out of file
handles, not that the job failed.** Seen 2026-09-10 after several hours of
soaking. Every command still executed and still printed to the CONSOLE, but
the batch could no longer open `C:\WORK\OUT.TXT`, so nothing came back and
`dosctl` reported "no output, and rc 0" -- which is also what a missing
program looks like, so it reads as the wrong fault entirely. Even `VER` and
`DIR` came back empty while plainly working on screen.

`doscap shot` is what identified it: **"Extended Error 4"** on the DOS
console, which is DOS's "too many open files". `CONFIG.SYS` here carries
only the CH375 driver line, so `FILES=` is at the DOS default of **8** --
very tight for a box running dozens of programs an hour. A warm
`dosctl reboot` clears it in 20 seconds and is safe; do NOT power cycle,
because POST then stops at the F1 prompt and needs hands.

Raising `FILES=` in `CONFIG.SYS` would be the real fix and **that file is
never to be edited from here** -- a bad line there hangs the machine before
the network comes up. Raise it at the keyboard if this becomes a nuisance.

What exhausted them is NOT established. The suspect is `/R=8`: the soak
that failed was the first to use it, and an identical 40-command soak at
`/R=1` an hour earlier completed perfectly. But a slow leak across hundreds
of program runs finally tipping over fits the evidence just as well, and one
failure cannot separate those. Treat `/R=8` as unproven-guilty rather than
convicted.

**A failed `nasm` run DELETES `bin\USBPKT.COM`.** That is the safe
direction -- a deploy afterwards fails rather than shipping stale code -- but
do not reach for a binary that is "still there" after a build error, because
it will not be. Adding code to `rx_deliver` is the likeliest way to trigger
this: the conditional jumps in `rxd_ok` reach `rxd_bad`, an 8086 conditional
jump is short only, and growing the frame loop puts them out of range. There
is a trampoline above `rxd_ok` for exactly that -- add to it rather than
re-deriving the problem.

**Do not truncate a job's output with `tail` unless you are sure you do not
need it.** A three-download job piped through `tail -45` lost the first two
results, and each one had cost eleven minutes of box time to produce. There
is no way to get them back short of running the job again.

**Do not raise `/R` in `AUTOEXEC.BAT`.** It reprograms the PIT, and anything
that hooks INT 08h after the driver then runs eight times fast. `EDIT` wedges
the machine. `/R=8` for a big transfer is fine; leaving it there is not. Note
`longest poll` is only measured at `/R=1`, for a reason the README explains.

**`AXPROBE`/`USBLINK` is not a prerequisite** and running it first actively
gets in the way — it leaves the device enumerated, which is the state
`USBPKT` then has to fight. Run `USBPKT` first, always.

**Never install on INT 60h.** That is the network this machine is
administered over. The driver refuses it in code and that is not overridable.

## Tools you will want

| | |
|---|---|
| `USBPKT /S` | the driver's own counters, and `longest poll`. Every error line should read 0 |
| `USBPKT /8` | load with the portable byte loops. The first thing to try if anything ever CRCs wrong |
| `PKTTEST /I=65 /M=<free ip> /T=<router> /N=200` | real round-trip time |
| `PKTTEST /I=65 /M=<free ip> /L` | show every frame that arrives |
| `USBLINK /V` | bring-up narrated, chip status at every register access |
| `USBRECV /A /S=8` | read the adapter directly, no packet driver involved |
| `PKTTICK` | run the reference receive code from a timer interrupt |
| `TICKCHK` | INT 08h and INT 1Ch rates — tells you if the PIT is disturbed |

`PKTTICK` exists because "it only breaks inside the ISR" was a theory that
needed killing. It killed it. Reach for it if something similar comes up.

## The verification harness, so you do not have to invent one

There is an HTTP server on the LAN at **192.168.50.46 port 80** serving
`/download/1mb`, `/download/5mb` and `/download/10mb`. Their checksums are
fixed and have been the reference set since the driver first moved volume:

| | bytes | CRC-32 |
|---|---|---|
| `/download/1mb` | 1,048,576 | `04D0E435` |
| `/download/5mb` | 5,242,880 | `BDBF684D` |
| `/download/10mb` | 10,485,760 | `2B11D791` |

```
MSYS_NO_PATHCONV=1 python C:\dosbridgeDEV\dosctl.py exec --timeout 1200 ^
  "C:\TOOLS\ELAPSED.COM /S" ^
  "HTGET -o C:\WORK\M5.BIN http://192.168.50.46/download/5mb" ^
  "C:\TOOLS\ELAPSED.COM fetched" ^
  "C:\TOOLS\HD.EXE C:\WORK\M5.BIN 0 1" ^
  "C:\WORK\USBPKT.COM /S"
```

`HD` prints a CRC-32 that matches Python's `zlib.crc32`, so the check is
end-to-end and needs no file coming back. **Verify on the box, not by
pulling the file** — anything over about half a megabyte does not fit in one
bridge job. Allow generous `--timeout`: `HD` reads every byte on an 8086 and
costs roughly as long as the download did.

Two properties of this harness are worth knowing before you use it:

* **The files are a repeating `00`..`FF` ramp**, so the correct byte at any
  offset is `offset mod 256`. A hex dump therefore says *how* a file went
  wrong -- altered, dropped or duplicated bytes each look different, and a
  shift shows up as a ramp out of step with its own address. A CRC only ever
  says "no". Use `HD <file> <offset> 32` when you need more than that.
* **`HD` CRCs the whole file even when you ask for 32 bytes.** One dump from
  a 5 MB file is a full read, about six minutes here. Five dumps in one job
  is therefore five full reads -- half an hour of a box that cannot poll
  while it works, and it was tried: `dosctl` gave up at its own 900s timeout
  long before the batch ended, so the whole half hour produced **nothing at
  all**. Use `RAMPCHK`, which reads once and says more; if you must use
  `HD`, one window per job and set `--timeout` above the total.
* **`--timeout` is `dosctl`'s patience, not the box's.** When it expires the
  box carries on running the batch to the end, unreachable the whole time,
  and the result is discarded. There is no way to call a job back; the only
  levers are waiting it out or a power cycle, and on this machine a power
  cycle halts at the F1 prompt and needs hands. Size the timeout for the
  work, not for your attention span.
