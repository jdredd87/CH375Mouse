@ECHO OFF
REM  NETTEST -- prove the whole stack, then put everything back.
REM
REM  USBPKT goes FIRST.  NETID and USBLINK enumerate the adapter and
REM  leave it configured, and a configured adapter will not answer a
REM  fresh enumeration -- so running either of them before USBPKT stops
REM  USBPKT loading.  They belong after the unload, not before the load.
ECHO ===== 1. load the packet driver (bring-up included) =====
C:\CH375\USBPKT.COM
C:\CH375\PKTSCAN.EXE
SET MTCPCFG=C:\CH375\MTCPAX.CFG
ECHO ===== 2. ping the gateway =====
C:\NETWORK\MTCP\PING.EXE -count 3 192.168.50.1
ECHO ===== 3. ping the internet =====
C:\NETWORK\MTCP\PING.EXE -count 3 8.8.8.8
ECHO ===== 4. DNS, by pinging a name =====
C:\NETWORK\MTCP\PING.EXE -count 2 example.com
ECHO ===== 5. fetch a web page =====
C:\NETWORK\MTCP\HTGET.EXE -o C:\CH375\EX.HTM http://example.com/
SET MTCPCFG=c:\network\mtcp\mtcp.cfg
ECHO ===== 6. driver counters =====
C:\CH375\USBPKT.COM /S
ECHO ===== 7. put it all back =====
C:\CH375\USBPKT.COM /U
C:\CH375\PKTSCAN.EXE
