#!/bin/sh

# Include common function definitions.
. $(dirname "$0")/common.shi

shell_import build-defaults.shi

usage () {
    cat >&2 <<EOF
Usage: $(program_name) <destination-path>

This script is used to unpack all required support library sources needed
by the qemu-android build system. Sources will be extracted at the target
destination path, which will be created on demand by this script.
EOF
    exit ${1:-0}
}

if [ -z "$1" ]; then
    usage 1
fi

DEST_DIR=$1
if [ ! -d "$DEST_DIR" ]; then
    dump "Creating $DEST_DIR"
    mkdir -p "$DEST_DIR" ||
    panic "Could not create destination directory: $DEST_DIR"
else
    dump "Cleaning up $DEST_DIR"
    rm -rf "$DEST_DIR"/*
fi

# Sanity check.
ARCHIVE_DIR=$(program_directory)/../archive
if [ ! -d "$ARCHIVE_DIR" ]; then
    panic "Missing archive directory: $ARCHIVE_DIR"
fi
ARCHIVE_DIR=$(cd "$ARCHIVE_DIR" && pwd -P)

MISSING_PKGS=
for PKG in $SOURCES_PACKAGES; do
    PKG_PATH=$ARCHIVE_DIR/$PKG
    if [ ! -f "$PKG_PATH" ]; then
        MISSING_PKGS="$MISSING_PKGS $PKG_PATH"
    else
        dump "Unpacking $PKG"
        unpack_archive "$PKG_PATH" "$DEST_DIR"
    fi
done

if [ "$MISSING_PKGS" ]; then
    panic "Missing packages: $MISSING_PKGS"
fi

echo "Done!"
