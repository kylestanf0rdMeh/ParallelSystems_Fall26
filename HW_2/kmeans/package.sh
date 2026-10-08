#!/bin/sh
# builds the submission tarball. run from this directory.
# usage: sh package.sh <uteid>
#
# the archive has to expand to a single folder named first_last_uteid_lab2 with the
# submit file sitting directly inside it.

if [ -z "$1" ]; then
    echo "usage: sh package.sh <uteid>"
    exit 1
fi

NAME=kyle_stanford_$1_lab2
STAGE=/tmp/$NAME
# the archive lands here rather than /tmp so it shows up in the codio file tree and can be
# downloaded from there. *.tar.gz is gitignored, so it will not get committed by accident.
ARCHIVE=$NAME.tar.gz

rm -rf "$STAGE" "$ARCHIVE"
mkdir -p "$STAGE/bin"

cp Makefile submit "$STAGE"/
cp -r src "$STAGE"/

tar -czf "$ARCHIVE" -C /tmp "$NAME"

echo "wrote $ARCHIVE"
tar -tzf "$ARCHIVE"
