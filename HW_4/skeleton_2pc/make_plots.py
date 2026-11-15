#!/usr/bin/env python3
#
#  Builds the report graphs from results/runs.csv and prints the -s / -S table.
#  Every point is the mean of its runs.
#

import csv
import os
from collections import defaultdict
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

OUT = "../report/plots"


def read_means():
    runs = defaultdict(list)
    with open("results/runs.csv") as f:
        for r in csv.DictReader(f):
            key = (r["sweep"], int(r["clients"]), int(r["participants"]), int(r["requests"]),
                   float(r["s"]), float(r["S"]))
            runs[key].append((float(r["seconds"]), int(r["committed"]), int(r["aborted"])))
    return {k: [sum(col) / len(col) for col in zip(*v)] for k, v in runs.items()}


def plot_throughput(means, sweep, x_index, xlabel, title, fname):
    pts = sorted((k[x_index], (c + a) / t) for k, (t, c, a) in means.items() if k[0] == sweep)
    fig, ax = plt.subplots(figsize=(6, 4))
    ax.plot([x for x, _ in pts], [y for _, y in pts], marker="o")
    ax.set_xticks([x for x, _ in pts])
    ax.set_xlabel(xlabel)
    ax.set_ylabel("transactions per second")
    ax.set_ylim(bottom=0)
    ax.set_title(title)
    ax.grid(alpha=0.3)
    fig.tight_layout()
    fig.savefig(os.path.join(OUT, fname), dpi=150)


def print_probabilities(means):
    print("flag  value  commit rate  expected  seconds")
    for k, (t, c, a) in sorted(means.items()):
        if k[0] not in ("exec", "send"):
            continue
        p = k[4] if k[0] == "exec" else k[5]
        print("%-5s %5.2f  %11.3f  %8.3f  %7.2f" % ("-s" if k[0] == "exec" else "-S", p,
                                                   c / (c + a), p ** k[2], t))


if __name__ == "__main__":
    os.makedirs(OUT, exist_ok=True)
    means = read_means()
    plot_throughput(means, "clients", 1, "clients", "Throughput vs clients (10 participants)",
                    "clients.png")
    plot_throughput(means, "participants", 2, "participants",
                    "Throughput vs participants (4 clients)", "participants.png")
    print_probabilities(means)
