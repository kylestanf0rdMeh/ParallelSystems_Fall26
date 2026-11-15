#!/bin/sh
# builds the code tarball (the report pdf is submitted separately). run from this directory.
# usage: sh package.sh <uteid>

if [ -z "$1" ]; then
    echo "usage: sh package.sh <uteid>"
    exit 1
fi

NAME=kyle_stanford_$1_lab4
STAGE=/tmp/$NAME
# lands here rather than /tmp so it shows up in the codio file tree and can be downloaded
ARCHIVE=$NAME.tar.gz

rm -rf "$STAGE" "$ARCHIVE"
mkdir -p "$STAGE"

cp -r Cargo.toml Cargo.lock src run_sweep.sh make_plots.py "$STAGE"/

tar -czf "$ARCHIVE" -C /tmp "$NAME"

echo "wrote $ARCHIVE"
tar -tzf "$ARCHIVE"
