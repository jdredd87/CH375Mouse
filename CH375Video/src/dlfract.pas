program dlfract;
{ DLFRACT -- compute a Mandelbrot set on the V30 and display it over USB.
  CH375Video, StevenC.  Public domain (the Unlicense).

    DLFRACT [/P=260] [/M=n] [/W=n] [/I=n] [/S=secs] [/R]

      /P=hex   I/O base, default 260
      /M=dec   video mode index, default 0 (640x480@60)
      /W=dec   COMPUTED width, default 160.  The picture is expanded to
               fill the mode, so this is detail, not size
      /I=dec   iteration limit, default 16
      /S=dec   seconds to hold the finished picture, default 5
      /R       draw the rows as they are computed, instead of computing
               the whole picture and then sending it

  WHY THIS IS HERE, AND WHAT IT MEASURES

  Every other tool in CH375Video is transfer-bound: the V30 has nothing
  much to do and the USB path is the whole cost. This one inverts that
  deliberately, and then TIMES BOTH HALVES SEPARATELY so the claim is
  measured rather than asserted.

  A Mandelbrot is the right load for it because the arithmetic is
  irreducible -- there is no encoding trick that makes the escape-time
  loop cheaper -- while the PICTURE is unusually kind to a run-length
  encoder, being made of large flat bands of equal iteration count.

  THE ARITHMETIC IS Q8 AND 16-BIT, WHICH IS THE WHOLE PERFORMANCE STORY.
  BENCH on this machine measures a 16-bit multiply at 58,640 a second and
  a 32-bit one at 10,920 -- 5.4x -- because FPC calls a software routine
  for LongInt. The inner loop needs three multiplies per iteration, so
  done in LongInt a 160x100 picture at 16 iterations would spend about
  70 seconds in the multiplier alone. MulQ8 below is a single 16x16->32
  IMUL and a shift across the register pair, which is what makes this
  finish in a useful time. CLAUDE.md records the same lesson from the
  dosbridge Mandelbrot: moving it from Q10 LongInt to Q8 with one IMUL
  was worth more than every other optimisation combined.

  Q8 means 1.0 is 256, and the escape radius of 2 squared is 4.0 = 1024.
  zr and zi stay inside +/-512, so their products fit the 16-bit result
  the shift produces.

  Exit codes: 0 ok, 9 out of heap, otherwise the DlOpen reason (all <= 20) }

{$MODE OBJFPC}{$H-}
{$BOOLEVAL OFF}
{$ASMMODE INTEL}

uses ch375, chtool, dl;

const
  VER = '1.0.0';
  MAXW = 320;                 { widest picture we will compute }
  MAXH = 200;

type
  TIter = array[0..MAXW * MAXH - 1] of Byte;
  PIter = ^TIter;
  TRow  = array[0..1023] of Word;

var
  T:       TDlTiming;
  ModeIx:  Integer = 0;
  CW:      Integer = 160;     { computed width  }
  CH_:     Integer = 100;     { computed height }
  MaxIt:   Integer = 16;
  Secs:    Integer = 5;
  AsYouGo: Boolean = False;
  Iter:    PIter;
  Row:     TRow;
  Pal:     array[0..31] of Word;

function Dec1(V: LongInt): ShortString;
var S: ShortString;
begin
  Str(V, S); Dec1 := S;
end;

{ (A*B) >> 8 as ONE 16x16->32 IMUL and a shift across DX:AX.

  FPC has no 16-bit fixed-point multiply, so writing this in Pascal as
  (LongInt(A) * B) shr 8 calls the 32-bit software multiply -- 10,920 a
  second against 58,640 for the 16-bit instruction. Three of these run per
  Mandelbrot iteration, so that difference is the difference between this
  tool finishing and this tool being abandoned.

  The shift is the classic trick: the result's low word is the high byte
  of AX joined to the low byte of DX. }
function MulQ8(A, B: Integer): Integer; assembler;
asm
    mov  ax, [A]
    imul word ptr [B]
    mov  al, ah
    mov  ah, dl
end;

procedure BuildPal;
var I: Integer;
begin
  { A ramp that stays legible on a capture card: dark blue through cyan
    and yellow to white, with the interior black. }
  for I := 0 to 31 do
    if I = 0 then Pal[I] := DlRgb(0, 0, 0)
    else if I < 6  then Pal[I] := DlRgb(0, 0, 60 + I * 30)
    else if I < 12 then Pal[I] := DlRgb(0, (I - 5) * 38, 255)
    else if I < 20 then Pal[I] := DlRgb((I - 11) * 30, 255, 255 - (I - 11) * 28)
    else if I < 27 then Pal[I] := DlRgb(255, 255, (I - 19) * 34)
    else Pal[I] := DlRgb(255, 255, 255);
end;

{ The escape-time loop, Q8 throughout.  1.0 is 256; the escape test is
  |z|^2 > 4.0, which is 1024. }
function Escape(Cr, Ci: Integer): Byte;
var
  Zr, Zi, Zr2, Zi2: Integer;
  N: Integer;
begin
  Zr := 0; Zi := 0;
  for N := 1 to MaxIt do
  begin
    Zr2 := MulQ8(Zr, Zr);
    Zi2 := MulQ8(Zi, Zi);
    if Zr2 + Zi2 > 1024 then
    begin
      Escape := Byte(N);
      Exit;
    end;
    Zi := MulQ8(Zr, Zi) * 2 + Ci;
    Zr := Zr2 - Zi2 + Cr;
  end;
  Escape := 0;                        { never escaped: inside the set }
end;

{ One computed row, expanded to fill the mode's width and sent as however
  many scanlines that row is worth.  Adjacent expanded pixels are
  identical, so the encoder collapses each into one run -- which is why a
  low computed width costs almost nothing extra to display large. }
function SendRow(Cy: Integer): Boolean;
var
  X, I, Sc, BW, BH, Y0: Integer;
  C: Word;
begin
  SendRow := False;
  BW := T.XRes div CW;
  BH := T.YRes div CH_;
  if BW < 1 then BW := 1;
  if BH < 1 then BH := 1;

  for X := 0 to CW - 1 do
  begin
    C := Pal[Iter^[Cy * CW + X] and 31];
    for I := 0 to BW - 1 do
      if X * BW + I < SizeOf(Row) div 2 then Row[X * BW + I] := C;
  end;

  Y0 := Cy * BH;
  for Sc := 0 to BH - 1 do
  begin
    if Y0 + Sc >= T.YRes then Break;
    if not DlRleRun(DlAddr(T, 0, Word(Y0 + Sc)), @Row[0],
                    Word(CW * BW)) then Exit;
  end;
  SendRow := True;
end;

{ ------------------------------------------------------------------ main }

procedure Usage;
var I: Integer;
begin
  WriteLn('  DLFRACT [/P=260] [/M=n] [/W=n] [/I=n] [/S=secs] [/R]');
  WriteLn;
  WriteLn('    /W=dec  computed width, default 160 (detail, not size)');
  WriteLn('    /I=dec  iteration limit, default 16');
  WriteLn('    /S=dec  seconds to hold the picture, default 5');
  WriteLn('    /R      draw rows as they are computed');
  WriteLn('    /M=dec  mode, default 0:');
  for I := 0 to NDLMODES - 1 do
    WriteLn('              ', I, ' = ', DlModes[I].Name);
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

procedure Quieten;
begin
  WrCmd(CMD_ABORT_NAK);
  SetRetry($00);
end;

var
  I, Rc, X, Y: Integer;
  S:           ShortString;
  Cr, Ci:      Integer;
  X0, X1, Y0, Y1: Integer;
  TComp, TSend, T0, TAll: LongInt;
  B0:          LongInt;

begin
  Banner('DLFRACT', VER, 'a Mandelbrot computed on an 8086, shown over USB');

  for I := 1 to ParamCount do
  begin
    S := ParamStr(I);
    if Length(S) < 2 then Continue;
    if (S[1] = '/') or (S[1] = '-') then
      case UpCase(S[2]) of
        'P': Base := HexArg(S, 4);
        'M': ModeIx := DecArg(S, 4);
        'W': CW := DecArg(S, 4);
        'I': MaxIt := DecArg(S, 4);
        'S': Secs := DecArg(S, 4);
        'R': AsYouGo := True;
      end;
  end;
  if HelpWanted then begin Usage; Halt(0); end;
  if (ModeIx < 0) or (ModeIx >= NDLMODES) then ModeIx := 0;
  if CW < 40 then CW := 40;
  if CW > MAXW then CW := MAXW;
  if MaxIt < 2 then MaxIt := 2;
  if MaxIt > 31 then MaxIt := 31;       { the palette has 32 entries }
  if Secs < 0 then Secs := 0;
  T := DlModes[ModeIx];

  { Keep the aspect roughly right for the mode rather than assuming 4:3. }
  CH_ := (CW * T.YRes) div T.XRes;
  if CH_ < 20 then CH_ := 20;
  if CH_ > MAXH then CH_ := MAXH;

  Iter := PIter(GetMem(LongInt(CW) * CH_));
  if Iter = nil then
  begin
    WriteLn('out of heap for a ', LongInt(CW) * CH_, '-byte iteration map');
    Halt(9);
  end;
  BuildPal;

  ExitProc := @Quieten;
  Rc := DlOpen;
  if Rc <> DL_OK then begin WriteLn(DlWhy(Rc)); Halt(Rc); end;

  WriteLn('mode      ', T.Name);
  WriteLn('computed  ', CW, ' x ', CH_, ', ', MaxIt, ' iterations max');
  WriteLn('shown as  ', (T.XRes div CW) * CW, ' x ',
          (T.YRes div CH_) * CH_, '  (', T.XRes div CW, 'x',
          T.YRes div CH_, ' blocks)');
  WriteLn;

  if not DlSetMode(T) then
  begin
    WriteLn('the adapter stopped accepting the command stream');
    Halt(DL_REFUSED);
  end;
  DlFillRun(0, DlRgb(0, 0, 0), LongInt(T.XRes) * T.YRes);
  DlSend;

  DlZeroStats;
  B0 := DlBytes;
  TAll := Ticks;
  TComp := 0;
  TSend := 0;

  { The classic view: real -2.2..0.8, imaginary -1.2..1.2, in Q8. }
  X0 := -563; X1 := 205;
  Y0 := -307; Y1 := 307;

  for Y := 0 to CH_ - 1 do
  begin
    T0 := Ticks;
    Ci := Y0 + (LongInt(Y1 - Y0) * Y) div CH_;
    for X := 0 to CW - 1 do
    begin
      Cr := X0 + (LongInt(X1 - X0) * X) div CW;
      Iter^[Y * CW + X] := Escape(Cr, Ci);
    end;
    TComp := TComp + (Ticks - T0);

    if AsYouGo then
    begin
      T0 := Ticks;
      if not SendRow(Y) then
      begin
        WriteLn('the adapter stopped accepting pixels at row ', Y);
        Halt(DL_REFUSED);
      end;
      TSend := TSend + (Ticks - T0);
    end;
  end;

  if not AsYouGo then
  begin
    T0 := Ticks;
    for Y := 0 to CH_ - 1 do
      if not SendRow(Y) then
      begin
        WriteLn('the adapter stopped accepting pixels at row ', Y);
        Halt(DL_REFUSED);
      end;
    TSend := TSend + (Ticks - T0);
  end;
  if not DlSend then WriteLn('final send failed');

  TAll := Ticks - TAll;
  if TAll < 1 then TAll := 1;

  WriteLn('compute   ', TComp, ' ticks  (', (TComp * 10) div 182, '.',
          ((TComp * 100) div 182) mod 10, ' s)');
  WriteLn('transfer  ', TSend, ' ticks  (', (TSend * 10) div 182, '.',
          ((TSend * 100) div 182) mod 10, ' s)');
  WriteLn('total     ', TAll, ' ticks  (', (TAll * 10) div 182, '.',
          ((TAll * 100) div 182) mod 10, ' s)');
  WriteLn('compute is ', (TComp * 100) div TAll, '% of it');
  WriteLn('bytes     ', DlBytes - B0, '  against ',
          LongInt(T.XRes) * T.YRes * 2, ' for the same area raw');
  WriteLn('packets   ', DlPackets);
  WriteLn('NAKs      ', DlNaks);
  WriteLn;
  WriteLn('Every other tool here is transfer-bound.  If compute is the');
  WriteLn('bigger number above, this one is not -- which is the point of');
  WriteLn('timing the two halves apart rather than quoting one total.');

  if Secs > 0 then
  begin
    T0 := Ticks;
    while True do
    begin
      if Ticks < T0 then Break;
      if Ticks - T0 >= (LongInt(Secs) * 182) div 10 then Break;
    end;
  end;
  Halt(0);
end.
