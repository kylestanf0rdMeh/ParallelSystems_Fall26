#!/usr/bin/env python3
#
#  Builds the report graphs from results/*.csv.
#

import csv
import os
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

OUT = "../report/plots"
COLORS = {"1k.txt": "tab:blue", "8k.txt": "tab:orange", "16k.txt": "tab:green"}


def read_threads(path):
    with open(path) as f:
        rows = list(csv.reader(f))
    threads = [int(t) for t in rows[0][3:]]
    data = {}
    for r in rows[1:]:
        data[(r[0], r[1])] = (int(r[2]), [int(v) for v in r[3:]])
    return threads, data


def plot_speedup(path, title, out_name, barriers, ideal=True):
    threads, data = read_threads(path)
    fig, ax = plt.subplots(figsize=(7, 4.5))

    for inp in COLORS:
        for barrier in barriers:
            seq, times = data[(inp, barrier)]
            label = inp if len(barriers) == 1 else "{} {}".format(inp, barrier)
            ax.plot(threads, [seq / t for t in times],
                    marker="o" if barrier == "pthread" else "s",
                    linestyle="-" if barrier == "pthread" else "--",
                    color=COLORS[inp], label=label)

    if ideal:
        ax.plot(threads, threads, color="gray", linewidth=0.8, label="ideal")
    else:
        # every speedup here is below 1, so a log axis is the only way to read them
        ax.set_yscale("log")
        ax.axhline(1.0, color="gray", linewidth=0.8)

    ax.set_xlabel("worker threads")
    ax.set_ylabel("speedup (sequential / parallel)")
    ax.set_title(title)
    ax.legend(fontsize=8)
    ax.grid(alpha=0.3)
    fig.tight_layout()
    fig.savefig(os.path.join(OUT, out_name), dpi=150)


def plot_inflection():
    rows = {}
    with open("results/inflection.csv") as f:
        for r in csv.DictReader(f):
            rows.setdefault(r["input"], []).append(
                (int(r["loops"]), int(r["sequential"]), int(r["pthread"])))

    fig, axes = plt.subplots(1, 3, figsize=(12, 4), sharey=True)
    for ax, inp in zip(axes, ["1k.txt", "8k.txt", "16k.txt"]):
        pts = sorted(rows[inp])
        loops = [p[0] for p in pts]
        ax.plot(loops, [p[1] for p in pts], marker="o", label="sequential")
        ax.plot(loops, [p[2] for p in pts], marker="s", label="parallel, 8 threads")
        ax.set_xscale("log")
        ax.set_yscale("log")
        ax.set_xlabel("-l (operator cost)")
        ax.set_title(inp)
        ax.grid(alpha=0.3, which="both")
    axes[0].set_ylabel("elapsed microseconds")
    axes[0].legend(fontsize=8)
    fig.suptitle("Sequential and parallel elapsed time as operator cost grows")
    fig.tight_layout()
    fig.savefig(os.path.join(OUT, "inflection.png"), dpi=150)


def main():
    os.makedirs(OUT, exist_ok=True)
    plot_speedup("results/threads_l100000.csv",
                 "Speedup at -l 100000, pthread barrier",
                 "step1_l100000.png", ["pthread"])
    plot_speedup("results/threads_l10.csv",
                 "Speedup at -l 10, pthread barrier",
                 "step2_l10.png", ["pthread"], ideal=False)
    plot_inflection()
    plot_speedup("results/threads_l100000.csv",
                 "Speedup at -l 100000, both barriers",
                 "step3_l100000.png", ["pthread", "spin"])
    plot_speedup("results/threads_l10.csv",
                 "Speedup at -l 10, both barriers",
                 "step3_l10.png", ["pthread", "spin"], ideal=False)
    print("wrote plots to", OUT)


main()
