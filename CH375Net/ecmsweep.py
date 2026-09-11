"""A soak test for a DOS packet driver: N x 10 MB, every byte verified.

Separate jobs rather than one long one, for three reasons: a corruption
event stops the sweep with the box still in the state that produced it;
each job returning is a heartbeat, so a wedge is obvious within minutes
rather than at the end; and nothing is lost if the bridge hiccups half way
through.

The driver's own error counters are read before and after, because a
counter moving is evidence even across rounds that all verify clean.

    python ecmsweep.py http://SERVER/download/10mb
    python ecmsweep.py http://SERVER/download/10mb --rounds 4

WHY 13 ROUNDS IS THE DEFAULT.  A clean run proves very little on its own.
Against a fault of one event per 44 MB -- which is what the AX88179 vendor
path measured -- the chance of seeing nothing is e^-(MB/44):

    16 MB clean   P = 0.70    says nothing at all
   130 MB clean   P = 0.052   evidence, at roughly the 95% level

Thirteen rounds is 130 MB. Fewer is fine as a smoke test; just do not write
the result up as an exclusion. The verdict at the end does that arithmetic
for whatever you actually ran, so the number cannot be quoted without it.

NOTHING ABOUT ONE BENCH IS BUILT IN.  The first version of this script
carried a hardcoded server address and log path, which makes it useless
anywhere else -- the same mistake ECMLINK made by compiling in its own IP
defaults. The URL is now required and everything else has a switch.
"""
import argparse
import math
import os
import re
import subprocess
import sys
import time

J = os.path.join

ap = argparse.ArgumentParser(
    description=__doc__,
    formatter_class=argparse.RawDescriptionHelpFormatter)
ap.add_argument("url",
                help="a 10 MB ramp file, e.g. http://SERVER/download/10mb")
ap.add_argument("--rounds", type=int, default=13,
                help="10 MB downloads to do (default 13, so ~130 MB)")
ap.add_argument("--dosctl",
                default=os.environ.get("DOSBRIDGE_DOSCTL",
                                       J("C:\\", "dosbridgeDEV", "dosctl.py")),
                help="path to the bridge's dosctl.py")
ap.add_argument("--mtcpcfg", default=J("C:\\", "CH375", "MTCPAX.CFG"),
                help="mTCP config ON THE DOS BOX naming the adapter to test")
ap.add_argument("--dest", default=J("C:\\", "WORK", "T10.BIN"),
                help="where on the DOS box to land each download")
ap.add_argument("--rampchk", default=J("C:\\", "CH375", "RAMPCHK.EXE"))
ap.add_argument("--htget", default=J("C:\\", "NETWORK", "MTCP", "HTGET.EXE"))
ap.add_argument("--elapsed", default=J("C:\\", "TOOLS", "ELAPSED.COM"))
ap.add_argument("--status", default=J("C:\\", "CH375", "USBPKT.COM"),
                help="driver to ask for counters, or '' to skip")
ap.add_argument("--log", default="sweep.log")
A = ap.parse_args()

MB_PER = 10485760 / (1024.0 * 1024.0)
EXPECT = 10485760


def say(msg):
    line = time.strftime("%H:%M:%S ") + msg
    print(line, flush=True)
    with open(A.log, "a", encoding="utf-8") as fh:
        fh.write(line + "\n")


def run(cmds, timeout):
    argv = [sys.executable, A.dosctl, "exec", "--timeout", str(timeout)]
    try:
        p = subprocess.run(argv + cmds, capture_output=True, text=True,
                           timeout=timeout + 120)
        return p.stdout + p.stderr
    except subprocess.TimeoutExpired:
        return "<<the bridge itself timed out>>"


COUNTERS = ("protocol=", "link=", "bursts collected", "frames delivered",
            "frames nobody wanted", "bursts that made no sense",
            "reads with an impossible length",
            "bursts too big for the buffer",
            "bursts whose frames did not tile",
            "frames past the frame region",
            "reads rescued by flipping the toggle", "frames sent",
            "longest poll")


def counters():
    if not A.status:
        return {}
    out = run(["%s /S" % A.status], 200)
    got = {}
    for line in out.splitlines():
        for key in COUNTERS:
            if key in line:
                got[key] = line.strip()
    return got


say("=" * 64)
say("%.0f MB sweep -- %d rounds of 10 MB from %s"
    % (A.rounds * MB_PER, A.rounds, A.url))
if A.rounds * MB_PER < 100:
    say("NOTE: under 100 MB, so a clean result is NOT an exclusion.")
    say("See the arithmetic in this script's header before quoting it.")
say("=" * 64)

before = counters()
for k in sorted(before):
    say("  start  %s" % before[k])

total_mb = 0.0
bad = 0
rnd = 0
for rnd in range(1, A.rounds + 1):
    out = run([
        "SET MTCPCFG=%s" % A.mtcpcfg,
        "IF EXIST %s DEL %s" % (A.dest, A.dest),
        "%s /S" % A.elapsed,
        "%s -o %s %s" % (A.htget, A.dest, A.url),
        "%s round" % A.elapsed,
        "%s %s" % (A.rampchk, A.dest),
    ], 1200)

    secs = None
    m = re.search(r"round\s+([\d.]+)s", out)
    if m:
        secs = float(m.group(1))
    m = re.search(r"size\s*:\s*(\d+)", out)
    size = int(m.group(1)) if m else 0
    m = re.search(r"mismatches\s*:\s*(\d+)", out)
    mism = int(m.group(1)) if m else None

    if size == EXPECT and mism == 0:
        total_mb += MB_PER
        rate = (size / 1024.0) / secs if secs else 0
        say("round %2d/%d  CLEAN  %.1fs  %.1f KB/s   running total %.0f MB"
            % (rnd, A.rounds, secs or 0, rate, total_mb))
        continue

    bad += 1
    say("round %2d/%d  *** NOT CLEAN ***  size=%s mismatches=%s"
        % (rnd, A.rounds, size, mism))
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

if bad:
    say("VERDICT: sweep did not complete clean -- see above.")
    sys.exit(1)

p = math.exp(-total_mb / 44.0)
say("VERDICT: %.0f MB clean, P = %.3f against a 1-event-per-44-MB fault."
    % (total_mb, p))
if p < 0.1:
    say("That is evidence at roughly the %.0f%% level. It is not proof."
        % ((1 - p) * 100))
else:
    say("That is NOT an exclusion -- it is the outcome you would most")
    say("likely see either way. Run more rounds before concluding.")
