# Changelog

CH375USBTOOLS -- StevenC -- https://github.com/jdredd87/CH375USBTools

## Unreleased

* **Every program now prints its name, version and author on its first
  line, and answers `/?` with a full help screen.** `-?`, `?`, `/HELP` and
  `--HELP` do the same thing. Bare `/H` deliberately does not: `USBKBD` and
  `USBCOMBO` already use `/H` for the INT 16h delivery hook, and a switch
  that means "help" in one program and something else in the next is worse
  than no shorthand at all.
* The banner, the help footer and the `/P=` help line come from one shared
  unit, `chtool.pas` in `CH375USBTOOLS/src`, compiled into each project's
  own `bin\` with `-Fu`. Twenty-odd separate copies of the same three lines
  is exactly the kind of thing that drifts.
* Each program carries its own `VER` constant rather than sharing one.
  They are released together but they do not change together, and a tool
  reporting 1.4.0 because something else in the repository moved tells you
  nothing.
* **`USBSCAN /P=hex` tests one named address and stops.** The default scan
  tries eight addresses and nothing else, so a board jumpered outside that
  list reported "No CH375 found" while being perfectly healthy. When the
  jumpers are already known there is no reason to sweep at all -- and no
  reason to write to seven addresses that belong to something else.
* `USBSCAN`'s not-found advice now points at `/P=` rather than only at the
  `/A` sweep, which is the dangerous option of the two.
* All seven tools now report their version, and all seven answer `/?`.
  Each help screen is the tool's own header block, so `/?` is complete
  where the guide only summarises.
* New `src/chtool.pas`: the shared banner, `/?` detection, help footer and
  the `DEF_BASE` constant. It is compiled into each project's `bin\` from
  this one source, so the four projects share source and never a compiled
  unit -- the same arrangement `ch375.pas` already had.

* Documented the PS2-to-USB adapter (`0E8F:0020`): one low-speed device with
  two boot HID interfaces, keyboard on EP 81 and mouse on EP 82, and a mouse
  interface that declares report IDs so its native reports are 5 bytes with
  a leading ID byte rather than the classic 3-byte boot report.
* Noted the two rules that apply when `ch375.pas` routines are reachable
  from an interrupt handler: `CLD` before any string operation, and bounded
  waits only. Neither is a change to the unit; both are things a caller has
  to know.

## 1.0.0 -- 2026-09-06

First release. Everything below has been run on the hardware: a CH375B rev
B7 on an ISA card at `260h`, MS-DOS on an 8086-class machine, against an HP
USB keyboard (`04F2:1717`, low speed) and an ASUS WiFi dongle
(`0B05:1786`, full speed, vendor class).

* `ch375.pas`, the shared CH375 layer: port handshake, bring-up, control
  transfers with a real data stage, endpoint I/O. `CH375Keyboard` builds
  against it too.
* `USBINFO` dumps every descriptor a device will part with, decoded, with
  the raw bytes alongside -- device, string languages and strings, every
  configuration in full, class-specific descriptors, device qualifier, and
  each HID report descriptor. It is class-agnostic by design.
* `HIDREP` decodes a HID report descriptor to its item stream and to the
  field map each report actually has.
* `USBPOLL` polls any IN endpoint and hexdumps it, decoding boot keyboard
  and mouse reports when the interface says that is what it is.
* `USBCTL` issues an arbitrary control transfer and traces every stage.
* `CHREG` dumps the chip's 256 internal registers, with a watch mode.
* `USBSCAN` finds CH375 boards; `USBMON` watches for hot-plug events.
* **Control transfers must clear endpoint 0 first.** `CLR_STALL` also
  resets the chip's data toggle, and without it a transfer that succeeds
  breaks the next one -- transfers alternate fail/work. Found with
  `USBCTL /N=6`, which tallies attempts as `[X.X]`.
* **Descriptors are read in two stages**, length first: over-reading a
  string earns a `STALL` that then poisons the following transfer.
* `USBSCAN` does not sweep the I/O space by default. Probing an address
  means writing to it, and the first version hung the machine by writing
  into the floppy controller at `3F0h`.
