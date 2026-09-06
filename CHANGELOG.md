# Changelog

CH375Mouse -- StevenC -- https://github.com/jdredd87/CH375Mouse

The version lives in `ver_str` in `src/usbmouse.asm` and nowhere else. A
release is: bump it, add an entry here, `build.cmd`, commit, `git tag -a`.

## 1.0.0 -- 2026-09-06

First numbered release. Everything below has been run on the hardware: a
CH375B rev B7 on an ISA card at `260h`, a low-speed Pixart optical mouse
(VID/PID `093A/2510`), MS-DOS on an 8086-class machine.

* `USBMOUSE.COM`, a resident INT 33h mouse driver, about 1.5 KB resident.
  It enumerates the mouse itself -- bus reset, speed negotiation,
  descriptors, address, configuration, HID boot protocol -- and polls the
  interrupt IN endpoint from a timer hook.
* Low-speed devices work. `SET_USB_SPEED` has to be issued after the last
  `SET_USB_MODE` and after the post-reset connect has been cleared, or it is
  silently ignored; that is the whole reason a low-speed mouse would
  otherwise answer every transfer with `24h`.
* INT 08h is taken over and the PIT divided by 8 for a 145 Hz poll, with
  every 8th tick forwarded, so BIOS timekeeping and the DOS clock stay
  right. The fast rate is given up automatically if another program hooks
  the timer above us, which is what makes double-click work in Windows;
  `/K` keeps it anyway.
* `/W` presents the mouse as a PS/2 BIOS pointing device (INT 15h C0h/C2h,
  INT 11h bit 2, INT 74h), which is what Windows 3.x understands. Movement,
  clicks and double-click all work in Windows 3.0.
* Options: `@nnn /V /F /E=n /R=n /K /W /S /U /?`.
* Private INT 33h functions `7F00h`-`7F03h` for testing: status, report
  injection, poll suspend, last raw report.
* The version is printed on every run, and kept in the resident image at
  `010Bh` so `/S` reports the version of the copy that is already loaded.
* Test tools, 78 checks in all: `MOUSETST` (34), `EVTEST` (19),
  `PS2TEST` (25), plus `TICKCHK`, `CLKCHK`, `CLICKTST`, `MDEMO`, `CHDIAG`.
* Assembles identically with `nasm` on a PC and with `MNASMFIX.COM -O9` on
  the DOS machine itself; `build.cmd dosbuild` checks that, byte for byte.
* Released into the public domain under the Unlicense.  `tools/MNASMFIX.COM`
  is third-party and keeps its own terms.
* Built and tested over DOSBridge -- https://github.com/jdredd87/DOSBridge
