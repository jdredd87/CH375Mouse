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

## What is not done

- **The packet driver.** The goal is a Crynwr driver at INT 60h, because
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
