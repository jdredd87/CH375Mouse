# CH375Net — USB Ethernet on a machine older than USB

**Status: it talks both ways.** Bring-up, link negotiation, receive and
transmit all work and are proven on the hardware. What is left is the
packet driver that turns this into something `mTCP` can use.

A USB-to-RJ45 adapter, an ISA card from a different decade, and an IBM PS/2
Model 30 with an 8086 in it. The question this project answers is whether a
CH375 in host mode can carry a class of device nobody uses it for.

The adapter is an **ASIX AX88179** (`0B95:1790`) — a USB 3.0 gigabit part,
running here at full speed, 12 Mbps.

## What works today

```
AXPROBE 0.2.0 -- AX88179 bring-up over a CH375 -- StevenC
device   : 0B95:1790
bus      : full speed (12 Mbps)

Bringing the chip up
  set configuration 01............ ok
  PHY power/reset low............. ok
  ...
MAC address: 40:AE:30:6D:00:34
PHY id     : 001C C915

Link is up.
  medium mode   : 0136  10 Mbps full duplex
  rx control    : 01A8
```

And real frames arrive. This is one, read off the wire by `AXRECV` and
decoded by hand:

```
FF FF FF FF FF FF   destination: broadcast
0C C1 19 59 B1 D2   source
08 00               IPv4
45 00 00 C8 ...     200 bytes, protocol 11 = UDP
C0 A8 32 08         from 192.168.50.8
```

## The programs

| | |
|---|---|
| `src/ax179.pas` | everything that knows what an AX88179 is: the register map, the two vendor requests, the bring-up, and the bulk read |
| `src/axprobe.pas` | `AXPROBE.EXE` — runs the bring-up and reports every stage. Step one, and the one that decided the rest was worth writing |
| `src/axrecv.pas` | `AXRECV.EXE` — reads the bulk endpoint and makes sense of what comes back. Deliberately an **investigation**, not a parser |
| `src/axsend.pas` | `AXSEND.EXE` — sends an ARP request and waits for a real machine to answer it |
| `src/pktscan.pas` | `PKTSCAN.EXE` — which interrupt vectors hold a packet driver and which are free. Read-only, and the safety net for everything below |

All take `/?`. `/P=hex` sets the CH375 I/O base.

## Transmit, proved the only way that counts

A write to the bulk endpoint returning "success" only means the CH375 took
the bytes. It says nothing about whether a frame reached the wire — a
header field misplaced, a length off by the eight bytes of the header
itself, a padding flag missed, and the chip discards the lot in silence.

So `AXSEND` does not check that the write succeeded. It asks the network a
question and waits to be answered:

```
Asking 192.168.50.1 who it is, claiming to be 192.168.50.222
  request 1 sent

REPLY from 04:D4:C4:D2:2B:00 -- 192.168.50.1 answered us.
```

That reply cannot be manufactured at this end. A frame built on an 8086,
pushed through an ISA card, put on the wire by the adapter, was received by
the router, parsed, believed, and answered back to this MAC. The router's
MAC also matches the one seen in an unrelated IGMP query `AXRECV` caught
earlier, which is a second, independent confirmation.

**The transmit header** is 8 bytes, two little-endian 32-bit words in front
of the frame: the length, then zero — except when the total including the
header lands on an exact multiple of the endpoint's 64-byte packet size, in
which case bits 15 and 31 are set. That same case also needs a zero-length
packet to terminate the USB transfer, which is a *separate* requirement
that happens to arise at the same moment and is easy to confuse with it.

## Why 10BASE-T, on purpose

`AXPROBE` restricts the PHY to 10 Mbps unless you pass `/G`.

Every byte of every frame crosses the ISA bus one `IN` instruction at a
time through a 64-byte window, so a 1514-byte frame is **24 separate CH375
transfers**. Whatever that works out to, it is not megabits. A gigabit link
feeding a receiver that slow does not degrade gracefully — it overruns the
chip's buffers and stays overrun.

Dropping to 10 Mbps throws away no performance that was ever available. It
is done by *restricting what the PHY advertises* rather than by forcing the
speed, so the switch at the far end negotiates normally instead of being
left to guess. It negotiated `0136` — 10 Mbps full duplex — first time.

**On a 486 this calculation changes**, which is why the speed is a runtime
switch and not a constant. The same goes for the bulk-in burst size: this
driver holds it down to something it can drain, where Linux lets the chip
fill 20 KB because it can absorb that. Both are `/G` and `/B=` rather than
constants, so faster hardware needs a different flag and not a rewrite.

## Four traps that cost real time

**`BusUp` does not send SET_CONFIGURATION.** It fetches the descriptors and
assigns the address and stops there. A device with an address but no
configuration is in Address state, where *control transfers to endpoint 0
work perfectly and its other endpoints do not exist*. So every register
read and write succeeded, the link came up — and then every IN token to the
bulk endpoint timed out. 7056 of them, in the run that found it.

**`BusUp` also sets `SET_RETRY 8F`, meaning retry NAKs for ever.** That is
right while enumerating: a device still waking up should be waited for. It
is exactly wrong for polling an endpoint that is idle most of the time —
the CH375 sits there retrying instead of reporting, the caller's own wait
expires, and the poll comes back as "no interrupt" having taken seconds.
Two polls in nine seconds, before; 865 in under a second, after.

**A NAK is not the end of a transfer.** In USB a bulk transfer ends with a
*short* packet; a NAK part-way through only means "not ready yet, ask
again". Treating one as the end truncated every multi-frame transfer — the
first capture stopped at 256 bytes with a second frame cut in half and no
trailer anywhere in it, which sent this hunting for a buffer layout that
had been right all along.

And zeroing `AX_RX_BULK_QCTRL` does **not** mean "no aggregation". It means
*no limit*, which is the opposite: the chip keeps appending frames for as
long as traffic arrives and the transfer never ends. One capture reached
55,680 bytes before the buffer gave up.

**An unbounded drain loop will take the machine with it.** When a burst
overflows the buffer the remainder has to be read and discarded, or the
endpoint desynchronises. That drain was written as "read until a short
packet" — but the chip can stream continuously, so on a busy network it
never returns, and a DOS program that never returns hangs the box. It did,
twice, and needed the power cycled. It is bounded now.

`USBPOLL` already knew the first two of these. None of them is written down
anywhere except in source, which is why they are written down here.

## The receive buffer layout, confirmed

The AX88179 does not put a bare frame on its bulk endpoint. A transfer is:

```
[frame 1][pad to 8][frame 2][pad to 8]...[entry 1][entry 2]...[trailer]
```

* **trailer** — the last 4 bytes, little-endian. Low word is the packet
  count, high word is the offset of the entry array.
* **entry** — 4 bytes per packet. `(entry >> 16) and $1FFF` is the frame
  length.
* **frames** — from offset 0, each padded up to an 8-byte boundary. With
  `IP_ALIGN` clear there is no leading pad, so byte 0 is the destination
  MAC.

Verified live, with every invariant checked rather than assumed:

```
trailer at +676 = 02A00001   count=1  hdr_off=672
  [ok] count is sane (1..32)
  [ok] metadata offset inside the buffer
  metadata area 4 bytes over 1 packet(s) = 4 bytes each
  packet 1/1  entry=029E8800  len=670
      EC:8E:B5:7A:2C:F5 -> 01:00:5E:7F:FF:FA  IPv4
  [ok] frames end before the metadata (02A0 <= 02A0)
```

It looked wrong for a long while, and the layout was never the problem —
see the third trap above.

## Measured throughput

About **1650 bytes/sec** sustained, with the link deliberately loaded.
That is roughly 13 kbit/s, and it is a real measurement rather than an
estimate.

The interesting part is where it goes. In a 15-second run there were
**12,112 idle polls and only ~390 reads that carried data** — so the
limit is not how fast bytes come out of the CH375, it is that the chip
hands us data on about 3% of polls. Raw read bandwidth looks closer to
50 KB/s if the duty cycle could be fixed.

Burst size matters and not in the obvious direction. `/B=02` gives
1650 B/s; `/B=08` gives **302 B/s** — five times worse, because a larger
threshold makes the chip wait longer and drop more while it waits. The
default is 2 for that measured reason and not a guessed one.

## Not losing the machine

This box is administered over its own network. The working path is a packet
driver at **INT 60h**, `pm2000.com`, loaded from `AUTOEXEC.BAT` at boot,
with mTCP configured `packetint 0x60`. Break that and the machine goes
silent with no way in to undo it.

`AI.BAT` already states the principle, and it is the right one:

> *TZ lives here and not in AUTOEXEC.BAT: a mistake in AUTOEXEC.BAT breaks
> the network before the agent runs and needs hands on the keyboard, while
> a mistake here is fixable over the wire.*

So the rules for anything in this project that goes resident:

1. **The recovery mechanism already exists: power-cycle.** `pm2000.com`
   loads at boot, so a hard reset always comes back with working
   networking — *provided `AUTOEXEC.BAT` is never touched.*
2. **Never add anything from this project to `AUTOEXEC.BAT`.** A TSR that
   hangs at boot is not recoverable remotely at any price.
3. **Never install on INT 60h.** `PKTSCAN` says what is free; on this
   machine that is `61-66`, `68-6C`, `6E-6F` and `78-7E`. The driver here
   defaults to **65h** and refuses 60h outright.
4. **Refuse to install over an existing packet driver.** The signature is
   there to be checked, so check it.
5. **Always unloadable**, and every test runs load → check → unload as a
   single command, so a failure part-way through cannot leave a TSR
   resident.
6. **`PKTSCAN` before and after.** If 60h still answers, the way back is
   still there.

```
PKTSCAN 1.0.0 -- packet drivers in the interrupt table -- StevenC

  60h  15A2:03CE   PACKET DRIVER

1 packet driver(s) between 60h and 80h.
Vectors reading 0000:0000: 61 62 63 64 65 66 68 69 6A 6B 6C 6E 6F 78 79 7A 7B 7C 7D 7E
```

Note that `67h` and `6Dh` are in use but are *not* packet drivers — EMS and
video respectively. `PKTSCAN` reports them as occupied rather than free,
which is the distinction that matters when picking a vector.

## The packet driver

`AXPKT.COM` **installs, runs and unloads cleanly.** Proven on the hardware,
with the working network at 60h untouched throughout:

```
=== part one: /N, no timer hook ===
Resident at vector 65h.
  60h  15A2:03CE   PACKET DRIVER      <- the machine's own network
  65h  16DD:1245   PACKET DRIVER      <- this one
AXPKT unloaded.

=== part two: full, timer hooked ===
Resident at vector 65h.
  vector=65   I/O base=0260
  MAC=40:AE:30:6D:00:34
  open handles=0
  timer ticks=10
AXPKT unloaded.
=== done ===
```

`timer ticks=10` is the INT 08h hook firing ten times between install and
status. `PKTSCAN` afterwards shows 60h alone, exactly as before.

### The bug that made this look impossible for hours

`op_nopoll` — the flag saying whether the timer was hooked — lived in the
transient half of the image. `/U` reads it out of the *resident* copy to
decide whether to restore INT 08h, and that offset lands past
`resident_end`, in memory DOS has already taken back. So the answer was
whatever happened to be lying there.

When the garbage read non-zero, `/U` skipped a restore that was mandatory,
leaving our handler in the interrupt vector pointing at memory now issued to
something else. The machine died on some later timer tick — which is why the
fault never appeared in the program that caused it, and why the next
unrelated program looked guilty.

In the `/N` case the same garbage skipped a restore that genuinely *was*
skippable, so that path passed. Right by accident is the worst kind of
right: it makes the broken case look like a different bug.

### Three instruments earned their keep

* **`/N`** — install the vector but do not hook the timer. It is what
  separated "going resident is broken" from "the ISR is broken", and the
  answer was neither: it was unloading.
* **A batch file writing to a log.** `dosctl exec` does not echo program
  output to the screen and its result never arrives if the job outlives the
  timeout, so a file on disk is the only evidence that survives either. Both
  of those cost real time before being understood.
* **A heartbeat poked into video memory from the ISR.** A DOS box that has
  stopped answering still has a screen, and a capture card can photograph
  it. Two stores, and the only channel that reports from a dead machine.

## mTCP talks to it

mTCP's own `pkttool` finds the driver and reads everything off it — code
none of which is mine:

```
Details for driver at software interrupt: 0x65
  Name: AX88179/CH375
  Version: 1   Class: 1   Type: 0   Interface Number: 0
  Function flag: 2  (basic and extended functions)
  Current receive mode: packets for this MAC and broadcast packets
  MAC address: 40:AE:30:6D:00:34
```

And `PKTCAP` — DOSBridge's own capture tool, also not mine — registers a
real handle through `access_type` and gets clean frames out of it:

```
frames captured: 16      bytes: 2320      dropped (busy): 0
first frame    : 64 bytes
  destination  : FF:FF:FF:FF:FF:FF
  source       : 24:F5:A2:5F:61:A5
  ethertype    : 0806  (ARP)
```

So `driver_info`, `get_address`, `get_rcv_mode`, `get_statistics`,
`access_type`, `release_type` and the two-call receive handshake are all
exercised by third-party software and all correct.

`send_pkt` moves frames too: 11 out, 660 bytes — exactly 11 × 60, the right
size for an ARP request.

**What does not work yet is a round trip.** `PING` still reports "Timeout
waiting for ARP response": our requests leave and other traffic arrives,
but the replies to our own requests are not coming back up. Since `AXSEND`
gets a reply to a hand-built ARP through the same chip, the difference is
somewhere in the resident path rather than in the wire or the header
format. The receive filter is the current suspect.

### Two transmit bugs found on the way

* **`bulk_out` did not retry a NAK.** A NAK on an OUT means "busy, ask
  again", exactly as on an IN, and the chip is deliberately set to report
  NAKs rather than retry them itself. Every single send failed before this:
  25 errors out, 0 packets out. The retry has to rewind `SI`, because
  `LODSB` has already walked it through the data.
* **The chunk length was read back out of a clobbered `AX`.** `sub cx, ax`
  after `bulk_out` was subtracting a leftover CH375 opcode from the bytes
  remaining.

### And one the statistics block exposed

`pkttool` reported `Errors out: 65557` from a driver that had sent nothing.
`get_statistics` hands the caller a pointer to a struct of **seven**
consecutive 32-bit counters in a fixed order; mine had five, in a different
order, so `pkttool` was reading two variables past the end of it. Fixed,
including the `bytes_in` / `bytes_out` that were simply missing.

## What is not done

- **The ARP round trip.** When it loads, point a *copy* of `MTCP.CFG` at the new
  vector. Never the one the working network uses. The goal is a Crynwr driver at INT 60h, because
  that is what `mTCP`, `WATTCP` and NCSA Telnet all speak — get it right
  and the whole DOS networking ecosystem works, with no TCP stack written
  here.

## Building

    build.cmd            build both programs
    build.cmd probe      ...then bring the adapter up on the DOS machine
    build.cmd recv       ...then watch frames arrive
    build.cmd raw        ...then dump bursts without interpreting them
    build.cmd send       ...then ARP the router and wait to be answered

Needs Free Pascal cross-compiling to `i8086-msdos`. `ch375.pas` and
`chtool.pas` come from `..\CH375USBTOOLS\src` via `-Fu`.

Public domain, under [the Unlicense](https://unlicense.org). Written by
**StevenC**.
