"""130 MB over CDC-ECM, one 10 MB download at a time.

Thirteen separate jobs rather than one long one, for three reasons: a
corruption event stops the sweep with the box still in the state that
produced it; each job returning is a heartbeat, so a wedge is obvious
within minutes rather than at the end; and nothing is lost if the bridge
hiccups half way through.

The driver's own error counters are read every round, because a counter
moving is evidence even in a round that comes back byte-exact.
"""
import re
import subprocess
import sys
import time

DOSCTL = r"C:\dosbridgeDEV\dosctl.py"
URL = "http://192.168.50.46/download/10mb"
DEST = r"C:\WORK\T10.BIN"
ROUNDS = 13
MB_PER = 10485760 / (1024.0 * 1024.0)

LOG = (r"C:\Users\CPSTEV~1\AppData\Local\Temp\claude"
       r"\C--dosbridgeDEV\6aea47a4-080c-485a-bc58-ac8da2f3871a"
       r"\scratchpad\sweep.log")


def say(msg):
    line = time.strftime("%H:%M:%S ") + msg
    print(line, flush=True)
    with open(LOG, "a", encoding="utf-8") as fh:
        fh.write(line + "\n")


def run(cmds, timeout):
    argv = [sys.executable, DOSCTL, "exec", "--timeout", str(timeout)] + cmds
    try:
        p = subprocess.run(argv, capture_output=True, text=True,
                           timeout=timeout + 120)
        return p.stdout + p.stderr
    except subprocess.TimeoutExpired:
        return "<<the bridge itself timed out>>"


COUNTERS = ("bursts collected", "frames delivered", "frames nobody wanted",
            "bursts that made no sense", "reads with an impossible length",
            "bursts too big for the buffer", "bursts whose frames did not tile",
            "frames past the frame region",
            "reads rescued by flipping the toggle", "frames sent",
            "longest poll", "link=")


def counters():
    out = run([r"C:\CH375\USBPKT.COM /S"], 200)
    got = {}
    for line in out.splitlines():
        for key in COUNTERS:
            if key in line:
                got[key] = line.strip()
    return got


say("=" * 64)
say("130 MB sweep over CDC-ECM -- %d rounds of 10 MB" % ROUNDS)
say("A clean sweep at this size is a ~5%% outcome if the class path")
say("shared the vendor path's 1-event-per-44-MB fault.")
say("=" * 64)

before = counters()
for k in sorted(before):
    say("  start  %s" % before[k])

total_mb = 0.0
bad = 0
for rnd in range(1, ROUNDS + 1):
    out = run([
        "SET MTCPCFG=C:\\CH375\\MTCPAX.CFG",
        "IF EXIST %s DEL %s" % (DEST, DEST),
        r"C:\TOOLS\ELAPSED.COM /S",
        r"C:\NETWORK\MTCP\HTGET.EXE -o %s %s" % (DEST, URL),
        r"C:\TOOLS\ELAPSED.COM round",
        r"C:\CH375\RAMPCHK.EXE %s" % DEST,
    ], 1200)

    secs = None
    m = re.search(r"round\s+([\d.]+)s", out)
    if m:
        secs = float(m.group(1))
    m = re.search(r"size\s*:\s*(\d+)", out)
    size = int(m.group(1)) if m else 0
    m = re.search(r"mismatches\s*:\s*(\d+)", out)
    mism = int(m.group(1)) if m else None

    if size == 10485760 and mism == 0:
        total_mb += MB_PER
        rate = (size / 1024.0) / secs if secs else 0
        say("round %2d/%d  CLEAN  %.1fs  %.1f KB/s   running total %.0f MB"
            % (rnd, ROUNDS, secs or 0, rate, total_mb))
        continue

    bad += 1
    say("round %2d/%d  *** NOT CLEAN ***  size=%s mismatches=%s"
        % (rnd, ROUNDS, size, mism))
    say("---- full output ----")
    for line in out.splitlines():
        say("    " + line)
    say("---- end ----")
    say("STOPPING so the box is left in the state that produced this.")
    break

after = counters()
say("-" * 64)
for k in sorted(after):
    say("  end    %s" % after[k])
say("-" * 64)
say("clean: %.0f MB in %d round(s), %d bad round(s)" % (total_mb, rnd, bad))
if bad == 0 and total_mb >= 129:
    say("VERDICT: 130 MB clean. If the class path shared the vendor")
    say("path's fault rate this would happen about 5%% of the time,")
    say("so this IS evidence -- at roughly the 95%% level, not proof.")
else:
    say("VERDICT: sweep did not complete clean -- see above.")
