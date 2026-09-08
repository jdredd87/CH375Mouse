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
* A NAK part-way through a burst ends the transfer with what has been
  collected, instead of being reported as an error. On a busy network the
  old behaviour printed one error line per poll and the program spent all
  its time on output.

### Not done

* **The receive buffer layout.** The trailing count-and-offset word the
  Linux driver describes reads as zero on this part, so the recollection
  does not match the silicon. An `AA 55` pattern recurs in the gaps between
  frames. `AXRECV /X /R` exists to dump bursts raw until this is settled --
  a driver written from a guess that happened to be wrong is how this
  repository once lost a day to a mouse.
* **Transmit.** Each frame needs an 8-byte header; none is sent yet.
* **The packet driver.** A Crynwr driver at INT 60h, so `mTCP` and
  `WATTCP` work without a TCP stack being written here.
* **A throughput number** that means anything. The current one includes
  idle polling and a link nobody is saturating.
