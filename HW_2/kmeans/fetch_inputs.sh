#!/bin/sh
# the three sample inputs come to about 38 MB, so they are pulled down instead of committed

BASE=https://www.cs.utexas.edu/~rossbach/cs380p/lab/kmeans-sample-inputs
DEST=`dirname "$0"`/inputs

mkdir -p "$DEST"

for f in random-n2048-d16-c16.txt random-n16384-d24-c16.txt random-n65536-d32-c16.txt; do
    if [ -f "$DEST/$f" ]; then
        echo "already have $f"
    else
        echo "fetching $f"
        wget -q -O "$DEST/$f" "$BASE/$f" || curl -sL -o "$DEST/$f" "$BASE/$f"
    fi
done

ls -l "$DEST"
