# Installing CH375Net

USB Ethernet on a DOS machine, in one command.

If you have used `NE2000.COM` or any other packet driver, this works the same
way: run one program, tell mTCP which interrupt it is on, done.

```
C:\CH375> USBPKT
USBPKT 1.0.0 -- StevenC
Bringing the adapter up... link up.
MAC address: 40:AE:30:6D:00:34
Resident at vector 65h.

C:\CH375> PING 8.8.8.8
Packet sequence number 0 received from 8.8.8.8 in 45.90 ms, ttl=118
```

That is the whole thing. The rest of this file is what to do when it is not.

---

## What you need

**A CH375 board in an ISA slot.** The CH375 is a USB *host* controller that
talks over eight data lines and an address line, which is why it can work on
a machine this old. Its I/O address is set by jumpers on the board; the
usual one, and this driver's default, is `260h`.

**A USB Ethernet adapter this driver knows.** Today that means an ASIX
AX88179 or AX88178A; many cheap "USB 3.0 gigabit" dongles are one of these,
and they fall back to full speed quite happily. **[ADAPTERS.md](ADAPTERS.md)
is the list** — what works, what only needs a bring-up written, and what
cannot work at all.

Do not trust the box it came in. `NETID` reads the USB ID off the device,
which is the only thing that actually identifies it, and packaging that says
AX88179 over an RTL8153 inside is common.

**DOS, and mTCP if you want TCP/IP.** Any DOS. The driver is a Crynwr packet
driver, so anything that speaks to a packet driver can use it.

It was developed on an IBM PS/2 Model 30 from 1987, running at 8 MHz with a
NEC V30 fitted, so whatever you have is probably faster. The binaries are
built for the plain 8086 and will load on anything.

## Installing

Copy the contents of `bin\` to a directory on the DOS machine. `C:\CH375` is
what the examples assume.

There is nothing to configure and no driver to add to `CONFIG.SYS`.

## Step 1: check the adapter is one this understands

```
C:\CH375> NETID

device   : 0B95:1790  ASIX
chip     : ASIX AX88179
family   : ASIX AX88179/178A
bus      : full speed (12 Mbps)

SUPPORTED.
```

`NETID` reads the USB descriptors and nothing more, so it is safe to run at
any time.

**If it does not recognise your adapter, try `USBPKT` anyway.** The driver
never looks at the USB ID — it brings up whatever enumerates — so an ASIX
part sold under somebody else's ID works fine despite `NETID` calling it
unknown, which docks and own-brand dongles frequently are. A wrong guess
fails at a numbered step and harms nothing. [ADAPTERS.md](ADAPTERS.md) has
the detail.

If it finds no CH375 at all, your board is on a different I/O address —
`NETID /P=<hex>` and `USBPKT /P=<hex>` both take one.

**If `USBPKT` brings it up and then nothing you send is answered, try
`ECMLINK`.** Some adapters offer a standard **CDC-ECM** configuration
alongside their vendor one, and at least one part here works through the
former and not the latter:

```
C:\CH375> USBPKT /U            <- one program owns the chip at a time
C:\CH375> ECMLINK
```

It brings the adapter up entirely from its own descriptors, then ARPs a host
and requires that host's reply, so a successful run is proof of transmit and
not merely of enumeration. `ECMLINK [@260] [our-ip] [target-ip]` overrides
the I/O address and the two addresses it uses.

**`USBPKT` handles this by itself** -- it asks the device what it is before
choosing a path, so an ECM adapter needs no special command. The banner says
which one it took:

```
C:\CH375> USBPKT
Bringing the adapter up...ECM: cfg 03 ctl if 00 data if 01 alt 01 ep in 02 out 03
CDC-ECM adapter - using the class driver.
MAC address: A0:CE:C8:BC:0A:91
```

`USBPKT /S` then reports `protocol=CDC-ECM` and `link=UP`. `/X` forces the
vendor path if you ever need to compare the two.

**One trap.** An adapter that offers both may stop offering the class
configuration once its vendor path has run, and a warm reboot does not undo
that -- the CH375 feeds the adapter off the ISA bus, so it is never
re-powered. If `USBPKT` says `link up` where you expected `CDC-ECM`,
power-cycle the machine or re-plug the adapter and try again.

## Step 2: pick an interrupt vector

Packet drivers live on a software interrupt between `60h` and `80h`. The
default here is `65h`, and the only real requirement is that nothing else is
using it.

```
C:\CH375> PKTSCAN

  60h  1416:03CE   PACKET DRIVER

1 packet driver(s) between 60h and 80h.
Vectors reading 0000:0000: 61 62 63 64 65 66 67 ...
```

Anything in that free list will do. If `65h` is free, you can skip this
step entirely.

## Step 3: load the driver

```
C:\CH375> USBPKT
```

Add `/I=<hex>` for a different vector, `/P=<hex>` for a different card
address. `USBPKT /?` lists the rest.

**It will refuse to install on `60h`, and it will refuse any vector that
already has a packet driver on it.** That is deliberate and cannot be
overridden. On a machine administered over its network, installing on top of
the packet driver carrying that network takes the machine off the air with
no way to undo it.

## Step 4: tell mTCP where it is

One line in your mTCP config:

```
packetint 0x65
```

Then use mTCP normally. `PING`, `HTGET`, `FTP`, `TELNET`, `IRCJR` all work
over it with no further changes.

> **If this machine already has a working network**, do not edit the config
> that network uses. Copy it, change `packetint` in the copy, and point
> `MTCPCFG` at the copy when you want the USB adapter:
>
> ```
> COPY C:\NETWORK\MTCP\MTCP.CFG C:\CH375\MTCPAX.CFG
> (edit the copy: packetint 0x65, and give it its own IPADDR)
> SET MTCPCFG=C:\CH375\MTCPAX.CFG
> ```
>
> One environment variable is a much smaller thing to get wrong than the
> config file your only route into the machine depends on.

## If you want it faster

`USBPKT /R=8` speeds the receive poll up: about twice the throughput and a
6 ms round trip instead of ~55 ms.

**Do not leave it there.** The driver reprograms the PC's timer to do it, and
anything that hooks the timer interrupt after the driver — or reprograms it
for itself — then gets the wrong rate. MS-DOS `EDIT` is one: at `/R=8` it
wedges the machine hard enough to need the power switch.

The default leaves the timer completely alone, which is why it is the
default. Use `/R=8` for a big transfer and unload it afterwards.

## Unloading

```
C:\CH375> USBPKT /U
```

It puts the interrupt vector and the timer back, and shuts the adapter down.
Load and unload as often as you like; it does not need a reboot between.

## Loading it at boot

It works, and one rule makes it safe:

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
ECHO USB adapter did not come up.
:NETOK
```

`IF ERRORLEVEL` catches a bring-up that **fails**. Nothing catches one that
**hangs** — and a hang in `AUTOEXEC.BAT` happens before anything is
listening, so on a machine you reach over the network it costs a walk to the
keyboard. The flag fixes that: drop it before trying, delete it after, and a
boot that finds it still there knows the last attempt never came back. Worst
case becomes one power cycle.

`AUTOEXEC.SAMPLE.BAT` is the real file from the machine this was developed
on. Do not put `USBLINK` in `AUTOEXEC.BAT` — `USBPKT` needs it for nothing,
and `USBLINK` is the one that used to hang.

## When it does not work

**"No CH375 answers at that address."** The board is on a different I/O
address, or it is not seated. `USBPKT /P=<hex>` to try another.

**"a device is attached but nothing answers."** Usually the adapter is
already enumerated by something that ran before — `NETID` and `USBLINK` both
enumerate it just to look at it. Run `USBPKT` **first**, before either of
them. If it is already in that state, the only reliable cure is removing the
adapter's power: unplug it and plug it back in, or power-cycle the machine.
Resetting the CH375 does not do it, because the adapter is fed off the ISA
bus.

**"FAILED at step 10."** Step 10 is waiting for a link. That is the cable or
the far end, not the adapter.

**Any other step number.** `USBLINK /V` walks the same sequence and prints
the chip status at every register access, which is usually enough to see
where it stops.

**It loads but nothing arrives.** `USBPKT /S` prints the driver's counters.
Everything should be zero except the ones counting real traffic:

```
  bursts collected=967
  frames delivered=154
  bursts that made no sense=0
  reads with an impossible length=0
  bursts too big for the buffer=0
```

**Testing without mTCP.** `PKTTEST` talks to a packet driver on a vector you
name, so it can never reach the wrong card:

```
PKTTEST /I=65 /M=<a free address> /T=<your router>     ARP and wait
PKTTEST /I=65 /M=<a free address> /L                   show what arrives
PKTTEST /I=65 /M=<a free address> /T=<router> /N=200   time the round trip
```

## What to expect

On an 8 MHz V30, fetching 1 MB over HTTP:

| | this driver | ISA NE2000, same machine |
|---|---|---|
| 1 MB | 36 s (~29 KB/s) | 18 s (~58 KB/s) |
| round trip | 6 ms | 1 ms |

Being within a factor of two of a real ISA card is about the ceiling for a
CH375 on an 8-bit bus: it polls on a timer where the NE2000 interrupts, and
it moves one byte per bus cycle where the NE2000 moves two. On a faster
machine the gap closes.

Verified with 64 KB, 512 KB, 1 MB, 5 MB and 10 MB downloads, each checksummed
on the DOS box and compared against the source. All exact.

## The programs

| | |
|---|---|
| `USBPKT.COM` | the packet driver. This is the one you need. |
| `NETID.EXE` | what USB adapter is plugged in, and is it supported |
| `PKTSCAN.EXE` | which interrupt vectors are free |
| `USBLINK.EXE` | brings the adapter up and narrates every step. Diagnostic. |
| `PKTTEST.EXE` | ARP, listen and time round trips on a named vector |
| `USBRECV.EXE` | read the adapter directly, no packet driver involved |
| `USBSEND.EXE` | send an ARP directly and prove something answered |
| `PKTTICK.EXE` | foreground vs timer-interrupt receive, for driver work |
| `ECMLINK.EXE` | for a **CDC-ECM** adapter: brings it up from its own descriptors and proves it can transmit. Not a packet driver -- see below |

Only `USBPKT.COM` is needed to use the adapter. The rest are for finding out
why it is not working.
