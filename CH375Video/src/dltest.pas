program dltest;
{ DLTEST -- set a video mode on a DisplayLink adapter over a CH375, put test
  patterns on the screen, and ask the person watching whether each appeared.
  CH375Video, StevenC.  Public domain (the Unlicense).

  DLPROBE identifies the adapter and reads the monitor. This one tries to
  make a picture, which is the first thing here that cannot be verified by
  reading a status byte: the only instrument that can tell us a pattern
  appeared is somebody looking at the screen.

    DLTEST [/P=260] [/M=n] [/W=secs] [/A=secs] [/N] [/Q] [/B] [/X=n] [/Y=n]

      /P=hex   I/O base, default 260
      /M=dec   mode: 0 = 640x480@60 (default), 1 = 640x480@75,
                     2 = 800x600@56, 3 = 800x600@60 (over the clock cap)
      /W=dec   seconds to hold each pattern before asking, default 3
      /A=dec   seconds to wait for an answer, default 10
      /N       do not ask anything -- just run the patterns, unattended
      /Q       no beep
      /B       blank the output again on the way out

  HOW THE ASKING WORKS, AND WHY IT IS ON STDERR

  A job's stdout is redirected into C:\WORK\OUT.TXT and reaches nobody
  until the job has finished, so a prompt written there would be read some
  minutes after the moment it was asking about. DOS 6.22 cannot redirect
  handle 2 at all -- normally a nuisance in this project -- so stderr lands
  on the machine's real screen, which is exactly where somebody watching
  it is looking. The prompt and the verdict go there; the full narration
  goes to stdout for the transcript.

  Each question beeps first, then waits a bounded number of seconds. No
  answer is recorded as "no answer" and the run moves on, because the two
  cases it cannot tell apart -- the pattern did not appear, and nobody was
  looking -- are both non-answers, and pretending otherwise would put a
  guess in the log. Every wait is bounded by the BIOS tick counter, so an
  unattended run finishes on its own rather than blocking a job forever.

  WHAT THE PROTOCOL NEEDS, AND THE ONE PART NOBODY WOULD GUESS

  Commands are a byte stream on the bulk OUT endpoint, each starting AF.
  A register write is "AF 20 <reg> <val>", the video registers are bracketed
  by a lock (FF=00) and an unlock (FF=FF), and blanking is register 1F.

  The part that is not guessable: most of the timing registers do NOT take
  the number you want. Registers 01 through 15 take that number pushed
  through a 16-bit LFSR -- the sequence in Lfsr16 below -- while 0F and 17
  take a plain big-endian word and 1B takes a byte-swapped one. Writing the
  raw values produces a dead screen and nothing to diagnose. This follows
  the Linux udlfb driver, which is the readable record of the protocol.

  Exit codes: 0 every pattern confirmed seen, 1 no chip, 2 chip too old,
              3 nothing attached, 4 attached but silent,
              5 device stopped answering, 6 not a DisplayLink device,
              7 the adapter refused the command stream,
              8 patterns were sent but NOT confirmed (asked and told no,
                or nobody answered) -- deliberately distinct from 0 }

{$MODE OBJFPC}{$H-}
{$ASMMODE INTEL}

uses ch375, chtool;

const
  VER = '1.0.0';

  DL_VID         = $17E9;
  DL_REQ_CHANNEL = $12;
  PIT_FREQ       = 1193180;

  { 16bpp 5-6-5. Chosen so the bands cannot be mistaken for a monitor's
    own blank screen or its "no signal" caption -- which is the failure a
    single solid colour would be ambiguous about. }
  NBANDS = 8;
  Bands: array[0..NBANDS - 1] of Word =
    ($F800, $07E0, $001F, $FFFF, $FFE0, $07FF, $F81F, $8410);
  BandNames: ShortString = 'red green blue white yellow cyan magenta grey';

  ChanKey: array[0..15] of Byte = (
    $57, $CD, $DC, $A7, $1C, $88, $5E, $15,
    $60, $FE, $C6, $97, $16, $3D, $47, $F2);

type
  { Timings as Linux fb states them, because that is the form udlfb's
    register arithmetic is written against and translating twice is how
    sign errors get in. Margins are the porches; PixClk is picoseconds. }
  TTiming = record
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
  NTIMINGS = 4;
  Timings: array[0..NTIMINGS - 1] of TTiming = (
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
     UpperM: 23; LowerM: 1;  VSync: 4;  PixClk: 25000));

var
  { Sized with headroom above the flush threshold, because PadTail appends
    to a buffer that is already at its fullest. }
  Cmd:      array[0..1279] of Byte;
  CmdLen:   Word = 0;
  TogOut:   Byte = $80;
  EpBulk:   Byte = 0;
  Cfg:      array[0..511] of Byte;
  CfgGot:   Word = 0;
  ModeIx:   Integer = 0;
  HoldSecs: Integer = 3;
  AskSecs:  Integer = 10;
  NoAsk:    Boolean = False;
  NoBeep:   Boolean = False;
  BlankOut: Boolean = False;
  Verbose:  Boolean = False;
  NSeen:    Integer = 0;
  NUnseen:  Integer = 0;
  NNoAns:   Integer = 0;
  HNudge:   Integer = 0;        { + moves the picture right, - moves it left }
  VNudge:   Integer = 0;        { + moves it down }

{ ------------------------------------------------------------- utilities }

procedure Narrate(const S: ShortString);
begin
  WriteLn(S);
end;

function Pad(const S: ShortString; N: Integer): ShortString;
var R: ShortString;
begin
  R := S;
  while Length(R) < N do R := R + ' ';
  Pad := R;
end;

function Dec1(V: LongInt): ShortString;
var S: ShortString;
begin
  Str(V, S); Dec1 := S;
end;

{ Everything that waits is measured against the BIOS tick counter at
  18.2 Hz, never a spin count -- a spin loop calibrated on this V30 means
  nothing on any other machine, and a wait that cannot expire is how a job
  turns into a hang that needs hands on the keyboard. }
procedure WaitTicks(N: LongInt);
var T0: LongInt;
begin
  T0 := Ticks;
  while True do
  begin
    if Ticks < T0 then Break;             { midnight rollover: give up }
    if Ticks - T0 >= N then Break;
  end;
end;

procedure WaitSecs(S: Integer);
begin
  WaitTicks((LongInt(S) * 182) div 10);
end;

procedure SpeakerOff;
begin
  OutB($61, InB($61) and $FC);
end;

{ Short, and on the way in to a question rather than after it -- the point
  is to move somebody's eyes to the screen before the prompt matters. }
procedure Attention;
var D: Word;
begin
  if NoBeep then Exit;
  D := Word(PIT_FREQ div 1000);
  OutB($43, $B6);
  OutB($42, Lo(D));
  OutB($42, Hi(D));
  OutB($61, InB($61) or 3);
  WaitTicks(3);
  SpeakerOff;
end;

function GetKey: Char; assembler;
asm
  mov ah, 0
  int 16h
end;

{ ------------------------------------------------- the command byte stream }

procedure Emit(B: Byte);
begin
  if CmdLen < SizeOf(Cmd) then
  begin
    Cmd[CmdLen] := B;
    Inc(CmdLen);
  end;
end;

{ A bulk OUT that retries its own NAKs, which is right for a data endpoint:
  a NAK there means "busy, ask again", and EpOut only advances the data
  toggle on success, so re-issuing the identical token is correct rather
  than merely harmless. The chip is left on SetRetry(00) so those NAKs are
  reported to us instead of being absorbed in hardware for the whole
  timeout -- the opposite of what enumeration wants. }
function BulkOut(const Buf; Len: Byte): Boolean;
var
  R: Integer;
  Tries: Word;
begin
  BulkOut := False;
  for Tries := 1 to 600 do
  begin
    R := EpOut(EpBulk, TogOut, Buf, Len);
    if R = INT_SUCCESS then begin BulkOut := True; Exit; end;
    if R = INT_RET_NAK then Continue;
    if R = INT_RET_STALL then ClrStall(EpBulk);
    Exit;
  end;
end;

{ Pad the tail of every transfer with AF, which udlfb also does and which
  is NOT tidiness.

  The command parser does not act on the final command until more bytes
  follow it, so without padding the LAST command of each transfer silently
  does nothing. That showed up as the last ~256 pixels of a fill keeping
  their previous colour -- which reads as a drawing bug, or an off-by-one
  in the address arithmetic, and is neither: it is a framing problem, and
  the address arithmetic was right all along.

  AF is the byte every command starts with, so a run of them is a safe
  filler the parser can resynchronise on. Sixteen, then out to a packet
  boundary -- enough to push the real last command through, without
  paying for a full-size transfer on every flush. }
procedure PadTail;
var I: Integer;
begin
  for I := 1 to 16 do Emit($AF);
  while (CmdLen mod 64) <> 0 do Emit($AF);
end;

{ Push the buffered commands out in 64-byte packets. DisplayLink parses a
  byte STREAM, so a command may straddle a packet boundary. }
function Send: Boolean;
var
  I: Word;
  N, J: Byte;
  Pk: array[0..63] of Byte;
begin
  Send := True;
  if CmdLen = 0 then Exit;
  PadTail;
  I := 0;
  while I < CmdLen do
  begin
    if CmdLen - I < 64 then N := Byte(CmdLen - I) else N := 64;
    for J := 0 to N - 1 do Pk[J] := Cmd[I + J];
    if not BulkOut(Pk, N) then
    begin
      Send := False;
      CmdLen := 0;
      Exit;
    end;
    Inc(I, N);
  end;
  CmdLen := 0;
end;

procedure Reg(R, V: Byte);
begin
  Emit($AF); Emit($20); Emit(R); Emit(V);
end;

{ Plain 16-bit: high byte to reg, low to reg+1. }
procedure Reg16(R: Byte; V: Word);
begin
  Reg(R, Hi(V)); Reg(R + 1, Lo(V));
end;

{ Byte-swapped 16-bit -- udlfb's set_register_16be, low byte first. }
procedure Reg16Sw(R: Byte; V: Word);
begin
  Reg(R, Lo(V)); Reg(R + 1, Hi(V));
end;

{ THE part that cannot be guessed. Most timing registers want their value
  pushed through this 16-bit LFSR rather than written as a number. Seeding
  0xFFFF and stepping it `V` times is not a checksum or an obfuscation we
  can skip: it is how the hardware reads the field. }
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

{ ---------------------------------------------------------- the video mode }

function SetVideoMode(const T: TTiming): Boolean;
var
  Xds, Xde, Yds, Yde, Yec: Word;
  Fb: LongInt;
begin
  CmdLen := 0;


  Reg($FF, $00);                        { lock the video registers }
  Reg($00, $00);                        { colour depth: the 16bpp segment }
  Reg($20, 0); Reg($21, 0); Reg($22, 0);        { 16bpp base = 0 }

  { The 8bpp segment is parked at the end of the 16bpp framebuffer so the
    two cannot overlap. Nothing here draws through it. }
  Fb := LongInt(T.XRes) * T.YRes * 2;
  Reg($26, Byte(Fb shr 16)); Reg($27, Byte(Fb shr 8)); Reg($28, Byte(Fb));

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

  Reg($1F, $00);                        { unblank }
  Reg($FF, $FF);                        { and release the registers }

  WriteLn('  ', CmdLen, ' command bytes: lock, depth, bases, timings',
          ' through the LFSR, unblank, unlock.');
  SetVideoMode := Send;
end;

{ ------------------------------------------------------------- the pixels }

{ A solid run, RLE-encoded, and this is the whole reason a full screen is
  affordable on this machine: 256 identical pixels -- 512 bytes of
  framebuffer -- encode in TEN bytes. Raw, the same screen would be 614400
  bytes, which at the 22 KB/s this chip manages is nearly half a minute.

  The encoding is "AF 6B <addr24> <pixels in this command> <raw count>
  <pixel> <repeat-1>". A run of one carries NO repeat byte, which is a
  genuine shape difference rather than a count of zero. }
function FillRun(Addr: LongInt; Colour: Word; Pixels: LongInt): Boolean;
var N: Word;
begin
  FillRun := False;
  while Pixels > 0 do
  begin
    if Pixels >= 256 then N := 256 else N := Word(Pixels);
    { Flush well short of the buffer end: PadTail still has to fit. }
    if CmdLen > 1000 then
      if not Send then Exit;

    Emit($AF); Emit($6B);
    Emit(Byte(Addr shr 16)); Emit(Byte(Addr shr 8)); Emit(Byte(Addr));
    Emit(Byte(N and $FF));                     { 256 encodes as 0 }
    Emit(1);                                   { one literal pixel ... }
    Emit(Hi(Colour)); Emit(Lo(Colour));
    if N > 1 then Emit(Byte(N - 1));           { ... repeated N-1 times }

    Addr := Addr + LongInt(N) * 2;
    Pixels := Pixels - N;
  end;
  FillRun := Send;
end;

function FillSolid(const T: TTiming; Colour: Word): Boolean;
begin
  FillSolid := FillRun(0, Colour, LongInt(T.XRes) * T.YRes);
end;

{ Horizontal bands, because they tile the framebuffer as contiguous runs
  and so cost almost nothing to encode -- vertical bars would break every
  line into eight separate runs for no extra diagnostic value. }
function FillBands(const T: TTiming): Boolean;
var
  I:    Integer;
  Rows: LongInt;
  Px:   LongInt;
begin
  FillBands := False;
  Rows := T.YRes div NBANDS;
  for I := 0 to NBANDS - 1 do
  begin
    Px := Rows * T.XRes;
    { the last band absorbs any rows that did not divide evenly }
    if I = NBANDS - 1 then
      Px := (LongInt(T.YRes) - Rows * (NBANDS - 1)) * T.XRes;
    if not FillRun(LongInt(I) * Rows * T.XRes * 2, Bands[I], Px) then Exit;
  end;
  FillBands := True;
end;

{ ------------------------------------------------------------- the asking }

{ Hold the pattern, then beep and ask -- bounded, and honest about a
  non-answer. Returns 'Y', 'N' or '?'. }
function AskSeen(const What: ShortString): Char;
var
  T0:    LongInt;
  Limit: LongInt;
  C:     Char;
begin
  WriteLn('  showing: ', What);
  WaitSecs(HoldSecs);

  if NoAsk then
  begin
    AskSeen := '?';
    Inc(NNoAns);
    WriteLn('  /N given -- not asked.');
    Exit;
  end;

  Attention;
  Write(ErrOutput, '>> ', What, ' -- SEEN IT?  Y/N  (',
        Dec1(AskSecs), 's) ');

  C := #0;
  T0 := Ticks;
  Limit := (LongInt(AskSecs) * 182) div 10;
  while True do
  begin
    if KeyWaiting then begin C := GetKey; Break; end;
    if Ticks < T0 then Break;                  { rollover }
    if Ticks - T0 >= Limit then Break;
  end;

  if (C = 'Y') or (C = 'y') then
  begin
    AskSeen := 'Y'; Inc(NSeen);
    WriteLn(ErrOutput, ' yes');
    WriteLn('  CONFIRMED SEEN.');
  end
  else if (C = 'N') or (C = 'n') then
  begin
    AskSeen := 'N'; Inc(NUnseen);
    WriteLn(ErrOutput, ' no');
    WriteLn('  reported NOT seen.');
  end
  else
  begin
    AskSeen := '?'; Inc(NNoAns);
    if C = #0 then
    begin
      WriteLn(ErrOutput, ' (no answer)');
      WriteLn('  NO ANSWER in ', AskSecs, 's -- which means either the');
      WriteLn('  pattern did not appear or nobody was watching.  Those');
      WriteLn('  are not distinguishable from here and are not guessed at.');
    end
    else
    begin
      WriteLn(ErrOutput, ' (not Y or N)');
      WriteLn('  answered with something other than Y or N -- taken as');
      WriteLn('  no answer rather than interpreted.');
    end;
  end;
end;

{ ------------------------------------------------------------------ main }

procedure Usage;
var I: Integer;
begin
  WriteLn('  DLTEST [/P=260] [/M=n] [/W=secs] [/A=secs] [/N] [/Q] [/B] [/X=n] [/Y=n]');
  WriteLn;
  WriteLn('    /P=hex  I/O base, default 260');
  WriteLn('    /M=dec  mode, default 0:');
  for I := 0 to NTIMINGS - 1 do
    WriteLn('              ', I, ' = ', Timings[I].Name);
  WriteLn('    /W=dec  seconds to hold each pattern, default 3');
  WriteLn('    /A=dec  seconds to wait for an answer, default 10');
  WriteLn('    /N      do not ask -- run the patterns unattended');
  WriteLn('    /Q      no beep');
  WriteLn('    /B      blank the output again on the way out');
  WriteLn('    /X=n    move the picture n pixels right (negative = left)');
  WriteLn('    /Y=n    move the picture n lines down (negative = up)');
  WriteLn;
  WriteLn('  A picture landing off-centre is USUALLY the monitor needing');
  WriteLn('  its own auto-adjust, not the timings.  Press that first --');
  WriteLn('  it is what fixed the DELL 1708FP here.  /X and /Y exist to');
  WriteLn('  prove where the fault is, and have no default.');
  HelpTail;
end;

function HexArg(const S: ShortString; From: Integer): Word;
var I: Integer; V: Word;
begin
  V := 0;
  for I := From to Length(S) do
    case UpCase(S[I]) of
      '0'..'9': V := V * 16 + (Ord(S[I]) - 48);
      'A'..'F': V := V * 16 + (Ord(UpCase(S[I])) - 55);
    end;
  HexArg := V;
end;

function DecArg(const S: ShortString; From: Integer): Integer;
var I, V: Integer;
begin
  V := 0;
  for I := From to Length(S) do
    if (S[I] >= '0') and (S[I] <= '9') then V := V * 10 + (Ord(S[I]) - 48);
  DecArg := V;
end;

{ The nudges have to accept a negative, which is the whole point of them --
  a picture sitting too far right needs to move left. }
function SignedArg(const S: ShortString; From: Integer): Integer;
var Neg: Boolean;
begin
  Neg := (From <= Length(S)) and (S[From] = '-');
  if Neg then Inc(From);
  if Neg then SignedArg := -DecArg(S, From)
         else SignedArg :=  DecArg(S, From);
end;

{ Leave the chip fit for the next program, and the speaker quiet. A token
  stranded in the chip makes the NEXT tool report "no CH375 at 0260" on a
  card that is plainly fitted, and a beep left gated leaves the machine
  screaming -- both cost somebody a walk to the machine. }
procedure Quieten;
begin
  SpeakerOff;
  WrCmd(CMD_ABORT_NAK);
  SetRetry($00);
end;

function ChipThere: Boolean;
begin
  ChipThere := ChipHere(Base);
  if ChipThere then Exit;
  WriteLn('CHECK_EXIST found nothing -- resetting and re-asking, because a');
  WriteLn('chip left mid-transaction by an earlier program fails this test');
  WriteLn('on a card that is fitted.');
  ChipReset;
  DelayMs(200);
  ChipThere := ChipHere(Base);
end;

var
  Rc, I, St: Integer;
  S:         ShortString;
  Got:       Word;
  VID:       Word;
  T:         TTiming;
  L, N:      Byte;

begin
  Banner('DLTEST', VER, 'DisplayLink video-output test');
  if HelpWanted then begin Usage; Halt(0); end;

  for I := 1 to ParamCount do
  begin
    S := ParamStr(I);
    if Length(S) < 2 then Continue;
    if (S[1] = '/') or (S[1] = '-') then
      case UpCase(S[2]) of
        'P': Base := HexArg(S, 4);
        'M': ModeIx := DecArg(S, 4);
        'W': HoldSecs := DecArg(S, 4);
        'A': AskSecs := DecArg(S, 4);
        'N': NoAsk := True;
        'Q': NoBeep := True;
        'B': BlankOut := True;
        'V': Verbose := True;
        'X': HNudge := SignedArg(S, 4);
        'Y': VNudge := SignedArg(S, 4);
      end;
  end;
  if (ModeIx < 0) or (ModeIx >= NTIMINGS) then ModeIx := 0;
  if HoldSecs < 0 then HoldSecs := 0;
  if AskSecs < 1 then AskSecs := 1;
  if Verbose then Trace := @Narrate;
  T := Timings[ModeIx];

  { Move the active region within the line and frame WITHOUT changing
    either total or the dot clock -- so it stays the same mode and only
    the picture's position inside it moves.  Whatever comes out of one
    porch goes into the other.

    This is a diagnostic knob, and it is deliberately NOT given a default.
    A picture landing off-centre on an analogue VGA input is usually the
    monitor needing its own auto-adjust, not the timings being wrong, and
    compensating in software for one monitor's un-adjusted position would
    bake this bench into the tool and be wrong everywhere else. Try the
    monitor's auto-adjust FIRST; use this to prove where the fault is. }
  if HNudge <> 0 then
  begin
    if (Integer(T.LeftM) + HNudge >= 0)
       and (Integer(T.RightM) - HNudge >= 0) then
    begin
      T.LeftM  := Word(Integer(T.LeftM) + HNudge);
      T.RightM := Word(Integer(T.RightM) - HNudge);
      WriteLn('h-nudge  ', HNudge, ' px: back porch ', T.LeftM,
              ', front porch ', T.RightM, ' (line total unchanged)');
    end
    else
      WriteLn('h-nudge  ', HNudge, ' REFUSED -- it would drive a porch',
              ' negative, which would corrupt the mode rather than move it.');
  end;
  if VNudge <> 0 then
  begin
    if (Integer(T.UpperM) + VNudge >= 0)
       and (Integer(T.LowerM) - VNudge >= 0) then
    begin
      T.UpperM := Word(Integer(T.UpperM) + VNudge);
      T.LowerM := Word(Integer(T.LowerM) - VNudge);
      WriteLn('v-nudge  ', VNudge, ' lines: back porch ', T.UpperM,
              ', front porch ', T.LowerM, ' (frame total unchanged)');
    end
    else
      WriteLn('v-nudge  ', VNudge, ' REFUSED -- it would drive a porch',
              ' negative.');
  end;

  WriteLn('I/O base ', Hex4(Base), 'h');
  WriteLn('mode     ', T.Name, '  (', T.XRes, 'x', T.YRes, ', ',
          LongInt(T.XRes) * T.YRes * 2, ' bytes a frame at 16bpp)');
  WriteLn;

  ExitProc := @Quieten;
  if not ChipThere then
  begin
    WriteLn(BusUpReason(BU_NO_CHIP));
    Halt(BU_NO_CHIP);
  end;

  Rc := BusUp;
  if Rc <> BU_OK then
  begin
    WriteLn(BusUpReason(Rc));
    if Rc >= BU_NOTHING then WhyNoAnswer;
    Halt(Rc);
  end;

  VID := DevDesc[8] or (Word(DevDesc[9]) shl 8);
  if VID <> DL_VID then
  begin
    WriteLn('idVendor ', Hex4(VID), ' is not DisplayLink -- refusing to send');
    WriteLn('a DisplayLink command stream to it.  Run DLPROBE first.');
    Halt(6);
  end;

  { The configuration, for the bulk endpoint number. Nothing is assumed
    about it: this adapter answers 01, another need not. }
  St := CtrlIn($80, REQ_GET_DESCR, Word(DT_CONFIG) shl 8, 0,
               CfgWant, Cfg, SizeOf(Cfg), CfgGot);
  if (St <> INT_SUCCESS) or (CfgGot < 9) then
  begin
    WriteLn('The configuration descriptor would not come back: ',
            StatusStr(St));
    Halt(5);
  end;
  I := 0;
  while I + 1 < CfgGot do
  begin
    L := Cfg[I];
    if L < 2 then Break;
    if (Cfg[I + 1] = DT_ENDPOINT) and (L >= 6) then
      if ((Cfg[I + 3] and $03) = $02) and ((Cfg[I + 2] and $80) = 0) then
        EpBulk := Cfg[I + 2] and $0F;
    Inc(I, L);
  end;
  if EpBulk = 0 then
  begin
    WriteLn('No bulk OUT endpoint in the configuration -- nothing to send to.');
    Halt(5);
  end;

  St := SetConfig(CfgDesc[5]);
  WriteLn('SET_CONFIGURATION ', CfgDesc[5], ' -> ', StatusStr(St));

  St := CtrlOut($40, DL_REQ_CHANNEL, 0, 0, ChanKey, 16);
  WriteLn('channel unlock      -> ', StatusStr(St));
  if St <> INT_SUCCESS then
  begin
    WriteLn;
    WriteLn('The adapter refused the unlock key, and it ignores rendering');
    WriteLn('commands until that succeeds -- so there is no point sending');
    WriteLn('any.  Stopping here rather than drawing into a void and');
    WriteLn('blaming the pattern.');
    Halt(7);
  end;
  WriteLn('bulk OUT endpoint    ', Hex2(EpBulk));

  { NAKs reported, not absorbed: this is a data endpoint from here on. }
  SetRetry($00);
  WriteLn;

  { ---- 1. the mode ---- }
  WriteLn('TEST 1 -- set the mode and unblank');
  if not SetVideoMode(T) then
  begin
    WriteLn('  the adapter stopped accepting the command stream.');
    Halt(7);
  end;
  WriteLn('  sent.  A monitor takes a second or two to sync.');
  WaitSecs(2);
  { Asked about the monitor LEAVING "no signal" rather than about "any
    picture", because at this point the framebuffer holds whatever was
    left in it and there is nothing specific to describe. The observable
    event is the monitor acquiring sync, and that is answerable. Note this
    question is also the redundant one: any later pattern being seen
    proves the mode was set, since nothing can appear without it. }
  AskSeen('mode ' + T.Name + ' -- monitor STOPPED saying "no signal"');

  { ---- 2. a solid fill ---- }
  WriteLn;
  WriteLn('TEST 2 -- solid red, whole screen');
  if not FillSolid(T, $F800) then
  begin
    WriteLn('  the adapter stopped accepting pixels.');
    Halt(7);
  end;
  AskSeen('solid RED filling the whole screen');

  { ---- 3. the bands ---- }
  WriteLn;
  WriteLn('TEST 3 -- ', NBANDS, ' horizontal colour bands');
  WriteLn('  top to bottom: ', BandNames);
  if not FillBands(T) then
  begin
    WriteLn('  the adapter stopped accepting pixels.');
    Halt(7);
  end;
  AskSeen(Dec1(NBANDS) + ' colour bands, red at the top');

  { ---- 4. blue, to settle the byte order ---- }
  WriteLn;
  WriteLn('TEST 4 -- solid blue');
  WriteLn('  This one is about BYTE ORDER, not about drawing.  If this');
  WriteLn('  comes out blue the 5-6-5 pixels are going out the right way');
  WriteLn('  round; if it is red or green they are byte-swapped, and the');
  WriteLn('  bands above would have looked plausible while being wrong.');
  if not FillSolid(T, $001F) then
  begin
    WriteLn('  the adapter stopped accepting pixels.');
    Halt(7);
  end;
  AskSeen('solid BLUE -- not red, not green');

  { ---- 5. the stale tail ---- }
  WriteLn;
  WriteLn('TEST 5 -- does the END of a fill actually land?');
  WriteLn('  White over blue, and the question is about the BOTTOM RIGHT');
  WriteLn('  corner only.  The command parser does not act on the last');
  WriteLn('  command of a transfer until more bytes follow it, so without');
  WriteLn('  AF padding the final command -- 256 pixels -- silently does');
  WriteLn('  nothing and the previous colour survives there.  That reads');
  WriteLn('  as a drawing bug and is a framing one, so it gets its own');
  WriteLn('  test rather than hiding inside "did you see white".');
  if not FillSolid(T, $FFFF) then
  begin
    WriteLn('  the adapter stopped accepting pixels.');
    Halt(7);
  end;
  AskSeen('ALL white -- no blue surviving in the bottom-right corner');

  if BlankOut then
  begin
    CmdLen := 0;
    Reg($FF, $00); Reg($1F, $01); Reg($FF, $FF);
    Send;
    WriteLn;
    WriteLn('Output blanked again (/B).');
  end;

  { ---- the tally ---- }
  WriteLn;
  WriteLn('================================================================');
  WriteLn('  confirmed seen : ', NSeen);
  WriteLn('  reported unseen: ', NUnseen);
  WriteLn('  no answer      : ', NNoAns);
  WriteLn('================================================================');
  if (NUnseen = 0) and (NNoAns = 0) then
  begin
    WriteLn('Every pattern was confirmed by somebody looking at it.  That is');
    WriteLn('the only instrument that can settle this, and it says the');
    WriteLn('adapter is displaying what it was told to.');
    Halt(0);
  end;
  WriteLn('NOT a clean pass.  Patterns were sent and the command stream was');
  WriteLn('accepted throughout -- so what is unproven is whether anything');
  WriteLn('reached the glass, and that is exactly what "no answer" leaves');
  WriteLn('open.  Re-run with somebody watching before reading anything');
  WriteLn('into it either way.');
  Halt(8);
end.
