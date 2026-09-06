program clkchk;
{ DOS clock check  --  CH375Mouse, StevenC

  USBMOUSE divides the PIT by eight so it can poll the mouse at 145 Hz, and
  forwards every eighth tick to the original INT 08h.  If that arithmetic
  were wrong the DOS clock would run eight times fast or eight times slow,
  and nothing else in the driver would look any different.

  So: wait until the DOS clock says N seconds have passed, and let the
  caller time the run from outside.  Real elapsed time equal to N means the
  chain is intact; N/8 or 8N means it is not.

      CLKCHK [seconds]        default 20                                  }

{$MODE OBJFPC}{$H-}

uses Dos;

function Now100: LongInt;
var H, M, S, C: Word;
begin
  GetTime(H, M, S, C);
  Now100 := LongInt(H) * 360000 + LongInt(M) * 6000 + LongInt(S) * 100 + C;
end;

var
  T0, T1, Want: LongInt;
  N, Code: Integer;
  H, M, S, C: Word;

begin
  N := 20;
  if ParamCount >= 1 then
  begin
    Val(ParamStr(1), N, Code);
    if (Code <> 0) or (N < 1) or (N > 120) then N := 20;
  end;
  Want := LongInt(N) * 100;

  GetTime(H, M, S, C);
  WriteLn('DOS clock now ', H, ':', M, ':', S, '.', C);
  WriteLn('waiting for the DOS clock to advance ', N, ' seconds');
  T0 := Now100;
  repeat
    T1 := Now100;
    if T1 < T0 then T0 := T1;          { midnight rollover }
  until (T1 - T0) >= Want;
  GetTime(H, M, S, C);
  WriteLn('DOS clock now ', H, ':', M, ':', S, '.', C);
  WriteLn('DOS says ', (T1 - T0) div 100, '.', (T1 - T0) mod 100,
          ' seconds elapsed');
  Halt(0);
end.
