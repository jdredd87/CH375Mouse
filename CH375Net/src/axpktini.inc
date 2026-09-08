; ==========================================================================
; AXPKT -- the transient half: arguments, the safety checks, install,
;          unload and status.  Everything here is released when the driver
;          goes resident and none of it may be reached from the ISR.
;
;   CH375Net, StevenC.  Public domain (the Unlicense).
;
; WHY THIS DOES NOT BRING THE ADAPTER UP
;
;   Run AXPROBE first.  It powers the PHY, sets the clocks, configures the
;   receive path and negotiates the link, and it leaves the adapter in
;   exactly that state when it exits -- the chip does not forget because a
;   DOS program ended.  AXPKT checks the chip is there, reads the MAC, and
;   goes resident.
;
;   That is a real limitation and not a design: a driver you have to
;   prepare with a second program is a driver somebody will forget to
;   prepare.  It is split this way because the bring-up is a page of
;   control transfers that already exist, tested, in Pascal, and having
;   them in one place while the layout was still being learned was worth
;   more than having them in the .COM.  Folding them in is the next job.
; ==========================================================================

PID_SETUP        equ 0x0D
INT_STALL        equ 0x2E

; --------------------------------------------------------------------------
; Clear endpoint 0.  Required before every control transfer, not tidying:
; CLR_STALL on the CH375 also resets the endpoint's data toggle, and
; without it a transfer that SUCCEEDS leaves endpoint 0 advanced so the
; next one is stalled by the device.  Control transfers then work every
; other time, which reads as a flaky device and is not one.
; --------------------------------------------------------------------------
clr_ep0:
        mov     al, CMD_CLR_STALL
        call    ch_cmd
        xor     al, al
        call    ch_wr
        mov     cx, 0x4000
        call    ch_wait
        ret

; --------------------------------------------------------------------------
; How hard the chip tries when a device answers NAK.  8F is "for ever",
; 00 is "report it and move on", and which one is right depends entirely
; on what you are doing:
;
;   control transfers want 8F.  A device that is busy NAKs, and the right
;   response is to ask again -- treating one NAK as a failed transfer means
;   the transfer fails whenever the device happens to be thinking.
;
;   polling an idle endpoint wants 00.  With 8F the chip sits there
;   retrying instead of reporting, the caller's own wait expires, and a
;   poll takes seconds.
;
; AXPROBE leaves the chip on 00 because that is what its receive loop
; needs, so this has to put it back to 8F for its own control transfer and
; then set it to 00 again before going resident.  Getting that wrong is
; what made read_mac fail here while the identical request from Pascal
; succeeded four times out of four -- the Pascal had just enumerated, so
; the chip was still on 8F.
; --------------------------------------------------------------------------
set_retry:                               ; AL = the retry byte
        push    ax
        mov     al, CMD_SET_RETRY
        call    ch_cmd
        mov     al, 0x25
        call    ch_wr
        pop     ax
        call    ch_wr
        ret

; --------------------------------------------------------------------------
; A control transfer with an IN data stage.  DS:SI -> 8 setup bytes,
; ES:DI -> where the data goes, BL = how many bytes are wanted.
; CF set on failure; on success BH = bytes actually stored.
; --------------------------------------------------------------------------
ctrl_in:
        push    bp
        call    clr_ep0
        mov     al, CMD_WR_USB_DATA7
        call    ch_cmd
        mov     al, 8
        call    ch_wr
        mov     cx, 8
ci_setup:
        lodsb
        call    ch_wr
        loop    ci_setup

        mov     al, CMD_SET_ENDP6
        call    ch_cmd
        mov     al, 0x80                 ; SETUP is always DATA0
        call    ch_wr
        mov     al, CMD_ISSUE_TOKEN
        call    ch_cmd
        mov     al, PID_SETUP
        call    ch_wr
        mov     cx, 0xFFFF
        call    ch_wait
        pushf
        push    ax
        mov     al, 'S'
        call    mark
        pop     ax
        push    ax
        call    markhex
        pop     ax
        popf
        jnc     short __iovr1
        jmp     near ci_fail
__iovr1:
        cmp     al, INT_SUCCESS
        je     short __iovr2
        jmp     near ci_fail
__iovr2:

        ; The data stage starts on DATA1 by spec, and the chip has to be
        ; told: it does not infer it from the SETUP that preceded it.
        mov     bh, 0                    ; stored so far
        mov     bp, 0xC0                 ; the toggle for the next IN
ci_data:
        mov     al, CMD_SET_ENDP6
        call    ch_cmd
        mov     ax, bp
        call    ch_wr
        mov     al, CMD_ISSUE_TOKEN
        call    ch_cmd
        mov     al, PID_IN
        call    ch_wr
        mov     cx, 0xFFFF
        call    ch_wait
        pushf
        push    ax
        mov     al, 'I'
        call    mark
        pop     ax
        push    ax
        call    markhex
        pop     ax
        popf
        jc      short ci_fail
        cmp     al, INT_SUCCESS
        jne     short ci_fail
        push    bx
        mov     cl, bl
        sub     cl, bh                   ; room left
        call    ch_read                  ; AL = stored, AH = reported
        push    ax
        mov     al, 'n'
        call    mark
        pop     ax
        push    ax
        call    markhex
        pop     ax
        mov     dl, al
        pop     bx
        add     bh, dl
        xor     bp, 0x40                 ; DATA0 <-> DATA1
        cmp     dl, 8
        jb      short ci_status          ; a short packet ends the stage
        cmp     bh, bl
        jb      short ci_data

ci_status:
        ; The status stage of an IN transfer is an OUT carrying DATA1.
        mov     al, CMD_WR_USB_DATA7
        call    ch_cmd
        xor     al, al
        call    ch_wr
        mov     al, CMD_SET_ENDP7
        call    ch_cmd
        mov     al, 0xC0
        call    ch_wr
        mov     al, CMD_ISSUE_TOKEN
        call    ch_cmd
        mov     al, PID_OUT
        call    ch_wr
        mov     cx, 0xFFFF
        call    ch_wait
        pop     bp
        clc
        ret
ci_fail:
        push    ax
        call    clr_ep0
        pop     ax
        pop     bp
        stc
        ret

; --------------------------------------------------------------------------
; Read the adapter's MAC into `mac`.  One vendor request: AX_ACCESS_MAC
; with the register in wValue and its length in wIndex, which is unusual
; enough to be worth restating at the one place it is built.
; --------------------------------------------------------------------------
setup_mac:
        db      0xC0                     ; IN, vendor, device
        db      AX_ACCESS_MAC
        dw      AX_NODE_ID               ; wValue  = the register
        dw      6                        ; wIndex  = its length
        dw      6                        ; wLength

read_mac:
        push    cs
        pop     ds

        ; Retry in software, with the chip set to report a NAK rather than
        ; keep asking.  The obvious way round is to set retry to 8F and let
        ; the CH375 be patient for us, and that is what this did first --
        ; but when our own wait then expires we walk away from a chip that
        ; is still retrying in the background, and the NEXT program to open
        ; it finds a transaction in flight that its bring-up does not
        ; expect.  That did not hang AXPKT.  It hung AXPROBE, afterwards,
        ; which is a far more confusing thing to debug.
        ;
        ; With 00 the chip answers immediately and is idle between tries,
        ; so eight attempts here cost the same patience and leave nothing
        ; outstanding when they run out.  Every attempt starts with
        ; clr_ep0 inside ctrl_in, which resets the endpoint toggle.
        xor     al, al
        call    set_retry
        mov     bp, 8
rm_try:
        push    cs
        pop     es
        mov     si, setup_mac
        mov     di, mac
        mov     bl, 6
        call    ctrl_in
        jc      short rm_again
        cmp     bh, 6
        je      short rm_good
rm_again:
        dec     bp
        jnz     short rm_try

        ; Out of tries.  Leave the endpoint clear so whatever runs next
        ; opens a quiet chip.
        call    clr_ep0
        stc
        ret
rm_good:
        clc
        ret

; --------------------------------------------------------------------------
; /V prints one letter as each stage of the bring-up is passed.  Crude on
; purpose: a hang inside a DOS program that has not installed anything is
; invisible from outside -- the machine simply stops answering -- and the
; last letter to reach the screen is the only evidence of where it stopped.
; --------------------------------------------------------------------------
markhex:                                 ; AL in hex, only under /V
        cmp     byte [cs:op_verb], 0
        je      short markhex_out
        call    puthex
markhex_out:
        ret

mark:                                    ; AL = the letter
        cmp     byte [cs:op_verb], 0
        je      short mark_out
        call    putc
mark_out:
        ret

; --------------------------------------------------------------------------
; Output helpers.
; --------------------------------------------------------------------------
puts:                                    ; DX -> '$'-terminated
        push    ax
        mov     ah, 9
        int     0x21
        pop     ax
        ret

putc:
        push    ax
        push    dx
        mov     dl, al
        mov     ah, 2
        int     0x21
        pop     dx
        pop     ax
        ret

crlf:
        mov     al, 13
        call    putc
        mov     al, 10
        call    putc
        ret

puthex:                                  ; AL
        push    cx                       ; CL is a shift count here and a
        push    ax                       ; live byte count in ctrl_in; not
        push    ax                       ; saving it is the sort of thing
        mov     cl, 4                    ; that only bites once tracing is
        shr     al, cl                   ; added to a working routine
        call    puthex1
        pop     ax
        and     al, 0x0F
        call    puthex1
        pop     ax
        pop     cx
        ret
puthex1:
        add     al, '0'
        cmp     al, '9'
        jbe     short puthex1_p
        add     al, 7
puthex1_p:
        call    putc
        ret

puthexw:                                 ; AX
        push    ax
        mov     al, ah
        call    puthex
        pop     ax
        call    puthex
        ret

putdecw:                                 ; AX
        push    ax
        push    bx
        push    cx
        push    dx
        xor     cx, cx
        mov     bx, 10
pdw_d:
        xor     dx, dx
        div     bx
        push    dx
        inc     cx
        or      ax, ax
        jne     short pdw_d
pdw_p:
        pop     ax
        add     al, '0'
        call    putc
        loop    pdw_p
        pop     dx
        pop     cx
        pop     bx
        pop     ax
        ret

; --------------------------------------------------------------------------
; hexval: AL char -> AL value, CF on error.
; --------------------------------------------------------------------------
hexval:
        cmp     al, '0'
        jb      short hv_bad
        cmp     al, '9'
        ja      short hv_a
        sub     al, '0'
        clc
        ret
hv_a:
        and     al, 0xDF
        cmp     al, 'A'
        jb      short hv_bad
        cmp     al, 'F'
        ja      short hv_bad
        sub     al, 'A' - 10
        clc
        ret
hv_bad:
        stc
        ret

; --------------------------------------------------------------------------
; The command line.
; --------------------------------------------------------------------------
op_unload:  db 0
op_status:  db 0
op_verb:    db 0
op_help:    db 0
op_giga:    db 0
op_test:    db 0

; Set the moment this program first speaks to the chip.  Any exit that does
; NOT go resident has to hand the chip back in a state the next program's
; bring-up can start from, and the only state that qualifies is "just
; reset".  Leaving it configured-but-idle is what wedged AXPROBE on the
; following invocation -- its enumeration begins by waiting for a connect
; interrupt that a chip already past that point never raises again.
touched:    db 0

parse_args:
        mov     si, 0x81
        mov     cl, [0x80]
        xor     ch, ch
        jcxz    pa_done
pa_loop:
        lodsb
        dec     cx
        cmp     al, ' '
        je      short pa_more
        cmp     al, 9
        je      short pa_more
        cmp     al, '@'
        je      short pa_j_base
        cmp     al, '/'
        je      short pa_slash
        cmp     al, '-'
        je      short pa_slash
        jmp     near pa_more
pa_j_base:
        jmp     near pa_base
pa_more:
        jcxz    pa_done
        jmp     short pa_loop
pa_done:
        ret

pa_slash:
        jcxz    pa_done
        lodsb
        dec     cx
        ; '?' before the upper-casing.  AND 0DFh clears bit 5, which folds
        ; letters and turns '?' (3Fh) into 1Fh -- the bug that stopped /?
        ; ever working in USBKBD.
        cmp     al, '?'
        jne     short pa_notq
        mov     byte [op_help], 1
        jmp     near pa_more
pa_notq:
        and     al, 0xDF
        cmp     al, 'U'
        jne     short pa_s2
        mov     byte [op_unload], 1
        jmp     near pa_more
pa_s2:
        cmp     al, 'S'
        jne     short pa_s3
        mov     byte [op_status], 1
        jmp     near pa_more
pa_s3:
        cmp     al, 'V'
        jne     short pa_s4
        mov     byte [op_verb], 1
        jmp     near pa_more
pa_s4:
        cmp     al, 'G'
        jne     short pa_s5
        mov     byte [op_giga], 1
        jmp     near pa_more
pa_s5:
        cmp     al, 'T'
        jne     short pa_s6
        mov     byte [op_test], 1
        jmp     near pa_more
pa_s6:
        cmp     al, 'N'
        jne     short pa_s7
        mov     byte [op_nopoll], 1
        jmp     near pa_more
pa_s7:
        cmp     al, 'I'
        je      short pa_vec_arg
        jmp     near pa_more
pa_vec_arg:
        ; /I=nn -- the vector, in hex
        or      cx, cx
        jnz     short pa_vec_eq          ; jcxz has no near form on an 8086
        jmp     near pa_more
pa_vec_eq:
        cmp     byte [si], '='
        je      short pa_vec_go
        jmp     near pa_more
pa_vec_go:
        inc     si
        dec     cx
        xor     bx, bx
pa_vec_d:
        jcxz    pa_vec_set
        mov     al, [si]
        call    hexval
        jc      short pa_vec_set
        inc     si
        dec     cx
        push    cx
        mov     cl, 4
        shl     bx, cl
        pop     cx
        xor     ah, ah
        add     bx, ax
        jmp     short pa_vec_d
pa_vec_set:
        or      bx, bx
        jne     short pa_vec_store
        jmp     near pa_more
pa_vec_store:
        mov     [our_vec], bl
        jmp     near pa_more

pa_base:
        xor     bx, bx
pa_base_d:
        jcxz    pa_base_set
        mov     al, [si]
        call    hexval
        jc      short pa_base_set
        inc     si
        dec     cx
        push    cx
        mov     cl, 4
        shl     bx, cl
        pop     cx
        xor     ah, ah
        add     bx, ax
        jmp     short pa_base_d
pa_base_set:
        or      bx, bx
        je      short pa_base_out
        mov     [io_dat], bx
        inc     bx
        mov     [io_cmd], bx
pa_base_out:
        jmp     near pa_more

; --------------------------------------------------------------------------
; Is there a packet driver at vector BL?  The signature sits three bytes
; into the handler, which is the whole discovery mechanism the standard
; defines.  Returns CF set if one is there.
; --------------------------------------------------------------------------
vec_has_pkt:
        push    es
        push    ds
        push    si
        push    di
        xor     ax, ax
        mov     es, ax
        mov     al, bl
        xor     ah, ah
        shl     ax, 1
        shl     ax, 1
        mov     di, ax
        mov     ax, [es:di]              ; offset
        mov     dx, [es:di+2]            ; segment
        mov     bx, ax
        or      bx, dx
        je      short vhp_no             ; 0000:0000 is not a driver
        mov     ds, dx
        mov     si, ax
        add     si, 3
        push    cs
        pop     es
        mov     di, sig_pkt
        mov     cx, 8
        repe    cmpsb
        jne     short vhp_no
        pop     di
        pop     si
        pop     ds
        pop     es
        stc
        ret
vhp_no:
        pop     di
        pop     si
        pop     ds
        pop     es
        clc
        ret

sig_pkt:    db 'PKT DRVR'

; --------------------------------------------------------------------------
; Find a resident copy of ourselves.
;
; By looking at the one vector we would have installed on, and nowhere
; else.  A previous version walked the DOS MCB chain instead, which is how
; TSRs traditionally find themselves and is a bad trade here: it needs an
; undocumented DOS call, it reads structures this program does not own, and
; a walk that loses its place does not fail -- it loops, inside a program
; that has not installed anything yet and cannot be talked out of it.  It
; hung the machine twice.
;
; There is nothing to walk for.  If a copy is resident then our vector
; points at it, so the question is answered by one indirection: does the
; segment behind that vector carry our signature at 0103?  Constant time,
; no undocumented anything, and it cannot loop.
; --------------------------------------------------------------------------
res_seg:    dw 0

find_resident:
        push    es
        push    ds
        push    si
        push    di
        push    bx

        mov     word [cs:res_seg], 0
        xor     ax, ax
        mov     es, ax
        mov     al, [cs:our_vec]
        xor     ah, ah
        shl     ax, 1
        shl     ax, 1
        mov     bx, ax
        mov     ax, [es:bx+2]            ; the segment behind the vector
        or      ax, ax
        je      short fr_none            ; nothing there at all

        mov     ds, ax
        mov     si, SIG_OFS
        push    cs
        pop     es
        mov     di, sig_self
        mov     cx, 8
        repe    cmpsb
        jne     short fr_none
        mov     [cs:res_seg], ds         ; that is us
fr_none:
        pop     bx
        pop     di
        pop     si
        pop     ds
        pop     es
        mov     ax, [cs:res_seg]
        ret

sig_self:   db 'AXPKT001'

; ==========================================================================
; INIT
; ==========================================================================
init:
        cld
        call    parse_args
        mov     dx, msg_prog
        call    puts
        mov     dx, ver_str
        call    puts
        mov     dx, msg_by
        call    puts

        cmp     byte [op_help], 0
        je      short init_nohelp
        mov     dx, msg_help
        call    puts
        jmp     near quit
init_nohelp:

        call    find_resident
        mov     al, 'a'
        call    mark
        cmp     byte [op_status], 0
        je      short init_nostat
        jmp     near do_status
init_nostat:
        cmp     byte [op_unload], 0
        je      short init_nounload
        jmp     near do_unload
init_nounload:

        cmp     word [res_seg], 0
        je      short init_fresh
        mov     dx, msg_already
        call    puts
        mov     al, 1
        jmp     near die

init_fresh:
        ; ---- the two refusals.  Neither can be overridden, because there
        ; is no legitimate reason to want either and the cost of being
        ; wrong is a trip to the machine. ----
        cmp     byte [our_vec], 0x60
        jne     short init_not60
        mov     dx, msg_no60
        call    puts
        mov     al, 4
        jmp     near die
init_not60:
        mov     bl, [our_vec]
        call    vec_has_pkt
        jnc     short init_vecfree
        mov     dx, msg_vectaken
        call    puts
        mov     al, [our_vec]
        call    puthex
        mov     dx, msg_vectaken2
        call    puts
        mov     al, 5
        jmp     near die
init_vecfree:
        mov     al, 'b'
        call    mark

        ; ---- is the chip there ----
        mov     al, CMD_CHECK_EXIST
        call    ch_cmd
        mov     al, 0x55
        call    ch_wr
        call    ch_rd
        cmp     al, 0xAA
        je      short init_chip
        mov     dx, msg_nochip
        call    puts
        mov     al, 1
        jmp     near die
init_chip:
        mov     byte [touched], 1
        mov     al, 'c'
        call    mark

        ; ---- who are we ----
        call    read_mac
        jnc     short init_gotmac
        mov     dx, msg_nomac
        call    puts
        mov     al, 6
        jmp     near die
init_gotmac:
        mov     al, 'd'
        call    mark

        mov     dx, msg_mac
        call    puts
        mov     cx, 6
        mov     si, mac
init_macl:
        lodsb
        call    puthex
        cmp     cx, 1
        je      short init_macskip
        mov     al, ':'
        call    putc
init_macskip:
        loop    init_macl
        call    crlf

        cmp     byte [op_test], 0
        jne     short __ii
        jmp     near init_install
__ii:
        mov     dx, msg_testonly
        call    puts
        jmp     near quit
init_install:

        ; ---- hook the vector, and INT 08h for the polling ----
        push    ds
        xor     ax, ax
        mov     ds, ax
        mov     al, [cs:our_vec]
        xor     ah, ah
        shl     ax, 1
        shl     ax, 1
        mov     si, ax
        mov     ax, [si]
        mov     [cs:old_vec], ax
        mov     ax, [si+2]
        mov     [cs:old_vec+2], ax
        cli
        mov     word [si], pkt_entry
        mov     [si+2], cs
        ; INT 08h -- /N leaves the timer alone, which installs a driver
        ; that can be interrogated but never collects a packet.  It exists
        ; to tell an install fault from an ISR fault, because from the
        ; outside both look identical: a machine that stops answering.
        cmp     byte [cs:op_nopoll], 0
        je      short __in8
        jmp     near init_no08
__in8:
        mov     ax, [0x08*4]
        mov     [cs:old08], ax
        mov     ax, [0x08*4+2]
        mov     [cs:old08+2], ax
        mov     word [0x08*4], isr08
        mov     [0x08*4+2], cs
init_no08:
        sti
        pop     ds

        mov     dx, msg_installed
        call    puts
        mov     al, [our_vec]
        call    puthex
        mov     dx, msg_installed2
        call    puts

        ; ---- go resident ----
        mov     dx, (resident_end - start + 0x100 + 15) >> 4
        mov     ax, 0x3100
        int     0x21

; ==========================================================================
; /S
; ==========================================================================
do_status:
        cmp     word [res_seg], 0
        jne     short stat_have
        mov     dx, msg_notres
        call    puts
        mov     al, 1
        jmp     near die
stat_have:
        mov     dx, msg_isres
        call    puts
        push    ds
        mov     ds, [cs:res_seg]
        mov     dx, ver_str
        call    puts
        pop     ds
        call    crlf

        mov     es, [res_seg]

        mov     dx, msg_s_vec
        call    puts
        mov     al, [es:our_vec]
        call    puthex
        call    crlf

        mov     dx, msg_s_base
        call    puts
        mov     ax, [es:io_dat]
        call    puthexw
        call    crlf

        mov     dx, msg_s_mac
        call    puts
        mov     cx, 6
        xor     si, si
stat_macl:
        mov     al, [es:si+mac]
        call    puthex
        cmp     cx, 1
        je      short stat_macskip
        mov     al, ':'
        call    putc
stat_macskip:
        inc     si
        loop    stat_macl
        call    crlf

        mov     dx, msg_s_handles
        call    puts
        mov     al, [es:n_handles]
        xor     ah, ah
        call    putdecw
        call    crlf

        mov     dx, msg_s_ticks
        call    puts
        mov     ax, [es:n_ticks]
        call    putdecw
        call    crlf

        mov     dx, msg_s_bursts
        call    puts
        mov     ax, [es:n_bursts]
        call    putdecw
        call    crlf

        mov     dx, msg_s_frames
        call    puts
        mov     ax, [es:n_frames]
        call    putdecw
        call    crlf

        mov     dx, msg_s_nohandle
        call    puts
        mov     ax, [es:n_nohandle]
        call    putdecw
        call    crlf

        mov     dx, msg_s_short
        call    puts
        mov     ax, [es:n_short]
        call    putdecw
        call    crlf

        mov     dx, msg_s_sent
        call    puts
        mov     ax, [es:st_out]
        call    putdecw
        call    crlf

        xor     al, al
        jmp     near die

; ==========================================================================
; /U
; ==========================================================================
do_unload:
        cmp     word [res_seg], 0
        jne     short unl_have
        mov     dx, msg_notres
        call    puts
        mov     al, 1
        jmp     near die
unl_have:
        mov     es, [res_seg]

        ; Refuse if anything hooked either vector after us.  Unhooking out
        ; of order leaves whatever came later pointing into memory that is
        ; about to be handed back, and the machine dies at a moment
        ; unrelated to anything visible.
        push    ds
        xor     ax, ax
        mov     ds, ax
        mov     al, [es:our_vec]
        xor     ah, ah
        shl     ax, 1
        shl     ax, 1
        mov     si, ax
        mov     ax, [si+2]
        pop     ds
        mov     bx, es
        cmp     ax, bx
        je      short unl_vecok
        mov     dx, msg_hooked
        call    puts
        mov     al, 7
        jmp     near die
unl_vecok:
        cmp     byte [es:op_nopoll], 0
        jne     short unl_08ok           ; never hooked it
        push    ds
        xor     ax, ax
        mov     ds, ax
        mov     ax, [0x08*4+2]
        pop     ds
        mov     bx, es
        cmp     ax, bx
        je      short unl_08ok
        mov     dx, msg_hooked08
        call    puts
        mov     al, 7
        jmp     near die
unl_08ok:

        ; Put both back, then release the block.
        push    ds
        xor     ax, ax
        mov     ds, ax
        mov     al, [es:our_vec]
        xor     ah, ah
        shl     ax, 1
        shl     ax, 1
        mov     si, ax
        cli
        mov     ax, [es:old_vec]
        mov     [si], ax
        mov     ax, [es:old_vec+2]
        mov     [si+2], ax
        cmp     byte [es:op_nopoll], 0
        jne     short unl_no08
        mov     ax, [es:old08]
        mov     [0x08*4], ax
        mov     ax, [es:old08+2]
        mov     [0x08*4+2], ax
unl_no08:
        sti
        pop     ds

        mov     ah, 0x49                 ; release the resident block
        int     0x21

        mov     dx, msg_unloaded
        call    puts
        xor     al, al
        jmp     near die

; Every exit that is not "went resident" comes through here.  If the chip
; was touched, reset it: a program that leaves shared hardware half-set-up
; breaks the NEXT program, which is a much worse thing to debug than
; failing honestly on the spot.
quit:
        xor     al, al
die:
        cmp     byte [cs:touched], 0
        je      short die_now
        push    ax
        mov     al, CMD_RESET_ALL
        call    ch_cmd
        ; The chip needs a moment after a reset before it will answer
        ; again, and the next program will start by talking to it.
        mov     cx, 0xFFFF
die_wait:
        push    dx
        mov     dx, 0x61
        in      al, dx
        pop     dx
        loop    die_wait
        pop     ax
die_now:
        mov     ah, 0x4C
        int     0x21

; ==========================================================================
; MESSAGES
; ==========================================================================
msg_prog:      db 'AXPKT $'
msg_by:        db ' -- StevenC', 13, 10, '$'

msg_help:
        db 13, 10
        db 'A packet driver for a USB Ethernet adapter on a CH375 card,', 13, 10
        db 'so mTCP and anything else speaking the Crynwr interface can', 13, 10
        db 'use it.  RUN AXPROBE FIRST -- it brings the adapter up.', 13, 10
        db 13, 10
        db '  AXPKT          load it at vector 65h', 13, 10
        db '  AXPKT /I=6A    ...at 6Ah instead', 13, 10
        db '  AXPKT /S       report what it is doing', 13, 10
        db '  AXPKT /U       unload', 13, 10
        db 13, 10
        db 'OTHER  @nnn CH375 I/O base in hex, default 260', 13, 10
        db '       /G   leave the PHY at gigabit    /V  trace', 13, 10
        db '       /T   check the adapter and STOP, installing nothing', 13, 10
        db '       /N   install but do not hook the timer: no packets are', 13, 10
        db '            collected, which tells an install fault from an', 13, 10
        db '            ISR one when both just look like a dead machine', 13, 10
        db 13, 10
        db 'VECTOR 60h IS REFUSED, and so is any vector already holding a', 13, 10
        db 'packet driver.  On this machine 60h is the network you are', 13, 10
        db 'reading this over; installing on top of it would take the box', 13, 10
        db 'off the air with no way back in.  PKTSCAN lists what is free.', 13, 10
        db 13, 10
        db 'DO NOT PUT THIS IN AUTOEXEC.BAT.  Loaded from the prompt, a', 13, 10
        db 'mistake costs a power cycle; loaded at boot, it costs a walk', 13, 10
        db 'to the machine.', 13, 10, '$'

msg_already:   db 'AXPKT is already loaded.  /U unloads it, /S reports.', 13, 10, '$'
msg_notres:    db 'AXPKT is not loaded.', 13, 10, '$'
msg_no60:
        db 'Refusing vector 60h.', 13, 10
        db 'That is where a packet driver normally lives, and on this', 13, 10
        db 'machine it is the network everything else depends on.  Pick', 13, 10
        db 'another with /I=nn; PKTSCAN lists the free ones.', 13, 10, '$'
msg_vectaken:  db 'Refusing vector $'
msg_vectaken2:
        db 'h: a packet driver is already there.', 13, 10
        db 'Two cannot share one.  PKTSCAN lists the free vectors.', 13, 10, '$'
msg_nochip:
        db 'No CH375 answers at that address.  USBSCAN finds the card.', 13, 10, '$'
msg_nomac:
        db 'The adapter did not return its MAC address.', 13, 10
        db 'Run AXPROBE first -- it brings the chip up, and this program', 13, 10
        db 'deliberately does not.', 13, 10, '$'
msg_mac:       db 'MAC address: $'
msg_testonly:
        db 'That is /T: everything up to reading the adapter worked, and', 13, 10
        db 'nothing was installed.  Drop /T to go resident.', 13, 10, '$'
msg_installed: db 'Resident at vector $'
msg_installed2:
        db 'h.  Point mTCP at it with PACKETINT in its', 13, 10
        db 'config -- and use a COPY of MTCP.CFG, not the one the working', 13, 10
        db 'network uses.', 13, 10, '$'
msg_unloaded:  db 'AXPKT unloaded.', 13, 10, '$'
msg_hooked:
        db 'Cannot unload: something hooked our vector after us.', 13, 10, '$'
msg_hooked08:
        db 'Cannot unload: something hooked INT 08h after us.', 13, 10, '$'

msg_isres:     db 'Loaded: AXPKT $'
msg_s_vec:     db '  vector=$'
msg_s_base:    db '  I/O base=$'
msg_s_mac:     db '  MAC=$'
msg_s_handles: db '  open handles=$'
msg_s_ticks:   db '  timer ticks=$'
msg_s_bursts:  db '  bursts collected=$'
msg_s_frames:  db '  frames delivered=$'
msg_s_nohandle:db '  frames nobody wanted=$'
msg_s_short:   db '  bursts that made no sense=$'
msg_s_sent:    db '  frames sent=$'
