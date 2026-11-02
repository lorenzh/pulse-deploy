#!/usr/bin/env python3
"""Time `pulse init --setup demo --yes` (Performance impact of the CLI spec).

Usage: measure-init.py <pulse binary> [runner label]
       measure-init.py --self-test

One warm-up run, then 11 timed runs, each in a fresh empty temp directory with stdin
/dev/null. The clock is time.perf_counter() around subprocess.run. The statistic is the
median, the 6th smallest of the 11 samples (no averaging), rounded to 1 ms, plus min and max.
Prints one Markdown line for the job summary. Never prints a file content.
"""

import os
import random
import shutil
import subprocess
import sys
import tempfile
import time

RUNS = 11


def stats(samples):
    """Return (median, min, max) of an odd number of samples; median is the middle value."""
    if len(samples) % 2 != 1:
        raise ValueError("need an odd number of samples")
    ordered = sorted(samples)
    return ordered[len(ordered) // 2], ordered[0], ordered[-1]


def one_run(binary):
    work = tempfile.mkdtemp(prefix="pulse-measure-")
    try:
        with open(os.devnull, "rb") as stdin:
            start = time.perf_counter()
            done = subprocess.run(
                [binary, "init", work, "--setup", "demo", "--yes"],
                stdin=stdin,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                check=False,
            )
            elapsed = (time.perf_counter() - start) * 1000.0
        if done.returncode != 0:
            sys.exit("measure-init: pulse init exited %d" % done.returncode)
        return elapsed
    finally:
        shutil.rmtree(work, ignore_errors=True)


def self_test():
    samples = list(range(120, 131))
    random.Random(529).shuffle(samples)
    got = stats(samples)
    if got != (125, 120, 130):
        sys.exit("measure-init: self-test failed: %r" % (got,))
    try:
        stats([1, 2])
    except ValueError:
        pass
    else:
        sys.exit("measure-init: self-test failed: even sample count accepted")
    print("measure-init: self-test passed (median 125, min 120, max 130)")


def main(argv):
    if argv[1:] == ["--self-test"]:
        self_test()
        return
    if len(argv) not in (2, 3):
        sys.exit(__doc__)
    binary = os.path.abspath(argv[1])
    label = argv[2] if len(argv) == 3 else "local"
    one_run(binary)
    samples = [one_run(binary) for _ in range(RUNS)]
    median, low, high = stats(samples)
    print(
        "| %s | pulse init --setup demo --yes | %d runs | median %d ms | min %d ms | max %d ms |"
        % (label, RUNS, round(median), round(low), round(high))
    )


if __name__ == "__main__":
    main(sys.argv)
