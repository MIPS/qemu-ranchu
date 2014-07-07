#!/bin/sh

. $(dirname "$0")/common.shi
shell_import build-defaults.shi

# Do we have ccache ?
CCACHE=$(which ccache 2>/dev/null)
if [ "$CCACHE" ]; then
    log "Found ccache as: $CCACHE"
else
    log "Cannot find ccache in PATH."
fi

ARCHIVE_DIR=$(dirname "$0")/../archive
if [ ! -d "$ARCHIVE_DIR" ]; then
    panic "Missing archive directory: $ARCHIVE_DIR"
fi
ARCHIVE_DIR=$(cd "$ARCHIVE_DIR" && pwd -P)
log "Using archive directory: $ARCHIVE_DIR"

HOST_OS=linux-x86_64

# TODO(digit): Take these from command-line parameters.
AOSP_SOURCE_DIR=/opt/digit/repo/aosp
QEMU_ANDROID=$UPSTREAM/qemu-android

TEMP_DIR=/tmp/build-qemu-android-aarch64-100
mkdir -p "$TEMP_DIR"
rm -rf "$TEMP_DIR"/*

NUM_JOBS=$(get_build_num_cores)
log "Parallel jobs count: $NUM_JOBS"

ORIGINAL_PATH=$PATH

export PKG_CONFIG=$(which pkg-config 2>/dev/null)
if [ -z "$PKG_CONFIG" ]; then
    panic "You must have pkg-config installed on this system!"
fi

# Generate a small wrapper program
#
# $1: program name, without any prefix (e.g. gcc, g++, ar, etc..)
# $2: source prefix (e.g. 'i586-mingw32msvc-')
# $3: destination prefix (e.g. 'i586-px-mingw32msvc-')
# $4: destination directory for the generated program
#
gen_wrapper_program ()
{
    local PROG="$1"
    local SRC_PREFIX="$2"
    local DST_PREFIX="$3"
    local DST_FILE="$4/${SRC_PREFIX}$PROG"
    local FLAGS=""
    local LDFLAGS=""

    case $PROG in
      cc|gcc|cpp)
          FLAGS=$FLAGS" $EXTRA_CFLAGS"
          ;;
      c++|g++)
          FLAGS=$FLAGS" $EXTRA_CXXFLAGS"
          ;;
      ar) FLAGS=$FLAGS" $EXTRA_ARFLAGS";;
      as) FLAGS=$FLAGS" $EXTRA_ASFLAGS";;
      ld|ld.bfd|ld.gold) FLAGS=$FLAGS" $EXTRA_LDFLAGS";;
      windres) FLAGS=$FLAGS" $EXTRA_WINDRESFLAGS";;
    esac

    if [ "$CCACHE" ]; then
        DST_PREFIX="$CCACHE $DST_PREFIX"
    fi

    cat > "$DST_FILE" << EOF
#!/bin/sh
# Auto-generated, do not edit
${DST_PREFIX}$PROG $FLAGS "\$@" $LDFLAGS
EOF
    chmod +x "$DST_FILE"
    log "Generating: ${SRC_PREFIX}$PROG"
}

# $1: source prefix
# $2: destination prefix
# $3: destination directory.
gen_wrapper_toolchain () {
    local SRC_PREFIX="$1"
    local DST_PREFIX="$2"
    local DST_DIR="$3"
    local PROG
    local PROGRAMS="cc gcc c++ g++ cpp as ld ar ranlib strip strings nm objdump objcopy dlltool"

    log "Generating toolchain wrappers in: $DST_DIR"
    run mkdir -p "$DST_DIR"

    case $SRC_PREFIX in
        *mingw*)
            PROGRAMS="$PROGRAMS windres"
            case $CURRENT_HOST in
                windows-x86)
                    EXTRA_WINDRESFLAGS="--target=pe-i386"
                    ;;
            esac
            ;;
    esac

    for PROG in $PROGRAMS; do
        gen_wrapper_program $PROG "$SRC_PREFIX" "$DST_PREFIX" "$DST_DIR"
    done

    EXTRA_CFLAGS=
    EXTRA_CXXFLAGS=
    EXTRA_LDFLAGS=
    EXTRA_ARFLAGS=
    EXTRA_ASFLAGS=
    EXTRA_WINDRESFLAGS=
}

# Prepare the build for a given host system.
# $1: Host system name (e.g. linux-x86_64)
prepare_build_for_host () {
    CURRENT_HOST=$1

    CURRENT_TEXT="[$CURRENT_HOST]"

    PREBUILT_TOOLCHAIN_DIR=
    TOOLCHAIN_PREFIX=
    HOST_EXE_EXTENSION=
    case $CURRENT_HOST in
        linux-*)
            PREBUILT_TOOLCHAIN_DIR=$AOSP_SOURCE_DIR/prebuilts/gcc/linux-x86/host/x86_64-linux-glibc2.11-4.8
            TOOLCHAIN_PREFIX=x86_64-linux-
            ;;
        windows-*)
            PREBUILT_TOOLCHAIN_DIR=$AOSP_SOURCE_DIR/prebuilts/gcc/linux-x86/host/x86_64-w64-mingw32-4.8
            TOOLCHAIN_PREFIX=x86_64-w64-mingw32-
            HOST_EXE_EXTENSION=.exe
            ;;
        *)
            panic "Host system '$CURRENT_HOST' is not supported by this script!"
            ;;
    esac

    case $CURRENT_HOST in
        linux-x86_64)
            GNU_CONFIG_HOST=x86_64-linux
            ;;
        linux-x86)
            GNU_CONFIG_HOST=i686-linux
            ;;
        windows-x86)
            GNU_CONFIG_HOST=i686-w64-mingw32
            ;;
        windows-x86_64)
            GNU_CONFIG_HOST=x86_64-w64-mingw32
            ;;
        *)
            panic "Host system '$CURRENT_HOST' is not supported by this script!"
            ;;
    esac

    case $CURRENT_HOST in
        *-x86)
            EXTRA_CFLAGS="-m32"
            EXTRA_CXXFLAGS="-m32"
            EXTRA_LDFLAGS="-m32"
            ;;
        *-x86_64)
            EXTRA_CFLAGS="-m64"
            EXTRA_CXXFLAGS="-m64"
            EXTRA_LDFLAGS="-m64"
            ;;
        *)
            panic "Host system '$CURRENT_HOST' is not supported by this script!"
            ;;
    esac

    CROSS_PREFIX=${GNU_CONFIG_HOST}-

    PATH=$ORIGINAL_PATH

    BUILD_DIR=$TEMP_DIR/build-$CURRENT_HOST
    log "$CURRENT_TEXT Creating build directory: $BUILD_DIR"
    run mkdir -p "$BUILD_DIR"
    run rm -rf "$BUILD_DIR"/*

    PREFIX=$BUILD_DIR/install
    log "$CURRENT_TEXT Using build prefix: $PREFIX"
    EXTRA_CFLAGS="$EXTRA_CFLAGS -I$PREFIX/include"
    EXTRA_CXXFLAGS="$EXTRA_CXXFLAGS -I$PREFIX/include"
    EXTRA_LDFLAGS="$EXTRA_LDFLAGS -L$PREFIX/lib"

    log "$CURRENT_TEXT Generating $CROSS_PREFIX wrapper toolchain in $TOOLCHAIN_WRAPPER_DIR"
    TOOLCHAIN_WRAPPER_DIR=$BUILD_DIR/toolchain-wrapper
    gen_wrapper_toolchain "${GNU_CONFIG_HOST}-" "$PREBUILT_TOOLCHAIN_DIR/bin/$TOOLCHAIN_PREFIX" "$TOOLCHAIN_WRAPPER_DIR"
    PATH=$TOOLCHAIN_WRAPPER_DIR:$PATH
    log "$CURRENT_TEXT Path: $(echo \"$PATH\" | tr ' ' '\n')"
}

# Handle zlib, only on Win32 because the zlib configure script
# doesn't know how to generate a static library with -fPIC!
do_windows_zlib_package () {
    local ZLIB_VERSION ZLIB_PACKAGE
    local LOC LDFLAGS
    case $CURRENT_HOST in
        windows-x86)
            LOC=-m32
            LDFLAGS=-m32
            ;;
        windows-x86_64)
            LOC=-m64
            LDFLAGS=-m64
            ;;
    esac
    ZLIB_VERSION=$(get_source_package_version zlib)
    dump "$CURRENT_TEXT Building zlib-$ZLIB_VERSION"
    ZLIB_PACKAGE=$(get_source_package_name zlib)
    unpack_archive "$ARCHIVE_DIR/$ZLIB_PACKAGE" "$BUILD_DIR"
    (
        run cd "$BUILD_DIR/zlib-$ZLIB_VERSION"
        export BINARY_PATH=$PREFIX/bin
        export INCLUDE_PATH=$PREFIX/include
        export LIBRARY_PATH=$PREFIX/lib
        run make -fwin32/Makefile.gcc install PREFIX=$CROSS_PREFIX LOC=$LOC LDFLAGS=$LDFLAGS
    )
}

require_program () {
    local VARNAME PROGNAME CMD
    VARNAME=$1
    PROGNAME=$2
    CMD=$(which $PROGNAME 2>/dev/null)
    if [ -z "$CMD" ]; then
        panic "Cannot find required build executable: $PROGNAME"
    fi
    eval $VARNAME=\'$CMD\'
}

# Cross-compiling glib for Win32 is broken and requires special care.
# The following was inspired by the glib.mk from MXE (http://mxe.cc/)
# $1: bitness (32 or 64)
do_windows_glib_package () {
    local GLIB_VERSION GLIB_PACKAGE GLIB_DIR
    GLIB_VERSION=$(get_source_package_version glib)
    dump "$CURRENT_TEXT Building glib-$GLIB_VERSION"
    GLIB_PACKAGE=$(get_source_package_name glib)
    require_program GLIB_GENMARSHAL glib-genmarshal
    require_program GLIB_COMPILE_SCHEMAS glib-compile-schemas
    require_program GLIB_COMPILE_RESOURCES glib-compile-resources
    unpack_archive "$ARCHIVE_DIR/$GLIB_PACKAGE" "$BUILD_DIR"
    GLIB_DIR=$BUILD_DIR/glib-$GLIB_VERSION
    (
        run cd "$GLIB_DIR"
        export LDFLAGS="-L$PREFIX/lib -L$PREFIX/lib$1"
        export CPPFLAGS="-I$PREFIX/include -I$GLIB_DIR -I$GLIB_DIR/glib"
        export CC=${GNU_CONFIG_HOST}-gcc
        export CXX=${GNU_CONFIG_HOST}-c++
        export PKG_CONFIG=$(which pkg-config)
        export PKG_CONFIG_PATH=$PREFIX/lib/pkgconfig
        run ./configure \
            --prefix=$PREFIX \
            --host=$GNU_CONFIG_HOST \
            --disable-shared \
            --with-threads=win32 \
            --with-pcre=internal \
            --disable-debug \
            --disable-gtk-doc \
            --disable-gtk-doc-html \
            --disable-man \
            GLIB_GENMARSHAL=$GLIB_GENMARSHAL \
            GLIB_COMPILE_SCHEMAS=$GLIB_COMPILE_SCHEMAS \
            GLIB_COMPILE_RESOURCES=$GLIB_COMPILE_RESOURCES

        # Necessary to build gio stuff properly.
        run ln -s "$GLIB_COMPILE_RESOURCES" gio/

        run make -j$NUM_JOBS -C glib install sbin_PROGRAMS= noinst_PROGRAMS=
        run make -j$NUM_JOBS -C gmodule install bin_PROGRAMS= sbin_PROGRAMS= noinst_PROGRAMS=
        run make -j$NUM_JOBS -C gthread install bin_PROGRAMS= sbin_PROGRAMS= noinst_PROGRAMS=
        run make -j$NUM_JOBS -C gobject install bin_PROGRAMS= sbin_PROGRAMS= noinst_PROGRAMS=
        run make -j$NUM_JOBS -C gio install bin_PROGRAMS= sbin_PROGRAMS= noinst_PROGRAMS= MISC_STUFF=
        run make -j$NUM_JOBS install-pkgconfigDATA
        run make -j$NUM_JOBS -C m4macros install

        # Missing -lole32 results in link failure later!
        sed -i -e 's|\-lglib-2.0 -lintl|-lglib-2.0 -lole32 -lintl|g' \
            $PREFIX/lib/pkgconfig/glib-2.0.pc
    )
}

# Generic routine used to unpack and rebuild a generic auto-tools package
# $1: package name, unversioned and unsuffixed (e.g. 'libpng')
# $2+: extra configuration flags
do_autotools_package () {
    local PKG PKG_VERSION PKG_NAME
    PKG=$1
    shift
    PKG_VERSION=$(get_source_package_version $PKG)
    PKG_NAME=$(get_source_package_name $PKG)
    dump "$CURRENT_TEXT Building $PKG-$PKG_VERSION"
    unpack_archive "$ARCHIVE_DIR/$PKG_NAME" "$BUILD_DIR" ||
    panic "Could not unpack $PKG_NAME"
    (
        run cd "$BUILD_DIR/$PKG-$PKG_VERSION"
        export LDFLAGS="-L$PREFIX/lib"
        export CPPFLAGS="-L$PREFIX/include"
        run ./configure \
            --prefix=$PREFIX \
            --host=$GNU_CONFIG_HOST \
            --disable-shared \
            --with-pic \
            "$@"
        run make -j$NUM_JOBS
        run make install
    ) ||
    panic "Could not build and install $PKG_NAME"
}

# Assume you have called prepare_build_for_host previously.
# $1: host os name.
build_qemu_android () {
    prepare_build_for_host $1

    export PKG_CONFIG_PATH=$PREFIX/lib/pkgconfig

    # Handle zlib for Windows
    case $1 in
        windows-*)
            do_windows_zlib_package
            ;;
    esac

    # Handle libpng
    do_autotools_package libpng

    case $1 in
        windows-*)
            do_autotools_package libiconv \
                --disable-rpath \
            ;;
    esac

    do_autotools_package gettext \
        --disable-rpath \
        --disable-acl \
        --disable-curses \
        --disable-openmp \
        --disable-java \
        --disable-rpath \
        --without-emacs \
        --disable-c++

    do_autotools_package libffi

    case $1 in
        windows-x86)
            do_windows_glib_package 32
            ;;
        windows-x86_64)
            do_windows_glib_package 64
            ;;
        *)
            do_autotools_package glib \
                --disable-man \
                --disable-gtk-doc \
                --disable-always-build-tests \
                --disable-installed-tests \
                --enable-included-printf
            ;;
    esac

    do_autotools_package pixman \
        --disable-gtk

    do_autotools_package SDL \
        --disable-audio \
        --disable-joystick \
        --disable-cdrom \
        --disable-file \
        --disable-threads

    export SDL_CONFIG=$PREFIX/bin/sdl-config

    dump "$CURRENT_TEXT Building qemu-android"
    (
        run mkdir -p "$BUILD_DIR/qemu-android"
        run rm -rf "$BUILD_DIR"/qemu-android/*
        run cd "$BUILD_DIR/qemu-android"
        run $QEMU_ANDROID/configure \
            --cross-prefix=$CROSS_PREFIX \
            --target-list=aarch64-softmmu \
            --prefix=$PREFIX \
            --extra-ldflags="-L$PREFIX/lib -static-libgcc -static-libstdc++" \
            --disable-attr \
            --disable-blobs \
            --disable-cap-ng \
            --disable-curses \
            --disable-docs \
            --disable-glusterfs \
            --disable-gtk \
            --disable-guest-agent \
            --disable-libnfs \
            --disable-libiscsi \
            --disable-libssh2 \
            --disable-libusb \
            --disable-quorum \
            --disable-seccomp \
            --disable-spice \
            --disable-smartcard-nss \
            --disable-usb-redir \
            --disable-user \
            --disable-vde \
            --disable-vhdx \
            --disable-vhost-net \

            # The Windows parallel build fails early on, so try to catch
            # up later with -j1 to complete it.
            (run make -j$NUM_JOBS || run make -j1 || true)

            if [ ! -f "aarch64-softmmu/qemu-system-aarch64$HOST_EXE_EXTENSION" ]; then
                panic "$CURRENT_TEXT Could not build qemu-system-aarch64!!"
            fi

    ) || panic "Build failed!!"

    dump "$CURRENT_TEXT Copying qemu-system-aarch64 to binaries/$CURRENT_HOST"

    BINARY_DIR=$(dirname "$0")/../binaries/$CURRENT_HOST
    run mkdir -p "$BINARY_DIR" ||
    panic "Could not create final directory: $BINARY_DIR"

    run cp -p \
        "$BUILD_DIR"/qemu-android/aarch64-softmmu/qemu-system-aarch64$HOST_EXE_EXTENSION \
        "$BINARY_DIR"/qemu-system-aarch64$HOST_EXE_EXTENSION

    run ${GNU_CONFIG_HOST}-strip "$BINARY_DIR"/qemu-system-aarch64$HOST_EXE_EXTENSION
}

build_qemu_android linux-x86
build_qemu_android linux-x86_64
build_qemu_android windows-x86
build_qemu_android windows-x86_64

echo "Done!"
