#!/usr/bin/env python3
#
#  Builds the report graphs from results/times.csv. Every point is the mean of its runs.
#

import csv
import os
from collections import defaultdict
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

OUT = "../report/plots"
INPUTS = ["coarse", "fine"]
N = {"coarse": 100, "fine": 100000}


def read_means():
    runs = defaultdict(lambda: defaultdict(list))
    with open("results/times.csv") as f:
        for r in csv.DictReader(f):
            key = (r["input"], r["impl"], r["hash_workers"], r["data_workers"], r["comp_workers"])
            for col in ("hash_time", "group_time", "compare_time"):
                if r[col]:
                    runs[key][col].append(float(r[col]))
    return {k: {c: sum(v) / len(v) for c, v in cols.items()} for k, cols in runs.items()}


def series(means, inp, impl, col, x_of):
    # (x, mean) for every config of one implementation, sorted by x
    pts = [(x_of(k), v[col]) for k, v in means.items() if k[0] == inp and k[1] == impl]
    return sorted(pts)


def label(x, inp):
    return "N=%d" % x if x == N[inp] else str(x)


def speedup_axes(ax, xs, inp, title):
    ax.axhline(1.0, color="gray", linewidth=0.8)
    ax.set_xticks(range(len(xs)))
    ax.set_xticklabels([label(x, inp) for x in xs])
    ax.set_title(title)
    ax.grid(alpha=0.3)


def plot_seq(means):
    fig, ax = plt.subplots(figsize=(7, 4.5))
    steps = [("hash", "hash", "hash_time"), ("hash + insert", "seq", "group_time"),
             ("compare", "seq", "compare_time")]
    width = 0.35
    for i, inp in enumerate(INPUTS):
        heights = [means[(inp, impl, "1", "-" if impl == "hash" else "1",
                          "-" if impl == "hash" else "1")][col] for _, impl, col in steps]
        bars = ax.bar([s + (i - 0.5) * width for s in range(len(steps))], heights, width,
                      label=inp + ".txt")
        for b, h in zip(bars, heights):
            ax.text(b.get_x() + b.get_width() / 2, h * 1.1, "%.4f" % h, ha="center", fontsize=7)
    ax.set_yscale("log")
    ax.set_xticks(range(len(steps)))
    ax.set_xticklabels([s[0] for s in steps])
    ax.set_ylabel("seconds")
    ax.set_title("Sequential time of each step")
    ax.legend(fontsize=8)
    ax.grid(alpha=0.3, axis="y", which="both")
    fig.tight_layout()
    fig.savefig(os.path.join(OUT, "seq.png"), dpi=150)


def plot_hash(means):
    fig, axes = plt.subplots(1, 2, figsize=(11, 4))
    for ax, inp in zip(axes, INPUTS):
        base = means[(inp, "hash", "1", "-", "-")]["hash_time"]
        pts = [p for p in series(means, inp, "hash", "hash_time", lambda k: int(k[2])) if p[0] > 1]
        ax.plot(range(len(pts)), [base / t for _, t in pts], marker="o")
        speedup_axes(ax, [x for x, _ in pts], inp, inp + ".txt")
        ax.set_xlabel("hash-workers")
    axes[0].set_ylabel("speedup over sequential")
    fig.suptitle("Hashing only")
    fig.tight_layout()
    fig.savefig(os.path.join(OUT, "hash.png"), dpi=150)


def plot_hash_insert(means):
    fig, axes = plt.subplots(1, 2, figsize=(11, 4))
    for ax, inp in zip(axes, INPUTS):
        base = means[(inp, "seq", "1", "1", "1")]["group_time"]
        for impl, name in (("channel", "one manager over a channel"), ("lock", "one mutex")):
            pts = series(means, inp, impl, "group_time", lambda k: int(k[2]))
            ax.plot(range(len(pts)), [base / t for _, t in pts], marker="o", label=name)
        speedup_axes(ax, [x for x, _ in pts], inp, inp + ".txt")
        ax.set_xlabel("hash-workers")
    axes[0].set_ylabel("speedup over sequential")
    axes[0].legend(fontsize=8)
    fig.suptitle("Hashing and inserting into the map")
    fig.tight_layout()
    fig.savefig(os.path.join(OUT, "hash_insert.png"), dpi=150)


def plot_fine_grained(means):
    fig, axes = plt.subplots(1, 2, figsize=(11, 4))
    for ax, inp in zip(axes, INPUTS):
        base = means[(inp, "seq", "1", "1", "1")]["group_time"]
        for hw in ("16", str(N[inp])):
            for impl, name in (("fine-lock", "locks"), ("fine-channel", "channels")):
                pts = [(int(k[3]), v["group_time"]) for k, v in means.items()
                       if k[0] == inp and k[1] == impl and k[2] == hw]
                pts.sort()
                ax.plot([x for x, _ in pts], [base / t for _, t in pts], marker="o",
                        label="%s, hash-workers=%s" % (name, hw))
        ax.axhline(1.0, color="gray", linewidth=0.8)
        ax.set_xscale("log", base=2)
        ax.set_xticks([2, 4, 8, 16])
        ax.set_xticklabels(["2", "4", "8", "16"])
        ax.set_xlabel("data-workers")
        ax.set_title(inp + ".txt")
        ax.grid(alpha=0.3)
    axes[0].set_ylabel("speedup over sequential")
    axes[0].legend(fontsize=8)
    fig.suptitle("Hashing and inserting with fine grained map access")
    fig.tight_layout()
    fig.savefig(os.path.join(OUT, "fine_grained.png"), dpi=150)


def plot_compare(means):
    fig, ax = plt.subplots(figsize=(7, 4.5))
    base = means[("coarse", "compare", "16", "16", "1")]["compare_time"]
    pts = [p for p in series(means, "coarse", "compare", "compare_time", lambda k: int(k[4]))
           if p[0] > 1]
    ax.plot(range(len(pts)), [base / t for _, t in pts], marker="o", label="comp-workers pool")
    per = means[("coarse", "compare", "16", "16", "0")]["compare_time"]
    ax.axhline(base / per, color="tab:orange", linestyle="--", label="goroutine per comparison")
    speedup_axes(ax, [x for x, _ in pts], "coarse", "Tree comparison on coarse.txt")
    ax.set_xlabel("comp-workers")
    ax.set_ylabel("speedup over sequential")
    ax.legend(fontsize=8)
    fig.tight_layout()
    fig.savefig(os.path.join(OUT, "compare.png"), dpi=150)


def main():
    os.makedirs(OUT, exist_ok=True)
    means = read_means()
    plot_seq(means)
    plot_hash(means)
    plot_hash_insert(means)
    plot_fine_grained(means)
    plot_compare(means)

    print("mean seconds")
    for k in sorted(means):
        print("  %-7s %-13s hw=%-6s dw=%-3s cw=%-3s %s" % (k + (
            "  ".join("%s %.6f" % (c, t) for c, t in sorted(means[k].items())),)))
    print("wrote plots to", OUT)


main()
