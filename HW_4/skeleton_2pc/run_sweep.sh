#!/bin/bash
# runs every configuration the report needs and writes the results to results/runs.csv.
# usage: bash run_sweep.sh [runs per config, default 3]
# needs cargo build --release first.

RUNS=${1:-3}
OUT=results/runs.csv
BIN=./target/release/two_phase_commit
TMP=/tmp/2pc_sweep_out.txt

mkdir -p results
echo "sweep,clients,participants,requests,s,S,run,seconds,committed,aborted,check" > $OUT

# run <sweep> <clients> <participants> <requests> <s> <S>
run() {
    args="-c $2 -p $3 -r $4 -s $5 -S $6"
    for r in `seq $RUNS`; do
        start=`date +%s.%N`
        $BIN $args -m run > $TMP
        end=`date +%s.%N`
        secs=`awk "BEGIN {print $end - $start}"`
        line=`grep '^coordinator' $TMP`
        c=`echo "$line" | awk '{print $4}'`
        a=`echo "$line" | awk '{print $6}'`
        # the checker panics on any mismatch, so a clean exit is a pass
        if $BIN $args -m check > /dev/null 2>&1; then ok=pass; else ok=FAIL; fi
        echo "$1,$2,$3,$4,$5,$6,$r,$secs,$c,$a,$ok" >> $OUT
    done
    echo "$1 $args"
}

for c in 1 2 4 8 16 20; do
    run clients $c 10 200 1 1
done

for p in 1 2 4 8 10; do
    run participants 4 $p 200 1 1
done

for s in 0.95 0.9 0.8; do
    run exec 4 10 200 $s 1
done

for S in 0.95 0.9 0.8; do
    run send 4 10 200 1 $S
done

rm -f $TMP
echo "wrote $OUT"
