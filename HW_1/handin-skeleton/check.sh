#!/bin/bash
# Diffs the parallel output against the sequential one for a range of thread counts.
# Pass -s as an argument to exercise the spin barrier instead of the pthread barrier.

EXTRA="$@"

# every supplied input is a power of two, so make one that is not
if [ ! -f tests/odd_1000.txt ]; then
    { echo 1000; seq 0 999; } > tests/odd_1000.txt
fi

INPUTS="seq_64_test.txt odd_1000.txt 1k.txt 8k.txt 16k.txt"
THREADS="1 2 3 5 6 8 13 16 32"
LOOPS=10
FAIL=0

for inp in $INPUTS; do
    ./bin/prefix_scan -i tests/$inp -o /tmp/golden.txt -n 0 -l $LOOPS > /dev/null
    for t in $THREADS; do
        ./bin/prefix_scan -i tests/$inp -o /tmp/out.txt -n $t -l $LOOPS $EXTRA > /dev/null
        if diff -q /tmp/golden.txt /tmp/out.txt > /dev/null; then
            echo "ok    $inp n=$t"
        else
            echo "FAIL  $inp n=$t"
            FAIL=1
        fi
    done
done

exit $FAIL
