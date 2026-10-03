#!/usr/bin/env python3
# compares two centroid dumps. the clusters do not have to come out in the same order,
# so each produced centroid is greedily paired with its nearest unused reference centroid.

import sys


def read_centroids(path):
    rows = []
    with open(path) as f:
        for line in f:
            parts = line.split()
            if len(parts) < 2:
                continue
            rows.append([float(x) for x in parts[1:]])
    return rows


def main():
    if len(sys.argv) != 3:
        print("usage: check.py mine.txt answer.txt")
        return 1

    mine = read_centroids(sys.argv[1])
    ref = read_centroids(sys.argv[2])

    if len(mine) != len(ref):
        print("centroid count mismatch: %d vs %d" % (len(mine), len(ref)))
        return 1

    if len(mine[0]) != len(ref[0]):
        print("dimension mismatch: %d vs %d" % (len(mine[0]), len(ref[0])))
        return 1

    taken = [False] * len(ref)
    worst = 0.0

    for row in mine:
        best = -1
        best_dist = None
        for i, other in enumerate(ref):
            if taken[i]:
                continue
            dist = sum((a - b) ** 2 for a, b in zip(row, other))
            if best_dist is None or dist < best_dist:
                best_dist = dist
                best = i

        taken[best] = True
        error = max(abs(a - b) for a, b in zip(row, ref[best]))
        if error > worst:
            worst = error

    print("worst per dimension error: %.8f" % worst)
    print("PASS" if worst < 1e-4 else "FAIL")
    return 0


if __name__ == "__main__":
    sys.exit(main())
