#!/bin/sh

. $(dirname "$0")/common.shi

shell_import build-defaults.shi

usage () {
    cat <<EOF
Usage: $(program_name) [options] <src-directory>

Valid options:
    --help, -?          Print this message.
    --verbose           Increment verbosity.
    --quiet             Decrement verbosity.
    --prefix=<path>     Installation path prefix [/usr/local].
EOF