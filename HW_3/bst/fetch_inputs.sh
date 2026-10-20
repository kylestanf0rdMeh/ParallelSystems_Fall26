#!/bin/sh
# the sample inputs come to about 10 MB, so they are pulled down instead of committed

BASE=https://www.cs.utexas.edu/~rossbach/cs380p/lab/go-sample-inputs
DEST=`dirname "$0"`/inputs

mkdir -p "$DEST"

for f in simple.txt coarse.txt fine.txt; do
    if [ -f "$DEST/$f" ]; then
        echo "already have $f"
    else
        echo "fetching $f"
        wget -q -O "$DEST/$f" "$BASE/$f" || curl -sL -o "$DEST/$f" "$BASE/$f"
    fi
done

ls -l "$DEST"
