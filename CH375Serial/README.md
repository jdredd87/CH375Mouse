# CH375Serial

USB-to-serial adapters on an 8086-class DOS machine, through a CH375 USB host
card.

**Status: early. The probe works and is verified against real hardware; nothing
drives a serial port yet.** This file says exactly what has been measured and
what has not, because the interesting part of this project is that — unlike
CH375Audio — there is no architectural reason it should fail.

---

## Why this one should work

CH375Audio ended in a measured impossibility. A USB-to-serial adapter is the
opposite of a USB speaker on every count that mattered there:

| | USB audio | USB serial |
|---|---|---|
| transfer type | isochronous — no handshake | **bulk** |
| packet size | 192 bytes | **64 bytes or less** |
| rate | 192,000 B/s, hard 1 ms deadline | **11,520 B/s at 115200 baud** |
| late data | an audible click | a byte that arrives late |

Against ~19,000 bytes/second measured on this hardware, **the link is not the
limit**. Both ends buffer, which is the property that decides everything on
this bus — see the rule in the collection's [top-level README](../README.md).

---

## The reference adapter, and the trap it exposed

The part this was written against is a **Keyspan USA-19H** (`06CD:0121`).

```
  device              : 06CD:0121  Keyspan / InnoSys
  configurations      : 2
  selected            : index 1, value 2
      EP 01  OUT  bulk  max 64
      EP 02  OUT  bulk  max 64
      EP 03  OUT  bulk  max 64
      EP 81  IN   bulk  max 64
      EP 82  IN   bulk  max 64
```

### It has TWO configurations, and they are not interchangeable

| | EP 81 / 82 |
|---|---|
| index 0, value 1 | **interrupt** IN |
| index 1, value 2 | **bulk** IN |

Same endpoints, same numbers, same everything else — only the transfer type
differs. Both are drivable from a CH375, which does interrupt *and* bulk, but
bulk is what you want for a data pipe.

This matters beyond this one adapter. Nearly every USB device has exactly one
configuration, so nearly every driver — including the first draft of this
project's — fetches index 0 and sends its `bConfigurationValue` without ever
looking. That would have worked here, slower, for reasons that would never
appear in its own logs.

Note also that the descriptor **index** and the **bConfigurationValue** are
different numbers — 0/1 and 1/2 here — and sending the index where the value
belongs selects nothing at all. This device makes that mistake visible, which
is a good reason to keep it as the reference part.

### Four endpoints, not two

Keyspan splits the job further than most: data in and out, **plus a separate
control OUT and status IN**.

```
  data OUT            : 01  (addr 01)  max 64
  data IN             : 01  (addr 81)  max 64
  control OUT         : 02  (addr 02)
  status IN           : 02  (addr 82)
```

A driver that assumes the usual two-endpoint shape would send its line settings
down the data pipe and out of the serial port as gibberish.

---

## What is verified, and what is not

| | |
|---|---|
| Enumeration over CH375 | **verified** |
| Both configurations read and decoded | **verified** |
| Selecting the bulk configuration | **verified** |
| Endpoint map | **verified** |
| Status pipe behaviour with an idle port | **verified** — steady NAK (42), 4487 of them in 5 s |
| Setting baud rate / line settings | **not implemented** |
| Sending or receiving a byte of serial data | **not attempted** |

A steady NAK on the status pipe is the *correct* answer for a port that has not
been opened: the adapter has nothing to report until it has been configured
over the control endpoint. It is not evidence of a fault, and `SERPROBE` says
so rather than implying otherwise.

**Nothing here can tell you whether anything is plugged into the serial end.**
With an empty port a healthy adapter and a dead one look identical: the data
pipe NAKs either way.

---

## The honest problem: Keyspan's protocol is private

Only **CDC-ACM** is a real standard. Everything else — FTDI, Prolific, WCH,
Silicon Labs, Keyspan — is a private vendor protocol reached through control
transfers or a control endpoint, and they disagree about everything: how a baud
rate is encoded, whether line settings are one message or three, and in FTDI's
case whether the data stream contains only data.

Keyspan is at the difficult end of that range. Its message format is not
published; what is known publicly comes from the Linux `keyspan` driver, and
reproducing it from memory of that driver is exactly the kind of guessing this
collection tries not to do. So the line-setting path is **written as
unimplemented rather than written as a guess**, and `SERPROBE` reports the
family as *recognised but not driven*.

**If the goal is a working serial port sooner rather than later, a cheap
CH340, CP2102, FTDI or CDC-ACM adapter is a far better target** — those are
documented, and the code for them can be written with confidence instead of
reverse-engineered. The Keyspan remains the better *test* part, because its
two-configuration layout catches driver bugs that a simple adapter never
would.

One thing in its favour: `06CD:0121` is the Keyspan USA-19HS product ID, which
in the Linux driver's table is a **working** ID rather than a pre-firmware one
— so this adapter should not need a firmware download before it will talk.
That is an inference from the ID table, not something measured here.

---

## The tools

### `SERPROBE` — identify the adapter

```
SERPROBE [/P=260] [/C=n] [/S=secs] [/E=n] [/V] [/T]

  /C=n     configuration INDEX to select, default 0
  /S=secs  poll an IN endpoint and print whatever arrives, raw
  /E=n     which endpoint to poll (default: the status pipe)
```

Read-only: it selects a configuration and reads descriptors, and sends no data.
`/S` is how to watch a status pipe — on a part that has one it reports the
modem lines, and it should change when a cable is finally attached, which is
the experiment worth running once there is something to plug in.

---

## Building

```
build.cmd            build only
build.cmd probe      ...then identify the attached adapter
build.cmd bulk       ...select the bulk configuration and report
build.cmd watch      ...and poll the status pipe for 20 seconds
```

Needs Free Pascal cross-compiling to real-mode DOS (`-Tmsdos -Pi8086`). The
CH375 layer is `ch375.pas` from `..\CH375USBTOOLS\src`, found with `-Fu`.

### `dser.pas`

Family detection and the bring-up. One ordering detail in it was learned here
and is worth repeating, because it is subtle and it bit twice:

**`SET_RETRY 00` must come after every control transfer of the bring-up, and
before any endpoint is polled.** `BusUp` arms `SET_RETRY 8F` — retry NAKs
forever — which is right while enumerating and catastrophic afterwards, since
an idle adapter NAKs its bulk IN constantly and the chip will grind on that
until it stops answering anything at all. But putting it *early* is just as
wrong: a device that NAKs one control transfer while preparing a response then
fails on the first ask. This adapter has an 8-byte control endpoint, so its
descriptors take many round trips and it NAKs during them — it failed
immediately with `cannot read the configuration header (NAK)` until the call
moved to the end. CH375Audio's speaker answered fast enough to hide the same
bug.

---

## Where this sits in the collection

| project | |
|---|---|
| [CH375USBTOOLS](../CH375USBTOOLS) | the shared CH375 layer and the generic probes |
| [CH375Keyboard](../CH375Keyboard) | USB keyboards |
| [CH375Mouse](../CH375Mouse) | USB mice |
| [CH375Net](../CH375Net) | USB Ethernet |
| [CH375Video](../CH375Video) | USB display adapters |
| [CH375Audio](../CH375Audio) | USB audio: the mixer and the buttons, not the sound |
| **CH375Serial** | USB-to-serial: identified, not yet driven |

---

Public domain (the Unlicense); see [LICENSE](../LICENSE).
