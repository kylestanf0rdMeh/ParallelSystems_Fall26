#!/bin/sh
# builds the submission tarball. run from this directory.
# usage: sh package.sh <uteid>

if [ -z "$1" ]; then
    echo "usage: sh package.sh <uteid>"
    exit 1
fi

NAME=kyle_stanford_$1_lab3
STAGE=/tmp/$NAME
# lands here rather than /tmp so it shows up in the codio file tree and can be downloaded
ARCHIVE=$NAME.tar.gz

rm -rf "$STAGE" "$ARCHIVE"
mkdir -p "$STAGE"

cp BST_opt.go Makefile fetch_inputs.sh run_sweep.sh make_plots.py "$STAGE"/
cp -r results "$STAGE"/
cp ../report/*.pdf "$STAGE"/ 2>/dev/null || echo "note: no report pdf in ../report yet"

tar -czf "$ARCHIVE" -C /tmp "$NAME"

echo "wrote $ARCHIVE"
tar -tzf "$ARCHIVE"
