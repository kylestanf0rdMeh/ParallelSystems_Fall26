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
INPUTS = ["2048", "16384", "65536"]
LABELS = {"2048": "n=2048 d=16", "16384": "n=16384 d=24", "65536": "n=65536 d=32"}
GPU = ["cuda", "shared", "thrust"]
COLORS = {"cuda": "tab:blue", "shared": "tab:orange", "thrust": "tab:green"}


def read_sweep():
    best = {}
    with open("results/sweep.csv") as f:
        for r in csv.DictReader(f):
            key = (r["n"], r["alg"])
            ms = float(r["ms_per_iter"])
            if key not in best or ms < best[key]:
                best[key] = ms
    return best


def read_breakdown():
    rows = {}
    with open("results/breakdown.csv") as f:
        for r in csv.DictReader(f):
            rows[(r["n"], r["alg"])] = (float(r["kernel_ms"]), float(r["transfer_ms"]),
                                        float(r["solve_ms"]))
    return rows


def plot_speedup(best):
    fig, ax = plt.subplots(figsize=(7, 4.5))
    width = 0.25
    spots = range(len(INPUTS))

    for i, alg in enumerate(GPU):
        heights = [best[(n, "seq")] / best[(n, alg)] for n in INPUTS]
        offset = (i - 1) * width
        bars = ax.bar([x + offset for x in spots], heights, width,
                      color=COLORS[alg], label=alg)
        for b, h in zip(bars, heights):
            ax.text(b.get_x() + b.get_width() / 2, h + 0.2, "%.1f" % h,
                    ha="center", fontsize=7)

    ax.axhline(1.0, color="gray", linewidth=0.8)
    ax.set_xticks(list(spots))
    ax.set_xticklabels([LABELS[n] for n in INPUTS])
    ax.set_ylabel("speedup (sequential / parallel)")
    ax.set_title("Speedup over the sequential CPU implementation, best of five runs")
    ax.legend(fontsize=8)
    ax.grid(alpha=0.3, axis="y")
    fig.tight_layout()
    fig.savefig(os.path.join(OUT, "speedup.png"), dpi=150)


def plot_breakdown(rows):
    fig, axes = plt.subplots(1, 3, figsize=(12, 4))

    for ax, n in zip(axes, INPUTS):
        spots = range(len(GPU))
        transfers = [rows[(n, a)][1] for a in GPU]
        # whatever is left is allocation, the host side convergence test and launch overhead
        kernels = [rows[(n, a)][0] for a in GPU]
        rest = [max(rows[(n, a)][2] - rows[(n, a)][0] - rows[(n, a)][1], 0.0) for a in GPU]

        ax.bar(spots, transfers, 0.6, label="transfer", color="tab:red")
        ax.bar(spots, kernels, 0.6, bottom=transfers, label="kernel", color="tab:blue")
        ax.bar(spots, rest, 0.6,
               bottom=[t + k for t, k in zip(transfers, kernels)],
               label="other", color="lightgray")

        for i, a in enumerate(GPU):
            share = 100.0 * rows[(n, a)][1] / rows[(n, a)][2]
            ax.text(i, rows[(n, a)][2] * 1.02, "%.0f%%" % share, ha="center", fontsize=8)

        ax.set_xticks(list(spots))
        ax.set_xticklabels(GPU)
        ax.set_title(LABELS[n])
        ax.grid(alpha=0.3, axis="y")

    axes[0].set_ylabel("milliseconds for the whole solve")
    axes[0].legend(fontsize=8)
    fig.suptitle("Where the end to end time goes, with the transfer share labelled")
    fig.tight_layout()
    fig.savefig(os.path.join(OUT, "breakdown.png"), dpi=150)


def main():
    os.makedirs(OUT, exist_ok=True)
    best = read_sweep()
    plot_speedup(best)
    plot_breakdown(read_breakdown())

    print("best ms per iteration")
    for n in INPUTS:
        line = "  %-12s" % LABELS[n]
        for alg in ["seq"] + GPU:
            line += "  %s %8.4f" % (alg, best[(n, alg)])
        print(line)

    print("wrote plots to", OUT)


main()
