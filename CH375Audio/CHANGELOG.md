# Changelog

CH375Audio -- StevenC -- https://github.com/jdredd87/CH375USBTools

The version lives in the `VER` constant of each tool in `src/`. A release
is: bump it, add an entry here, `build.cmd`, commit, `git tag -a`.

## 1.0.0 -- 2026-09-12

First release. Four tools for USB Audio Class devices over a CH375, and a
measured negative result on playback.

**What works.** `DAPROBE` decodes the whole Audio Class topology from the
configuration descriptor -- terminals, feature units, formats, alternate
settings, endpoints -- and ends with a verdict computed from the attached
device rather than from a table. `DAVOL` reads and sets volume and mute
through Audio Class control transfers on the Feature Unit, with actions
applied left to right so a command line is a little script. `DAKEYS` reads
the transport buttons off the HID interrupt endpoint, decoding the
bit-to-button map from the device's own report descriptor rather than
hardcoding it.

**What does not, and why it is a tool rather than a sentence.** `DAISO`
arms the isochronous stream and tries to feed it. Playback is blocked three
times over: the endpoint is isochronous and the CH375 always waits for a
handshake that isochronous does not send; the endpoint wants 192-byte
packets and the chip transmits from a 64-byte buffer; and the stream needs
192,000 bytes/second on a hard 1 ms deadline against 19,055 measured. Any
one of those ends it. Measured on the hardware: `SET_INTERFACE` succeeds,
then 0 of 100 packets are accepted, every one a timeout.

It is a runnable tool rather than a paragraph so that a future chip
revision or an unusual device gets tested instead of being talked out of it
by a comment -- the same reason CH375Video keeps its FL2000 findings.

**Verified against** a Jieli Technology `UACDemoV1.0` (`4C4A:4155`) on an
NEC V30 with a CH375 rev B7 at I/O 260h. Volume written and read back at
both ends of the device's range; mute set, read, toggled, read. The one
path **not** observed is an actual button press -- the poll loop runs and
the endpoint NAKs cleanly, but nobody has pressed a button while `DAKEYS`
was watching, and the tool says so rather than implying silence is health.

### Four bugs worth recording, all caught by the hardware

* **A nine-byte configuration descriptor decoded as "not an audio
  device".** `BusUp` keeps only what its bring-up needed, which here is the
  header. The first run reported no audio interfaces on a speaker. The
  truncation warning is what caught it; `GetConfigFull` now fetches in two
  stages and refuses a short read rather than decoding a partial topology,
  because that and "a device with no controls" look identical.
* **The playback format was read as mono.** The format block was assigned
  straight to the playback fields, so the *last* one seen won -- and on any
  speaker with a microphone that is the capture format. Formats are now
  held and committed by the endpoint that follows them.
* **Every button was off by one bit.** The `Usage` before a `Collection`
  names the collection, not a field. HID local items are consumed by the
  next main item, so usages are buffered and only committed at the `Input`.
* **Channel counts disagreed between tools.** `DAVOL` counted channels with
  a non-zero control bitmap and called it "channels past master", which
  reported the microphone unit as having none while `DAPROBE`, reading the
  descriptor length, said one. Counted from the length now -- and taken
  before the padding loop that had been running the count to 8.

### And one inherited from CH375Video

`DAKEYS` polls an interrupt endpoint, and exiting while that endpoint is
NAKing strands a token in the chip -- so the next program's `CHECK_EXIST`
fails and reports "no CH375 at 0260" on a card that is fitted. It happened
during development exactly as CH375Video's notes predicted. The cure is two
halves that must agree, so both live in `daudio.pas` rather than being
copied into four programs: `Quieten` as an `ExitProc`, and `ChipThere`
resetting and re-asking on the way in.
