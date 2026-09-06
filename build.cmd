@echo off
REM  CH375Mouse -- build everything into bin\
REM
REM    build.cmd            build only
REM    build.cmd test       ...then run the INT 33h and event-handler suites
REM                         on the DOS machine
REM    build.cmd diag       ...then run the CH375 diagnostic there
REM    build.cmd ps2        ...then run the PS/2 BIOS emulation test
REM    build.cmd demo       ...then drive the on-screen cursor for 25 seconds
REM    build.cmd click      ...then watch the button path for 30 seconds.
REM                         Click the mouse while it runs; it beeps at you.
REM
REM  NEEDS
REM    fpc    Free Pascal cross-compiling to MS-DOS real mode (-Tmsdos -Pi8086)
REM    nasm   ships with Free Pascal; both must be on PATH
REM
REM  The build needs nothing else.  The "test", "diag", "ps2", "demo" and
REM  "click" targets additionally need dosbridge to reach the DOS machine --
REM  set DOSBRIDGE if it is not in C:\dosbridge.
REM
REM  USBMOUSE.COM also assembles on the DOS machine itself, byte for byte
REM  identically, with the patched mininasm:
REM    MNASMFIX -O9 -f bin -o USBMOUSE.COM USBMOUSE.ASM
REM  -O9 matters; without it some jumps stay in their long form.

setlocal
cd /d "%~dp0"
if "%DOSBRIDGE%"=="" set DOSBRIDGE=C:\dosbridge
if not exist bin mkdir bin

echo --- USBMOUSE.COM
nasm -f bin src\usbmouse.asm -o bin\USBMOUSE.COM
if errorlevel 1 goto failed

for %%T in (chdiag mousetst evtest ps2test tickchk clkchk mdemo clicktst) do (
  echo --- %%T
  fpc -Tmsdos -Pi8086 -WmLarge -FEbin -FUbin src\%%T.pas >nul
  if errorlevel 1 goto failed
)
if exist bin\*.a   del /q bin\*.a
if exist bin\*.o   del /q bin\*.o
if exist bin\*.ppu del /q bin\*.ppu

echo.
dir /b bin
echo.

if /I "%1"=="test"  goto runtest
if /I "%1"=="diag"  goto rundiag
if /I "%1"=="ps2"   goto runps2
if /I "%1"=="demo"  goto rundemo
if /I "%1"=="click" goto runclick
echo Built.  "build.cmd test" runs the suites on the DOS machine.
exit /b 0

:runtest
call :push USBMOUSE.COM
call :push MOUSETST.EXE
call :push EVTEST.EXE
python "%DOSBRIDGE%\dosctl.py" exec "C:\WORK\USBMOUSE.COM" "C:\WORK\MOUSETST.EXE" "C:\WORK\EVTEST.EXE" "C:\WORK\USBMOUSE.COM /U"
exit /b %ERRORLEVEL%

:rundiag
python "%DOSBRIDGE%\dosctl.py" run bin\CHDIAG.EXE
exit /b %ERRORLEVEL%

:runps2
call :push USBMOUSE.COM
call :push PS2TEST.EXE
python "%DOSBRIDGE%\dosctl.py" exec "C:\WORK\USBMOUSE.COM /W" "C:\WORK\PS2TEST.EXE 8" "C:\WORK\USBMOUSE.COM /U"
exit /b %ERRORLEVEL%

:rundemo
call :push USBMOUSE.COM
call :push MDEMO.EXE
python "%DOSBRIDGE%\dosctl.py" exec "C:\WORK\USBMOUSE.COM" "C:\WORK\MDEMO.EXE 25" "C:\WORK\USBMOUSE.COM /U"
exit /b %ERRORLEVEL%

:runclick
call :push USBMOUSE.COM
call :push CLICKTST.EXE
echo.
echo Click the mouse while this runs -- it beeps when it starts watching.
python "%DOSBRIDGE%\dosctl.py" exec "C:\WORK\USBMOUSE.COM" "C:\WORK\CLICKTST.EXE 30" "C:\WORK\USBMOUSE.COM /U" --timeout 240
exit /b %ERRORLEVEL%

:push
python "%DOSBRIDGE%\dosctl.py" deploy bin\%1 C:\WORK
if errorlevel 1 exit /b 1
goto :eof

:failed
echo.
echo BUILD FAILED
exit /b 1
