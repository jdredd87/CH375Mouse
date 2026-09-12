unit daudio;
{ daudio -- the parts every CH375Audio tool needs, in one place.
  CH375Audio, StevenC.  Public domain (the Unlicense).

  Three things live here and they are the three where a hand-copied second
  version would be dangerous rather than merely untidy:

    * CHIP RECOVERY.  A program that polls an interrupt endpoint and exits
      while the endpoint is NAKing leaves a token stranded in the chip, and
      the next program's CHECK_EXIST then fails -- which reads as "no CH375
      at 0260" on a card that is plainly fitted.  CH375Video learned this
      the hard way and the cure is in two halves that have to agree: abort
      the NAK on the way out, and reset-and-re-ask on the way in.  Split
      across four programs, one of them would eventually have only half.

    * THE CONFIGURATION FETCH.  BusUp keeps only what its bring-up needed,
      which on a speaker is the nine-byte header.  Every tool here has to
      go and get the rest, in two stages, and a tool that forgets decodes
      a nine-byte descriptor and reports the device has no audio
      interfaces.  That is not a hypothetical: it is what the first run of
      DAPROBE did.

    * THE VERDICT ON PLAYBACK.  Stated once, from constants, so the four
      tools cannot drift into disagreeing about why it cannot work. }

{$MODE OBJFPC}{$H-}

interface

uses ch375;

const
  { Audio Class 1.0 }
  CLASS_AUDIO   = $01;
  CLASS_HID     = $03;
  AC_SUBCLASS   = $01;
  AS_SUBCLASS   = $02;
  CS_INTERFACE  = $24;
  CS_ENDPOINT   = $25;
  AC_FEATURE    = $06;

  { The fastest this project has ever driven a CH375, measured by DLBENCH
    on the 8086-class machine this collection is developed against.  It is
    a real measurement rather than a datasheet figure, which is why it is
    worth quoting at people who want to stream audio. }
  CH375_BYTES_PER_SEC = 19055;

type
  TBigCfg = array[0..1023] of Byte;

{ CHECK_EXIST, and if it fails, reset and ask again.  True if a chip is
  there.  Always use this rather than ChipHere: a wedged chip and an empty
  slot are the same answer otherwise. }
function ChipThere: Boolean;

{ Abort a NAKing transaction and drop the retry count.  Install as
  ExitProc so it runs on every path out, including a runtime error. }
procedure Quieten;

{ The whole configuration descriptor, in two fetches.  Returns True only
  if all of it arrived -- a short read is refused rather than decoded,
  because a partial topology and a device with no controls look identical
  and only one of them is worth reporting. }
function GetConfigFull(var Buf: TBigCfg; var Len: Word;
                       var Why: ShortString): Boolean;

implementation

function ChipThere: Boolean;
begin
  ChipThere := ChipHere(Base);
  if ChipThere then Exit;
  WriteLn('CHECK_EXIST found nothing -- resetting the chip and re-asking,');
  WriteLn('because a chip left mid-transaction by an earlier program');
  WriteLn('fails this test on a card that is fitted.');
  ChipReset;
  DelayMs(200);
  ChipThere := ChipHere(Base);
  if ChipThere then WriteLn('  ...answered on the second ask.');
end;

procedure Quieten;
begin
  WrCmd(CMD_ABORT_NAK);
  SetRetry($00);
end;

function GetConfigFull(var Buf: TBigCfg; var Len: Word;
                       var Why: ShortString): Boolean;
var
  R, Total: Integer;
  S: ShortString;
begin
  GetConfigFull := False;
  Why := '';
  R := GetDescr(DT_CONFIG, 0, 0, Buf, 9, Len);
  if Len < 9 then
  begin
    Why := 'cannot read the configuration header (' + StatusName(R) + ')';
    Exit;
  end;
  Total := Buf[2] or (Integer(Buf[3]) shl 8);
  if Total > SizeOf(Buf) then Total := SizeOf(Buf);
  R := GetDescr(DT_CONFIG, 0, 0, Buf, Total, Len);
  if Len < Word(Total) then
  begin
    Str(Len, S);
    Why := 'only ' + S + ' of ';
    Str(Total, S);
    Why := Why + S + ' bytes of the configuration descriptor arrived ('
           + StatusName(R) + '); refusing to decode a partial topology';
    Exit;
  end;
  GetConfigFull := True;
end;

end.
