# CH375Video — USB display adapters over a CH375

An 8086 with a CH375 USB host card, asked whether it can drive a USB-to-VGA
adapter. This directory holds what has been established so far, which is
identification and the control path — not pixels.

`DLPROBE` is the tool. It identifies the adapter from the device itself,
decodes the chip's own capability limits, and reads the attached monitor's
EDID through the adapter.

```
DLPROBE [/P=260] [/E=n] [/K] [/I=n] [/V] [/T]
```

| | |
|---|---|
| `/P=hex` | I/O base, default 260 |
| `/E=dec` | EDID bytes to read, default 128. `0` skips it |
| `/K` | skip the channel unlock — the only write it makes |
| `/I=dec` | also poll the interrupt endpoint this many times |
| `/V` | narrate the bring-up |
| `/T` | trace every control-transfer stage |

`build.cmd` builds it; `build.cmd probe` builds and runs it on the DOS box,
`build.cmd read` does the same with `/K` so nothing is written at all.

## Why this is a different problem from CH375Net

CDC-ECM worked out because Ethernet **has a class**. The device describes
itself, so one bring-up covers adapters from vendors nobody here has
bought, and `USBPKT` picks the class path from the descriptors.

There is no USB display class. The Video class is for cameras. Every USB
display adapter is a private protocol, so there is nothing to generalise
over and no descriptor that says how to drive it. The only useful first
question is *which* private protocol, and that is what `DLPROBE` answers.

## The adapter on the bench

An **IOGEAR GUC2015V**, "USB 2.0 to VGA". Read off the device rather than
the box:

```
17E9:0058   bcdDevice 1.02
iManufacturer  "DisplayLink"
iProduct       "IOGEAR External VGA"
iSerialNumber  "009091"

one configuration, one interface, class FF vendor-specific
  EP 01  OUT  bulk       max 64      <- commands and pixels
  EP 82  IN   interrupt  max 8, interval 4
  descriptor type 5F, 30 bytes       <- the capability list
```

`17E9` is DisplayLink, and that is the whole identification. The product
ID varies per OEM and the strings are whatever the reseller asked for, so
neither is evidence of anything.

## What the 5Fh descriptor says, and why it is trustworthy

DisplayLink's capability list: a five-byte header, then key/length/value
triples. Both checks pass on this device — the header self-describes twice
(`bLength` whole, and again as `bLength-2`), and the triples **tile the
descriptor exactly**, ending on byte 30 of 30 with nothing left over.

That second check is the one that matters. A wrong guess at the layout
still produces plausible-looking keys and values; the only thing that
catches it is insisting the walk land on the final byte. `DLPROBE` says so
out loud when it does not tile, and distrusts its own output in that case.

```
key 0005  len 1  03           = 3
key 0204  len 4  FF 59 62 02  = 39999999   pixel-clock limit, Hz
key 0200  len 4  60 E3 16 00  = 1500000    pixel-area limit
key 0400  len 4  01 00 03 60  = 1610809345
```

**Both caps bind, and the clock is the tighter one.** That is the part a
glance at the pixel count gets wrong, in the optimistic direction: 1.5
million pixels of area sounds like it should allow 1024x768, and the 40
MHz clock refuses it outright at 65 MHz.

| mode | dot clock | verdict |
|---|---|---|
| 640x480@60/72/75 | 25.2 / 31.5 MHz | ok |
| 800x600@56 | 36.0 MHz | ok |
| **800x600@60** | **40.0 MHz** | **marginal — see below** |
| 800x600@72/75 | 50.0 / 49.5 MHz | no — clock |
| 1024x768@60 | 65.0 MHz | no — clock |
| 1280x1024@60 | 108.0 MHz | no — clock |

The cap is advertised as **39,999,999 Hz** — one hertz under a round 40
MHz. That is a fencepost in whoever programmed the descriptor, not a real
boundary, so 800x600@60 is reported as MARGINAL rather than refused.
Calling it impossible over one hertz would be precisely, confidently
wrong, and only the hardware can settle it. Truncating rather than
rounding also printed the cap as "39.9 MHz", which reads as a limit below
40 and invites the same mistake; it rounds now.

## What has actually been proven on hardware

| | |
|---|---|
| device identified | from its own descriptors, not from the packaging |
| capability list decoded | tiles exactly, so the limits are believable |
| `GET_DESCRIPTOR 5F` standalone | works — 30 bytes, the way udlfb asks |
| **vendor control path with a data stage** | **works — 128 of 128 EDID transfers succeeded** |
| **channel unlock accepted** | **status 14** — the chip will take a command stream |
| interrupt endpoint | answers NAK: alive, nothing to report |

Those last two are the milestone. The unlock is a fixed 16-byte key on a
vendor request, and the hardware ignores rendering commands until it has
been sent — so a refusal there would have made the pixel format irrelevant.
It was accepted.

**No monitor is attached to the adapter.** All 128 EDID transfers
succeeded and every byte came back zero. Those are two separate findings
and `DLPROBE` reports them separately: the control path works, and the
adapter has nothing to describe. Nothing is decoded from a zero block —
it passes the EDID checksum test trivially, because 128 zeroes sum to
zero, so printing "checksum ok" beside a failed header would be worse
than printing nothing.

## What has NOT been done, and the honest ceiling

No video mode is set and no pixels are sent. Those need the register
table, and a tool that half set a mode would leave the adapter in a state
the next run would have to guess at.

Before anyone invests in that, the arithmetic. The CH375 moved Ethernet
frames at a **measured 22–23 KB/s** on this machine, and there is no
reason a display adapter's bulk endpoint would do better — it is the same
chip, the same ISA bus and the same byte-at-a-time port I/O.

```
640x480 at 16bpp = 614,400 bytes
614,400 / 22,528 = about 27 seconds per full frame
```

So this will never be a second monitor for anything that moves. What it
could plausibly be is a **static image or a text console**, because the
protocol has an RLE-compressed pixel command and the content that suits
this machine — solid areas, text, line art — is exactly what compresses
well. A solid fill is a few hundred bytes rather than 600 KB.

That is the honest shape of it: worth doing, and not worth doing for
animation.

## Traps, all of them paid for here

**Polling an endpoint that never answers wedges the chip.** `WaitInt`
gives up after its timeout; the chip does not. A program that exits at
that moment strands the token, and the next tool asks `CHECK_EXIST`, gets
nothing, and reports **"no CH375 at 0260" on a card that is plainly
fitted** — which reads as a hardware fault and is entirely
self-inflicted. It cost a power cycle here. `DLPROBE` now retires the
token with `ABORT_NAK` on the way out, and resets-and-re-asks before
believing the slot is empty, because `BusUp` gives up on a failed
`CHECK_EXIST` before it reaches its own `ChipReset`.

**The retry policy is opposite for the two transfer types**, and this
project has now learned it twice. `BusUp` leaves the chip on `8F` — retry
NAKs in hardware — which is right while enumerating, because a control
transfer's data stage must be retried inside the transfer. On a **data**
endpoint it is exactly wrong: a NAK there means "nothing for you yet",
which is an *answer*, and absorbing it turns every quiet poll into a
60 ms timeout reported as "no interrupt" — indistinguishable from a dead
endpoint. Setting `00` around the interrupt poll changed the output from
six timeouts to six honest NAKs.

**EDID is read two bytes at a time.** The device returns two bytes per
EDID byte and only the second is the data. 128 transfers for 128 bytes is
not a misunderstanding of the protocol; it is the protocol. A reply
shorter than two bytes means the byte was not delivered, so the read
stops rather than storing a zero — a short EDID is honest, an EDID padded
with invented zeroes would pass its own header check and lie.

**EDID is read before the unlock, on purpose.** The unlock is the step
most likely to be refused by a chip revision nobody here has seen. Done
first, a refusal would have cost the monitor report as well.

**Git Bash mangles `/K` into a Windows path** before Python sees it, so
program flags passed through `dosctl run` from a bash shell silently
vanish. `DLPROBE` accepts `-K` as well, which survives; `cmd`/PowerShell
pass either form intact. This looked exactly like a bridge bug and was
not one — `dosd`'s dispatch line showed the arguments already missing.

## Next, in order

1. **Plug a monitor into the adapter** and re-run. The EDID decoder is
   written and untested against real data; that is the cheapest useful
   step and it also settles what timings the display will accept.
2. Work out how to *see* the output. The capture card watches the box's
   own VGA, not the adapter's, so nothing here can currently verify a
   pixel. Either move the capture input or have somebody look.
3. Set a mode: the register writes are `AF 20 <reg> <val>` on bulk
   endpoint 01, and 640x480@60 is the one to try first — comfortably
   inside both caps.
4. Only then, pixels, and RLE before raw.
