program UsbVfy;

{ USBVFY -- verify the CH375 receive path with nothing else in it.

  CH375Net, StevenC.  Public domain (the Unlicense).

      USBVFY <sender-ip> [/P=nnnn] [/I=nn] [/C=path] [/S=secs] [/V]

  WHY THIS EXISTS

  The corruption hunt had reached the point where every layer above the
  driver was excluded by measurement -- the disk, the burst parser, the
  server, and finally mTCP and HTGET together across 165 MB of clean
  NE2000 -- leaving the CH375 read itself.  But every test so far had run
  through a whole stack to reach it: HTTP over mTCP, to a file, checked
  afterwards.  That is a long way round for a question about one chip, and
  it costs 45 minutes per expected event.

  There is no need for any of it.  FPC is right here, DOSBridge's own
  IPv4/UDP is a unit we can call, and the packet driver takes a vector.  So
  this listens for UDP datagrams whose payload is a known function of their
  position in the stream, checks every byte as it arrives, and reports the
  EXACT displacement of anything wrong.  No TCP, no mTCP, no file system,
  no checksum filtering anywhere -- our stack does not verify receive
  checksums, so whatever the chip hands up is what gets tested.

  Two things it buys beyond convenience:

    * about twice the bytes per minute.  A blasting sender needs no
      acknowledgement, so the box collects bursts as fast as it can poll --
      the driver's ceiling is 31 reads of 64 bytes a tick, near 36 KB/s,
      against 16.8 measured over HTTP.  Events arrive twice as often.
    * the payload is a 32-bit counter of the absolute stream position, so a
      displacement is read off the bytes directly rather than inferred
      modulo 256.  That is the one measurement the whole hypothesis turns
      on: -64 means the chip's 64-byte packet buffer, -320 means the 64 was
      a coincidence twice over.

  THE WIRE FORMAT, which mkblast.py on the Windows side produces

    bytes 0..3    datagram sequence number, little endian
    bytes 4..N    payload[i] = byte ((G mod 4)) of (G div 4)
                  where G = seq * PAYLOAD + (i - 4)

  Each datagram is self-describing, so loss costs nothing: a dropped one is
  simply not checked, and there is no ordering requirement at all. }

{$MODE OBJFPC}{$H-}

uses Net;

const
  VER      = '1.0.0';
  DEF_PORT = 9999;
  DEF_VEC  = $65;
  DEF_CFG  = 'C:\CH375\MTCPAX.CFG';
  DEF_SECS = 120;
  MAXDG    = 1400;
  HDR      = 4;              { the sequence number in front of the payload }
  MAXBAD   = 6;              { events reported in full before summarising }

var
  Sender  : TIP;
  Buf     : array[0..MAXDG - 1] of Byte;
  Port    : Word;
  Vec     : Byte;
  Cfg     : ShortString;
  Secs    : Word;
  Verbose : Boolean;
  A       : ShortString;
  I, J    : Integer;
  Got     : Word;
  Seq     : LongInt;
  Bytes   : LongInt;
  Datas   : LongInt;
  BadD    : LongInt;
  BadB    : LongInt;
  Shown   : Integer;
  Deadline: LongInt;
  G       : LongInt;
  Want    : Byte;
  FirstBad: Integer;
  SrcW    : LongInt;
  Al      : Integer;

procedure Usage;
begin
  WriteLn('USBVFY ', VER, ' -- check the CH375 receive path, nothing above it');
  WriteLn;
  WriteLn('  USBVFY <sender-ip> [/P=nnnn] [/I=nn] [/C=path] [/S=secs] [/V]');
  WriteLn;
  WriteLn('  /P=n   UDP port to listen on, default ', DEF_PORT);
  WriteLn('  /I=nn  packet driver vector in hex, default 65');
  WriteLn('  /S=n   seconds to listen, default ', DEF_SECS);
  WriteLn;
  WriteLn('Run mkblast.py on the sender first.  Every datagram carries its');
  WriteLn('own sequence number and a payload that is a function of absolute');
  WriteLn('stream position, so loss costs nothing and a displacement is');
  WriteLn('read straight off the bytes instead of inferred modulo 256.');
end;

{ The expected byte at absolute stream position G. }
function WantAt(G: LongInt): Byte;
var W: LongInt;
begin
  W := G shr 2;
  case Byte(G and 3) of
    0: WantAt := Byte(W and 255);
    1: WantAt := Byte((W shr 8) and 255);
    2: WantAt := Byte((W shr 16) and 255);
  else WantAt := Byte((W shr 24) and 255);
  end;
end;

function HexByte(S: ShortString; var B: Byte): Boolean;
var K, V, D: Integer;
begin
  HexByte := False; V := 0;
  if Length(S) = 0 then Exit;
  for K := 1 to Length(S) do
  begin
    case UpCase(S[K]) of
      '0'..'9': D := Ord(S[K]) - 48;
      'A'..'F': D := Ord(UpCase(S[K])) - 55;
    else Exit;
    end;
    V := V * 16 + D;
    if V > 255 then Exit;
  end;
  B := Byte(V); HexByte := True;
end;

function DecNum(S: ShortString): LongInt;
var K: Integer; V: LongInt;
begin
  V := 0;
  for K := 1 to Length(S) do
    if (S[K] >= '0') and (S[K] <= '9') then V := V * 10 + (Ord(S[K]) - 48);
  DecNum := V;
end;

begin
  Port := DEF_PORT; Vec := DEF_VEC; Cfg := DEF_CFG;
  Secs := DEF_SECS; Verbose := False;

  if ParamCount < 1 then begin Usage; Halt(2); end;
  if not ParseIP(ParamStr(1), Sender) then
  begin
    WriteLn('USBVFY: "', ParamStr(1), '" is not an IP address');
    Halt(2);
  end;

  for I := 2 to ParamCount do
  begin
    A := ParamStr(I);
    for J := 1 to Length(A) do A[J] := UpCase(A[J]);
    if (A = '-V') or (A = '/V') then Verbose := True
    else if Copy(A, 1, 3) = '/P=' then Port := Word(DecNum(Copy(A, 4, 9)))
    else if Copy(A, 1, 3) = '/S=' then Secs := Word(DecNum(Copy(A, 4, 9)))
    else if Copy(A, 1, 3) = '/I=' then
    begin
      if not HexByte(Copy(A, 4, 9), Vec) then
      begin WriteLn('USBVFY: /I= wants a hex vector'); Halt(2); end;
    end
    else if Copy(A, 1, 3) = '/C=' then
      Cfg := Copy(ParamStr(I), 4, Length(ParamStr(I)) - 3);
  end;

  { Same refusal as USBGET, same reason: 60h is the network this machine is
    administered over, and taking an IP handle there loses the box. }
  if Vec = $60 then
  begin
    WriteLn('USBVFY: vector 60h is the bridge''s own network.  Refused.');
    Halt(4);
  end;

  NetVecWant := Vec;
  NetCfgWant := Cfg;

  if not NetReadConfig then begin WriteLn('USBVFY: ', NetErr); Halt(2); end;
  if not NetOpen(Sender) then begin WriteLn('USBVFY: ', NetErr); Halt(2); end;

  WriteLn('USBVFY: vector ', Vec, '  addr ', IPStr(NetMyIP),
          '  port ', Port, '  for ', Secs, 's');
  WriteLn('  listening -- run the blaster now');

  Bytes := 0; Datas := 0; BadD := 0; BadB := 0; Shown := 0;
  Deadline := NetTicks + LongInt(Secs) * 18;

  while NetTicks < Deadline do
  begin
    if not NetUdpRecv(Port, Buf, MAXDG, Got, 18) then Continue;
    if Got < HDR + 4 then Continue;

    Seq := LongInt(Buf[0]) + LongInt(Buf[1]) * 256
         + LongInt(Buf[2]) * 65536 + LongInt(Buf[3]) * 16777216;
    Inc(Datas);
    Inc(Bytes, Got - HDR);

    FirstBad := -1;
    for I := HDR to Got - 1 do
    begin
      G := Seq * (MAXDG - HDR) + (I - HDR);
      Want := WantAt(G);
      if Buf[I] <> Want then
      begin
        Inc(BadB);
        if FirstBad < 0 then FirstBad := I;
      end;
    end;

    if FirstBad >= 0 then
    begin
      Inc(BadD);
      if Shown < MAXBAD then
      begin
        Inc(Shown);
        G := Seq * (MAXDG - HDR) + (FirstBad - HDR);
        WriteLn;
        WriteLn('  BAD datagram seq ', Seq, ' at payload offset ',
                FirstBad - HDR, '  (stream ', G, ')');

        { Decode the misplaced word.  Its index IS the position the data
          actually came from, so the displacement is exact -- which is the
          whole reason the payload is a counter and not a ramp. }
        Al := FirstBad;
        while ((Al - HDR + (Seq * (MAXDG - HDR))) and 3) <> 0 do Inc(Al);
        J := 0;
        while (Al + 3 <= Got - 1) and (J < 4) do
        begin
          SrcW := LongInt(Buf[Al]) + LongInt(Buf[Al + 1]) * 256
                + LongInt(Buf[Al + 2]) * 65536
                + LongInt(Buf[Al + 3]) * 16777216;
          G := Seq * (MAXDG - HDR) + (Al - HDR);
          WriteLn('    +', Al - FirstBad, ' came from ', SrcW * 4,
                  '  displacement ', SrcW * 4 - G);
          Inc(Al, 4); Inc(J);
        end;
      end;
    end;
  end;

  NetClose;

  WriteLn;
  WriteLn('  datagrams  : ', Datas, '  (', Bytes, ' payload bytes)');
  WriteLn('  bad        : ', BadD, ' datagram(s), ', BadB, ' byte(s)');
  if Verbose then
    WriteLn('  driver rx  : ', NetRxFrames, ' accepted, ', NetRxWrong,
            ' not ours, ', NetRxDrop, ' dropped');
  if Datas = 0 then
  begin
    WriteLn('  nothing arrived -- is the blaster running, and pointed here?');
    Halt(3);
  end;
  if BadD = 0 then
  begin
    WriteLn('  VERDICT: every byte of every datagram was correct.');
    Halt(0);
  end;
  WriteLn('  VERDICT: the receive path altered data.  Nothing above the');
  WriteLn('  driver is in this test, so the displacement above is the');
  WriteLn('  chip or the code reading it, and nothing else.');
  Halt(1);
end.
