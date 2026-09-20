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
CORES = 8
COLORS = {"1k.txt": "tab:blue", "8k.txt": "tab:orange", "16k.txt": "tab:green"}


def read_threads(path):
    with open(path) as f:
        rows = list(csv.reader(f))
    threads = [int(t) for t in rows[0][3:]]
    data = {}
    for r in rows[1:]:
        data[(r[0], r[1])] = (int(r[2]), [int(v) for v in r[3:]])
    return threads, data


def plot_speedup(path, n_loops, out_name):
    threads, data = read_threads(path)
    fig, ax = plt.subplots(figsize=(7, 4.5))

    for (inp, barrier), (seq, times) in data.items():
        ax.plot(threads, [seq / t for t in times],
                marker="o" if barrier == "pthread" else "s",
                linestyle="-" if barrier == "pthread" else "--",
                color=COLORS[inp],
                label="{} {}".format(inp, barrier))

    ax.plot(threads, threads, color="gray", linewidth=0.8, label="ideal")
    ax.axvline(CORES, color="red", linewidth=0.8)
    ax.text(CORES + 0.3, ax.get_ylim()[1] * 0.9, "{} cores".format(CORES), color="red")

    ax.set_xlabel("worker threads")
    ax.set_ylabel("speedup (sequential / parallel)")
    ax.set_title("Speedup at -l {}".format(n_loops))
    ax.legend(fontsize=7)
    ax.grid(alpha=0.3)
    fig.tight_layout()
    fig.savefig(os.path.join(OUT, out_name), dpi=150)


def plot_speedup_zoom(path, n_loops, out_name):
    threads, data = read_threads(path)
    keep = [i for i, t in enumerate(threads) if t <= CORES]
    fig, ax = plt.subplots(figsize=(7, 4.5))

    for (inp, barrier), (seq, times) in data.items():
        ax.plot([threads[i] for i in keep], [seq / times[i] for i in keep],
                marker="o" if barrier == "pthread" else "s",
                linestyle="-" if barrier == "pthread" else "--",
                color=COLORS[inp],
                label="{} {}".format(inp, barrier))

    ax.plot([threads[i] for i in keep], [threads[i] for i in keep],
            color="gray", linewidth=0.8, label="ideal")
    ax.axhline(CORES / 3.0, color="purple", linestyle=":", linewidth=1.2,
               label="work-efficiency ceiling, {} / 3".format(CORES))

    ax.set_xlabel("worker threads")
    ax.set_ylabel("speedup (sequential / parallel)")
    ax.set_title("Speedup at -l {}, threads at or below core count".format(n_loops))
    ax.legend(fontsize=7)
    ax.grid(alpha=0.3)
    fig.tight_layout()
    fig.savefig(os.path.join(OUT, out_name), dpi=150)


def plot_barrier_cost(path, n_loops, out_name):
    threads, data = read_threads(path)
    fig, ax = plt.subplots(figsize=(7, 4.5))

    for inp in COLORS:
        _, pth = data[(inp, "pthread")]
        _, spn = data[(inp, "spin")]
        ax.plot(threads, [s / p for s, p in zip(spn, pth)],
                marker="o", color=COLORS[inp], label=inp)

    ax.axhline(1.0, color="gray", linewidth=0.8)
    ax.axvline(CORES, color="red", linewidth=0.8)
    ax.set_yscale("log")
    ax.set_xlabel("worker threads")
    ax.set_ylabel("spin time / pthread time  (below 1 means spin is faster)")
    ax.set_title("Spin barrier relative to pthread barrier at -l {}".format(n_loops))
    ax.legend(fontsize=8)
    ax.grid(alpha=0.3, which="both")
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
    fig.suptitle("Sequential and parallel crossover as operator cost grows")
    fig.tight_layout()
    fig.savefig(os.path.join(OUT, "inflection.png"), dpi=150)


def main():
    os.makedirs(OUT, exist_ok=True)
    plot_speedup("results/threads_l100000.csv", 100000, "speedup_l100000.png")
    plot_speedup("results/threads_l10.csv", 10, "speedup_l10.png")
    plot_speedup_zoom("results/threads_l100000.csv", 100000, "speedup_l100000_zoom.png")
    plot_barrier_cost("results/threads_l10.csv", 10, "barrier_ratio_l10.png")
    plot_barrier_cost("results/threads_l100000.csv", 100000, "barrier_ratio_l100000.png")
    plot_inflection()
    print("wrote plots to", OUT)


main()
