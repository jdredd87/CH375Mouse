# Changelog

CH375Net -- StevenC -- https://github.com/jdredd87/CH375USBTools

Versions live in the `VER` constant of each program.

## Second adapter, and the tools stop being called AX

**A second, physically different AX88179 works, with nothing changed.** It
was plugged in and the machine booted; `AUTOEXEC.BAT` brought it up
unprompted. Different manufacturer, different MAC — `00:50:B6:B6:1C:64`
against the first adapter's `40:AE:30:6D:00:34`.

- boot brought it up on its own, no intervention
- ARP answered, 100/100 round trips at 7 ms
- ping 8.8.8.8 3/3 `ttl=118`, `google.com` 2/2 `ttl=109`
- 1 MB `04D0E435` and 5 MB `BDBF684D`, checksummed on the box, both exact
- three boots — two warm, one cold — all up at 6-7 ms
- every error counter zero throughout

That is worth more than it might look. A sample of one cannot tell a working
bring-up from one accidentally tuned to a single unit's quirks. Two
independent adapters can. It is **not** evidence about a different chipset —
same `0B95:1790` silicon — and the register map has still only ever driven
one part.

### Renamed away from AX

The tools were named for the only chip they had ever seen, which is a poor
name for a project that wants more of them:

| was | is |
|---|---|
| `AXPKT.COM` | `USBPKT.COM` |
| `AXPROBE.EXE` | `USBLINK.EXE` |
| `AXRECV.EXE` | `USBRECV.EXE` |
| `AXSEND.EXE` | `USBSEND.EXE` |
| `AXNET.EXE` | `PKTTEST.EXE` |
| `AXTICK.EXE` | `PKTTICK.EXE` |

`NETID` and `PKTSCAN` were already generic. **`ax179.pas` keeps its name on
purpose** — it is the AX88179/178A register map, it is chip-specific, and
pretending otherwise would be the actual lie. Same for the resident
signature, `AXPKT001` → `USBPKT01`.

Whole suite re-run on hardware afterwards: `PKTSCAN`, `NETID`, `USBLINK`,
`USBRECV` (20 frames, 0 errors, 0 layout wrong), `USBSEND` (router replied),
`USBPKT`, `PKTTEST` 100/100 at 7 ms. `AUTOEXEC.BAT` and `NET.BAT` updated on
the machine and verified across a reboot.

### ADAPTERS.md

A support matrix, to grow: works / should work / needs a driver / unlikely,
with USB IDs. Currently one part in the first column and one in the second.

It is honest about what the rename bought, which is naming and not much
else. A new chipset still needs a bring-up in `ax179.pas`'s equivalent *and*
in `usbpktini.inc`, plus a dispatch on the USB ID. What it would **not**
need is the CH375 layer, the packet driver side, or most of the receive
engine — and that engine is the part that took four sessions, so the second
chipset should cost far less than the first. Suggested order: AX88772, then
RTL8152/8153, then CDC-ECM as a class driver covering many at once.

It also warns to run `NETID` rather than believe the packaging, because a box
marked AX88179 with an RTL8153 inside is a common way to waste an evening.


## 1.0.0 — it works, and a stranger can install it

The whole suite goes to 1.0.0 together. `USBPKT` had been sitting at 0.1.0
while it grew into something that enumerates the device, brings the adapter
up, goes resident, survives a boot and moves ten megabytes without an error.
The version had stopped describing it.

- `USBPKT` 0.1.0 → **1.0.0**
- `USBLINK` 0.2.0 → **1.0.0**
- `USBRECV` 0.1.0 → **1.0.0**
- `USBSEND` 0.1.0 → **1.0.0**
- `NETID`, `PKTSCAN`, `PKTTEST`, `PKTTICK` already 1.0.0

**[INSTALL.md](INSTALL.md) is new** and is the front door: what hardware you
need, four steps, how to load it at boot safely, and what to do when it does
not work. Written for somebody who has never seen this project — the test
being whether it reads as *one command like `NE2000.COM`*, because that is
what it now is.

The README has grown into a 750-line engineering notebook. That content is
worth keeping and is not what a new reader wants first, so it now says so
and points at the install guide.

Everything below this line is that notebook, newest first.


## Suite regression pass, and USBSEND stops guessing

`AxBulkSize` went from `$02` to `$01` in `ax179.pas` during the receive
hunt, and that file is shared -- `USBLINK`, `USBRECV` and `USBSEND` all build
on it and none had been run since. They have now:

| | result |
|---|---|
| `PKTSCAN` | both drivers found, 60h and 65h |
| `NETID` | `0B95:1790 ASIX AX88179`, supported |
| `USBLINK` | `bulk-in queue, size 01`, link up, 10 Mbps full duplex |
| `USBRECV` | 17 bursts, 17 frames, 0 errors, 0 layout wrong |
| `USBSEND` | `REPLY from 04:D4:C4:D2:2B:00` -- transmit works |
| `PKTTICK` | both phases, 0 errors |
| `PKTTEST` | 100/100 round trips, 7 ms |
| `USBPKT` | link up, resident, 0 in every counter |

Nothing regressed.

**`USBSEND` no longer defaults its addresses.** It shipped with
`/I=192.168.50.222` and `/T=192.168.50.1` baked in -- this machine's
network. On anybody else's it would quietly ARP a subnet they have never
heard of, on a range that might well belong to someone. Both are required
now, with a message that says why, which is how `PKTTEST` has always worked.

The example in the README keeps the real addresses, because it is a
transcript and transcripts should be true, but it now shows the invocation
above the output so it is clear they were given rather than assumed.


## Latency measured properly, and it was never 50 ms

`PKTTEST` grew `/N=count`: it sends an ARP, waits for the answer, repeats, and
divides the elapsed BIOS ticks by the count. One exchange is far shorter
than the 55 ms tick, so a single timing is meaningless and a few hundred is
not.

That was worth building, because mTCP's `PING` reports about 50 ms over this
adapter *at every poll rate*, and I spent a while hunting a fixed 46 ms
delay on the strength of it. The AX88179's aggregation timer was the prime
suspect -- the adapter holds a part-full burst until it expires -- so `/Q=n`
was added to sweep it. `/Q=2` and `/Q=128` measure identically. Not that.

Timed honestly, there is no anomaly to explain:

```
            /R=1    /R=4    /R=8   /R=16    NE2000
round trip  ~55ms    13ms     6ms     6ms      1ms
```

It tracks the poll interval and floors at 6 ms. mTCP's 50 ms is its own
timing granularity. **Measure a driver with something that is not the thing
you are trying to measure through.**

**`/R` now defaults to 8** rather than 4. Throughput stops improving after
4, but latency does not, and latency is what a telnet session or a BBS
feels -- which is most of what this machine does. It fits because bursts are
1 KB: 17 reads at about 5.3 µs a byte is 5.7 ms inside a 6.9 ms tick.

Verified at the new default: 6 ms round trip over 200 exchanges with none
lost, three boots (two warm, one cold) all coming up at 6-7 ms, 1 MB and
5 MB fetched and CRC-32'd on the box (`04D0E435`, `BDBF684D`) both exact,
every error counter zero, and `TICKCHK` showing INT 08h at 145 Hz with
INT 1Ch still at 18 Hz so DOS timekeeping is untouched.

`/Q` is kept. It is a real knob and now a documented dead end.


## Twice as fast, and a measurement I had to withdraw

1 MB now takes 36s where it took 73s. The ISA NE2000 in the same machine
does it in 18s, so this went from 4x that to 2x.

**The retraction first.** The previous entry says the poll rate does not
affect throughput -- 39s at `/R=1`, 39s at `/R=2`, 37s at `/R=4`. That was
measured through a write to the PicoMEM disk, which hid the entire effect.
Fetching to `NUL` instead shows it plainly:

```
                    /R=1   /R=2   /R=4   /R=8      NE2000
before               73s    61s    60s    48s        18s
after the read fix   71s    43s    36s    36s
```

The claim was wrong and the numbers it was based on were worthless. Fetch to
`NUL` when measuring a driver; a disk on a machine this slow will happily
absorb whatever you are trying to see.

**The payload read loop was costing about 150 clocks a byte.** A `call
ch_rd` per byte: call, push, two port-61h settling reads, the data read,
pop, ret, plus the caller's bookkeeping. Around 19 µs a byte, which caps the
whole driver near 50 KB/s however fast the wire is. It is now inlined, with
the settling pair dropped -- in that loop only, nowhere else.

That is safe here because of what the CPU is. `IN` is 14 clocks with the bus
wait states, `STOSB` 11, `LOOP` 17: about 5 µs between consecutive reads on
an 8 MHz 8086 with no help at all, already far longer than the CH375 asks
for. `REP INSB` would be the obvious answer and is not available -- `INS` is
80186 and up, and this is an 8086. On anything faster the delay wants
putting back.

Correctness was checked before speed, and again after: 1 MB fetched to disk
and CRC-32'd on the box, `04D0E435`, exact, with every error counter at
zero.

**`/R` now defaults to 4** rather than 1. `/R=8` ties on throughput but its
6.9 ms tick cannot hold a full 31-read burst at 10.5 ms; `/R=4` gives 13.7
ms, which can. The 480 ms latency outliers `/R=4` used to produce are gone
now the interrupt is cheap -- 6/6 pings, average 50.29 ms, no spikes.
`TICKCHK` confirms INT 08h at 72 Hz and INT 1Ch still at 18 Hz, so DOS
timekeeping is untouched.


## Proved with real volume, not just pings

Everything up to here had been small packets -- pings, a 559-byte page,
protocol banners -- which is not evidence that a receive path works.

Fetched over HTTP onto the DOS box and checksummed there with `HD.EXE`
against the source -- 64 KB `8156EC0D`, 512 KB `9EBAF22E`, 1 MB `04D0E435`,
5 MB `BDBF684D`, 10 MB `2B11D791`. **Every one exact.**

The 10 MB run:

```
bursts collected 18439   frames delivered 15858   frames sent 11977
bursts that made no sense       = 0
reads with an impossible length = 0
bursts too big for the buffer   = 0
reads rescued by flipping toggle= 0
```

Twenty-eight thousand frames through an 8086 without a single counted
error. Verifying on the box rather than pulling the file back matters above
about half a megabyte: a megabyte does not fit in one bridge job.

Throughput is about 18 KB/s and the poll rate does not change it: 39s at
`/R=1`, 39s at `/R=2`, 37s at `/R=4`. Nor does it change latency. Both were
measured because both looked like obvious wins; neither was. `/R` stays at
its default and the README now says so, with the numbers.


## It works

An IBM PS/2 Model 30 -- 8086, 1987 -- on the internet through a USB
Ethernet adapter, driven by a CH375 on the ISA bus.

```
USBPKT /I=65
Bringing the adapter up... link up.
MAC address: 40:AE:30:6D:00:34
Resident at vector 65h.
```

```
ping 192.168.50.1     3/3    ttl=64     49.30 ms
ping 8.8.8.8          3/3    ttl=118    49.30 ms
ping google.com       3/3    ttl=106    55.25 ms   (resolved to 192.179.24.113)
HTGET example.com     559 bytes of HTML
NC test.rebex.net 21  220-Welcome to test.rebex.net!
NC pocbbs...net 23    Net2BBS - Resolving your IP Address...
```

And the driver's own counters after all of that, which are the part worth
looking at:

```
bursts collected                = 967
frames delivered                = 154
frames sent                     = 108
frames nobody wanted            = 0
bursts that made no sense       = 0
reads with an impossible length = 0
bursts too big for the buffer   = 0
```

### The last bug was one line, and it was an optimisation

`rx_poll` opened with this:

```
cmp     byte [n_handles], 0
jne     short rx_go
ret                              ; nobody is listening; do not even
                                 ; touch the chip
```

Perfectly reasonable, and completely wrong. Nothing is listening between
the driver going resident and an application opening a handle -- and during
that gap the AX88179 keeps receiving, with nobody draining it. By the time a
client arrives the adapter is backed up, the driver starts already behind,
and it never catches up: every read returns another full 64-byte packet,
the transfer never ends, the buffer fills, the burst is discarded, and the
next one starts mid-transfer. That is the whole of the "endless stream of
FF" that took the previous four sessions.

It now polls whether or not anyone is listening, and throws the result away
if not. An idle poll is a NAK and returns almost at once, so it costs the
couple of percent this driver already spent looking. Overflows in a
ten-second run went from 182 to **0**, and the ARP reply that had never once
come back arrived on the first try, three times out of three.

The measurement that pointed at it was crude and worth remembering: loading
the driver and opening a handle back to back in one batch file, with no
pause between them, took frames delivered from 2 to 18. That was the whole
clue.

### What was eliminated to get there

Worth listing, because each one cost an experiment and none of them was the
answer:

- **Polling rate.** `USBRECV` gained a `/D=ms` switch and ran at 28 ms
  between polls, exactly USBPKT's rate: 20 bursts, 0 errors.
- **Interrupt context.** `PKTTICK` ran the reference `AxRxBurst` from a hook
  on INT 08h: 9 bursts, 0 errors, 0 overruns.
- **The receive filter.** `RX_CTL_PROMISC` set as a probe changed nothing.
- **Transmit.** A listen-only run from fresh power wedged just the same.
- **Read pacing.** Extra settling inside the payload loop changed nothing.
- **The bring-up path.** USBLINK's Pascal bring-up and USBPKT's own assembly
  one both wedged identically.
- **Aggregation size and timer.** Both were separately wrong and both were
  fixed; neither was the cause.

`PKTTICK.EXE` is kept. It is the tool that killed the interrupt-context
theory and it will be the right tool the next time something only goes
wrong inside the ISR.


## USBPKT brings the adapter up on its own at last

`USBPKT /I=65` with no `USBLINK` in front of it:

```
Bringing the adapter up... link up.
MAC address: 40:AE:30:6D:00:34
Resident at vector 65h.
```

That had failed every single time before, always at step 2 -- the second
PHY power write -- with status 28, a timeout. The cause was the one already
found in `read_mac` and not yet applied anywhere else: `ctrl_out_r` and
`ctrl_in_r` ran with the chip set to **report** NAKs rather than absorb
them, so a device that was merely busy failed the transfer outright. They
now set `8F` for the duration and put it back to `00` before returning.

The comment above `set_retry` in that file has said "control transfers want
8F" since it was written. It took three separate bugs to notice it applied
to the code underneath it.

**`CLR_STALL` was being given the wrong endpoint.** `82h` -- the USB
endpoint address with the direction bit -- where the CH375 wants the bare
number `2`. `ch375.pas` calls `ClrStall(AX_EP_BULK_IN)` and that constant is
2. So every attempt to resynchronise the bulk endpoint was clearing an
endpoint that does not exist, silently. Fixing it changed the symptom
immediately: instead of returning a "successful" 64 bytes of FF, the chip
started reporting `2B`, `INT_RET_TOGGLE_MISMATCH`, which says exactly what
is wrong.

**A toggle mismatch is now recovered rather than treated as a lost packet.**
The device sent the other DATAx; the data is still there and we asked with
the wrong PID. `bulk_in` flips and asks again, once. Overflows in a
ten-second run went from 181 to 4.

### Two theories killed, which is worth as much as a fix

**Polling rate is not the cause.** `USBRECV` polls flat out -- about 850
times a second -- and `USBPKT` manages 36, because it polls from the timer
and a 64-byte read off this bus is expensive. That looked like the whole
story. So `USBRECV` grew a `/D=ms` switch and was run at 28 ms between
polls, exactly USBPKT's rate, against the same adapter: **20 bursts, 20
frames, 0 errors, 0 layout wrong.** The reference is perfectly happy at
USBPKT's speed. Whatever the difference is, it is not the rate.

**Nor is it the receive filter.** `RX_CTL_PROMISC` was set as a probe, on
the theory that unicast replies were being dropped by the adapter while
broadcasts got through. It changed nothing. Reverted -- and it is the wrong
default regardless, on a machine that cannot drain what it already asks for.

### Where the remaining fault stands

Transmit is correct and confirmed from another machine. Frames that arrive
parse correctly. But after a frame or two the bulk endpoint starts
returning full 64-byte packets of FF, reported as `INT_SUCCESS` with length
40h, and never sends a short packet again -- so the burst never ends, the
buffer fills, and everything after it is discarded.

Not the hardware, not the poll rate, not the filter, not the aggregation
size, not the toggle alone, and `CLEAR_FEATURE` on the correct endpoint
does not clear it. What is left is something `rx_poll` does that
`AxRxBurst` does not, and the two now agree on every point that has been
checked line by line. The next thing to try is running the reference code
itself from the timer interrupt -- if `AxRxBurst` wedges there and not in
the foreground, the difference is interrupt context, not logic.


## Our own test tools, and mTCP off the CH375 entirely

`PKTTEST.EXE` and the `PktApi` unit. A Crynwr packet-driver client that talks
to **the vector you name** -- no scan, no config file, no default that can
reach the wrong card.

The reason is a rule for this project from here on: **mTCP is for sanity
checks on the working NE2000 at 60h, and nothing else.** Testing the CH375
adapter through mTCP meant pointing `MTCPCFG` at a second config for the
duration of a test and pointing it back afterwards -- two adapters, one
environment variable, and a machine administered over the other one. That
arrangement only has to be got wrong once. Everything that touches the
CH375 is now ours.

```
PKTTEST /M=<my ip> [/I=hex] [/T=<target ip>] [/S=secs] [/L] [/R] [/X]
```

`/T` ARPs an address and waits. `/L` listens and prints every frame. `/R`
listens *and answers* -- ARP for `/M`, and ICMP echo -- so the adapter is
pingable from another machine, which is the only way to prove it takes
unicast traffic. A driver can receive every broadcast on the wire and still
drop everything addressed to itself.

It asks the driver for every protocol and picks out what it wants in
software, deliberately: a tool that exists to diagnose a driver must not
depend on that driver's type filtering being right.

### What now works

Measured with PKTTEST against a live network:

- **Transmit is correct**, and confirmed from outside the machine rather
  than by trusting our own counters: an ARP request sent through USBPKT
  reached the wire and the far end learned `192.168.50.222` at the
  adapter's MAC.
- **Receive parses correctly.** Real frames arrive through the packet
  driver with the right addresses and ethertypes, and `bursts that made no
  sense` is 0 where it used to be 4657 out of 4659.

### Four receive faults fixed on the way

**A length the chip could not have meant.** When the CH375 stops driving
the ISA data bus every read returns FF, so the length byte reads as 255.
`ch_read` drained 255 bytes, stored the first 64, and reported a full
packet. `rx_poll` then kept asking until its budget ran out and handed up
1536 bytes of FF as a burst. A bulk packet cannot exceed 64 bytes, so a
length above that is now refused outright.

**One bad read poisoned the endpoint for ever.** `bulk_in` advanced the
data toggle on *every* success, including reads that were not packets.
After one, every IN asked for the wrong DATAx and nothing matched again.
The toggle now only advances on a read we believe.

**The toggle was never resynchronised when adopting an adapter.** `rx_tog`
is assembled as DATA0, but after `USBLINK` the adapter has been receiving
and the device's toggle has moved on. `/A` now clears both bulk endpoints,
which resets the toggle at both ends.

**A budget that discarded what it had already read.** Ending a burst when
the read budget ran out lost the frames already collected *and* left the
remainder in the chip, so the next tick began mid-transfer. Bursts are now
collected across ticks -- the chip holds the rest quite happily -- and only
a genuinely full buffer discards.

Two constants are a pair and must move together: `RX_BUDGET` and `tick_n`.
A 64-byte read costs enough on this bus that 31 of them do not fit in a
145 Hz tick, and a receive loop that overruns its own period leaves the
foreground no time to run at all. That is not a crash; the machine simply
stops getting anywhere, and it took a power cycle to clear. `tick_n` now
defaults to 2.

### Still open: an endless stream of FF

After the first frame or two, the adapter starts returning full 64-byte
packets of FF, reported as `INT_SUCCESS` with length 40h, and never sends a
short packet again. Nothing recovers it -- not draining, not
`CLEAR_FEATURE(ENDPOINT_HALT)` on the bulk endpoint, not a bigger buffer,
not smaller aggregation.

It is emphatically not the hardware. `USBRECV.EXE` was run against the same
adapter minutes later and read 20 frames with 0 errors and every layout
check passing.

The one measured difference is the polling pattern, and it is stark:
**USBRECV made 5083 idle polls in six seconds -- about 850 a second -- and
got clean NAKs whenever the wire was quiet. USBPKT polls 36 times a second**,
because it polls from the timer and each 64-byte read is expensive. Whatever
this state is, USBRECV never stays still long enough to enter it. That is
where to look next.


## The MAC read had to let the chip absorb NAKs

`USBPKT /A` — take the adapter exactly as `USBLINK` left it — failed on its
very first act, reading the MAC, on hardware `USBLINK` had finished with
seconds earlier:

```
Taking the adapter as it stands (/A).
The adapter did not return its MAC address.
Chip status on the last try: 2A
```

`2A` is `INT_RET_NAK`: the device is awake and saying "not now". `read_mac`
set retry to `00` — report a NAK rather than retry it — which is right for
polling an idle endpoint and wrong for a control transfer, as the comment
above `set_retry` in this very file already said. It now sets `8F` for the
transfer and puts it back to `00` on every exit, so nothing is left retrying
in the background for the next program to trip over. That is the whole fix,
and `/A` has been reliable since.

Three things found alongside it:

**`ctrl_in` never recorded the chip status.** `bu_st` held whatever the last
high-level command had put there, so `read_mac`'s "only a stall needs
clearing" test — and every error message — was reading a status belonging to
an unrelated operation. There is now a `ch_waitst` wrapper that records it,
with `FF` for no interrupt at all. Until this was fixed no failure in a
control transfer could be diagnosed at all, which is why the NAK above went
unseen for so long.

**`delay_ticks 1` guarantees nothing.** It waits for the BIOS counter to
*change*, so `1` is anywhere from 0 to 55 ms depending on where in the tick
you arrive; `n` guarantees `n-1` whole ticks. The 20 ms the AX88179 needs
between the two PHY reset writes was sometimes not happening at all. Callers
now pass `n+1` and the routine's comment says so.

**A comment here was simply wrong.** The entry below says "the Pascal
bring-up clears a stall only after one happens". It does not: `Setup8` in
`ch375.pas` opens *every* control transfer, in and out, with `ClrStall(0)`.
The claim had never been checked against the source it described. The clear
is back where the reference has it.

### Still broken: the receive path

`USBPKT` brings the adapter up and sends, but what comes back off the bulk
endpoint is not frames. A cold boot, a clean `USBLINK`, `/A` loading and
reading the MAC, and then 521 of 522 bursts rejected, each 1536 bytes of a
repeating four-byte pattern.

It is not the hardware and it is not the adapter. `USBRECV.EXE` — the Pascal
receiver — was run on the same machine minutes later and read 20 bursts, 20
frames, 4104 bytes, 0 errors, layout checks all passing. The fault is in
`rx_poll` in `usbpkt.asm`, and `USBRECV` is the working reference to diff it
against.

### USBLINK can hang the machine, so nothing USB belongs in AUTOEXEC.BAT

Loading the adapter from `AUTOEXEC.BAT` was tried and has been taken out
again. On four boots out of five — cold power cycles included — `USBLINK`
hung outright, before the point where the machine becomes reachable over the
network. A hang is not something `IF ERRORLEVEL` can catch, so the fallback
that was supposed to make this safe never ran. Recovering needed the power
switch each time, and on a machine administered remotely that is the one
failure mode worth designing against.

`NET.BAT` from the prompt costs a power cycle at worst. That is where this
stays until the bring-up cannot hang.


## USBPKT does the whole job

`USBPKT.COM` now enumerates the device and brings the adapter up itself, so
it is one command like `NE2000.COM`. `USBLINK` is a diagnostic now, not a
prerequisite. Verified from a cold start: link up, gateway 2/2, 8.8.8.8 2/2
at ttl=118, and `HTGET http://example.com/` returning 200 OK, with the
machine's own driver at 60h untouched.

Four faults found getting there, and the order matters because each one hid
the next:

**`CLEAR_FEATURE` before every register access.** `CMD_CLR_STALL` is not a
local chip operation — the CH375 issues a real control transfer to the
device. Doing that ahead of every write left the device busy when the write
arrived, so it NAKed. The failure moved around as timing shifted (step 7,
then 9, then 3), always with status 2A, always blaming whichever register
happened to be next. The Pascal bring-up clears a stall only after one
happens, and never NAKs; this now does the same.

**`SET_USB_MODE` without its readback.** The chip leaves a status byte in
the data port and a byte nobody collects is still there for the next read.
Three mode changes during enumeration meant three stale bytes queued ahead
of the device descriptor — which is where it failed, three commands
downstream of the cause.

**`WaitInt` milliseconds treated as a spin count.** The Pascal's
`WaitInt(Ms)` is an outer loop over an inner 400-poll spin. `wait_for(300)`
was being handed 300 raw iterations: four hundred times too short.

**A teardown that overwrote its own diagnostic**, so a failure at step 3
reported a register the teardown had touched on the way out.

Also: `/A` takes the adapter as it stands (`/N` was already taken -- it
means "do not hook the timer", and binding a second meaning to it made a
documented switch silently do something else), `/U` unconfigures the device
before releasing memory, and the failure message now names the real cause
of the common step-23 failure and the only thing that actually fixes it.

## Unreleased

### Working, and proven on the hardware

* **`USBLINK` 0.2.0 brings an ASIX AX88179 (`0B95:1790`) all the way up**
  over a CH375: configuration set, PHY powered and out of reset, clocks
  selected, MAC read (`40:AE:30:6D:00:34`), receive path configured, link
  negotiated. First run, no debugging. `medium mode 0136` — 10 Mbps full
  duplex — and `rx control` reads back exactly the bits written.
* **`USBRECV` 0.1.0 reads real Ethernet off the wire.** A broadcast UDP
  frame from `192.168.50.8` and an IGMP query from the router both arrived
  and decode correctly by hand from the hex dump. Frames start at offset 0
  with no padding, which confirms `RX_CTL` `IP_ALIGN` being clear does what
  was intended.
* **`ax179.pas`** holds everything that knows what an AX88179 is, so the
  two programs and the eventual packet driver share one register map
  rather than three copies of it.
* The PHY is restricted to **10BASE-T** by default, by withdrawing the
  gigabit and 100 advertisements rather than by forcing the speed, so the
  far end negotiates normally. `/G` leaves it at gigabit. This is a runtime
  switch and not a constant because the arithmetic changes on a 486.
* Bulk-in aggregation is turned **off**, where Linux turns it on: this
  machine cannot absorb a 20 KB burst 64 bytes at a time. Also a 486
  decision waiting to be reversed.

### Two traps in the shared CH375 layer, found the hard way

* **`BusUp` never sends SET_CONFIGURATION.** A device with an address but
  no configuration is in Address state, where control transfers to endpoint
  0 work perfectly and every other endpoint does not exist. Every register
  access succeeded and the link came up; then all 7056 IN tokens to the
  bulk endpoint timed out in eight seconds. `AxInit` now sets the
  configuration first, taking the value from the descriptor rather than
  assuming 1.
* **`BusUp` sets `SET_RETRY 8F`, retry NAKs for ever.** Correct while
  enumerating, wrong for polling an idle endpoint: the chip retries instead
  of reporting, the caller's wait expires, and a poll takes seconds and
  returns "no interrupt". Two polls in nine seconds became 865 in under
  one. `AxInit` now sets no-retry after bring-up.

  `USBPOLL` already did both of these. Neither was documented anywhere but
  its source; both are now in this project's README.

* `AxRxBurst` drains and discards the remainder of a transfer that will not
  fit the caller's buffer, and reports how much went missing in
  `AxRxOver`. Leaving a transfer half-read desynchronises the endpoint and
  every burst after it is garbage -- which is what the first 2 KB buffer
  did before it was enlarged to 16 KB.
* Error reporting from the poll loop is capped at eight lines. An error
  that repeats every poll otherwise printed thousands of identical lines
  and the run spent all its time on output rather than on the wire.

### The receive buffer layout, solved and verified

    [frame 1][pad to 8][frame 2][pad to 8]...[entry 1][entry 2]...[trailer]

* trailer: last 4 bytes LE, low word = packet count, high word = offset of
  the entry array.
* entry: 4 bytes per packet, `(entry >> 16) and $1FFF` = frame length.
* frames: from offset 0, each padded to an 8-byte boundary. With IP_ALIGN
  clear there is no leading pad, so byte 0 is the destination MAC.

It matches what the Linux driver describes after all. Every earlier reading
that said otherwise was a truncated transfer, not a different format --
see the two bugs below. `USBRECV` checks each invariant and prints a tick or
a cross beside it rather than assuming any of them.

### Two more bugs, both mine, both in AxRxBurst

* **A NAK was being treated as the end of a transfer.** In USB a bulk
  transfer ends with a SHORT packet; a NAK part-way through only means "not
  ready yet, ask again". Every multi-frame transfer was being truncated --
  the capture that started this hunt stopped at 256 bytes with a second
  frame cut in half and no trailer in it at all. Mid-burst NAKs are now
  retried, bounded, and only a short packet ends a burst.
* **Zeroing `AX_RX_BULK_QCTRL` does not mean "no aggregation".** It means
  *no limit*, which is the opposite: the chip appends frames for as long as
  traffic arrives and the transfer never ends. One capture reached 55,680
  bytes before the buffer gave up. The control byte is now 07 -- all three
  limits on -- with the size, timer and inter-frame gap exposed as
  `AxBulkCtrl` / `AxBulkSize` / `AxBulkTimer` / `AxBulkIfg` and reachable
  from `USBRECV` as `/C=` and `/B=`.

### Throughput, measured

* About **1650 bytes/sec** sustained with the link deliberately loaded --
  roughly 13 kbit/s.
* In a 15-second run: **12,112 idle polls against ~390 reads carrying
  data**. The limit is not how fast bytes leave the CH375, it is that the
  chip has something for us on about 3% of polls. Raw read bandwidth looks
  nearer 50 KB/s if the duty cycle could be improved.
* Burst size does not behave the way you would guess: `/B=02` gives
  1650 B/s and `/B=08` gives **302 B/s**, five times worse, because a
  bigger threshold makes the chip wait longer and drop more while waiting.
  The default is 2 for that measured reason rather than a guessed one.

### Transmit works, and a real machine confirmed it

* **`USBSEND` 0.1.0** builds an ARP request, sends it, and waits for an
  answer. The router replied: `REPLY from 04:D4:C4:D2:2B:00 --
  192.168.50.1 answered us.` Three runs, three replies, two polls to the
  first one.
* Proving it this way is deliberate. A bulk write returning success only
  means the CH375 accepted the bytes; a misplaced header field or a missed
  padding flag makes the chip drop the frame in silence and report nothing.
  A reply cannot be manufactured at this end -- it means another computer
  received the frame, parsed it, believed it and addressed a response back
  to this MAC. The router's MAC also matches the one in an unrelated IGMP
  query `USBRECV` caught earlier.
* The TX header is 8 bytes: two little-endian 32-bit words, the frame
  length then zero -- except when the total including the header is an
  exact multiple of the 64-byte packet size, when bits 15 and 31 are set.
  That case separately needs a zero-length packet to end the USB transfer;
  the two requirements arise together and are easy to conflate.

### A third bug in AxRxBurst, and this one hung the machine

* **The overflow drain was unbounded.** When a burst does not fit the
  caller's buffer the remainder has to be read and discarded or the
  endpoint desynchronises -- but that was written as "read until a short
  packet", and the chip can stream continuously. On a busy network the
  loop never returned, and a DOS program that never returns takes the box
  with it. It hung twice and needed the power cycled both times. Now
  bounded at 1024 packets, which is far more than any sane burst and
  finite.

### USBPKT, and PKTSCAN before it

* **`PKTSCAN` 1.0.0** lists which interrupt vectors hold a packet driver,
  by the "PKT DRVR" signature three bytes into the handler. Read-only, so
  it is safe over the live connection it is reporting on. On this machine:
  60h taken, 61-66 / 68-6C / 6E-6F / 78-7E free, and 67h and 6Dh occupied
  by EMS and video rather than free.
* **`USBPKT.COM` 0.1.0 is written and assembles at 8,221 bytes.** It does
  not work yet, and it refuses to do damage while not working, which was
  the part worth getting right first:
  - vector 60h refused outright, exit code 4, proven on the hardware;
  - any vector already carrying the signature refused;
  - neither overridable by a switch;
  - install aborts cleanly when the adapter will not answer, leaving no
    vector hooked -- `PKTSCAN` before and after shows 60h untouched.
* Written but unproven: the Crynwr entry point and dispatch, the two-call
  receive handshake, `send_pkt` with its 8-byte header, the INT 08h poll
  with an adaptive budget and a re-entry guard, install, unload with
  out-of-order hook detection, and `/S`.
* **The bug:** `read_mac` in `usbpktini.inc` returns an error where the
  identical vendor request from Pascal returns the MAC four times out of
  four. New assembly, not the chip and not the register map -- both proven.
* **The split is wrong and known to be.** `USBPKT` needs `USBLINK` to have
  brought the adapter up first. A driver you have to prepare with a second
  program is one somebody will forget to prepare; folding the bring-up in
  comes after the control transfer works.

### It pings

    Packet sequence number 0 received from 192.168.50.1 in 46.75 ms, ttl=64
    Packet sequence number 1 received from 192.168.50.1 in 51.85 ms, ttl=64
    Packet sequence number 2 received from 192.168.50.1 in 51.85 ms, ttl=64
    Packets sent: 3, Replies received: 3, Replies lost: 0

mTCP, on an IBM PS/2 Model 30, over USB Ethernet on a CH375 ISA card, with
the machine's own network at INT 60h untouched throughout. The ~50 ms round
trip is the 18.2 Hz poll interval showing through, not the wire.

`USBPKT.COM` implements driver_info, access_type, release_type, send_pkt,
get_address, reset_interface, set_rcv_mode, get_rcv_mode and
get_statistics, with receive collected on the timer and handed up through
the two-call handshake. mTCP's `pkttool` and DOSBridge's `PKTCAP` both
drive it correctly.

### The two bugs between "frames move" and "it pings"

Both hid behind a partial success, which is the worst place for a bug to
hide.

* **The delivered length included the Ethernet FCS.** RX_CTL_DROP_CRC means
  "discard frames whose CRC is wrong", not "strip the CRC". PKTCAP's own
  dump had been saying so for a while: a 42-byte ARP request padded to the
  60-byte minimum arrived as 64 bytes, with four non-zero bytes after the
  padding.
* **bulk_out restored SI on success.** It was added for the NAK rewind and
  wrongly applied to the success path, so the caller's SI never advanced
  and every 64-byte packet after the first re-sent the beginning of the
  frame.

The second is why this looked like a receive fault for hours. A 60-byte ARP
request is 68 bytes with the transmit header -- 64 plus 4 -- and the four
repeated bytes land in padding nobody reads, so ARP resolved perfectly. A
74-byte ping is 82 -- 64 plus 18 -- and those are real IP header bytes, so
the router dropped every one in silence. ARP succeeding is precisely what
made the transmit path look innocent.

### Also

* PKTCAP, in DOSBridge, gained a third argument naming the interrupt
  vector. That is a safety feature rather than a convenience: without it
  the tool attaches to the first packet driver between 60h and 80h, which
  on a bridge machine is the network the bridge runs over, and with ALL the
  frames it captures are frames nobody else receives. Naming a second
  driver confines the capture to the card being debugged.

### Not done
* **The packet driver.** A Crynwr driver at INT 60h, so `mTCP` and
  `WATTCP` work without a TCP stack being written here.
* **A duty-cycle fix.** 3% of polls carrying data is the thing standing
  between 1.6 KB/s and something nearer 50 KB/s, and it is a tuning
  problem rather than a bus-speed one.
