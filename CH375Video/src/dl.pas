unit dl;
{ DisplayLink over a CH375 -- the shared half.
  CH375Video, StevenC.  Public domain (the Unlicense).

  DLPROBE and DLTEST each grew their own copy of the bring-up and the
  command framing, and a third tool would have made three. This is that
  code once: open the adapter, set a mode, and get pixels into it.

  WHAT IS WORTH KNOWING BEFORE CHANGING ANY OF IT

  * Commands are a byte stream on the bulk OUT endpoint, each starting AF.
    A register write is "AF 20 <reg> <val>".

  * Most timing registers do NOT take the number you want. Registers 01
    through 15 take it pushed through a 16-bit LFSR; 0F and 17 take a
    plain big-endian word; 1B takes a byte-swapped one. Raw values give a
    dead screen and nothing to diagnose. From Linux's udlfb, which is the
    readable record of this protocol.

  * EVERY transfer must be padded with AF. The parser does not act on the
    final command until more bytes follow it, so an unpadded transfer
    silently drops its last command -- 256 pixels, which showed up as a
    strip of the previous picture surviving in the bottom-right corner.
    It reads as a drawing bug and is a framing one.

  * A bulk endpoint here is 64 bytes a packet and that is a USB limit, not
    a tunable. So throughput is transaction-bound: the only way to go
    faster is to SEND FEWER BYTES, which is what the RLE encoder and the
    dirty-rectangle helpers are for. CH375Net measured the same shape --
    inlining REP INSB there "moved 1 MB by 2 seconds in 73".

  DlBytes and DlPackets are kept so that claim stays measurable rather
  than becoming folklore. }

{$MODE OBJFPC}{$H-}
{$BOOLEVAL OFF}
{$ASMMODE INTEL}

interface

uses ch375;

type
  { Timings as Linux fb states them, because that is the form udlfb's
    register arithmetic is written against and translating twice is how
    sign errors get in. Margins are the porches; PixClk is picoseconds. }
  TDlTiming = record
    Name:   ShortString;
    XRes:   Word;
    YRes:   Word;
    LeftM:  Word;      { h back porch }
    RightM: Word;      { h front porch }
    HSync:  Word;
    UpperM: Word;      { v back porch }
    LowerM: Word;      { v front porch }
    VSync:  Word;
    PixClk: LongInt;   { picoseconds per pixel }
  end;

const
  DL_VID = $17E9;

  { DlOpen results, all <= 20 so they can be exit codes. }
  DL_OK      = 0;
  DL_NO_CHIP = 1;
  DL_OLD     = 2;
  DL_NOTHING = 3;
  DL_SILENT  = 4;
  DL_NODESC  = 5;
  DL_NOTDL   = 6;
  DL_REFUSED = 7;

  { WIDESCREEN, and what the clock cap does to it. 1280x720@60 needs
    74.25 MHz and even CVT reduced blanking wants 64 MHz, so 720p is not
    reachable on this adapter at any blanking -- the 40 MHz cap decides it,
    not the pixel count. 848x480@60 is the VESA 16:9 mode that does fit, at
    33.75 MHz, and 1024x576 does not (46.5 MHz).

    A modern 16:9 panel will usually letterbox or stretch 640x480 and
    800x600 quite happily, so those stay the dependable choices; 848x480
    is the one worth trying for a native-aspect picture. DLPROBE's
    intersection will say whether a given monitor lists it. }
  NDLMODES = 5;
  DlModes: array[0..NDLMODES - 1] of TDlTiming = (
    (Name: '640x480@60';  XRes: 640; YRes: 480;
     LeftM: 48;  RightM: 16; HSync: 96;
     UpperM: 33; LowerM: 10; VSync: 2;  PixClk: 39721),
    (Name: '640x480@75';  XRes: 640; YRes: 480;
     LeftM: 120; RightM: 16; HSync: 64;
     UpperM: 16; LowerM: 1;  VSync: 3;  PixClk: 31746),
    (Name: '800x600@56';  XRes: 800; YRes: 600;
     LeftM: 128; RightM: 24; HSync: 72;
     UpperM: 22; LowerM: 1;  VSync: 2;  PixClk: 27778),
    (Name: '800x600@60';  XRes: 800; YRes: 600;
     LeftM: 88;  RightM: 40; HSync: 128;
     UpperM: 23; LowerM: 1;  VSync: 4;  PixClk: 25000),
    { 16:9 at 33.75 MHz -- total 1088x517, which is 60.0 Hz exactly. }
    (Name: '848x480@60 (16:9)'; XRes: 848; YRes: 480;
     LeftM: 112; RightM: 16; HSync: 112;
     UpperM: 23; LowerM: 6;  VSync: 8;  PixClk: 29630));

var
  DlEpBulk:  Byte = 0;
  DlBytes:   LongInt = 0;    { payload bytes handed to the chip }
  DlPackets: LongInt = 0;    { bulk OUT transactions issued }
  DlNaks:    LongInt = 0;    { NAKs retried in software }
  DlPad:     LongInt = 0;    { of DlBytes, how much was AF padding }
  { Use ch375's EpOut instead of the inlined packet writer. Exists so the
    two can be measured against each other rather than argued about --
    DLBENCH /O turns it on. }
  DlSlow:    Boolean = False;

function  DlOpen: Integer;
function  DlWhy(Code: Integer): ShortString;
procedure DlZeroStats;

procedure DlEmit(B: Byte);
function  DlSend: Boolean;
procedure DlReg(R, V: Byte);
function  DlSetMode(const T: TDlTiming): Boolean;
function  DlBlank(On_: Boolean): Boolean;

{ 16bpp 5-6-5 from 8-bit components. }
function  DlRgb(R, G, B: Byte): Word;

{ A solid run of pixels at a byte address in the adapter's framebuffer. }
function  DlFillRun(Addr: LongInt; Colour: Word; Pixels: LongInt): Boolean;

{ A rectangle, which is just one run per row. }
function  DlFillRect(const T: TDlTiming; X, Y, W, H: Word;
                     Colour: Word): Boolean;

{ Arbitrary pixels, RLE-encoded -- the general primitive. P points at NPix
  16bpp values; Addr is where the first one goes. }
function  DlRleRun(Addr: LongInt; P: PWord; NPix: Word): Boolean;

{ Address of a pixel, for callers building their own runs. }
function  DlAddr(const T: TDlTiming; X, Y: Word): LongInt;

implementation

const
  DL_REQ_CHANNEL = $12;
  DL_CMDMAX      = 2048;
  { Flush this far short of the end: one RLE command can reach ~775 bytes
    in the worst case, and PadTail still has to fit after it. }
  DL_FLUSHAT     = 1100;

  ChanKey: array[0..15] of Byte = (
    $57, $CD, $DC, $A7, $1C, $88, $5E, $15,
    $60, $FE, $C6, $97, $16, $3D, $47, $F2);

var
  Cmd:    array[0..DL_CMDMAX - 1] of Byte;
  CmdLen: Word = 0;
  TogOut: Byte = $80;
  Cfg:    array[0..511] of Byte;
  CfgGot: Word = 0;

procedure DlZeroStats;
begin
  DlBytes := 0; DlPackets := 0; DlNaks := 0; DlPad := 0;
end;

function DlRgb(R, G, B: Byte): Word;
begin
  DlRgb := (Word(R and $F8) shl 8) or (Word(G and $FC) shl 3) or (B shr 3);
end;

function DlAddr(const T: TDlTiming; X, Y: Word): LongInt;
begin
  DlAddr := (LongInt(Y) * T.XRes + X) * 2;
end;

{ ------------------------------------------------------------ the stream }

procedure DlEmit(B: Byte);
begin
  if CmdLen < DL_CMDMAX then
  begin
    Cmd[CmdLen] := B;
    Inc(CmdLen);
  end;
end;

{ Load the chip's OUT buffer straight from the command buffer, as ONE
  assembler block with no procedure calls in it.

  This is the whole speed story on this path, and the benchmark is what
  found it rather than a guess. The first measurement was 72 packets a
  second, which is 13.9 ms for a 64-byte packet -- and a USB bulk
  transaction takes microseconds, so the time was never on the wire. It
  was 64 iterations of ch375's WrDat, each of which is three nested
  procedure calls: WrDat, OutB, and IoDelay's two InB. In a Large-model
  binary every one of those reloads a far pointer, and BENCH measures a
  procedure call on this machine at 46,501 a second. 64 x 3 of them is
  about 4 ms spent before a single byte reaches a port.

  Deliberately NOT using REP OUTSB. That is an 80186 instruction which
  this V30 has and a plain 8086 does not, so it would need a run-time gate
  and an 8086 fallback kept working beside it -- and the portable loop
  below already collapses the per-byte cost from three calls to three
  instructions. CLAUDE.md's rule applies: do not write a gated fast path
  when the gate costs more to maintain than the win buys. One path, runs
  everywhere, and the same code will be correct on the 486 this is
  eventually meant for.

  The two IN 61h reads are ch375's standard ISA settling delay and are
  kept where they matter -- after a COMMAND byte -- and dropped between
  payload bytes, which is what USBPKT's REP OUTSB already proved safe on
  this machine. }
procedure WrPacket(Ofs: Word; Len: Byte); assembler;
asm
    push  si
    mov   dx, [PortCmd]
    in    al, $61
    in    al, $61
    mov   al, $2B                  { CMD_WR_USB_DATA7 }
    out   dx, al
    in    al, $61
    in    al, $61
    mov   dx, [PortDat]
    mov   al, [Len]
    out   dx, al
    in    al, $61
    in    al, $61
    mov   cl, [Len]
    xor   ch, ch
    jcxz  @done
    lea   si, [Cmd]
    add   si, [Ofs]
    cld
@lp:
    lodsb
    out   dx, al
    loop  @lp
@done:
    pop   si
end;

{ A bulk OUT that retries its own NAKs, which is right for a data endpoint:
  a NAK there means "busy, ask again", and the data toggle only advances on
  success, so re-issuing the identical token is correct rather than merely
  harmless. The payload is re-loaded on a retry because the chip's buffer
  is not guaranteed to have survived the failed attempt. }
function SendPacket(Ofs: Word; Len: Byte): Boolean;
var
  R: Integer;
  Tries: Word;
begin
  SendPacket := False;
  for Tries := 1 to 600 do
  begin
    if DlSlow then
      R := EpOut(DlEpBulk, TogOut, Cmd[Ofs], Len)
    else
    begin
      WrPacket(Ofs, Len);
      WrCmd(CMD_SET_ENDP7);   WrDat(TogOut);
      WrCmd(CMD_ISSUE_TOKEN); WrDat((DlEpBulk shl 4) or PID_OUT);
      R := WaitInt(60);
      if R = INT_SUCCESS then TogOut := TogOut xor $40;
    end;
    Inc(DlPackets);
    if R = INT_SUCCESS then
    begin
      DlBytes := DlBytes + Len;
      SendPacket := True;
      Exit;
    end;
    if R = INT_RET_NAK then begin Inc(DlNaks); Continue; end;
    if R = INT_RET_STALL then ClrStall(DlEpBulk);
    Exit;
  end;
end;

{ Pad the tail with AF.  Not tidiness: the parser does not act on the final
  command until more bytes follow it, so without this the last command of
  every transfer is silently dropped.  AF is the byte every command starts
  with, so a run of them is filler the parser resynchronises on. }
procedure PadTail;
var I: Integer;
begin
  for I := 1 to 16 do begin DlEmit($AF); Inc(DlPad); end;
  while (CmdLen mod 64) <> 0 do begin DlEmit($AF); Inc(DlPad); end;
end;

{ Sent straight out of the command buffer at an offset -- there is no
  intermediate 64-byte copy, which was another 128 far-pointer array
  accesses per packet for nothing. }
function DlSend: Boolean;
var
  I: Word;
  N: Byte;
begin
  DlSend := True;
  if CmdLen = 0 then Exit;
  PadTail;
  I := 0;
  while I < CmdLen do
  begin
    if CmdLen - I < 64 then N := Byte(CmdLen - I) else N := 64;
    if not SendPacket(I, N) then
    begin
      DlSend := False;
      CmdLen := 0;
      Exit;
    end;
    Inc(I, N);
  end;
  CmdLen := 0;
end;

procedure DlReg(R, V: Byte);
begin
  DlEmit($AF); DlEmit($20); DlEmit(R); DlEmit(V);
end;

procedure Reg16(R: Byte; V: Word);          { high byte first }
begin
  DlReg(R, Hi(V)); DlReg(R + 1, Lo(V));
end;

procedure Reg16Sw(R: Byte; V: Word);        { udlfb's _16be: low first }
begin
  DlReg(R, Lo(V)); DlReg(R + 1, Hi(V));
end;

{ THE part that cannot be guessed.  Registers 01..15 want their value
  pushed through this LFSR rather than written as a number. }
function Lfsr16(V: Word): Word;
var
  Lv: LongInt;
  I:  Word;
begin
  Lv := $FFFF;
  for I := 1 to V do
    Lv := ((Lv shl 1)
           or (((Lv shr 15) xor (Lv shr 4) xor (Lv shr 2) xor (Lv shr 1))
               and 1)) and $FFFF;
  Lfsr16 := Word(Lv);
end;

procedure RegL16(R: Byte; V: Word);
begin
  Reg16(R, Lfsr16(V));
end;

{ ------------------------------------------------------------- the mode }

function DlSetMode(const T: TDlTiming): Boolean;
var
  Xds, Xde, Yds, Yde, Yec: Word;
  Fb: LongInt;
begin
  CmdLen := 0;

  DlReg($FF, $00);                      { lock the video registers }
  DlReg($00, $00);                      { colour depth: the 16bpp segment }
  DlReg($20, 0); DlReg($21, 0); DlReg($22, 0);      { 16bpp base = 0 }

  { The 8bpp segment is parked past the end of the 16bpp framebuffer so
    the two cannot overlap.  Nothing here draws through it. }
  Fb := LongInt(T.XRes) * T.YRes * 2;
  DlReg($26, Byte(Fb shr 16));
  DlReg($27, Byte(Fb shr 8));
  DlReg($28, Byte(Fb));

  Xds := T.LeftM + T.HSync;             RegL16($01, Xds);
  Xde := Xds + T.XRes;                  RegL16($03, Xde);
  Yds := T.UpperM + T.VSync;            RegL16($05, Yds);
  Yde := Yds + T.YRes;                  RegL16($07, Yde);
  RegL16($09, Xde + T.RightM - 1);
  RegL16($0B, 1);
  RegL16($0D, T.HSync + 1);
  Reg16 ($0F, T.XRes);
  Yec := T.YRes + T.UpperM + T.LowerM + T.VSync;
  RegL16($11, Yec);
  RegL16($13, 0);
  RegL16($15, T.VSync);
  Reg16 ($17, T.YRes);
  Reg16Sw($1B, Word(200000000 div T.PixClk));

  DlReg($1F, $00);                      { unblank }
  DlReg($FF, $FF);                      { and release the registers }

  DlSetMode := DlSend;
end;

function DlBlank(On_: Boolean): Boolean;
begin
  CmdLen := 0;
  DlReg($FF, $00);
  if On_ then DlReg($1F, $01) else DlReg($1F, $00);
  DlReg($FF, $FF);
  DlBlank := DlSend;
end;

{ ------------------------------------------------------------- the pixels }

{ A solid run.  This is why a full screen is affordable at all: 256
  identical pixels -- 512 bytes of framebuffer -- encode in TEN bytes.
  A run of exactly one carries NO repeat byte, which is a genuine shape
  difference rather than a count of zero. }
function DlFillRun(Addr: LongInt; Colour: Word; Pixels: LongInt): Boolean;
var N: Word;
begin
  DlFillRun := False;
  while Pixels > 0 do
  begin
    if Pixels >= 256 then N := 256 else N := Word(Pixels);
    if CmdLen > DL_FLUSHAT then
      if not DlSend then Exit;

    DlEmit($AF); DlEmit($6B);
    DlEmit(Byte(Addr shr 16)); DlEmit(Byte(Addr shr 8)); DlEmit(Byte(Addr));
    DlEmit(Byte(N and $FF));                   { 256 encodes as 0 }
    DlEmit(1);                                 { one literal pixel ... }
    DlEmit(Hi(Colour)); DlEmit(Lo(Colour));
    if N > 1 then DlEmit(Byte(N - 1));         { ... repeated N-1 times }

    Addr := Addr + LongInt(N) * 2;
    Pixels := Pixels - N;
  end;
  DlFillRun := True;
end;

function DlFillRect(const T: TDlTiming; X, Y, W, H: Word;
                    Colour: Word): Boolean;
var I: Word;
begin
  DlFillRect := False;
  for I := 0 to H - 1 do
    if not DlFillRun(DlAddr(T, X, Y + I), Colour, W) then Exit;
  DlFillRect := True;
end;

{ udlfb's compress_hline, faithfully: a mixed raw/repeat encoding over an
  arbitrary run of pixels.  This is what makes text and line art cheap --
  both are mostly background, which collapses into repeats -- and what
  leaves photographs expensive, since nothing in them repeats.

  The counts are patched in after the fact because neither is known until
  the run has been walked, which is why this works on buffer indices
  rather than the pointer arithmetic the C uses. }
function DlRleRun(Addr: LongInt; P: PWord; NPix: Word): Boolean;
var
  I, Stop:            Word;
  CmdCountAt, RawAt:  Word;
  CmdStart, RawStart: Word;
  RepStart:           Word;
  V:                  Word;
begin
  DlRleRun := False;
  I := 0;
  while I < NPix do
  begin
    if CmdLen > DL_FLUSHAT then
      if not DlSend then Exit;

    DlEmit($AF); DlEmit($6B);
    DlEmit(Byte(Addr shr 16)); DlEmit(Byte(Addr shr 8)); DlEmit(Byte(Addr));
    CmdCountAt := CmdLen; DlEmit(0);
    CmdStart := I;
    RawAt := CmdLen; DlEmit(0);
    RawStart := I;

    Stop := I + 256;
    if Stop > NPix then Stop := NPix;

    while I < Stop do
    begin
      RepStart := I;
      V := P[I];
      DlEmit(Hi(V)); DlEmit(Lo(V));
      Inc(I);
      if I >= Stop then Break;
      if P[I] <> V then Continue;

      { A repeat: close the raw count, skip the run, state its length,
        and open a fresh raw count after it. }
      Cmd[RawAt] := Byte((RepStart - RawStart + 1) and $FF);
      repeat
        Inc(I);
        if I >= Stop then Break;
      until P[I] <> V;
      DlEmit(Byte((I - RepStart - 1) and $FF));
      RawStart := I;
      RawAt := CmdLen; DlEmit(0);
    end;

    if I > RawStart then
      Cmd[RawAt] := Byte((I - RawStart) and $FF)
    else
      Dec(CmdLen);                  { the raw count opened and unused }

    Cmd[CmdCountAt] := Byte((I - CmdStart) and $FF);
    Addr := Addr + LongInt(I - CmdStart) * 2;
  end;
  DlRleRun := True;
end;

{ ------------------------------------------------------------- bring-up }

function DlWhy(Code: Integer): ShortString;
begin
  case Code of
    DL_OK:      DlWhy := 'ok';
    DL_NO_CHIP: DlWhy := 'no CH375 responds at that I/O address';
    DL_OLD:     DlWhy := 'CH375 firmware too old for host mode';
    DL_NOTHING: DlWhy := 'nothing attached to the card';
    DL_SILENT:  DlWhy := 'attached, but nothing answers on the bus';
    DL_NODESC:  DlWhy := 'the device stopped answering mid-enumeration';
    DL_NOTDL:   DlWhy := 'not a DisplayLink device';
    DL_REFUSED: DlWhy := 'the adapter refused the channel unlock';
  else
    DlWhy := 'unknown';
  end;
end;

{ A chip left wedged by an earlier program fails CHECK_EXIST, and BusUp
  gives up on that before it reaches its own ChipReset -- so the wedge is
  sticky across runs and reads as an empty slot.  Reset and ask again. }
function ChipThere: Boolean;
begin
  ChipThere := ChipHere(Base);
  if ChipThere then Exit;
  ChipReset;
  DelayMs(200);
  ChipThere := ChipHere(Base);
end;

function DlOpen: Integer;
var
  Rc, St, I: Integer;
  VID: Word;
  L: Byte;
begin
  if not ChipThere then begin DlOpen := DL_NO_CHIP; Exit; end;

  Rc := BusUp;
  if Rc <> BU_OK then
  begin
    case Rc of
      BU_OLD_CHIP: DlOpen := DL_OLD;
      BU_NOTHING:  DlOpen := DL_NOTHING;
      BU_NO_ANSWER: DlOpen := DL_SILENT;
    else
      DlOpen := DL_NODESC;
    end;
    Exit;
  end;

  VID := DevDesc[8] or (Word(DevDesc[9]) shl 8);
  if VID <> DL_VID then begin DlOpen := DL_NOTDL; Exit; end;

  St := CtrlIn($80, REQ_GET_DESCR, Word(DT_CONFIG) shl 8, 0,
               CfgWant, Cfg, SizeOf(Cfg), CfgGot);
  if (St <> INT_SUCCESS) or (CfgGot < 9) then
  begin
    DlOpen := DL_NODESC; Exit;
  end;

  { Nothing is assumed about the endpoint number: this adapter answers 01,
    another need not. }
  DlEpBulk := 0;
  I := 0;
  while I + 1 < CfgGot do
  begin
    L := Cfg[I];
    if L < 2 then Break;
    if (Cfg[I + 1] = DT_ENDPOINT) and (L >= 6) then
      if ((Cfg[I + 3] and $03) = $02) and ((Cfg[I + 2] and $80) = 0) then
        DlEpBulk := Cfg[I + 2] and $0F;
    Inc(I, L);
  end;
  if DlEpBulk = 0 then begin DlOpen := DL_NODESC; Exit; end;

  SetConfig(CfgDesc[5]);

  St := CtrlOut($40, DL_REQ_CHANNEL, 0, 0, ChanKey, 16);
  if St <> INT_SUCCESS then begin DlOpen := DL_REFUSED; Exit; end;

  { A data endpoint from here on, so NAKs are reported rather than
    absorbed in hardware for the whole timeout. }
  SetRetry($00);
  DlZeroStats;
  DlOpen := DL_OK;
end;

end.
