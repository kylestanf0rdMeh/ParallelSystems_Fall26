#!/usr/bin/env python3
#
#  Sweeps thread count and operator cost for both barrier implementations.
#  Writes results/*.csv, which is what the graphs are built from.
#

import os
import re
import sys
from subprocess import check_output

INPUTS = ["1k.txt", "8k.txt", "16k.txt"]
THREADS = list(range(2, 33, 2))
INFLECTION_LOOPS = [1, 2, 5, 10, 20, 50, 100, 200, 500, 1000, 2000, 5000]
REPEATS = 5


def run(inp, n_threads, n_loops, spin):
    cmd = "./bin/prefix_scan -o temp.txt -n {} -i tests/{} -l {}{}".format(
        n_threads, inp, n_loops, " -s" if spin else "")
    times = []
    for _ in range(REPEATS):
        out = check_output(cmd, shell=True).decode("ascii")
        times.append(int(re.search("time: (.*)", out).group(1)))
    # the box is shared, so the fastest run is the one least disturbed by other tenants
    return min(times)


def sweep_threads(n_loops, path):
    with open(path, "w") as f:
        f.write("input,barrier,sequential," + ",".join(str(t) for t in THREADS) + "\n")
        for inp in INPUTS:
            seq = run(inp, 0, n_loops, False)
            for spin in [False, True]:
                row = [run(inp, t, n_loops, spin) for t in THREADS]
                label = "spin" if spin else "pthread"
                f.write("{},{},{},{}\n".format(
                    inp, label, seq, ",".join(str(v) for v in row)))
                print(inp, label, "l={}".format(n_loops), "done")


def sweep_loops(path, n_threads):
    with open(path, "w") as f:
        f.write("input,loops,sequential,pthread,spin\n")
        for inp in INPUTS:
            for n_loops in INFLECTION_LOOPS:
                seq = run(inp, 0, n_loops, False)
                par = run(inp, n_threads, n_loops, False)
                spn = run(inp, n_threads, n_loops, True)
                f.write("{},{},{},{},{}\n".format(inp, n_loops, seq, par, spn))
                print(inp, "l={}".format(n_loops), seq, par, spn)


def main():
    os.makedirs("results", exist_ok=True)
    n_cores = os.cpu_count()
    print("cores:", n_cores)

    which = sys.argv[1] if len(sys.argv) > 1 else "all"

    if which in ("all", "threads"):
        sweep_threads(100000, "results/threads_l100000.csv")
        sweep_threads(10, "results/threads_l10.csv")
    if which in ("all", "inflection"):
        sweep_loops("results/inflection.csv", n_cores)


main()
