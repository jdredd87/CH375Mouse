# CH375Net — USB Ethernet on a machine older than USB

**Status: work in progress.** Bring-up is finished and proven on the
hardware. Frames arrive and decode correctly. The receive *buffer layout*
is still being reverse-engineered, and nothing transmits yet.

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
| `src/axrecv.pas` | `AXRECV.EXE` — reads the bulk endpoint and tries to make sense of what comes back. Deliberately an **investigation**, not a parser |

Both take `/?`. `/P=hex` sets the CH375 I/O base.

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
switch and not a constant. The same goes for the bulk-in aggregation
setting: this driver turns it off because it cannot absorb a 20 KB burst,
where Linux turns it on because it can.

## Two traps that cost real time

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

`USBPOLL` already knew both of these. Neither is written down anywhere
except in its source, which is why they are written down here.

## What is not done

- **The receive buffer layout.** The AX88179 does not put a bare frame on
  its bulk endpoint. Frames sit at the front and something structured
  follows them — an `AA 55` pattern recurs between frames — but the
  trailing count-and-offset word the Linux driver describes reads as zero
  here, so the recollection does not match the silicon and the silicon
  wins. `AXRECV /X /R` dumps bursts raw for exactly this reason.
- **Transmit.** Nothing is sent. Each frame needs an 8-byte header.
- **The packet driver.** The goal is a Crynwr driver at INT 60h, because
  that is what `mTCP`, `WATTCP` and NCSA Telnet all speak — get it right
  and the whole DOS networking ecosystem works, with no TCP stack written
  here.

## Throughput

Not yet measured meaningfully. `AXRECV` reports a floor including idle
time; the real number needs a saturated link and the layout understood
first. That number is the one that decides whether this is useful or
merely interesting.

## Building

    build.cmd            build both programs
    build.cmd probe      ...then bring the adapter up on the DOS machine
    build.cmd recv       ...then watch frames arrive
    build.cmd raw        ...then dump bursts without interpreting them

Needs Free Pascal cross-compiling to `i8086-msdos`. `ch375.pas` and
`chtool.pas` come from `..\CH375USBTOOLS\src` via `-Fu`.

Public domain, under [the Unlicense](https://unlicense.org). Written by
**StevenC**.
