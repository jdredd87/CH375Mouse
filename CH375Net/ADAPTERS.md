# USB Ethernet adapters and CH375Net

Which chipsets this driver handles, which it could, and which it cannot.

**Run `NETID` before believing any of it.** It reads the USB descriptors and
prints the vendor and product ID, which is the only thing that actually
identifies what you have. A box that says "AX88179" and a chip that is an
RTL8153 are a common combination, and so are two adapters with the same
outward appearance and different silicon inside.

```
C:\CH375> NETID
device   : 0B95:1790  ASIX
chip     : ASIX AX88179
family   : ASIX AX88179/178A
SUPPORTED.
```

---

## Status key

| | |
|---|---|
| **Works** | driven, on hardware, by this project |
| **Should work** | same register map as something that works, not yet tried |
| **Needs a driver** | understood part, no bring-up written for it yet |
| **Unlikely** | needs more than the CH375 can give it |

---

## Works

| Chip | USB ID | Notes |
|---|---|---|
| ASIX AX88179 | `0B95:1790` | The reference part. Verified on **two physically different adapters** from different manufacturers — MACs `40:AE:30:6D:00:34` and `00:50:B6:B6:1C:64`. Both boot, link, and move 5 MB byte-exact with no counted errors. |

## Should work

| Chip | USB ID | Notes |
|---|---|---|
| ASIX AX88178A | `0B95:178A` | Same register map and the same bring-up as the 179 — `ax179.pas` covers both, which is why it is not called `ax88179.pas`. Nobody has plugged one in yet. |

If you have one, `NETID` will call it supported and `USBPKT` will try. Please
say whether it worked.

## Needs a driver

Understood parts where the work is a bring-up module, not new research. All
of them are USB 2.0 or a 2.0 fallback mode, which is what matters — see
below.

| Chip | USB ID | Notes |
|---|---|---|
| ASIX AX88772 / 772A/B/C | `0B95:7720`, `0B95:772A`, `0B95:772B` | The most common 100 Mbit USB adapter ever made. Different register map from the 179 but the same *shape* — vendor control requests, an MII PHY behind them. The obvious next one. |
| ASIX AX88772 (Linksys etc.) | `077B:2226`, `2001:1A02`, others | Same silicon, rebadged. |
| Realtek RTL8152 | `0BDA:8152` | 100 Mbit. Very common. Register access is vendor requests over control, like the ASIX parts. |
| Realtek RTL8153 | `0BDA:8153` | Gigabit sibling of the 8152, falls back to USB 2.0. |
| Microchip/SMSC LAN9500 | `0424:9500`, `0424:EC00` | 100 Mbit, used in older Raspberry Pi boards among others. |
| Davicom DM9601 | `0A46:9601` | 100 Mbit, cheap and old, seen in very inexpensive dongles. |
| CDC-ECM / CDC-NCM (class) | any | A *standard* rather than a chip: several adapters expose it, and a class driver would cover all of them at once. Arguably better value than any single chip. NCM is the harder of the two. |

## Unlikely

| Chip | Why |
|---|---|
| Anything USB 3.0 **only** | The CH375 is a full-speed host: 12 Mbps, USB 1.1 signalling. A 3.0-only device with no 2.0 fallback cannot talk to it at all. In practice almost every "USB 3.0 gigabit" adapter does fall back — the AX88179 here is one, and it runs at full speed quite happily. |
| Anything needing isochronous transfers | The CH375 does control, bulk and interrupt. Ethernet adapters do not use isochronous, so this is theoretical. |

---

## What "add a chipset" actually involves

Renaming the tools away from `AX*` was the easy half. The honest position is
that the bring-up is still one chip's:

- `ax179.pas` is the AX88179/178A register map and bring-up. It keeps its
  chip name deliberately, because that is what it is.
- `usbpktini.inc` — the driver's own bring-up — has the same sequence in
  assembly.

So a new chipset needs a bring-up in **both**, plus a dispatch on the USB ID.
Everything underneath is already generic and would not need touching:

- `ch375.pas` / the CH375 layer in `usbpkt.asm` — enumeration, control
  transfers, bulk endpoints. Chip-agnostic.
- `pktapi.pas`, `pktscan.pas`, `pkttest.pas`, `pkttick.pas` — packet driver
  side, nothing USB-specific.
- The receive engine — burst collection, the frame/metadata layout parsing,
  the toggle handling. **This is the part that took four sessions to get
  right**, and the AX88179's burst format is not universal, so a new chip
  may need its own parser even though the machinery around it is shared.

The realistic order, easiest first:

1. **AX88772.** Same vendor, same idiom, best documented, most common.
2. **RTL8152/8153.** Different vendor, same idiom. Widely available.
3. **CDC-ECM.** A class driver, so one implementation covers many adapters —
   more upfront work, much better return.

---

## Reporting one

If you try an adapter this does not know, the useful thing is the `NETID`
output — the USB ID especially — plus what `USBPKT` said. If it got as far as
a step number, `USBLINK /V` prints the chip status at every register access,
which is usually enough to see where it stopped.

Adapters that **fail** are worth recording here too. "This ID is an RTL8153
and is not supported yet" saves the next person buying the same one.
