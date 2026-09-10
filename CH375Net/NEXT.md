# Picking this up next

Written 2026-09-09, rewritten 2026-09-10 after a long session on the data
corruption. For whoever continues this, including a fresh Claude Code
instance.

## Read these first, in this order

1. **`INSTALL.md`** -- what the thing does and how to use it. Short.
2. **This file** -- state, the open fault, and what to do next.
3. **`README.md`** -- the engineering notebook, newest at the top. The
   corruption sections are long because most of their value is the list of
   things that turned out not to be the cause.
4. **`CHANGELOG.md`** -- the same story in order. Several entries are
   retractions; those are the useful ones.

## Where to work from

**Use `C:\dosbridgeDEV`.** It is the git repo, it has the real `CLAUDE.md`,
and `dosd` runs from it. `C:\dosbridge` is an old runtime copy whose
`CLAUDE.md` is empty; never sync "the newer file" in that direction.

`MSYS_NO_PATHCONV=1` in front of anything passing a DOS switch like `/I=65`.

## State: it works, and one fault is still open

`USBPKT.COM` is a Crynwr packet driver for a USB Ethernet adapter on a CH375
ISA card. One command, like `NE2000.COM`. mTCP runs over it at
`packetint 0x65` and DOSBridge stays on the NE2000 at 60h throughout. Ping,
DNS, HTTP, FTP and telnet all work.

### Fixed this session

**`REP INSB` / `REP OUTSB`,** on all three byte-moving loops, gated on a
run-time `Has186` probe, portable loops kept and reachable via `/8`. Worth
2.6% on throughput -- which was the prediction, since at `/R=1` this is
round-trip-bound -- and **33% off the length of the interrupt**, which was
the point. `USBPKT /S` now measures its own worst poll.

**Two register-preservation bugs in the burst walk.** `rx_deliver` calls the
application's receiver through `call far [cs:rcv_tmp]`, and the comment above
that call says nothing may be assumed about any register afterwards. The loop
then assumed two: `CX`, the frame length used to compute the stride to the
next frame, and `BP`, the entry stride for the whole burst read as
`add si, bp` every iteration -- and the register a C compiler is likeliest to
be using as a frame pointer. Both are pushed now.

**Corruption went from 67% of 5 MB downloads to about 11%.** Large, and not a
cure.

### The open fault

A 5 MB download comes back the right length with a region of wrong bytes,
roughly **1 download in 9**, or **1 event per 44 MB**. The signature is
measured across the whole run, not inferred from a window:

```
deltas +192 x4 +76 x158
```

| | |
|---|---|
| first piece | always **exactly 4 bytes**, displacement -64 (mod 256) |
| second piece | the remainder, displacement +76 (mod 256) |
| length | 162 four times, 82 once -- only the second piece varies |
| alignment | every event starts at an **even** offset, 5 of 5 |

Fixed displacements with a variable length is the shape of a structural
offset applied in the wrong place. Nothing is altered bit by bit and nothing
is dropped -- the file stays in step everywhere else -- so a region is
**overwritten with payload duplicated from elsewhere in the stream**.

The displacements are known only **modulo 256** from the ramp files. That is
what `CNT5M.BIN` and `RAMPCHK /K` exist to fix, and they have not yet caught
an event.

## What has been EXCLUDED, and by how much

The most valuable part of this file. Do not re-run these.

| ruled out | how |
|---|---|
| disk, FAT, DOS file I/O | `RAMPCHK /W` writes 5 MB and reads it back perfect, no network in the path |
| mTCP + `HTGET` + disk | **165 MB** clean over the NE2000, P(0) = 2.4% |
| the burst parser | 3 corruptions with the tiling counter at **zero**, and 3 tiling anomalies that produced **perfect** files -- a clean anti-correlation |
| the HTTP server | dosd on 8080 corrupts at the same rate as the port-80 server |
| either byte loop | fast path and `/8` both corrupt, and differently |
| out-of-region delivery | `n_outside` reads 0 on the runs that corrupt |

**And one deduction.** A substitution *does* change a TCP checksum --
checked, not assumed; only a true permutation of 16-bit words is invisible.
Corrupt data nonetheless reaches the file, so **mTCP is not verifying receive
TCP checksums on this path**. That is why driver-level damage lands on disk
instead of costing a retransmission.

**What is left:** the CH375 read itself, or the contention between transmit
and receive on it.

## What to do next

### 1. Read the paired A/B result in `vfylog.txt`

`USBVFY` verifies the receive path with **nothing above it** -- our own
IPv4/UDP, a payload keyed to absolute stream position, every byte checked on
arrival, no TCP, no mTCP, no file system, and no checksum filtering anywhere.

It runs paired, because a pure listener tests the wrong thing: during a real
download the box ACKs constantly, so `pkt_send` and `rx_poll` interleave on
the chip under `chip_busy`. `/A=2` transmits back every second datagram,
`/A=0` never transmits, and windows alternate so nothing varying with time of
day favours an arm.

* **an event in `/A=2` and not `/A=0`** -> contention is the mechanism.
* **both arms clean at ~177 MB** -> the raw receive path is sound at ~2%, and
  the fault needs something only the mTCP/HTTP path produces. Surprising
  given the NE2000 control, and it would want explaining rather than
  ignoring.

At the time of writing: **44.35 MB clean, zero events** -- a 37% outcome, so
not yet a result.

### 2. Catch one event on the counter pattern

Everything about the displacement is modulo 256 until this happens. `-64`
could be `-320` or `-576`, and the "CH375's 64-byte packet buffer" idea rests
entirely on which. One event on `CNT5M.BIN` reports the true source offset
outright.

0 of 26 counter runs have corrupted against 5 of 44 ramp runs -- p about
0.15, suggestive, unexplained, possibly nothing. It is **not** the counter
hiding the fault: a planted displacement reads back exactly, and a 4 GB
period has no blind spot the way a 256-byte ramp does.

### 3. Only then, a second chipset

`ADAPTERS.md` has the survey: AX88772, then RTL8152/8153, then CDC-ECM as a
class driver. Not before the corruption is understood -- a second bring-up on
top of an unexplained receive fault makes both harder to diagnose.

## Tools

| | |
|---|---|
| `USBPKT /S` | counters, `longest poll`, `bursts whose frames did not tile`, `frames past the frame region` |
| `USBPKT /8` | load with the portable byte loops instead of `REP INSB` |
| `RAMPCHK f` | check a downloaded ramp: where, how much, **altered vs shifted** |
| `RAMPCHK f /K` | the counter pattern -- reports the **exact** source offset |
| `RAMPCHK f /W=n` | write a ramp, so the disk can be tested with no network |
| `USBGET ip name file` | fetch over TFTP on our own stack, mTCP absent |
| `USBVFY ip /A=n /S=n` | verify the receive path with nothing above it |
| `mkramp.py` | generates every fixture, byte-identically |
| `mkblast.py` | the Windows sender for `USBVFY` |
| `USBLINK /V` | bring-up narrated, chip status at every register access |
| `TICKCHK` | INT 08h and 1Ch rates -- tells you if the PIT is disturbed |

**Validate an instrument before believing it, and again after editing it.**
`RAMPCHK` has been re-validated three times against `RAMPOK`/`RAMPSH`/
`RAMPAL`, and `/K` against `CNTBAD`, which plants the real signature and
requires it back. Not ceremony: the first "event" `USBVFY` ever reported was
foreign traffic, decorated with an exact displacement computed from a
sequence number that had overflowed `LongInt` into the negative.

## Things that will bite you

**A clean run proves almost nothing.** At 1 event per 44 MB a 5 MB download
is a 90% chance of looking fine, and two clean runs is 1-in-9 of meaning
nothing. I stopped there once and shipped a false cure. Work out the expected
count before believing a null.

**Do not treat a small clean control as an exclusion.** 15 MB of clean
NE2000 was called an exoneration of mTCP; it was a 71% outcome. It took 165
MB to exclude them properly.

**`doscap` first when the box goes quiet.** A long job makes `dosctl status`
say STALE, which is not a fault. And a job that runs but returns **zero
bytes** means the box is out of file handles rather than that the job failed:
commands still run and print to the console, but the batch cannot open
`OUT.TXT`, so `dosctl` reports "no output, and rc 0" -- which is also exactly
what a missing program looks like. `doscap` showed "Extended Error 4".
`FILES=30` is now in `CONFIG.SYS`; a warm reboot clears it if it recurs.

**Never power cycle unattended.** POST stops at "Press F1 to continue"
because of the CMOS configuration fault, so a cut needs hands. A warm
`dosctl reboot` is safe and takes 20 seconds.

**Broadcast is not free.** `USBVFY` needs it -- nothing on the box answers
ARP while our stack holds only the 0800 handle, so unicast stops being
delivered once the sender's cache lapses, and 9 datagrams arrived in 15
minutes before that was understood. But broadcast reaches every host on the
segment, and here that includes the PicoMEM WiFi interface DOSBridge runs
over: at 40/s the agent could not get its own ARP through and a whole
15-minute window was lost. **12/s is the rate that has proved reliable.** A
static ARP entry on the sender (`arp -s`, needs elevation) would allow
unicast at full rate.

**The listener starts before the sender.** `NetOpen` must ARP the peer before
it can open the IP handle, and a flood already in progress loses that one
frame. The test can destroy its own setup step.

**Never background a `dosctl exec` with a shell ampersand.** The job runs to
completion on the box but the pipe collecting its output dies with the shell,
`dosd` discards a result nobody awaits, and a running DOS job cannot be
cancelled. That cost 75 minutes. Use the harness's own background facility.

**Do not truncate a job's output with `tail`** unless certain you do not need
it. A three-download job piped through `tail -45` lost the first two results,
each of which cost eleven minutes of box time.

**A failed `nasm` run deletes `bin\USBPKT.COM`.** Safe direction, but do not
reach for a binary that is "still there". Adding code to `rx_deliver` is the
likeliest trigger: the conditional jumps in `rxd_ok` reach `rxd_bad`, an 8086
conditional jump is short only, and there is a trampoline above `rxd_ok` for
exactly that.

**Pascal is case-insensitive.** `ACKEVY` and `AckEvy` are one identifier.
That has cost three names here -- see also `InC`/`Inc` and `DdX`/`DDX` in
`CLAUDE.md`.

**Nothing goes at I/O 0260.** `CONFIG.SYS` records why: the Lo-tech EMS board
sat there, which is the CH375's base, and the two fought -- the CH375 read
back `FF` and the receive buffers filled with it. Board and `LTEMM` both
removed 2026-09-08. Demonstrated precedent that bus contention at 0260
corrupts CH375 reads on this machine.

**`AXPROBE`/`USBLINK` is not a prerequisite** and running it first gets in
the way: it leaves the device enumerated, which is the state `USBPKT` then
has to fight. Run `USBPKT` first.

**Never install on INT 60h.** That is the network this machine is
administered over. `USBPKT`, `USBGET` and `USBVFY` all refuse it in code.

**Do not raise `/R` in `AUTOEXEC.BAT`.** It reprograms the PIT and `EDIT`
wedges the machine. `/R=8` is also the leading suspect for one bout of file
handle exhaustion, unproven.

## The verification harness

An HTTP server on the LAN at **192.168.50.46 port 80** serves
`/download/1mb`, `/download/5mb` and `/download/10mb`. `dosd` serves the same
shapes at **8080** under `/f/local/`, which is how the counter file is
available at all.

| | bytes | CRC-32 |
|---|---|---|
| 1 MB ramp | 1,048,576 | `04D0E435` |
| 5 MB ramp | 5,242,880 | `BDBF684D` |
| 10 MB ramp | 10,485,760 | `2B11D791` |
| `CNT5M.BIN`, the counter | 5,242,880 | `0FC93951` |

`RAMPCHK` is about 18 s for 5 MB, because a clean 8 KB block costs one
`CompareByte` against a prebuilt reference rather than 8192 tests; only
failing blocks pay for the per-byte walk. It was 340 s before that.

**Regenerate the fixtures rather than trusting copies:**

```
python mkramp.py --stage C:\dosbridgeDEV\files\local
```

## Two things that want hands at the keyboard

* **`C:\PATH` should be `C:\TOOLS`** in `AUTOEXEC.BAT`. The line reads
  `PATH=C:\PATH;C:\WINDOWS;...`, so the word `PATH` became the first
  directory and `C:\TOOLS` is still not on the path. Everything here calls
  tools by full path, so nothing is blocked.
* **The CMOS configuration.** Until it is set, a power cycle stops at F1 and
  cannot recover the box unattended, which constrains every recovery
  decision. POST code 162 is a configuration/checksum error rather than a
  dead battery, which fits an RTC that keeps the month and day and loses only
  the year. On the PS/2 it is *Set Configuration* from the Reference
  Diskette.
