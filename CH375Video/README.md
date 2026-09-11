# CH375Video — USB display adapters over a CH375

An 8086 with a CH375 USB host card, driving a USB-to-VGA adapter.

**It works.** A DisplayLink adapter is identified from its own descriptors,
a video mode is set, and pixels appear on the monitor — verified by
somebody looking at the screen, four patterns out of four.

| tool | |
|---|---|
| `DLPROBE` | identify the adapter, decode its capability limits, read the monitor's EDID |
| `DLTEST` | set a mode, draw test patterns, and ask the person watching whether each appeared |

```
DLPROBE [/P=260] [/E=n] [/K] [/I=n] [/V] [/T]
DLTEST  [/P=260] [/M=n] [/W=secs] [/A=secs] [/N] [/Q] [/B] [/X=n] [/Y=n]
```

`build.cmd` builds both. `build.cmd probe` runs `DLPROBE` on the DOS box;
`build.cmd read` runs it with `/K` so nothing is written at all.

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
the box it came in:

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

The cap is advertised as **39,999,999 Hz** — one hertz under a round 40
MHz. That is a fencepost in whoever programmed the descriptor, not a real
boundary, so 800x600@60 is reported as MARGINAL rather than refused.
Calling it impossible over one hertz would be precisely, confidently
wrong, and only the hardware can settle it. Truncating rather than
rounding also printed the cap as "39.9 MHz", which reads as a limit below
40 and invites the same mistake; it rounds now.

## The monitor, and why the intersection is the answer

`DLPROBE` reads the attached monitor's EDID **through** the adapter — 128
control transfers, two bytes each, of which only the second is data.

```
DELL 1708FP     manufacturer DEL, product 4023, EDID 1.3
                made week 41 of 2007, 34 x 27 cm
                preferred mode 1280x1024 @ 108.0 MHz
                range V 56-76 Hz, H 30-81 kHz, clock up to 140 MHz
```

Neither end's list is the answer on its own, and this pair shows exactly
why — the monitor advertises 1024x768 and 1280x1024, and the adapter
refuses every one of them on clock:

```
mode          dot clock   adapter                  monitor
640x480@60     25.2 MHz   ok                       yes   <--
640x480@75     31.5 MHz   ok                       yes   <--
720x400@70     28.3 MHz   ok                       yes   <--
800x600@56     36.0 MHz   ok                       no
800x600@60     40.0 MHz   MARGINAL -- 1% over cap  yes
1024x768@60    65.0 MHz   no -- clock              yes
1280x1024@60  108.0 MHz   no -- clock              yes
```

Three modes survive both ends, and `DLPROBE` names the largest rather
than leaving it to be worked out by eye. The monitor side is checked in
all three places EDID can state a mode — the established bitmap, the four
detailed blocks and the eight standard entries — because a display need
not use the same one.

## What has actually been proven on hardware

| | |
|---|---|
| device identified | from its own descriptors |
| capability list decoded | tiles exactly, so the limits are believable |
| `GET_DESCRIPTOR 5F` standalone | works — the way udlfb asks |
| vendor control path with a data stage | 128 of 128 EDID transfers succeeded |
| monitor EDID | read and decoded — a DELL 1708FP |
| channel unlock | accepted |
| interrupt endpoint | answers NAK: alive, nothing to report |
| **video mode set** | **640x480@60, monitor acquires sync** |
| **pixels** | **solid fills and colour bands, confirmed by eye** |
| **5-6-5 byte order** | **blue comes out blue, not red** |

That last row is its own test for a reason. A byte-swapped 5-6-5 pixel
still produces a colourful, plausible-looking band pattern — so the bands
alone could have passed while being wrong. Asking specifically for *blue*
is what settles it.

## Asking a human, because nothing else can answer

`DLTEST` is the first thing here that cannot be verified by reading a
status byte. The capture card watches the DOS box's own VGA output, not
the adapter's, so the only instrument that can confirm a pixel is a person
looking at the screen.

So each pattern **beeps**, then asks on **stderr**, then waits a bounded
ten seconds:

```
>> 8 colour bands, red at the top -- SEEN IT?  Y/N  (10s) yes
```

Three parts, each load-bearing:

* **stderr, not stdout.** A job's stdout is redirected into
  `C:\WORK\OUT.TXT` and reaches nobody until the job has finished, so a
  prompt written there would arrive minutes after the moment it was asking
  about. DOS 6.22 cannot redirect handle 2 at all — normally a nuisance in
  this project — so stderr lands on the real screen, where somebody
  watching the machine is already looking.
* **A beep first.** The prompt is useless if nobody's eyes are on the
  screen when the pattern is up, so the noise comes *before* the question
  rather than after it.
* **No answer is recorded as "no answer".** The two cases it cannot
  distinguish — the pattern did not appear, and nobody was watching — are
  both non-answers, and collapsing them into "fail" would put a guess in
  the log. A run with any non-answer exits **8**, deliberately distinct
  from a clean **0**.

Every wait is bounded by the BIOS tick counter, so an unattended run
finishes on its own instead of turning a job into a hang that needs hands
on the keyboard. `/N` skips the asking entirely.

## The part nobody would guess: the LFSR

Commands are a byte stream on the bulk OUT endpoint, each starting `AF`.
A register write is `AF 20 <reg> <val>`, the video registers are bracketed
by a lock (`FF`=00) and an unlock (`FF`=FF), and blanking is register `1F`.

**Most of the timing registers do not take the number you want.**
Registers `01` through `15` take that number pushed through a 16-bit LFSR
seeded `0xFFFF` and stepped once per unit of value, while `0F` and `17`
take a plain big-endian word and `1B` takes a byte-swapped one.

```
lv = 0xFFFF
repeat value times:
    lv = ((lv << 1) | (((lv>>15) ^ (lv>>4) ^ (lv>>2) ^ (lv>>1)) & 1)) & 0xFFFF
```

Writing the raw values produces a dead screen and nothing whatsoever to
diagnose. This is not something to be derived from first principles or
guessed at from a datasheet — it was taken from the Linux `udlfb` driver,
which is the readable record of this protocol. Reaching for that source
rather than trying register values was the single decision that made this
work at all.

## Why a full screen is affordable, and where the ceiling is

The CH375 moved Ethernet frames at a measured **22–23 KB/s** on this
machine, and a display adapter's bulk endpoint is the same chip, the same
ISA bus and the same byte-at-a-time port I/O. Raw, a 640x480 16bpp frame
is 614,400 bytes — about **27 seconds**.

The RLE command is what rescues it. A run of 256 identical pixels — 512
bytes of framebuffer — encodes in **ten bytes**:

```
AF 6B <addr24> <pixels in command> <raw count> <pixel> <repeat-1>
```

So a full-screen solid fill is 1,200 commands and about 12 KB, well under
a second. A run of exactly one carries **no** repeat byte at all, which is
a genuine shape difference rather than a count of zero.

That sets the honest shape of this: **static images, test patterns and a
text console are practical; anything that animates is not.** Content that
suits this machine — solid areas, text, line art — is exactly what the RLE
compresses well, and photographs are exactly what it does not.

## Traps, all of them paid for here

**Every transfer must be padded with `AF`, and it is not tidiness.** The
command parser does not act on the final command until more bytes follow
it, so an unpadded transfer silently drops its last command. One command
is 256 pixels, and the symptom was the last ~256 pixels of a fill keeping
their *previous* colour — visible as a strip of the old picture surviving
in the bottom-right corner.

That reads as a drawing bug, or an off-by-one in the address arithmetic,
and is neither: the addresses were right all along and the problem is
framing. `udlfb` does this with a `memset(cmd, 0xAF, ...)` that is easy to
read as housekeeping and skip — skipping it cost a round here. `AF` is the
byte every command starts with, so a run of them is filler the parser can
resynchronise on.

`DLTEST`'s **test 5** exists for this specific failure: it fills white
over blue and asks only about the bottom-right corner. Folding it into
"did you see white" would have hidden it, because the other 99% of the
screen was correct and the pattern looked fine.

**A picture landing off-centre is usually the monitor, not the timings.**
The first working pattern sat about 100 px right of centre. The fix was
the monitor's own auto-adjust button — the timings were correct. `/X` and
`/Y` can move the active region within the line and frame without changing
either total or the dot clock, but they have **no default** and exist to
prove where the fault is: compensating in software for one monitor's
un-adjusted position would have baked this bench into the tool and been
wrong on every other display.

**Polling an endpoint that never answers wedges the chip.** `WaitInt`
gives up after its timeout; the chip does not. A program that exits at
that moment strands the token, and the next tool asks `CHECK_EXIST`, gets
nothing, and reports **"no CH375 at 0260" on a card that is plainly
fitted** — which reads as a hardware fault and is entirely
self-inflicted. It cost a power cycle here. Both tools now retire the
token with `ABORT_NAK` on the way out, and reset-and-re-ask before
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

**EDID is read two bytes at a time**, and only the second byte is data.
128 transfers for 128 bytes is not a misunderstanding of the protocol; it
is the protocol. A reply shorter than two bytes means the byte was not
delivered, so the read stops rather than storing a zero — a short EDID is
honest, an EDID padded with invented zeroes would pass its own header
check and lie.

**All 128 bytes coming back zero is two findings, not one failure.** It
happened before the monitor was attached: every transfer succeeded and
every byte was zero, which says the control path works *and* the adapter
had nothing to describe. Nothing is decoded from a zero block — 128 zeroes
sum to zero, so it passes the EDID checksum test trivially, and printing
"checksum ok" beside a failed header would be worse than printing nothing.

**EDID is asked for before the unlock, and that ordering survived a
test.** The unlock is the step most likely to be refused by a chip
revision nobody here has seen, so a refusal should not cost the monitor
report too. When the first read came back empty that left an obvious
hypothesis — that this chip will not read the monitor's DDC until its
channel is open — so `DLPROBE` now asks a *second* time after the unlock
whenever the first came back empty. It has never needed to: the empty read
was a monitor that was not attached. 128 control transfers is a cheap way
to settle that rather than reason about it.

**Git Bash mangles `/K` into a Windows path** before Python sees it, so
program flags passed through `dosctl run` from a bash shell silently
vanish. Both tools accept `-K`, which survives; `cmd` and PowerShell pass
either form intact. This looked exactly like a bridge bug and was not one
— `dosd`'s own dispatch line showed the arguments already missing.

## Next

1. **A text console.** 80x30 at 8x16 in a 640x480 framebuffer, RLE'd per
   line. Text is mostly background, so this is the case the compression
   was made for, and it is the first thing that would make the adapter
   *useful* rather than proven.
2. **Only redraw what changed.** `udlfb` keeps a back buffer and skips
   unchanged pixels; at 22 KB/s that is the difference between a usable
   console and a slideshow.
3. **Derive timings from the EDID** rather than a built-in table, so any
   monitor's own preferred mode is used when it fits inside both caps.
4. **Try 800x600@60**, the MARGINAL row, and settle whether the
   39,999,999 Hz cap is a real boundary or a fencepost. `DLTEST /M=3`
   does exactly this.
