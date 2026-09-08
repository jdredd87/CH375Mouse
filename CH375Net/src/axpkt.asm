; ==========================================================================
; AXPKT.COM -- a Crynwr packet driver for an ASIX AX88179 USB Ethernet
;              adapter reached through a CH375 in host mode.
;
;   CH375Net, StevenC.  Public domain (the Unlicense).
;
;   AXPKT [@260] [/I=65] [/S] [/U] [/V] [/G] [/?]
;
;     @nnn    CH375 I/O base in hex, default 260
;     /I=nn   interrupt vector in hex, default 65.  60h is REFUSED
;     /S      status of the copy already loaded
;     /U      unload
;     /V      trace the bring-up
;     /G      leave the PHY at gigabit; the default forces 10BASE-T
;
;   Once resident, anything that speaks the packet driver interface can use
;   it -- mTCP, WATTCP, NCSA Telnet -- by being pointed at the vector.  The
;   whole reason for targeting this interface rather than inventing one is
;   that the DOS networking ecosystem already exists and none of it needs a
;   TCP stack written here.
;
; --------------------------------------------------------------------------
; NOT LOSING THE MACHINE
;
;   The box this was written on is administered over its own network, and
;   that network is a packet driver at INT 60h loaded from AUTOEXEC.BAT.
;   Installing on top of it takes the machine off the air with no way in to
;   undo it, so two refusals are built in rather than written down:
;
;     * vector 60h is rejected outright, whatever is or is not there;
;     * any vector already carrying the "PKT DRVR" signature is rejected.
;
;   Neither can be overridden by a switch.  There is no legitimate reason
;   to want either, and the cost of being wrong is a drive to the machine.
;
;   Do NOT put this in AUTOEXEC.BAT.  A resident driver that hangs during
;   boot cannot be recovered remotely at any price, whereas one loaded from
;   the prompt is undone by a power cycle -- AUTOEXEC reloads the working
;   driver and the machine comes back exactly as it was.
; --------------------------------------------------------------------------
;
; HOW RECEIVE GETS CPU TIME
;
;   The CH375 has no interrupt line wired here, so packets have to be
;   collected by polling, and a packet driver has nowhere of its own to run.
;   INT 08h is the only reliable heartbeat, so the driver hooks it.
;
;   The timer is NOT reprogrammed.  USBMOUSE and USBCOMBO multiply the PIT
;   rate because a mouse feels slow at 18 Hz; nothing here does, and leaving
;   the clock alone is one fewer interaction with the working network
;   driver, which is the thing that must not break.
;
;   The budget is adaptive, and that matters more than it sounds.  A poll
;   that comes back NAK costs about 1.2 ms and finding nothing is the normal
;   case -- so the first read of each tick is speculative and a NAK ends the
;   tick immediately.  Only when data actually arrives does the driver keep
;   draining, up to RX_BUDGET reads.  Idle costs about 2% of the machine;
;   busy costs more, and by then it is doing something useful with it.
;
; 8086 ONLY.  No near conditional jumps: where one cannot reach, the test is
; inverted over an unconditional `jmp near`.  Those are not stylistic.
; ==========================================================================

        cpu     8086
        org     0x100

SIG_OFS         equ 0x0103
VER_OFS         equ 0x010B

RX_BUDGET       equ 24           ; 64-byte reads per tick once data flows
RXBUF_SZ        equ 2048         ; one burst; the chip is held to small ones
TXBUF_SZ        equ 1536         ; 8-byte header plus a full frame
MAXHANDLE       equ 4

; ---- CH375 commands ----
CMD_GET_IC_VER   equ 0x01
CMD_SET_SPEED    equ 0x04
CMD_RESET_ALL    equ 0x05
CMD_CHECK_EXIST  equ 0x06
CMD_SET_RETRY    equ 0x0B
CMD_SET_USB_ADDR equ 0x13
CMD_SET_USB_MODE equ 0x15
CMD_TEST_CONNECT equ 0x16
CMD_SET_ENDP6    equ 0x1C
CMD_SET_ENDP7    equ 0x1D
CMD_GET_STATUS   equ 0x22
CMD_RD_USB_DATA  equ 0x28
CMD_WR_USB_DATA7 equ 0x2B
CMD_CLR_STALL    equ 0x41
CMD_SET_ADDRESS  equ 0x45
CMD_GET_DESCR    equ 0x46
CMD_SET_CONFIG   equ 0x49
CMD_ISSUE_TOKEN  equ 0x4F

INT_SUCCESS      equ 0x14
INT_CONNECT      equ 0x15
INT_DISCONNECT   equ 0x16
INT_RET_NAK      equ 0x2A
INT_RET_STALL    equ 0x2E

PID_OUT          equ 0x01
PID_IN           equ 0x09

USB_ADDR         equ 0x02

; ---- AX88179 ----
AX_ACCESS_MAC    equ 0x01
AX_ACCESS_PHY    equ 0x02
AX_RX_CTL        equ 0x0B
AX_NODE_ID       equ 0x10
AX_MEDIUM_MODE   equ 0x22
AX_MONITOR_MODE  equ 0x24
AX_PHYPWR_RSTCTL equ 0x26
AX_RX_BULK_QCTRL equ 0x2E
AX_CLK_SELECT    equ 0x33
AX_RXCOE_CTL     equ 0x34
AX_TXCOE_CTL     equ 0x35
AX_PAUSE_HIGH    equ 0x54
AX_PAUSE_LOW     equ 0x55
AX_PHY_ID        equ 0x03

EP_BULK_IN       equ 2
EP_BULK_OUT      equ 3

; ---- packet driver error codes ----
E_BAD_HANDLE     equ 1
E_NO_CLASS       equ 2
E_NO_TYPE        equ 3
E_NO_NUMBER      equ 4
E_BAD_TYPE       equ 5
E_NO_MULTICAST   equ 6
E_CANT_TERMINATE equ 7
E_BAD_MODE       equ 8
E_NO_SPACE       equ 9
E_TYPE_INUSE     equ 10
E_BAD_COMMAND    equ 11
E_CANT_SEND      equ 12
E_CANT_SET       equ 13
E_BAD_IOCTL      equ 14

start:
        jmp     near init

; --------------------------------------------------------------------------
; The published block.  Same convention as the other drivers here: an
; eight-byte signature at 0103 and an ASCII version at 010B, so a second
; copy can find the first and say what it is without guessing.
; --------------------------------------------------------------------------
        db      'AXPKT001'                      ; 0103
ver_str:
        db      '0.1.0$'                        ; 010B

; ---- hardware ----
io_dat:     dw  0x260
io_cmd:     dw  0x261
our_vec:    db  0x65
old_vec:    dd  0
old08:      dd  0
mac:        times 6 db 0
rx_tog:     db  0x80
tx_tog:     db  0x80
cfg_val:    db  1

; ---- state ----
in_isr:     db  0                ; re-entry guard: the ISR can take
                                 ; milliseconds and the next tick will
                                 ; arrive on top of it
rcv_mode:   dw  3                ; 3 = our address + broadcast
n_handles:  db  0

; ---- one row per handle: in use, packet type length, the type bytes, and
;      the application's receiver ----
h_used:     times MAXHANDLE db 0
h_typelen:  times MAXHANDLE db 0
h_type:     times MAXHANDLE*8 db 0
h_rcv:      times MAXHANDLE dd 0

; ---- statistics, as get_statistics reports them ----
st_in:      dd  0
st_out:     dd  0
st_inerr:   dd  0
st_outerr:  dd  0
st_indrop:  dd  0

; ---- counters of our own, for /S ----
n_ticks:    dw  0
n_bursts:   dw  0
n_frames:   dw  0
n_short:    dw  0
n_nohandle: dw  0

; Scratch the receive path keeps across the upcall.  It has to live in CS
; memory rather than in registers or on the stack: the receiver is the
; application's code, called from inside a timer interrupt, and nothing may
; be assumed about any register once it has run.
rx_frofs:   dw  0
rx_frlen:   dw  0
rx_handle:  dw  0
rcv_tmp:    dd  0

drv_name:   db  'AX88179/CH375', 0

rxbuf:      times RXBUF_SZ db 0
txbuf:      times TXBUF_SZ db 0

; ==========================================================================
; CH375 PORT LAYER.  Lifted from USBCOMBO, which has had the most hardware
; time of anything here.  The two reads of port 61h are the ISA settling
; delay -- port 61h is harmless to read and two of them are comfortably
; longer than the chip needs between a command and its data byte.
; ==========================================================================
ch_cmd:                                  ; AL = command
        push    dx
        push    ax
        mov     dx, 0x61
        in      al, dx
        in      al, dx
        pop     ax
        mov     dx, [cs:io_cmd]
        out     dx, al
        mov     dx, 0x61
        in      al, dx
        in      al, dx
        pop     dx
        ret

ch_wr:                                   ; AL = data
        push    dx
        mov     dx, [cs:io_dat]
        out     dx, al
        push    ax
        mov     dx, 0x61
        in      al, dx
        in      al, dx
        pop     ax
        pop     dx
        ret

ch_rd:                                   ; -> AL
        push    dx
        mov     dx, 0x61
        in      al, dx
        in      al, dx
        mov     dx, [cs:io_dat]
        in      al, dx
        pop     dx
        ret

; Wait for the chip's interrupt then read the status.  CX = spin limit.
; CF set on timeout, else AL = status.
ch_wait:
        push    dx
        mov     dx, [cs:io_cmd]
ch_wait_spin:
        in      al, dx
        test    al, 0x80
        je      short ch_wait_got
        loop    ch_wait_spin
        pop     dx
        stc
        ret
ch_wait_got:
        pop     dx
        mov     al, CMD_GET_STATUS
        call    ch_cmd
        call    ch_rd
        clc
        ret

; Read the chip buffer into ES:DI, at most CL bytes.  AH = length the chip
; reported, AL = bytes stored.  Everything is read out of the chip even
; when the caller cannot take it: bytes left behind desynchronise the next
; read, which is a fault that shows up much later and looks like nothing.
ch_read:
        push    bx
        mov     al, CMD_RD_USB_DATA
        call    ch_cmd
        call    ch_rd
        mov     ah, al
        mov     bl, al
        xor     bh, bh
        or      bl, bl
        je      short ch_read_done
ch_read_loop:
        call    ch_rd
        cmp     bh, cl
        jae     short ch_read_skip
        stosb
        inc     bh
ch_read_skip:
        dec     bl
        jne     short ch_read_loop
ch_read_done:
        mov     al, bh
        pop     bx
        ret

; --------------------------------------------------------------------------
; One IN token on the bulk endpoint.  ES:DI = where, CL = room.
; Returns AL = bytes stored, AH = chip status, CF set if the status was
; anything but success.
; --------------------------------------------------------------------------
bulk_in:
        mov     al, CMD_SET_ENDP6
        call    ch_cmd
        mov     al, [cs:rx_tog]
        call    ch_wr
        mov     al, CMD_ISSUE_TOKEN
        call    ch_cmd
        mov     al, (EP_BULK_IN << 4) | PID_IN
        call    ch_wr
        push    cx
        mov     cx, 0x3000
        call    ch_wait
        pop     cx
        jc      short bulk_in_bad
        cmp     al, INT_SUCCESS
        jne     short bulk_in_status
        push    ax
        xor     byte [cs:rx_tog], 0x40
        pop     ax
        mov     ah, al
        call    ch_read                  ; AL = stored
        clc
        ret
bulk_in_status:
        mov     ah, al
        xor     al, al
        stc
        ret
bulk_in_bad:
        mov     ah, 0
        xor     al, al
        stc
        ret

; --------------------------------------------------------------------------
; One OUT token.  DS:SI = data, CL = length (0..64).
; CF set unless the chip reported success.
; --------------------------------------------------------------------------
bulk_out:
        push    cx
        mov     al, CMD_WR_USB_DATA7
        call    ch_cmd
        mov     al, cl
        call    ch_wr
        or      cl, cl
        je      short bulk_out_sent
bulk_out_loop:
        lodsb
        call    ch_wr
        dec     cl
        jne     short bulk_out_loop
bulk_out_sent:
        mov     al, CMD_SET_ENDP7
        call    ch_cmd
        mov     al, [cs:tx_tog]
        call    ch_wr
        mov     al, CMD_ISSUE_TOKEN
        call    ch_cmd
        mov     al, (EP_BULK_OUT << 4) | PID_OUT
        call    ch_wr
        mov     cx, 0x3000
        call    ch_wait
        pop     cx
        jc      short bulk_out_bad
        cmp     al, INT_SUCCESS
        jne     short bulk_out_bad
        xor     byte [cs:tx_tog], 0x40
        clc
        ret
bulk_out_bad:
        stc
        ret

; ==========================================================================
; THE INT 08h HOOK -- where receive actually happens.
; ==========================================================================
isr08:
        push    ax
        ; Re-entry guard.  A tick that finds data can spend milliseconds
        ; draining it, and the next one will arrive on top.  Without this
        ; the second entry would use the same buffer and the same toggle as
        ; the first and both would be wrong.
        cmp     byte [cs:in_isr], 0
        je      short isr_enter
        pop     ax
        jmp     far [cs:old08]
isr_enter:
        mov     byte [cs:in_isr], 1
        push    bx
        push    cx
        push    dx
        push    si
        push    di
        push    bp
        push    ds
        push    es
        push    cs
        pop     ds
        cld                              ; the direction flag belongs to
                                         ; whoever we interrupted, and five
                                         ; string operations below assume
                                         ; forward
        inc     word [n_ticks]
        call    rx_poll
        pop     es
        pop     ds
        pop     bp
        pop     di
        pop     si
        pop     dx
        pop     cx
        pop     bx
        mov     byte [cs:in_isr], 0
        pop     ax
        jmp     far [cs:old08]

; --------------------------------------------------------------------------
; Collect at most one burst, then hand each frame in it to whoever asked.
; The first read is speculative: NAK means the wire is quiet, which is the
; usual answer, and the tick ends there having cost about a millisecond.
; --------------------------------------------------------------------------
rx_poll:
        cmp     byte [n_handles], 0
        jne     short rx_go
        ret                              ; nobody is listening; do not even
                                         ; touch the chip
rx_go:
        push    cs
        pop     es
        mov     di, rxbuf
        xor     bp, bp                   ; BP = bytes collected
        mov     dx, RX_BUDGET
rx_loop:
        mov     cl, 64
        call    bulk_in
        jc      short rx_done            ; NAK or error: nothing more now
        xor     ah, ah
        add     bp, ax
        cmp     al, 64
        jb      short rx_have            ; short packet ends the transfer
        cmp     bp, RXBUF_SZ - 64
        jae     short rx_have            ; no room for another
        dec     dx
        jnz     short rx_loop
rx_have:
        or      bp, bp
        je      short rx_done
        inc     word [n_bursts]
        mov     cx, bp
        call    rx_deliver
rx_done:
        ret

; --------------------------------------------------------------------------
; Pull the frames out of a burst and pass them up.  CX = bytes in rxbuf.
;
; The layout is the one AXRECV established on the hardware:
;   [frame][pad to 8][frame][pad to 8]...[entry][entry]...[trailer]
; trailer = last 4 bytes, low word the packet count and high word the
; offset of the entry array; each entry is 4 bytes and bits 16..28 of it
; are the frame length; frames start at offset 0 and each is padded up to
; an 8-byte boundary.
; --------------------------------------------------------------------------
rx_deliver:
        cmp     cx, 8
        jae     short rxd_ok
        inc     word [n_short]
        ret
rxd_ok:
        mov     si, rxbuf
        add     si, cx
        sub     si, 4                    ; SI -> trailer
        mov     ax, [si]                 ; low word  = packet count
        mov     bx, [si+2]               ; high word = entry array offset
        or      ax, ax
        je      short rxd_bad
        cmp     ax, 32
        ja      short rxd_bad
        mov     dx, cx
        sub     dx, 4
        cmp     bx, dx
        ja      short rxd_bad            ; entry array outside the buffer

        ; Entry stride, worked out from the data rather than assumed: the
        ; space between the array and the trailer over the packet count.
        push    ax
        sub     dx, bx                   ; DX = bytes of entry array
        xchg    ax, dx                   ; AX = bytes, DX = count
        xor     bp, bp
        or      dx, dx
        je      short rxd_pop_bad
        div     dl                       ; AL = bytes per entry
        xor     ah, ah
        mov     bp, ax                   ; BP = stride
        pop     ax                       ; AX = packet count
        or      bp, bp
        je      short rxd_bad

        mov     di, 0                    ; DI = offset of this frame
        mov     dx, ax                   ; DX = frames left
        mov     si, rxbuf
        add     si, bx                   ; SI -> first entry
rxd_next:
        push    dx
        push    si
        mov     ax, [si+2]               ; high word of the entry
        and     ax, 0x1FFF               ; ...bits 16..28 are the length
        mov     cx, ax
        cmp     cx, 14
        jb      short rxd_skip
        mov     bx, di
        add     bx, cx
        cmp     bx, RXBUF_SZ
        ja      short rxd_skip
        push    di
        call    rx_one                   ; DI = offset, CX = length
        pop     di
        inc     word [n_frames]
rxd_skip:
        ; on to the next frame: length rounded up to 8
        add     cx, 7
        and     cx, 0xFFF8
        add     di, cx
        pop     si
        add     si, bp
        pop     dx
        dec     dx
        jnz     short rxd_next
        ret
rxd_pop_bad:
        pop     ax
rxd_bad:
        inc     word [n_short]
        ret

; --------------------------------------------------------------------------
; One frame, at CS:rxbuf+DI, CX bytes.  Find a handle that wants it and do
; the two-call handshake the packet driver standard defines:
;
;   call the receiver with AX=0 and CX=length; it returns ES:DI, the buffer
;   to put the frame in, or 0:0 to say it does not want it.  Copy, then call
;   again with AX=1 and DS:SI pointing at the same buffer.
;
; Getting that wrong is not a subtle failure -- an application that is
; handed a buffer it never asked for writes over whatever was there.
; --------------------------------------------------------------------------
rx_one:
        mov     [rx_frofs], di
        mov     [rx_frlen], cx
        mov     bx, di
        add     bx, rxbuf                ; BX -> the frame itself
        mov     dx, [bx+12]              ; the type field.  Big-endian on
                                         ; the wire and left that way: the
                                         ; handle's stored copy is too, so
                                         ; the two compare without swapping
        xor     si, si                   ; SI = handle index
rx_find:
        cmp     byte [si+h_used], 0
        je      short rx_findnext
        mov     al, [si+h_typelen]
        or      al, al
        je      short rx_found           ; length 0 = wants everything
        cmp     al, 2
        jne     short rx_findnext        ; only 2-byte types are matched
        push    si
        shl     si, 1
        shl     si, 1
        shl     si, 1                    ; index * 8 into h_type
        mov     ax, [si+h_type]
        pop     si
        cmp     ax, dx
        je      short rx_found
rx_findnext:
        inc     si
        cmp     si, MAXHANDLE
        jb      short rx_find
        inc     word [n_nohandle]
        add     word [st_indrop], 1
        adc     word [st_indrop+2], 0
        ret

; --------------------------------------------------------------------------
; The two-call handshake, which is the part an application's memory depends
; on getting right.
;
;   AX=0, BX=handle, CX=length  ->  the application returns ES:DI, somewhere
;                                   to put the frame, or 0:0 to decline it
;   copy it there
;   AX=1, BX=handle, CX=length, DS:SI = that same buffer
;
; Skipping the first call and writing into a buffer nobody offered is not a
; subtle bug: it lands on whatever the application had there.  Skipping the
; second means the application never learns the frame arrived and the buffer
; leaks.  The receiver is somebody else's code called from inside a timer
; interrupt, so nothing may be assumed about any register after it returns,
; and everything worth keeping is in CS memory before the call.
; --------------------------------------------------------------------------
rx_found:
        mov     [rx_handle], si
        mov     ax, si
        shl     ax, 1
        shl     ax, 1
        mov     bx, ax
        mov     ax, [bx+h_rcv]
        mov     [rcv_tmp], ax
        mov     ax, [bx+h_rcv+2]
        mov     [rcv_tmp+2], ax

        mov     bx, [rx_handle]
        mov     cx, [rx_frlen]
        xor     ax, ax                   ; first call: "do you want it?"
        call    far [cs:rcv_tmp]

        push    cs
        pop     ds                       ; the receiver owned DS; take it back
        mov     ax, es
        or      ax, di
        jne     short rx_wanted
        inc     word [n_nohandle]        ; declined, and that is allowed
        add     word [st_indrop], 1
        adc     word [st_indrop+2], 0
        ret
rx_wanted:
        push    es
        push    di
        mov     si, [rx_frofs]
        add     si, rxbuf
        mov     cx, [rx_frlen]
        cld
        rep     movsb                    ; CS:rxbuf+ofs -> the app's buffer
        pop     di
        pop     es

        mov     ax, es                   ; second call: DS:SI = that buffer
        mov     ds, ax
        mov     si, di
        mov     cx, [cs:rx_frlen]
        mov     bx, [cs:rx_handle]
        mov     ax, 1
        call    far [cs:rcv_tmp]

        push    cs
        pop     ds
        add     word [st_in], 1
        adc     word [st_in+2], 0
        ret

; ==========================================================================
; THE PACKET DRIVER ENTRY POINT
; ==========================================================================
pkt_entry:
        jmp     short pkt_go
        nop
        db      'PKT DRVR', 0            ; the signature, at entry+3, which
                                         ; is the whole discovery mechanism
                                         ; the standard defines
pkt_go:
        sti
        cld
        cmp     ah, 1
        jne     short __ovr1
        jmp     near pkt_info
__ovr1:
        cmp     ah, 2
        jne     short __ovr2
        jmp     near pkt_access
__ovr2:
        cmp     ah, 3
        jne     short __ovr3
        jmp     near pkt_release
__ovr3:
        cmp     ah, 4
        jne     short __ovr4
        jmp     near pkt_send
__ovr4:
        cmp     ah, 5
        jne     short __ovr5
        jmp     near pkt_terminate
__ovr5:
        cmp     ah, 6
        jne     short __ovr6
        jmp     near pkt_getaddr
__ovr6:
        cmp     ah, 7
        jne     short __ovr7
        jmp     near pkt_reset
__ovr7:
        cmp     ah, 20
        jne     short __ovr8
        jmp     near pkt_setmode
__ovr8:
        cmp     ah, 21
        jne     short __ovr9
        jmp     near pkt_getmode
__ovr9:
        cmp     ah, 24
        jne     short __ovr10
        jmp     near pkt_stats
__ovr10:
        mov     dh, E_BAD_COMMAND
        stc
        retf    2

; ---- 1: driver_info ----
pkt_info:
        push    cs
        pop     ds
        mov     si, drv_name
        mov     bx, 1                    ; version
        mov     ch, 1                    ; class 1 = DIX Ethernet
        mov     dx, 0                    ; type: unregistered
        mov     cl, 0                    ; interface number
        mov     al, 2                    ; basic plus extended
        clc
        retf    2

; ---- 6: get_address ----
pkt_getaddr:
        cmp     cx, 6
        jae     short pga_ok
        mov     dh, E_NO_SPACE
        stc
        retf    2
pga_ok:
        push    si
        push    ds
        push    cs
        pop     ds
        mov     si, mac
        mov     cx, 6
        rep     movsb
        pop     ds
        pop     si
        mov     cx, 6
        clc
        retf    2

; ---- 21: get_rcv_mode ----
pkt_getmode:
        mov     ax, [cs:rcv_mode]
        clc
        retf    2

; ---- 20: set_rcv_mode ----
pkt_setmode:
        cmp     cx, 1
        jb      short psm_bad
        cmp     cx, 6
        ja      short psm_bad
        mov     [cs:rcv_mode], cx
        clc
        retf    2
psm_bad:
        mov     dh, E_BAD_MODE
        stc
        retf    2

; ---- 7: reset_interface ----
pkt_reset:
        clc
        retf    2

; ---- 24: get_statistics ----
pkt_stats:
        push    cs
        pop     ds
        mov     si, st_in
        clc
        retf    2

; ---- 2: access_type ----
; AL = class, BX = type, DL = number, DS:SI -> type bytes, CX = type length,
; ES:DI -> receiver.  Returns AX = handle.
pkt_access:
        cmp     al, 1                    ; class 1, DIX Ethernet
        je      short pa_class_ok
        mov     dh, E_NO_CLASS
        stc
        retf    2
pa_class_ok:
        cmp     cx, 8
        jbe     short pa_len_ok
        mov     dh, E_BAD_TYPE
        stc
        retf    2
pa_len_ok:
        push    bx
        push    cx
        push    si
        push    di
        push    es
        push    ds
        ; find a free row
        xor     bx, bx
pa_find:
        cmp     byte [cs:bx+h_used], 0
        je      short pa_got
        inc     bx
        cmp     bx, MAXHANDLE
        jb      short pa_find
        pop     ds
        pop     es
        pop     di
        pop     si
        pop     cx
        pop     bx
        mov     dh, E_NO_SPACE
        stc
        retf    2
pa_got:
        mov     byte [cs:bx+h_used], 1
        mov     al, cl
        mov     [cs:bx+h_typelen], al
        ; copy the type bytes
        push    bx
        push    di
        mov     ax, bx
        shl     ax, 1
        shl     ax, 1
        shl     ax, 1
        mov     di, ax
        add     di, h_type
        push    cs
        pop     es
        jcxz    pa_nocopy
        rep     movsb                    ; DS:SI -> type, ES:DI -> our row
pa_nocopy:
        pop     di
        pop     bx
        ; store the receiver
        pop     ds
        pop     es                       ; ES:DI is the receiver again
        push    es
        push    ds
        mov     ax, bx
        shl     ax, 1
        shl     ax, 1
        mov     si, ax
        mov     [cs:si+h_rcv], di
        mov     ax, es
        mov     [cs:si+h_rcv+2], ax
        inc     byte [cs:n_handles]
        pop     ds
        pop     es
        pop     di
        pop     si
        pop     cx
        pop     ax                       ; the pushed BX
        mov     ax, bx                   ; handle = row index
        clc
        retf    2

; ---- 3: release_type ----
pkt_release:
        cmp     bx, MAXHANDLE
        jb      short prl_ok
prl_bad:
        mov     dh, E_BAD_HANDLE
        stc
        retf    2
prl_ok:
        cmp     byte [cs:bx+h_used], 0
        je      short prl_bad
        mov     byte [cs:bx+h_used], 0
        dec     byte [cs:n_handles]
        clc
        retf    2

; ---- 5: terminate ----
; Refused.  Unloading has to put INT 08h back as well, and doing that from
; inside a call made by the program being unloaded is how a machine ends up
; with a vector pointing at freed memory.  AXPKT /U does it properly, from
; the command line, with the checks that need a transient copy to make.
pkt_terminate:
        mov     dh, E_CANT_TERMINATE
        stc
        retf    2

; ---- 4: send_pkt ----
; DS:SI -> frame, CX = length.
pkt_send:
        push    ax
        push    bx
        push    cx
        push    dx
        push    si
        push    di
        push    bp
        push    ds
        push    es
        cmp     cx, 14
        jae     short __ovr11
        jmp     near psend_bad
__ovr11:
        cmp     cx, 1514
        jbe     short __ovr12
        jmp     near psend_bad
__ovr12:

        ; Build the 8-byte header in front of a copy of the frame.  Two
        ; little-endian 32-bit words: the length, then zero -- except when
        ; the total lands on an exact multiple of the 64-byte packet size,
        ; when bits 15 and 31 are set.  That case ALSO needs a zero-length
        ; packet to end the USB transfer, which is a separate requirement
        ; that happens to arise at the same moment.
        push    cs
        pop     es
        mov     di, txbuf
        mov     ax, cx
        stosw                            ; length, low word
        xor     ax, ax
        stosw                            ; length, high word
        mov     bx, cx
        add     bx, 8
        test    bx, 0x003F
        jnz     short psend_nopad
        mov     ax, 0x8000
        stosw
        mov     ax, 0x8000
        stosw
        jmp     short psend_body
psend_nopad:
        xor     ax, ax
        stosw
        stosw
psend_body:
        push    cx
        rep     movsb                    ; DS:SI -> caller's frame
        pop     cx
        add     cx, 8                    ; CX = total to push out

        push    cs
        pop     ds
        mov     si, txbuf
psend_loop:
        mov     ax, cx
        cmp     ax, 64
        jbe     short psend_last
        mov     ax, 64
psend_last:
        push    cx
        mov     cl, al
        call    bulk_out
        pop     cx
        jc      short psend_fail
        sub     cx, ax
        jnz     short psend_loop

        ; the terminating zero-length packet, when it is needed
        test    bx, 0x003F
        jnz     short psend_ok
        xor     cl, cl
        call    bulk_out
        jc      short psend_fail
psend_ok:
        add     word [cs:st_out], 1
        adc     word [cs:st_out+2], 0
        pop     es
        pop     ds
        pop     bp
        pop     di
        pop     si
        pop     dx
        pop     cx
        pop     bx
        pop     ax
        clc
        retf    2
psend_fail:
        add     word [cs:st_outerr], 1
        adc     word [cs:st_outerr+2], 0
psend_bad:
        pop     es
        pop     ds
        pop     bp
        pop     di
        pop     si
        pop     dx
        pop     cx
        pop     bx
        pop     ax
        mov     dh, E_CANT_SEND
        stc
        retf    2

resident_end:

; ==========================================================================
; TRANSIENT -- everything below here is released when the driver goes
; resident, and none of it may be reached from the ISR.
; ==========================================================================
%include "axpktini.inc"
