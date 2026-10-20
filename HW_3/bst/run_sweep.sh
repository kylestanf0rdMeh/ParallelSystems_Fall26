#!/bin/sh
# runs every configuration the report needs and writes the times to results/times.csv.
# usage: sh run_sweep.sh [runs per config, default 5]
# needs make and sh fetch_inputs.sh first.

RUNS=${1:-5}
OUT=results/times.csv
TMP=/tmp/bst_sweep_out.txt
CORES=`nproc`

mkdir -p results
echo "input,impl,hash_workers,data_workers,comp_workers,run,hash_time,group_time,compare_time" > $OUT

# run <input> <impl> <hash workers> <data workers or -> <comp workers or -> [extra flags]
run() {
    in=$1; impl=$2; hw=$3; dw=$4; cw=$5; extra=$6
    args="-input=inputs/$in.txt -hash-workers=$hw $extra"
    [ "$dw" != "-" ] && args="$args -data-workers=$dw"
    [ "$cw" != "-" ] && args="$args -comp-workers=$cw"
    r=1
    while [ $r -le $RUNS ]; do
        ./BST_opt $args > $TMP
        h=`awk '/^hashTime:/ {print $2}' $TMP`
        g=`awk '/^hashGroupTime:/ {print $2}' $TMP`
        c=`awk '/^compareTreeTime:/ {print $2}' $TMP`
        echo "$in,$impl,$hw,$dw,$cw,$r,$h,$g,$c" >> $OUT
        r=$((r + 1))
    done
    echo "$in $impl $args"
}

for in in coarse fine; do
    if [ $in = coarse ]; then N=100; else N=100000; fi
    THREADS=`printf "2\n4\n8\n16\n$CORES\n$((CORES * 2))\n$N\n" | sort -n | uniq`

    # step 1 and the sequential baselines
    run $in hash 1 - -
    run $in seq 1 1 1
    for i in $THREADS; do
        run $in hash $i - -
        # step 2: one manager goroutine behind a channel, then one shared mutex
        run $in channel $i 1 -
        run $in lock $i $i -
    done

    # step 2 extra credit: j shards, each behind its own lock or its own manager
    for i in 16 $N; do
        for j in 2 4 8 16; do
            [ $j -ge $i ] && continue
            run $in fine-lock $i $j - "-fine-sync=lock"
            run $in fine-channel $i $j - "-fine-sync=channel"
        done
    done
done

# step 3 on coarse only, the lab makes fine optional. 0 is one goroutine per comparison.
for c in `printf "0\n1\n2\n4\n8\n16\n$CORES\n$((CORES * 2))\n" | sort -n | uniq`; do
    run coarse compare 16 16 $c
done

rm -f $TMP
echo "wrote $OUT"
