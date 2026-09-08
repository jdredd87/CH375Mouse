# CH375USBTools — DOS tools for a WCH CH375 in USB host mode

Five projects, one ISA card, and no storage anywhere in sight.

The WCH **CH375** is usually sold as a way to read a USB stick from an old
machine, and every driver you can find for it does exactly that. This
repository is what the chip can do *instead*: talk to arbitrary USB devices
from real-mode DOS, and present them — a mouse, a keyboard, or both at
once — to DOS as though they had always been there.

Everything here has been written for, and run on, one specific computer: an
**IBM PS/2 Model 30** — the original 8086 model, not one of the 286 or 386
ones — running MS-DOS 6.22, with a **CH375B rev B7** on an 8-bit ISA card at
I/O base `260h`. That machine is from 1987, nine years before USB existed,
which is rather the point.

> **[Read GUIDE.md](GUIDE.md)** — the complete guide: every tool, what works
> and what does not, the hardware limits and why they are limits, and
> troubleshooting. If you only read one file, read that one.

| | |
|---|---|
| **[CH375Mouse](CH375Mouse/)** | `USBMOUSE.COM`, a resident **INT 33h** mouse driver fed by a USB HID mouse. About 1.5 KB resident. Also does PS/2 BIOS emulation, so Windows 3.x sees a pointing device |
| **[CH375USBTOOLS](CH375USBTOOLS/)** | Seven probe tools. What is plugged in, what it says about itself, and what it puts on the wire — for any device, of any class, whether or not anything here can drive it |
| **[CH375Keyboard](CH375Keyboard/)** | `USBKBD.COM`, a resident keyboard driver, plus six diagnostics. Enumerates a USB HID keyboard, translates usages to PC scancodes, and writes them into the BIOS keyboard buffer where DOS expects to find them |
| **[CH375Combo](CH375Combo/)** | `USBCOMBO.COM`, both of the above in one image, for a **USB-to-PS/2 adapter** — one USB device with a keyboard interface and a mouse interface on it. About 5.3 KB resident |
| **[CH375Net](CH375Net/)** | **it browses a BBS.** USB Ethernet through an ASIX AX88179, with a Crynwr packet driver at INT 65h. ARP, ICMP, DNS and TCP all work: an 8086 pings 8.8.8.8 and telnets to a BBS in Italy |

Each project has its own `README.md`, `CHANGELOG.md`, `build.cmd` and
`bin\`. The binaries are committed deliberately: the machine this targets
has no compiler for them, and for most people the `.COM` file is the thing
they actually want.

## What works, and what does not

| | DOS | Windows 3.0 | Windows 95 |
|---|---|---|---|
| USB mouse | **yes**, INT 33h | **yes**, via `/W` | **untested** |
| USB keyboard | **yes**, BIOS buffer | **no** | **untested** |
| USB storage, hubs | no — out of scope | no | no |

Two limits are worth knowing before you start. Neither is a missing feature,
and neither can be fixed in software — both are facts about the Model 30, and
on a later machine they largely go away.

### The Model 30 has no 8042 keyboard controller

On an IBM AT and everything descended from it, an Intel 8042 sits between the
keyboard and the CPU, and its command `D2h` means *"pretend this scancode just
arrived from the keyboard."* That raises a genuine IRQ1 which no program can
tell from a real keypress, and it is the clean way to feed a synthetic
keyboard into DOS.

The Model 30 8086 predates that arrangement — it is XT-class inside, whatever
the PS/2 badge suggests — and there is nothing listening at the AT controller
ports: **`64h` reads `FF`.** So `USBKBD.COM` and `USBCOMBO.COM` write keys
directly into the BIOS keyboard buffer instead, and that decides what they can
and cannot reach:

* **Reached:** anything going through `INT 16h` or DOS — the command line,
  batch files, `EDLIN`, and most text-mode utilities.
* **Not reached:** anything that reads the keyboard hardware for itself. DOS
  EDIT's menus, QBASIC and most games are in this group.

The 8042 path is written — it is `/K` — and it works on a machine that has a
controller. This one does not. `KBCINJ`, in the keyboard project, reports
which kind of machine you are on.

### Windows 95 needs a 386, and this is an 8086

Nothing here has ever been run under Windows 95, so nothing here claims to
support it; saying otherwise would be a guess.
[`davidegat/CH375USB`](https://github.com/davidegat/CH375USB) does support
Windows 95 — use theirs if that is what you need.

## Two conventions

**Every program answers `/?`** with its own full help — `-?`, `?`, `/HELP`
and `--HELP` too — and prints its name, version and author on the first
line, so a captured log says which build produced it. Bare `/H` is not a
help switch: `USBKBD` and `USBCOMBO` already use it for the INT 16h hook.

**Nothing is hardwired to `260h`.** The board's address is set by jumpers.
The three drivers take `@hex`, every tool that opens the chip takes
`/P=hex`, `USBSCAN` finds the card for you, and `/S` prints the base the
loaded driver actually took. GUIDE.md has
[the whole story](GUIDE.md#if-your-card-is-not-at-260h).

## Start here

If you have the card and something plugged into it and no idea what:

    cd CH375USBTOOLS
    build.cmd scan            find the card
    build.cmd info            dump everything the device will tell you

`USBINFO` does not care what class the device is. That is the difference
between it and `CHDIAG` in the mouse project, which stops at *"this is not
a mouse"* — a perfectly reasonable thing for a mouse diagnostic to do and a
useless one for finding out what an unknown dongle is.

## One driver at a time

`USBMOUSE.COM` and `USBKBD.COM` **cannot both be loaded.** Each resets the
CH375, enumerates from scratch, assigns the USB address and hooks `INT 08h`
to poll; two of them on one chip would reset it out from under each other
and interleave transactions with no locking. One CH375, one host driver —
the same rule that stops either of them sharing the card with `CH375R9.SYS`
or `CH375DOS.SYS`.

That is what `CH375Combo` is for. A **USB-to-PS/2 adapter** with a keyboard
and mouse on it is *one* USB device with two HID interfaces, so a single
driver can own the chip and serve both — and `USBCOMBO.COM` does, delivering
keys to the BIOS buffer and the pointer to `INT 33h` from one timer hook.
Load exactly one of the three drivers.

## What is shared

`CH375USBTOOLS/src/ch375.pas` is the CH375 layer: the port handshake, the
bring-up sequence, control transfers with a real data stage, and endpoint
I/O. `CH375Keyboard` and `CH375Combo` compile against it with `-Fu`; each
project builds its own `.ppu` into its own `bin\`, so they share source and
never a compiled unit. Both assembly drivers are self-contained, and
`USBCOMBO.COM` is `USBKBD.COM`'s image with `USBMOUSE.COM`'s `INT 33h` half
transplanted into it.

## Three things the chip does that are not in the datasheet

**Command `0Ah` is a general register read.** The datasheet documents it
only as `GET_MAX_LUN`. WCH's own DOS driver uses it to read any internal
byte, and it is the only view there is of what the chip believes the USB
bus is doing. `CHREG` dumps all 256. Registers `C0h`–`FFh` turn out to be
the chip's 64-byte USB data buffer — run `CHREG` after a transfer and the
descriptor that just arrived is still sitting in it.

**`CLR_STALL` also resets the endpoint's data toggle**, and control
transfers do not work reliably without it. A transfer that *succeeds*
leaves endpoint 0 advanced and the next one gets stalled by the device; a
transfer that *failed* cleared the stall on its way out and left things
fine. So transfers alternate — fail, work, fail, work — which reads as a
flaky device and is not one. Clearing endpoint 0 before every control
transfer fixes it. `USBCTL /N=6` is what made it visible, as `[X.X.X.]`
before and `[......]` after.

**Low speed has to be set at exactly one moment.** `SET_USB_SPEED` is a
CH376 command that this B7 firmware implements, and it is silently ignored
unless it is issued after the last `SET_USB_MODE` *and* after the connect
interrupt raised by the bus reset has been read and cleared. Get the order
wrong and every transfer to a low-speed device times out, looking exactly
like a chip with no low-speed support — which is what this looked like for
a long time. Most mice and many keyboards are low-speed devices, so this is
not an edge case.

## A device's answer is not a promise

The PS/2 adapter answers `SET_PROTOCOL 0` — *"switch to the simple three-byte
boot report"* — with **success**, and then carries on sending its native
five-byte report-ID format regardless. So the request is worth making, and
its answer is worth nothing: `USBCOMBO.COM` reads the format off each packet
instead.

Building it the other way round cost a day. Believing the acknowledgement
meant treating every five-byte packet as impossible, and the driver that did
that **discarded 100% of real mouse data** — while its 43-check conformance
suite passed clean, because every one of those checks injects its own report
and never touches the USB read. The whole account, including the reasoning
that made the wrong version look right, is in
[`CH375Combo/README.md`](CH375Combo/README.md).

Two lessons outlast the bug:

* **A suite that fabricates its own inputs cannot test the input path.**
  Nothing in 43 passing checks touched a real packet.
* ***"No real device would send this"* is a claim about the device**, and the
  way to settle it is to make the device send something known — move the
  mouse — not to reason about what the bytes ought to look like. The tooling
  that mattered in the end was a live view that beeps at a human.

## Two rules for resident code in real-mode DOS

Both cost real debugging time, and both are worth knowing before writing a
fourth driver.

**`CLD` before any string operation reachable from an interrupt handler.**
The direction flag belongs to the interrupted program. Five string
operations in the keyboard driver's ISR ran backwards whenever the
foreground program left `DF=1` — a fault that depends entirely on what else
is running, so the driver works perfectly until it suddenly does not. The
mouse driver was checked and is not affected: all of its string operations
are in transient code, after `resident_end`. Credit for the rule goes to
[davidegat/CH375USB](https://github.com/davidegat/CH375USB), an independent
CH375 host stack whose engineering notes are worth reading.

**A polled driver has no safe context outside its own interrupt.** There is
nowhere else to run, which makes anything requiring "not inside an
interrupt" impossible. Calling `INT 09h` to wake a program that owns the
keyboard interrupt looks obvious, works in principle, and locks the machine
— the nested handler's EOI lands on top of the driver's own and the 8259's
in-service state is corrupted. `CH375Keyboard/README.md` has the details.

## Building

Each project's `build.cmd` compiles with Free Pascal cross-compiling to
`i8086-msdos` (`-Tmsdos -Pi8086`), plus `nasm` for the assembly drivers.
Both ship with FPC and both must be on `PATH`. The build needs nothing
else.

Targets that *run* something additionally need
[DOSBridge](https://github.com/jdredd87/DOSBridge) to reach the DOS
machine; set `DOSBRIDGE` if it is not in `C:\dosbridge`. That is what put
every binary here on the real machine and brought the output back.

Nothing in the bridge is required to use the drivers — copy the `.COM` file
to the DOS machine and run it.

## Licence

**Public domain**, under [the Unlicense](https://unlicense.org) — see
`LICENSE`. Copy it, sell it, strip my name off it, do whatever you like. No
attribution required, none expected.

The one exception is `CH375Mouse/tools/MNASMFIX.COM`, which is somebody
else's work and stays under their terms. Delete it if you would rather not
carry it: nothing depends on it, and `nasm` builds the identical image.

Written by **StevenC**. <https://github.com/jdredd87/CH375USBTools>
