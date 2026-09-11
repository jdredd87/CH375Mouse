@echo off
REM  CH375Video -- USB display adapters over a CH375, built into bin\
REM  StevenC -- https://github.com/jdredd87/CH375USBTools
REM  Public domain (the Unlicense); see LICENSE.
REM
REM    build.cmd            build only
REM    build.cmd probe      ...then identify the adapter on the DOS machine
REM    build.cmd read       ...then probe it WITHOUT writing anything to it
REM    build.cmd trace      ...then probe it narrating every control stage
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
REM  C:\dosbridgeDEV is the git repo and the one dosd runs from;
REM  C:\dosbridge is an older runtime copy.  Prefer DEV when it is there,
REM  and let DOSBRIDGE override both.
if "%DOSBRIDGE%"=="" if exist C:\dosbridgeDEV\dosctl.py set DOSBRIDGE=C:\dosbridgeDEV
if "%DOSBRIDGE%"=="" set DOSBRIDGE=C:\dosbridge
set TOOLS=%~dp0..\CH375USBTOOLS\src
if not exist bin mkdir bin

for %%T in (dlprobe) do (
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
if /I "%1"=="read"  goto runread
if /I "%1"=="trace" goto runtrace
echo Built.  "build.cmd probe" identifies whatever is plugged in.
exit /b 0

:runprobe
python "%DOSBRIDGE%\dosctl.py" run bin\DLPROBE.EXE --timeout 300
exit /b %ERRORLEVEL%

REM  /K holds back the channel unlock, which is the only write DLPROBE
REM  makes.  Use this one when the adapter's state must not be disturbed.
:runread
python "%DOSBRIDGE%\dosctl.py" run bin\DLPROBE.EXE /K --timeout 300
exit /b %ERRORLEVEL%

:runtrace
python "%DOSBRIDGE%\dosctl.py" run bin\DLPROBE.EXE /V /T /E=4 --timeout 300
exit /b %ERRORLEVEL%

:failed
echo.
echo BUILD FAILED
exit /b 1
