@echo off
REM  CH375Net -- USB Ethernet over a CH375, built into bin\
REM  StevenC -- https://github.com/jdredd87/CH375USBTools
REM  Public domain (the Unlicense); see LICENSE.
REM
REM    build.cmd            build only
REM    build.cmd probe      ...then bring the adapter up on the DOS machine
REM    build.cmd trace      ...then bring it up printing every register
REM    build.cmd giga       ...then bring it up WITHOUT forcing 10BASE-T
REM    build.cmd recv       ...then watch frames arrive, promiscuous
REM    build.cmd raw        ...then watch them without interpreting the
REM                         buffer at all, hex only
REM    build.cmd send       ...then ARP the router and wait to be answered
REM
REM  NEEDS
REM    fpc    Free Pascal cross-compiling to MS-DOS real mode (-Tmsdos -Pi8086)
REM
REM  The CH375 layer is ch375.pas and the banner/help convention is
REM  chtool.pas, both in ..\CH375USBTOOLS\src, found with -Fu.  Their .ppu
REM  files are compiled into THIS project's bin\, so the projects share
REM  source and never a compiled unit.
REM
REM  Every target that runs something on the DOS machine needs DOSBridge to
REM  reach it -- set DOSBRIDGE if it is not in C:\dosbridge.
REM      https://github.com/jdredd87/DOSBridge

setlocal
cd /d "%~dp0"
if "%DOSBRIDGE%"=="" set DOSBRIDGE=C:\dosbridge
set TOOLS=%~dp0..\CH375USBTOOLS\src
if not exist bin mkdir bin

echo --- AXPKT.COM
nasm -f bin -Isrc\ src\axpkt.asm -o bin\AXPKT.COM
if errorlevel 1 goto failed

for %%T in (netid axprobe axrecv axsend pktscan axnet) do (
  echo --- %%T
  fpc -Tmsdos -Pi8086 -WmLarge -Fu"%TOOLS%" -FEbin -FUbin src\%%T.pas >nul
  if errorlevel 1 goto failed
)
if exist bin\*.a   del /q bin\*.a
if exist bin\*.o   del /q bin\*.o
if exist bin\*.ppu del /q bin\*.ppu

echo.
dir /b bin
echo.

if /I "%1"=="probe" goto runprobe
if /I "%1"=="trace" goto runtrace
if /I "%1"=="giga"  goto rungiga
if /I "%1"=="recv"  goto runrecv
if /I "%1"=="raw"   goto runraw
if /I "%1"=="send"  goto runsend
echo Built.  "build.cmd probe" brings the adapter up on the DOS machine.
exit /b 0

:runprobe
python "%DOSBRIDGE%\dosctl.py" run bin\AXPROBE.EXE
exit /b %ERRORLEVEL%
:runtrace
python "%DOSBRIDGE%\dosctl.py" run bin\AXPROBE.EXE /V
exit /b %ERRORLEVEL%
:rungiga
python "%DOSBRIDGE%\dosctl.py" run bin\AXPROBE.EXE /G
exit /b %ERRORLEVEL%
:runrecv
python "%DOSBRIDGE%\dosctl.py" run bin\AXRECV.EXE /A /S=20
exit /b %ERRORLEVEL%
:runraw
python "%DOSBRIDGE%\dosctl.py" run bin\AXRECV.EXE /A /S=20 /N=3 /X /R
exit /b %ERRORLEVEL%
:runsend
python "%DOSBRIDGE%\dosctl.py" run bin\AXSEND.EXE
exit /b %ERRORLEVEL%

:failed
echo.
echo BUILD FAILED
exit /b 1
