# CH375Net — USB Ethernet on a machine older than USB

**Status: it reaches the internet.**

```
Sending ICMP packets to 8.8.8.8
Packet sequence number 0 received from 8.8.8.8 in 46.75 ms, ttl=118
Packet sequence number 1 received from 8.8.8.8 in 51.85 ms, ttl=118
Packet sequence number 2 received from 8.8.8.8 in 51.85 ms, ttl=118
Packets sent: 3, Replies received: 3, Replies lost: 0
Average time for a reply: 50.15 ms

Sending ICMP packets to 1.1.1.1
Packet sequence number 0 received from 1.1.1.1 in 47.60 ms, ttl=60
```

`ttl=118` from Google and `ttl=60` from Cloudflare are the giveaway: those
packets crossed a dozen routers each way. This is not a device on the local
segment answering politely — it is a full IP path, out and back.

That is mTCP on an **IBM PS/2 Model 30** — an 8086 from 1987, nine years
older than USB — reaching Google's DNS through a USB Ethernet adapter on a
CH375 ISA card. Bring-up, link negotiation, receive, transmit and a Crynwr
packet driver, all working, with the machine's own network at INT 60h
untouched throughout.

That ~50 ms is mTCP's own timing granularity rather than the wire — timed
properly with `PKTTEST /N=200` the round trip is **6 ms**. Which is a
reasonable illustration of this project generally: most of what looked wrong
turned out to be the instrument.

---

## Start here

**[INSTALL.md](INSTALL.md)** — how to actually use this. It is short.

**[ADAPTERS.md](ADAPTERS.md)** — which USB Ethernet chipsets are supported,
which need a bring-up writing, and which cannot work. Run `NETID` first; the
box an adapter came in is not evidence of what is inside it.

The whole of it, if you have used a packet driver before:

```
C:\CH375> USBPKT              <- one command, like NE2000.COM
C:\CH375> (mtcp.cfg: packetint 0x65)
C:\CH375> PING 8.8.8.8
```

Nothing to add to `CONFIG.SYS`, nothing to configure. `USBPKT` enumerates the
device over the CH375, brings the AX88179 up, and goes resident. `USBPKT /U`
unloads it again.

The rest of this file is the engineering: what was measured, what was tried
and thrown away, and why the code looks the way it does. It is a notebook,
not a manual.

---

A USB-to-RJ45 adapter, an ISA card from a different decade, and an IBM PS/2
Model 30 with an 8086 in it. The question this project answers is whether a
CH375 in host mode can carry a class of device nobody uses it for.

The adapter is an **ASIX AX88179** (`0B95:1790`) — a USB 3.0 gigabit part,
running here at full speed, 12 Mbps.

## What works today

```
USBLINK 0.2.0 -- AX88179 bring-up over a CH375 -- StevenC
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

And real frames arrive. This is one, read off the wire by `USBRECV` and
decoded by hand:

```
FF FF FF FF FF FF   destination: broadcast
0C C1 19 59 B1 D2   source
08 00               IPv4
45 00 00 C8 ...     200 bytes, protocol 11 = UDP
C0 A8 32 08         from 192.168.50.8
```

## Getting it running

One command, the way `NE2000.COM` is one command:

```
C:\CH375> USBPKT
USBPKT 0.1.0 -- StevenC
Bringing the adapter up... link up.
MAC address: 40:AE:30:6D:00:34
Resident at vector 65h.
```

`USBPKT` enumerates the device over the CH375, brings the AX88179 up, and
goes resident. Nothing has to be run before it. Point mTCP at it with a
**copy** of your config — never the one your working network uses:

```
SET MTCPCFG=C:\CH375\MTCPAX.CFG      (packetint 0x65)
PING 8.8.8.8
SET MTCPCFG=c:\network\mtcp\mtcp.cfg
```

`USBPKT /U` unloads it, `/S` reports counters, `/?` explains the rest.

### Loading it at boot

This works now, and on the machine it was written for it is what
`AUTOEXEC.BAT` does. One rule makes it safe:

```
IF EXIST C:\CH375\TRYING.FLG GOTO USBWEDGED
ECHO trying > C:\CH375\TRYING.FLG
C:\CH375\USBPKT.COM /I=65
IF ERRORLEVEL 1 GOTO NOUSB
DEL C:\CH375\TRYING.FLG
SET MTCPCFG=C:\CH375\MTCPAX.CFG
GOTO NETOK
:USBWEDGED
DEL C:\CH375\TRYING.FLG
ECHO Last boot hung bringing the adapter up - skipped this time.
GOTO NETOK
:NOUSB
IF EXIST C:\CH375\TRYING.FLG DEL C:\CH375\TRYING.FLG
ECHO USB adapter did not come up - staying on the other card.
:NETOK
```

`IF ERRORLEVEL` catches a bring-up that **fails**. Nothing catches one that
**hangs** — and if the machine is administered over the network, a hang in
`AUTOEXEC.BAT` happens before anything is listening, so it costs a walk to
the keyboard. The flag is the answer: drop it before trying, delete it
after, and a boot that finds it still there knows the last attempt never
came back. Worst case becomes one power cycle.

Do not put `USBLINK` in `AUTOEXEC.BAT`. `USBPKT` needs it for nothing, and
`USBLINK` is what used to hang.

Verified over eight consecutive boots — warm and cold — plus a deliberate
test with the flag planted by hand, which correctly skipped the block and
came up on the other card.

### What to expect from it

Real volume, checksummed on the DOS box itself with `HD.EXE` and compared
against the source:

| size | CRC-32 | result |
|---|---|---|
| 64 KB | `8156EC0D` | exact |
| 512 KB | `9EBAF22E` | exact |
| 1 MB | `04D0E435` | exact |
| 5 MB | `BDBF684D` | exact |
| 10 MB | `2B11D791` | exact |

The 10 MB run is 18,439 bursts collected, 15,858 frames delivered and 11,977
sent -- call it twenty-eight thousand frames through an 8086 -- with every
one of the driver's error counters still at zero afterwards: no nonsense
bursts, no impossible lengths, no overflows, no toggle rescues.

**About 29 KB/s**, fetching 1 MB in 36 seconds. For scale, the ISA NE2000 in
the same machine does the same megabyte in 18s, so this is within about a
factor of two of a card with hardware interrupts and a 16-bit data path.

Getting there took correcting a measurement. `/R` looked to make no
difference at all, and that was wrong: the test wrote its download to disk,
and the disk hid the whole effect. Fetching to `NUL` instead:

| | `/R=1` | `/R=2` | `/R=4` | `/R=8` |
|---|---|---|---|---|
| before | 73s | 61s | 60s | 48s |
| after inlining the read loop | 71s | 43s | **36s** | 36s |

Two separate things there. The poll rate matters (it always did), and the
payload read loop was costing about 150 clocks a byte in call overhead and
port-61h settling reads — roughly 19 µs a byte, which capped the driver near
50 KB/s regardless of the wire. Inlining it without the settling pair is
safe on an 8086 because `IN`+`STOSB`+`LOOP` already leaves ~5 µs between
reads, far more than the chip asks for. On a faster machine it would want
the delay back.

**Latency needs its own measurement, and mTCP is not it.** `PING` reports
about 50 ms over this adapter at every setting, which sent me looking for a
fixed 46 ms delay that does not exist. `PKTTEST /N=200` does the round trip
itself and divides by the count, which is the only honest way to time
something far shorter than the 55 ms BIOS tick:

| | `/R=1` | `/R=4` | `/R=8` | `/R=16` | NE2000 |
|---|---|---|---|---|---|
| round trip | ~55 ms | 13 ms | **6 ms** | 6 ms | 1 ms |

The real figure tracks the poll interval and floors at 6 ms. mTCP's 50 ms is
its own timing granularity, not the wire.

### But `/R` defaults to 1, and that is deliberate

On the numbers above, 8 is obviously right. It was made the default, and
that was wrong. **MS-DOS `EDIT` is what proved it: with the timer at 145 Hz,
opening the editor wedged the machine hard enough to need the power switch.**

The reason is the interrupt chain. This driver hooks INT 08h and reprograms
the PIT, then chains to whoever was there 1 tick in 8, so the BIOS clock and
INT 1Ch stay honest — `TICKCHK` confirms 145 Hz on 08h and 18 Hz on 1Ch, and
DOS keeps perfect time. But:

- a program that hooks INT 08h **after** this driver sits in **front** of it
  and sees all 145 interrupts, so its own timing runs eight times fast;
- a program that reprograms the PIT for itself leaves our 1-in-8 chaining
  dividing the wrong thing, which starves the BIOS clock by a factor of
  eight and looks exactly like a hang.

Neither is something a packet driver gets to do to the rest of the machine
without being asked. So **the default touches the PIT not at all**, and `/R`
is there for when you know what else is running:

```
USBPKT /R=8        while shifting a large file -- 2x throughput, 6 ms
USBPKT             everything else
```

`/R=8` in `AUTOEXEC.BAT` on a machine somebody actually uses is a bad idea,
and this is the cost of the default: ~55 ms round trip instead of 6 ms, and
1 MB in 71 s instead of 36 s. Correctness first. A network driver that
breaks the text editor is not a working network driver.

If you raise `/R`, note that the budget is sized for it: bursts are 1 KB, so
17 reads at ~5.3 µs a byte is 5.7 ms, which fits inside `/R=8`'s 6.9 ms tick.
Raise `AxBulkSize` as well and that stops being true — the two constants are
related and neither travels alone.

`/Q=n` sets the AX88179's bulk-in aggregation timer (default 128), which
decides how long the adapter holds a part-full burst. It was a suspect for
the latency and is not: 2 and 128 measure the same. The switch is kept
because it is a real knob and now a documented dead end.

The remaining ceiling is the ISA bus rather than the wire — the link is
still several times faster than the driver can drain it, which is why the
PHY is held at 10BASE-T and why a faster cable buys nothing.

Verified end to end on the hardware, from one command:

```
ping 192.168.50.1     3/3    ttl=64
ping 8.8.8.8          3/3    ttl=118
ping google.com       3/3    ttl=106     (DNS)
HTGET example.com     559 bytes of HTML
NC test.rebex.net 21  220-Welcome to test.rebex.net!
NC <a telnet BBS> 23  Net2BBS - Resolving your IP Address...
```

with the driver reporting 967 bursts, 154 frames delivered, 108 sent, and
zero of every error counter it keeps.

### Testing it: use our tools, not mTCP

mTCP is for sanity checks on whatever network the machine is administered
over, and nothing else. It finds its driver through a config file, so
pointing it at a second adapter means editing that file for the duration of
a test and remembering to put it back.

`PKTTEST` takes the vector as an argument instead, so it cannot reach the
wrong card:

```
PKTTEST /M=<a free address> /I=65 /T=<address to ARP>   ask, and wait
PKTTEST /M=<a free address> /I=65 /L                    show what arrives
PKTTEST /M=<a free address> /I=65 /R                    ...and answer ARP and pings
```

`/R` makes the adapter answer to its address, so another machine can ping
it. That matters more than it sounds: a driver can receive every broadcast
on the wire and still drop everything addressed to itself, and only unicast
traffic tells the two apart.

### One thing to know first

**Run `USBPKT` before `NETID` or `USBLINK`, not after.** Those two enumerate
the adapter in order to look at it, and an adapter that is already
enumerated will not answer a fresh enumeration — `USBPKT` then stops at step
23 with status FF, which reads like a dead card and is not one.

Removing the adapter's power is what clears that: unplug it and plug it
back in, or power-cycle the machine, which does the same thing because the
card feeds VBUS off the ISA bus. Resetting the CH375 does not, so there is
a limit to what any program here can do about it on its own. `USBPKT`
unconfigures the device on `/U` for exactly this reason, which makes an
unload-then-load usually work — usually, not always.

This is not new and not specific to `USBPKT`; `USBLINK` has always said
"unplug it and plug it back in" for the same state. It is simply much more
visible now that one program does the whole job.

## The programs

| | |
|---|---|
| `src/ax179.pas` | everything that knows what an AX88179 is: the register map, the two vendor requests, the bring-up, and the bulk read |
| `src/usbpkt.asm`, `src/usbpktini.inc` | `USBPKT.COM` — **the one you run.** Enumerates the device, brings the adapter up, and installs a Crynwr packet driver. Needs nothing before it |
| `src/usblink.pas` | `USBLINK.EXE` — runs the same bring-up and reports every stage. Step one historically, and the one that decided the rest was worth writing. Now a diagnostic rather than a prerequisite |
| `src/usbrecv.pas` | `USBRECV.EXE` — reads the bulk endpoint and makes sense of what comes back. Deliberately an **investigation**, not a parser |
| `src/usbsend.pas` | `USBSEND.EXE` — sends an ARP request and waits for a real machine to answer it |
| `src/pktscan.pas` | `PKTSCAN.EXE` — which interrupt vectors hold a packet driver and which are free. Read-only, and the safety net for everything below |

All take `/?`. `/P=hex` sets the CH375 I/O base (`@hex` for `USBPKT`).

`USBPKT /A` skips the bring-up and takes the adapter as it stands, which is
the old two-program arrangement and still the way to tell a fault in the
bring-up apart from a fault in the driver.  (`/N` is a different switch and
always has been: install the vector but do not hook the timer.)

## Transmit, proved the only way that counts

A write to the bulk endpoint returning "success" only means the CH375 took
the bytes. It says nothing about whether a frame reached the wire — a
header field misplaced, a length off by the eight bytes of the header
itself, a padding flag missed, and the chip discards the lot in silence.

So `USBSEND` does not check that the write succeeded. It asks the network a
question and waits to be answered:

```
USBSEND /I=<a free address> /T=<your router>

Asking 192.168.50.1 who it is, claiming to be 192.168.50.222
  request 1 sent

REPLY from 04:D4:C4:D2:2B:00 -- 192.168.50.1 answered us.
```

Both addresses are required and neither is guessed. A tool that defaults to
somebody else's subnet is a tool that puts an address you have never heard
of on your wire.

That reply cannot be manufactured at this end. A frame built on an 8086,
pushed through an ISA card, put on the wire by the adapter, was received by
the router, parsed, believed, and answered back to this MAC. The router's
MAC also matches the one seen in an unrelated IGMP query `USBRECV` caught
earlier, which is a second, independent confirmation.

**The transmit header** is 8 bytes, two little-endian 32-bit words in front
of the frame: the length, then zero — except when the total including the
header lands on an exact multiple of the endpoint's 64-byte packet size, in
which case bits 15 and 31 are set. That same case also needs a zero-length
packet to terminate the USB transfer, which is a *separate* requirement
that happens to arise at the same moment and is easy to confuse with it.

## Why 10BASE-T, on purpose

`USBLINK` restricts the PHY to 10 Mbps unless you pass `/G`.

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
   hangs at boot is not recoverable remotely at any price. This was tried
   anyway on 2026-09-09, with an `IF ERRORLEVEL` fallback that was supposed
   to make it safe. On four boots out of five, cold power cycles included,
   `USBLINK` hung before the machine became reachable — and a hang sets no
   errorlevel, so the fallback never ran. Every recovery needed the power
   switch. The rule stands, and now it is measured rather than assumed.
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

`USBPKT.COM` **installs, runs and unloads cleanly.** Proven on the hardware,
with the working network at 60h untouched throughout:

```
=== part one: /N, no timer hook ===
Resident at vector 65h.
  60h  15A2:03CE   PACKET DRIVER      <- the machine's own network
  65h  16DD:1245   PACKET DRIVER      <- this one
USBPKT unloaded.

=== part two: full, timer hooked ===
Resident at vector 65h.
  vector=65   I/O base=0260
  MAC=40:AE:30:6D:00:34
  open handles=0
  timer ticks=10
USBPKT unloaded.
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

### The two bugs between "frames move" and "it pings"

Both hid behind a partial success, which is the worst place for a bug to
hide.

**The delivered length included the Ethernet FCS.** `RX_CTL_DROP_CRC` means
"discard frames whose CRC is wrong", not "strip the CRC" — the four bytes
arrive with the frame. `PKTCAP`'s dump had said so plainly for some time: a
42-byte ARP request, padded to the 60-byte minimum, arrived as **64 bytes**
with four non-zero bytes sitting after the padding.

**`bulk_out` restored `SI` on success.** It was added for the NAK rewind and
applied to the success path too, so the caller's `SI` never advanced and
every 64-byte packet after the first re-sent the *beginning* of the frame.

That second one is why the fault looked like a receive problem for so long.
A 60-byte ARP request is 68 bytes with the transmit header — 64 plus 4 — and
those four repeated bytes land in padding nobody reads, so **ARP resolved
perfectly**. A 74-byte ping is 82 — 64 plus 18 — and those eighteen repeated
bytes are real IP header, so the router dropped every one in silence. ARP
working was the thing that made the transmit path look innocent.

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

### set_rcv_mode reaches the hardware

Modes 1 to 6 are mapped onto the adapter's filter bits and written to
`RX_CTL`. It used to store the value and stop there, so `get_rcv_mode`
agreed with itself while the adapter carried on doing whatever it had been
doing — and an application asking for promiscuous mode and silently not
getting it is a particularly unhelpful failure, because everything looks
fine and simply no interesting frames arrive.

Doing it needed a control transfer that survives going resident: the full
one lives in the transient half and is handed back to DOS. There is now a
minimal resident version — one register, one 16-bit value — reached only
from the INT 65h handler and never from the ISR, because it takes
milliseconds and that is not a cost worth paying inside a timer interrupt.

## What has been proved over it

| | |
|---|---|
| ARP | resolves both directions |
| ICMP, local | 3/3 to the gateway, 3/3 to a LAN host |
| ICMP, routed | 3/3 to `8.8.8.8` at ttl=118, 2/2 to `1.1.1.1` |
| DNS (UDP/53) | `example.com` resolved to `172.66.147.243` |
| TCP | a telnet session to a BBS in Rimini, full 80x24 screen |
| **HTTP** | **`example.com` 200 OK / 559 bytes, `info.cern.ch` 646 bytes** |

```
--- example.com over the CH375 USB adapter ---
mTCP HTGet by M Brutman
Server return code: 200 OK
```

559 bytes, byte for byte what a modern machine gets from the same URL, and
`info.cern.ch` fetched afterwards at 646 bytes with the server's 2014
Last-Modified date preserved on the file. An IBM PS/2 Model 30 from 1987
pulling web pages over a USB network adapter it predates by nine years.

### Two drivers at once

The machine's own network is an NE2000 packet driver at INT 60h and the
bridge this is developed over runs on it, so the two coexisting is not a
nicety. Checked in six stages: vectors before, load ours, vectors with both
present, ping over 60h **while ours is loaded**, ping over 65h, unload,
vectors again, ping over 60h again.

```
===== 5. unload ours =====
USBPKT unloaded.
  60h  15A2:03CE   PACKET DRIVER
1 packet driver(s) between 60h and 80h.
===== 6. 60h ping after unload =====
Packets sent: 2, Replies received: 2, Replies lost: 0
Average time for a reply: 4.25 ms
```

That 4.25 ms against roughly 51 ms over ours is the open question of this
project, and the section below is what is actually known about it.

## Latency: two theories tested, both wrong

The round trip to the gateway is a near-constant **51 ms** over this driver
and **4.25 ms** over the machine's interrupt-driven NE2000 to the same
address one hop away. It is a constant rather than a distribution, which is
the most useful thing about it.

**Theory one: our poll interval.** The ISR collects on the timer, so a
reply could be waiting for the next tick. `/R=n` divides the PIT the way
`USBMOUSE` and `USBCOMBO` do -- the timer runs fast and the handler that
was in the vector before us is called only every nth tick, so the BIOS
clock is undisturbed. Verified working rather than assumed:

```
DOS says 5.0 seconds elapsed
  timer ticks=855          (~171/sec; it reads 106 at /R=1)
  timer divisor (/R)=8
```

Eight times the poll rate, DOS clock still correct -- and the latency did
not move. `/R=8` gives ~51 ms and so does `/R=1`. **Not the cause.**

**Theory two: the adapter's bulk-in aggregation timer.** The chip holds
received data until its own timer expires, whatever we do. `USBLINK /K=hex`
sets it; `0x0080` and `0x0004` both give ~51 ms. **Not the cause.**

So something imposes a fixed ~51 ms in the receive path that is neither of
those. Untested: mTCP's own timing granularity over a polled driver, and
whatever the CH375 does between a frame reaching the chip and the bulk
endpoint having it.

The `/R` work stays. It is correct, it restores the PIT on unload -- leaving
the timer fast with our handler gone would make the DOS clock run eight
times quick with nothing on the machine able to explain why -- and an
eightfold increase in how often the wire is looked at matters for
throughput even if it did nothing here. `/R=1` leaves the timer alone.

### A process note worth more than either theory

Theory one was "disproven" once against a **stale binary**: built, never
re-staged, so the test ran the old driver and produced a confident wrong
answer. What caught it was measuring the *mechanism* -- `timer ticks` --
instead of the *outcome*. Source and behaviour disagreeing is visible; two
identical ping results are not.

`dosctl exec` runs what is already on the box and only `run` re-stages.
That has now cost three wrong conclusions in one session, so: after every
build, `run` the binary once before any test that uses `exec`.

## Which adapters can this drive?

`NETID` says, for whatever is plugged in:

```
device   : 0B95:1790  ASIX
chip     : ASIX AX88179
family   : ASIX AX88179/178A
SUPPORTED.
```

Recognition works two ways, and they are not equally good. **By class** is
the right way: CDC-ECM and CDC-NCM are standards, and an adapter declaring
interface class 02 can be driven without knowing who made it. **By
VID/PID** is the way that actually gets you online, because most cheap
adapters are vendor-specific -- the AX88179 here reports class `FF/FF/00`,
which means "ask the manufacturer".

`netchip.pas` holds both: 24 entries across ASIX, Realtek,
SMSC/Microchip, Davicom, Moschip and common rebadges, plus class-based
detection for anything not tabulated. "Recognised" and "supported" are
deliberately separate -- an adapter it knows but cannot drive says so in
one line, which is far more use than a bring-up that fails halfway and
leaves you wondering about the cable.

**Only the AX88179 is implemented today.** The most valuable one to add
next is CDC-ECM, because that is a standard: one driver, every adapter that
speaks it, instead of another entry in a table of vendor quirks.

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
