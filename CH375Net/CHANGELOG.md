# Changelog

CH375Net -- StevenC -- https://github.com/jdredd87/CH375USBTools

Versions live in the `VER` constant of each program. Nothing here has been
released; the project is in progress.

## Unreleased

### Working, and proven on the hardware

* **`AXPROBE` 0.2.0 brings an ASIX AX88179 (`0B95:1790`) all the way up**
  over a CH375: configuration set, PHY powered and out of reset, clocks
  selected, MAC read (`40:AE:30:6D:00:34`), receive path configured, link
  negotiated. First run, no debugging. `medium mode 0136` — 10 Mbps full
  duplex — and `rx control` reads back exactly the bits written.
* **`AXRECV` 0.1.0 reads real Ethernet off the wire.** A broadcast UDP
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
see the two bugs below. `AXRECV` checks each invariant and prints a tick or
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
  from `AXRECV` as `/C=` and `/B=`.

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

* **`AXSEND` 0.1.0** builds an ARP request, sends it, and waits for an
  answer. The router replied: `REPLY from 04:D4:C4:D2:2B:00 --
  192.168.50.1 answered us.` Three runs, three replies, two polls to the
  first one.
* Proving it this way is deliberate. A bulk write returning success only
  means the CH375 accepted the bytes; a misplaced header field or a missed
  padding flag makes the chip drop the frame in silence and report nothing.
  A reply cannot be manufactured at this end -- it means another computer
  received the frame, parsed it, believed it and addressed a response back
  to this MAC. The router's MAC also matches the one in an unrelated IGMP
  query `AXRECV` caught earlier.
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

### AXPKT, and PKTSCAN before it

* **`PKTSCAN` 1.0.0** lists which interrupt vectors hold a packet driver,
  by the "PKT DRVR" signature three bytes into the handler. Read-only, so
  it is safe over the live connection it is reporting on. On this machine:
  60h taken, 61-66 / 68-6C / 6E-6F / 78-7E free, and 67h and 6Dh occupied
  by EMS and video rather than free.
* **`AXPKT.COM` 0.1.0 is written and assembles at 8,221 bytes.** It does
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
* **The bug:** `read_mac` in `axpktini.inc` returns an error where the
  identical vendor request from Pascal returns the MAC four times out of
  four. New assembly, not the chip and not the register map -- both proven.
* **The split is wrong and known to be.** `AXPKT` needs `AXPROBE` to have
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

`AXPKT.COM` implements driver_info, access_type, release_type, send_pkt,
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
