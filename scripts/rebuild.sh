#!/bin/sh

. $(dirname "$0")/common.shi
shell_import build-defaults.shi

case $(uname -s) in
    Linux)
        BUILD_OS=linux
        DEFAULT_SYSTEMS="linux-x86_64,windows-x86_64"
        ;;
    Darwin)
        BUILD_OS=darwin
        DEFAULT_SYSTEMS="darwin-x86_64"
        ;;
    *)
        panic "Your operating system is not supported!"
        ;;
esac

# List of valid target systems.
VALID_SYSTEMS="linux-x86,linux-x86_64,windows-x86,windows-x86_64,darwin-x86,darwin-x86_64"

OPT_BUILD_DIR=
OPT_DARWIN_SSH=
OPT_HELP=
OPT_NO_CCACHE=
OPT_NUM_JOBS=
OPT_SYSTEM=

for OPT; do
    OPTARG=$(expr "x$OPT" : "x[^=]*=\\(.*\\)" || true)
    case $OPT in
        --build-dir=*)
            OPT_BUILD_DIR=$OPTARG
            ;;
        --darwin-ssh=*)
            OPT_DARWIN_SSH=$OPTARG
            ;;
        --help|-?)
            OPT_HELP=true
            ;;
        -j*)
            OPT_NUM_JOBS=${OPT##-j}
            ;;
        --jobs=*)
            OPT_NUM_JOBS=$OPTARG
            ;;
        --no-ccache)
            OPT_NO_CCACHE=true
            ;;
        --quiet)
            decrement_verbosity
            ;;
        --system=*)
            OPT_SYSTEM=$OPTARG
            ;;
        --verbose)
            increment_verbosity
            ;;
        -*)
            panic "Unknown option '$OPT', see --help."
            ;;
        *)
            PARAM_COUNT=$(( $PARAM_COUNT + 1))
            var_assign PARAM_${PARAM_COUNT} "$OPT"
            ;;
    esac
done

if [ "$OPT_HELP" ]; then
    cat <<EOF
Usage: $(program_name) [options]  <qemu-android-dir> <aosp-dir>

Rebuild qemu-android binaries from scratch. This requires two other
directories to be available:

  <qemu-android-dir>
      Path to a checkout of the QEMU-Android sources from
      https://qemu-android.googlesource.com/qemu-android

  <aosp-dir>
      Path to a checkout of an AOSP workspace. This is only used to
      use the prebuilts toolchains under prebuilts/gcc/

By default, everything is rebuilt in a temporary directory that is
automatically removed after script completion (and after the binaries are
copied into binaries/). This is very long due to the dependencies.

When performing incremental builds, it is HIGHLY recommended to use the
--build-dir=<path> option. This ensures that the dependencies are only
rebuilt once and kept under <path>. Note that the build directory will
also not be removed by the script in this case.

Valid options:
    --help|-?           Print this message.
    --verbose           Increase verbosity.
    --quiet             Decrease verbosity.
    --system=<list>     List of target systems [$DEFAULT_SYSTEMS].
    --darwin-ssh=<host> Perform remote build through SSH.
    --build-dir=<path>  Use specific build directory (default is temporary).
    --no-ccache         Don't try to probe and use ccache during build.
    -j<count>           Run <count> parallel build jobs.
    --jobs=<count>      Same as -j<count>.

EOF
    exit 0
fi

##
## Handle target system list
##
if [ "$OPT_SYSTEM" ]; then
    SYSTEMS=$(commas_to_spaces "$OPT_SYSTEM")
else
    SYSTEMS=$(commas_to_spaces "$DEFAULT_SYSTEMS")
    log "Auto-config: --system='$SYSTEMS'"
fi

BAD_SYSTEMS=
for SYSTEM in $SYSTEMS; do
    if ! list_contains "$VALID_SYSTEMS" "$SYSTEM"; then
        BAD_SYSTEMS="$BAD_SYSTEMS $SYSTEM"
    fi
done
if [ "$BAD_SYSTEMS" ]; then
    panic "Invalid system name(s): [$BAD_SYSTEMS], use one of: $VALID_SYSTEMS"
fi

##
## Handle remote darwin build
##
DARWIN_SSH=
if [ "$OPT_DARWIN_SSH" ]; then
    DARWIN_SSH=$OPT_DARWIN_SSH
elif [ "$ANDROID_EMULATOR_DARWIN_SSH" ]; then
    DARWIN_SSH=$ANDROID_EMULATOR_DARWIN_SSH
    log "Auto-config: --darwin-ssh=$DARWIN_SSH  [ANDROID_EMULATOR_DARWIN_SSH]"
fi

if [ "$DARWIN_SSH" ]; then
    HAS_DARWIN=
    for SYSTEM in $(commas_to_spaces "$SYSTEMS"); do
        case $SYSTEM in
            darwin-*)
                HAS_DARWIN=true
                ;;
        esac
    done
    if [ -z "$HAS_DARWIN" ]; then
        SYSTEMS="$SYSTEMS darwin-x86_64"
        log "Auto-config: --system='$SYSTEMS'  [darwin-ssh]"
    fi
fi

##
##  Parameters checks
##
if [ "$PARAM_COUNT" != 2 ]; then
    panic "This script requires two arguments, see --help for details."
fi

QEMU_ANDROID=$PARAM_1
if [ ! -f "$QEMU_ANDROID/include/qemu-common.h" ]; then
    panic "Not a valid qemu-android source directory: $QEMU_ANDROID"
fi

# Sanity check: a fresh qemu-android checkout is missing the libfdt
# sub-module and won't compile without it
if [ ! -f "$QEMU_ANDROID/dtc/Makefile" ]; then
    >&2 cat <<EOF
ERROR: Your qemu-android checkout does not have the device-tree library
       submodule (libfdt, a.k.a. DTC) checked out. Please run the
       following command, then re-run this script:

  (cd $QEMU_ANDROID && git submodule update --init dtc)

EOF
    exit 1
fi

# Sanity check: We need the 'ranchu' branch checked out in qemu-android
if [ ! -f "$QEMU_ANDROID/hw/misc/android_pipe.c" ]; then
    >&2 cat <<EOF
ERROR: Your qemu-android checkout is not from the 'ranchu' branch. Please
       run the following command an re-run this script:

  (cd $QEMU_ANDROID && git checkout origin/ranchu)

EOF
    exit 1
fi

AOSP_SOURCE_DIR=$PARAM_2
if [ ! -d "$AOSP_SOURCE_DIR"/prebuilts/gcc ]; then
    panic "Not a valid AOSP checkout directory: $AOSP_SOURCE_DIR"
fi

# Do we have ccache ?
if [ -z "$OPT_NO_CCACHE" ]; then
    CCACHE=$(which ccache 2>/dev/null || true)
    if [ "$CCACHE" ]; then
        log "Found ccache as: $CCACHE"
    else
        log "Cannot find ccache in PATH."
    fi
fi

ARCHIVE_DIR=$(dirname "$0")/../archive
if [ ! -d "$ARCHIVE_DIR" ]; then
    panic "Missing archive directory: $ARCHIVE_DIR"
fi
ARCHIVE_DIR=$(cd "$ARCHIVE_DIR" && pwd -P)
log "Using archive directory: $ARCHIVE_DIR"

case $BUILD_OS in
    darwin)
        # Force the use of the 10.8 SDK on OS X, this
        # ensures that the generated binaries run properly
        # on that platform, and also avoids build failures
        # in SDL!!
        export SDKROOT=macosx10.8
        ;;
esac

if [ "$OPT_BUILD_DIR" ]; then
    TEMP_DIR=$OPT_BUILD_DIR
else
    TEMP_DIR=/tmp/$USER-build-qemu-ranchu-$$
    log "Auto-config: --build-dir=$TEMP_DIR"
fi
run mkdir -p "$TEMP_DIR" ||
panic "Could not create build directory: $TEMP_DIR"

cleanup_temp_dir () {
    rm -rf "$TEMP_DIR"
    exit $1
}

if [ -z "$OPT_BUILD_DIR" ]; then
    # Ensure temporary directory is deleted on script exit, unless
    # --build-dir=<path> was used.
    trap "cleanup_temp_dir 0" EXIT
    trap "cleanup_temp_dir \$?" QUIT INT HUP
fi

log "Cleaning up build directory."
run rm -rf "$TEMP_DIR"/build-*

if [ "$OPT_NUM_JOBS" ]; then
    NUM_JONS=$OPT_NUM_JOBS
    log "Parallel jobs count: $NUM_JOBS"
else
    NUM_JOBS=$(get_build_num_cores)
    log "Auto-config: --jobs=$NUM_JOBS"
fi

ORIGINAL_PATH=$PATH

export PKG_CONFIG=$(which pkg-config 2>/dev/null)
if [ "$PKG_CONFIG" ]; then
    log "Found pkg-config at: $PKG_CONFIG"
else
    log "pkg-config is not installed on this system."
fi

# Generate a small toolchain wrapper program
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
        darwin-*)
            # Use host GCC for now.
            PREBUILT_TOOLCHAIN_DIR=
            TOOLCHAIN_PREFIX=
            HOST_EXE_EXTENSION=
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
        darwin-*)
            # Use host compiler.
            GNU_CONFIG_HOST=
            ;;
        *)
            panic "Host system '$CURRENT_HOST' is not supported by this script!"
            ;;
    esac

    if [ "$GNU_CONFIG_HOST" ]; then
        GNU_CONFIG_HOST_FLAG="--host=$GNU_CONFIG_HOST"
        GNU_CONFIG_HOST_PREFIX=${GNU_CONFIG_HOST}-
    else
        GNU_CONFIG_HOST_FLAG=
        GNU_CONFIG_HOST_PREFIX=
    fi

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

    PREFIX=$TEMP_DIR/install-$CURRENT_HOST
    log "$CURRENT_TEXT Using build prefix: $PREFIX"
    EXTRA_CFLAGS="$EXTRA_CFLAGS -I$PREFIX/include"
    EXTRA_CXXFLAGS="$EXTRA_CXXFLAGS -I$PREFIX/include"
    EXTRA_LDFLAGS="$EXTRA_LDFLAGS -L$PREFIX/lib"

    if [ "$GNU_CONFIG_HOST" ]; then
      log "$CURRENT_TEXT Generating $CROSS_PREFIX wrapper toolchain in $TOOLCHAIN_WRAPPER_DIR"
      TOOLCHAIN_WRAPPER_DIR=$BUILD_DIR/toolchain-wrapper
      gen_wrapper_toolchain "${GNU_CONFIG_HOST_PREFIX}" "$PREBUILT_TOOLCHAIN_DIR/bin/$TOOLCHAIN_PREFIX" "$TOOLCHAIN_WRAPPER_DIR"
      PATH=$TOOLCHAIN_WRAPPER_DIR:$PATH
      log "$CURRENT_TEXT Path: $(echo \"$PATH\" | tr ' ' '\n')"
    fi

    # Save environment definitions to file.
    set > $BUILD_DIR/environment.txt
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
        run cd "$BUILD_DIR/zlib-$ZLIB_VERSION" &&
        export BINARY_PATH=$PREFIX/bin &&
        export INCLUDE_PATH=$PREFIX/include &&
        export LIBRARY_PATH=$PREFIX/lib &&
        run make -fwin32/Makefile.gcc install PREFIX=$CROSS_PREFIX LOC=$LOC LDFLAGS=$LDFLAGS
    )
}

do_zlib_package () {
    local ZLIB_VERSION ZLIB_PACKAGE
    local LOC LDFLAGS
    case $CURRENT_HOST in
        *-x86)
            LOC=-m32
            LDFLAGS=-m32
            ;;
        *-x86_64)
            LOC=-m64
            LDFLAGS=-m64
            ;;
    esac
    ZLIB_VERSION=$(get_source_package_version zlib)
    dump "$CURRENT_TEXT Building zlib-$ZLIB_VERSION"
    ZLIB_PACKAGE=$(get_source_package_name zlib)
    unpack_archive "$ARCHIVE_DIR/$ZLIB_PACKAGE" "$BUILD_DIR"
    (
        run cd "$BUILD_DIR/zlib-$ZLIB_VERSION" &&
        export CROSS_PREFIX=${GNU_CONFIG_HOST_PREFIX} &&
        run ./configure --prefix=$PREFIX &&
        run make -j$NUM_JOBS &&
        run make install
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

# Unpack and patch GLib sources
# $1: Unversioned package name (e.g. 'glib')
unpack_and_patch () {
    local PKG_NAME="$1"
    local PKG_VERSION PKG_PACKAGE PKG_PATCHES_DIR PKG_PATCHES_PACKAGE
    local PKG_DIR PATCH
    PKG_VERSION=$(get_source_package_version $PKG_NAME)
    if [ -z "$PKG_VERSION" ]; then
        panic "Cannot find version for package $PKG_NAME!"
    fi
    log "Extracting $PKG_NAME-$PKG_VERSION"
    PKG_PACKAGE=$(get_source_package_name $PKG_NAME)
    unpack_archive "$ARCHIVE_DIR/$PKG_PACKAGE" "$BUILD_DIR" ||
    panic "Could not unpack $PKG_NAME-$PKG_VERSION"
    PKG_DIR=$BUILD_DIR/$PKG_NAME-$PKG_VERSION

    PKG_PATCHES_DIR=$PKG_NAME-$PKG_VERSION-patches
    PKG_PATCHES_PACKAGE=$ARCHIVE_DIR/${PKG_PATCHES_DIR}.tar.xz
    if [ -f "$PKG_PATCHES_PACKAGE" ]; then
        log "Patching $PKG_NAME-$PKG_VERSION"
        unpack_archive "$PKG_PATCHES_PACKAGE" "$BUILD_DIR"
        for PATCH in $(cd "$BUILD_DIR" && ls "$PKG_PATCHES_DIR"/*.patch); do
            log "Applying patch: $PATCH"
            (cd "$PKG_DIR" && run patch -p1 < "../$PATCH") ||
                    panic "Could not apply $PATCH"
        done
    fi
}

# Cross-compiling glib for Win32 is broken and requires special care.
# The following was inspired by the glib.mk from MXE (http://mxe.cc/)
# $1: bitness (32 or 64)
do_windows_glib_package () {
    unpack_and_patch glib
    local GLIB_VERSION GLIB_PACKAGE GLIB_DIR
    GLIB_VERSION=$(get_source_package_version glib)
    GLIB_DIR=$BUILD_DIR/glib-$GLIB_VERSION
    dump "$CURRENT_TEXT Building glib-$GLIB_VERSION"
    require_program GLIB_GENMARSHAL glib-genmarshal
    require_program GLIB_COMPILE_SCHEMAS glib-compile-schemas
    require_program GLIB_COMPILE_RESOURCES glib-compile-resources
    (
        run cd "$GLIB_DIR" &&
        export LDFLAGS="-L$PREFIX/lib -L$PREFIX/lib$1" &&
        export CPPFLAGS="-I$PREFIX/include -I$GLIB_DIR -I$GLIB_DIR/glib" &&
        export CC=${GNU_CONFIG_HOST_PREFIX}gcc &&
        export CXX=${GNU_CONFIG_HOST_PREFIX}c++ &&
        export PKG_CONFIG=$(which pkg-config) &&
        export PKG_CONFIG_PATH=$PREFIX/lib/pkgconfig &&
        run ./configure \
            --prefix=$PREFIX \
            $GNU_CONFIG_HOST_FLAG \
            --disable-shared \
            --with-threads=win32 \
            --with-pcre=internal \
            --disable-debug \
            --disable-man \
            --with-libiconv=no \
            GLIB_GENMARSHAL=$GLIB_GENMARSHAL \
            GLIB_COMPILE_SCHEMAS=$GLIB_COMPILE_SCHEMAS \
            GLIB_COMPILE_RESOURCES=$GLIB_COMPILE_RESOURCES &&

        # Necessary to build gio stuff properly.
        run ln -s "$GLIB_COMPILE_RESOURCES" gio/ &&

        run make -j$NUM_JOBS -C glib install sbin_PROGRAMS= noinst_PROGRAMS= &&
        run make -j$NUM_JOBS -C gmodule install bin_PROGRAMS= sbin_PROGRAMS= noinst_PROGRAMS= &&
        run make -j$NUM_JOBS -C gthread install bin_PROGRAMS= sbin_PROGRAMS= noinst_PROGRAMS= &&
        run make -j$NUM_JOBS -C gobject install bin_PROGRAMS= sbin_PROGRAMS= noinst_PROGRAMS= &&
        run make -j$NUM_JOBS -C gio install bin_PROGRAMS= sbin_PROGRAMS= noinst_PROGRAMS= MISC_STUFF= &&
        run make -j$NUM_JOBS install-pkgconfigDATA &&
        run make -j$NUM_JOBS -C m4macros install &&

        # Missing -lole32 results in link failure later!
        sed -i -e 's|\-lglib-2.0|-lglib-2.0 -lole32|g' \
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
    unpack_and_patch $PKG
    PKG_VERSION=$(get_source_package_version $PKG)
    PKG_NAME=$(get_source_package_name $PKG)
    dump "$CURRENT_TEXT Building $PKG-$PKG_VERSION"
    (
        run cd "$BUILD_DIR/$PKG-$PKG_VERSION" &&
        export LDFLAGS="-L$PREFIX/lib" &&
        export CPPFLAGS="-I$PREFIX/include" &&
        export PKG_CONFIG_LIBDIR="$PREFIX/lib/pkgconfig" &&
        run ./configure \
            --prefix=$PREFIX \
            $GNU_CONFIG_HOST_FLAG \
            --disable-shared \
            --with-pic \
            "$@" &&
        run make -j$NUM_JOBS V=1 &&
        run make install V=1
    ) ||
    panic "Could not build and install $PKG_NAME"
}

# $1: host os name.
build_qemu_android_deps () {
    prepare_build_for_host $1

    export PKG_CONFIG_PATH=$PREFIX/lib/pkgconfig
    # Handle zlib for Windows
    case $1 in
        windows-*)
            do_windows_zlib_package
            ;;
        *)
            do_zlib_package
            ;;
    esac

    # libffi is required by glib.
    do_autotools_package libffi

    # Must define LIBFFI_CFLAGS and LIBFFI_LIBS to ensure
    # that GLib picks it up properly. Note that libffi places
    # its headers and libraries in uncommon places.
    LIBFFI_VERSION=$(get_source_package_version libffi)
    LIBFFI_CFLAGS="-I$PREFIX/lib/libffi-$LIBFFI_VERSION/include"
    LIBFFI_LIBS="$PREFIX/lib/libffi.la"
    if [ ! -f "$LIBFFI_LIBS" ]; then
        LIBFFI_LIBS="$PREFIX/lib64/libffi.la"
    fi
    if [ ! -f "$LIBFFI_LIBS" ]; then
        LIBFFI_LIBS="$PREFIX/lib32/libffi.la"
    fi
    if [ ! -f "$LIBFFI_LIBS" ]; then
        panic "Cannot locate libffi libraries!"
    fi

    log "Using LIBFFI_CFLAGS=[$LIBFFI_CFLAGS]"
    log "Using LIBFFI_LIBS=[$LIBFFI_LIBS]"
    export LIBFFI_CFLAGS LIBFFI_LIBS

    # libiconv and gettext are needed on Darwin only
    case $1 in
        darwin-*)
            do_autotools_package libiconv
            do_autotools_package gettext \
                --disable-rpath \
                --disable-acl \
                --disable-curses \
                --disable-openmp \
                --disable-java \
                --disable-native-java \
                --without-emacs \
                --disable-c++ \
                --without-libexpat-prefix
            ;;
    esac

    # glib is required by pkg-config and qemu-android
    case $1 in
        windows-x86)
            do_windows_glib_package 32
            ;;
        windows-x86_64)
            do_windows_glib_package 64
            ;;
        *)
            do_autotools_package glib \
                --disable-always-build-tests \
                --disable-debug \
                --disable-fam \
                --disable-included-printf \
                --disable-installed-tests \
                --disable-libelf \
                --disable-man \
                --disable-selinux \
                --disable-xattr
            ;;
    esac

    # Export these to ensure that pkg-config picks them up properly.
    export GLIB_CFLAGS="-I$PREFIX/include/glib-2.0 -I$PREFIX/lib/glib-2.0/include"
    export GLIB_LIBS="$PREFIX/lib/libglib-2.0.la"
    case $BUILD_OS in
        darwin)
            GLIB_LIBS="$GLIB_LIBS -Wl,-framework,Carbon -Wl,-framework,Foundation"
            ;;
    esac

    # pkg-config is required by qemu-android, and not available on
    # Windows and OS X
    do_autotools_package pkg-config \
        --without-pc-path \
        --disable-host-tool

    # Handle libpng
    do_autotools_package libpng

    do_autotools_package pixman \
        --disable-gtk \
        --disable-libpng

    EXTRA_SDL_FLAGS=
    case $BUILD_OS in
        darwin)
            EXTRA_SDL_FLAGS="--disable-video-x11"
            ;;
    esac
    do_autotools_package SDL \
        --disable-audio \
        --disable-joystick \
        --disable-cdrom \
        --disable-file \
        --disable-threads \
        $EXTRA_SDL_FLAGS

    # The SDL build script install a buggy sdl.pc when cross-compiling for
    # Windows as a static library. I.e. it lacks many of the required
    # libraries, that are part of --static-libs. Patch it directly
    # instead.
    case $1 in
        windows-*)
            sed -i -e 's|^Libs: -L\${libdir}  -lmingw32 -lSDLmain -lSDL  -mwindows|Libs: -lmingw32 -lSDLmain -lSDL  -mwindows -lm -luser32 -lgdi32 -lwinmm -ldxguid|g' $PREFIX/lib/pkgconfig/sdl.pc
            ;;
    esac

    SDL_CONFIG=$PREFIX/bin/sdl-config
    PKG_CONFIG_LIBDIR=$PREFIX/lib/pkgconfig

    case $1 in
        windows-*)
            # Use the host version, or the build will freeze.
            PKG_CONFIG=pkg-config
            ;;
        *)
            PKG_CONFIG=$PREFIX/bin/pkg-config
            ;;
    esac
    export SDL_CONFIG PKG_CONFIG PKG_CONFIG_LIBDIR

    # Create script to setup the environment correctly for the
    # later qemu-android build.
    ENV_SH=$TEMP_DIR/env-$CURRENT_HOST.sh
    cat > $ENV_SH <<EOF
# Auto-generated automatically - DO NOT EDIT
export PREFIX=$PREFIX
export LIBFFI_CFLAGS="$LIBFFI_CFLAGS"
export LIBFFI_LIBS="$LIBFFI_LIBS"
export GLIB_CFLAGS="$GLIB_CFLAGS"
export GLIB_LIBS="$GLIB_LIBS"
export SDL_CONFIG=$SDL_CONFIG
export PKG_CONFIG=$PKG_CONFIG
export PKG_CONFIG_LIBDIR=$PKG_CONFIG_LIBDIR
export PKG_CONFIG_PATH=$PKG_CONFIG_PATH
export PATH=$PATH
EOF
}

# $1: host os name.
build_qemu_android () {
    prepare_build_for_host $1

    ENV_SH=$TEMP_DIR/env-$CURRENT_HOST.sh
    if [ ! -f "$ENV_SH" ]; then
        build_qemu_android_deps $1
    fi

    . "$ENV_SH"

    dump "$CURRENT_TEXT Building qemu-android"
    (
        run mkdir -p "$BUILD_DIR/qemu-android"
        run rm -rf "$BUILD_DIR"/qemu-android/*
        run cd "$BUILD_DIR/qemu-android"
        EXTRA_LDFLAGS="-L$PREFIX/lib"
        case $1 in
           darwin-*)
               EXTRA_LDFLAGS="$EXTRA_LDFLAGS -Wl,-framework,Carbon"
               ;;
           *)
               EXTRA_LDFLAGS="$EXTRA_LDFLAGS -static-libgcc -static-libstdc++"
               ;;
        esac
        case $1 in
            windows-*)
                ;;
            *)
                EXTRA_LDFLAGS="$EXTRA_LDFLAGS -ldl -lm"
                ;;
        esac
        CROSS_PREFIX_FLAG=
        if [ "$GNU_CONFIG_HOST_PREFIX" ]; then
            CROSS_PREFIX_FLAG="--cross-prefix=$GNU_CONFIG_HOST_PREFIX"
        fi
        run $QEMU_ANDROID/configure \
            $CROSS_PREFIX_FLAG \
            --target-list=aarch64-softmmu \
            --prefix=$PREFIX \
            --extra-cflags="-I$PREFIX/include" \
            --extra-ldflags="$EXTRA_LDFLAGS" \
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
            &&

            # The Windows parallel build fails early on, so try to catch
            # up later with -j1 to complete it.
            (run make -j$NUM_JOBS || run make -j1 || true)

            if [ ! -f "aarch64-softmmu/qemu-system-aarch64$HOST_EXE_EXTENSION" ]; then
                panic "$CURRENT_TEXT Could not build qemu-system-aarch64!!"
            fi

    ) || panic "Build failed!!"

    dump "$CURRENT_TEXT Copying qemu-system-aarch64 to binaries/$CURRENT_HOST"

    BINARY_DIR=$(program_directory)/../binaries/$CURRENT_HOST
    run mkdir -p "$BINARY_DIR" ||
    panic "Could not create final directory: $BINARY_DIR"

    run cp -p \
        "$BUILD_DIR"/qemu-android/aarch64-softmmu/qemu-system-aarch64$HOST_EXE_EXTENSION \
        "$BINARY_DIR"/qemu-system-aarch64$HOST_EXE_EXTENSION

    run ${GNU_CONFIG_HOST_PREFIX}strip "$BINARY_DIR"/qemu-system-aarch64$HOST_EXE_EXTENSION

    unset PKG_CONFIG PKG_CONFIG_PATH PKG_CONFIG_LIBDIR SDL_CONFIG
    unset LIBFFI_CFLAGS LIBFFI_LIBS GLIB_CFLAGS GLIB_LIBS
}

# Perform a Darwin build through ssh to a remote machine.
# $1: Darwin host name.
# $2: List of darwin target systems to build for.
do_remote_darwin_build () {
    local PKG_TMP=/tmp/$USER-rebuild-darwin-ssh-$$
    local PKG_SUFFIX=qemu-android-build
    local PKG_DIR=$PKG_TMP/$PKG_SUFFIX
    local PKG_TARBALL=$PKG_SUFFIX.tar.bz2
    local DARWIN_SSH="$1"
    local DARWIN_SYSTEMS="$2"

    DARWIN_SYSTEMS=$(commas_to_spaces "$DARWIN_SYSTEMS")

    dump "Creating tarball for remote darwin build."
    run mkdir -p "$PKG_DIR" && run rm -rf "$PKG_DIR"/*
    run cp -rp "$QEMU_ANDROID" "$PKG_DIR/qemu-android"
    run mkdir -p "$PKG_DIR/aosp/prebuilts/gcc"
    run cp -rp "$(program_directory)" "$PKG_DIR/scripts"
    run cp -rp "$(program_directory)/../archive" "$PKG_DIR/archive"
    local EXTRA_FLAGS=""

    case $(get_verbosity) in
        0)
            # pass
            ;;
        1)
            EXTRA_FLAGS="$EXTRA_FLAGS --verbose"
            ;;
        *)
            EXTRA_FLAGS="$EXTRA_FLAGS --verbose --verbose"
            ;;
    esac

    if [ "$OPT_NUM_JOBS" ]; then
        EXTRA_FLAGS="$EXTRA_FLAGS -j$OPT_NUM_JOBS"
    fi
    if [ "$OPT_NO_CCACHE" ]; then
        EXTRA_FLAGS="$EXTRA_FLAGS --no-ccache"
    fi

    # Generate a script to rebuild all binaries from sources.
    # Note that the use of the '-l' flag is important to ensure
    # that this is run under a login shell. This ensures that
    # ~/.bash_profile is sourced before running the script, which
    # puts MacPorts' /opt/local/bin in the PATH properly.
    #
    # If not, the build is likely to fail with a cryptic error message
    # like "readlink: illegal option -- f"
    cat > $PKG_DIR/build.sh <<EOF
#!/bin/bash -l
PROGDIR=\$(dirname \$0)
\$PROGDIR/scripts/rebuild.sh \\
    --build-dir=/tmp/$PKG_SUFFIX/build \\
    --system=$(spaces_to_commas "$DARWIN_SYSTEMS") \\
    $EXTRA_FLAGS \\
    /tmp/$PKG_SUFFIX/qemu-android \\
    /tmp/$PKG_SUFFIX/aosp
EOF
    chmod a+x $PKG_DIR/build.sh
    run tar cjf "$PKG_TMP/$PKG_TARBALL" -C "$PKG_TMP" "$PKG_SUFFIX"

    dump "Unpacking tarball in remote darwin host."
    run scp "$PKG_TMP/$PKG_TARBALL" "$DARWIN_SSH":/tmp/
    run ssh "$DARWIN_SSH" tar xf /tmp/$PKG_SUFFIX.tar.bz2 -C /tmp

    dump "Performing remote darwin build."
    run ssh "$DARWIN_SSH" /tmp/$PKG_SUFFIX/build.sh

    dump "Retrieving darwin binaries."
    local BINARY_DIR=$(program_directory)/../binaries
    run mkdir -p "$BINARY_DIR" ||
    panic "Could not create final directory: $BINARY_DIR"

    for SYSTEM in $DARWIN_SYSTEMS; do
        run scp -r "$DARWIN_SSH":/tmp/$PKG_SUFFIX/binaries/$SYSTEM $BINARY_DIR/
    done
}

# Special handling for Darwin target systems.
DARWIN_SYSTEMS=
for SYSTEM in $SYSTEMS; do
    case $SYSTEM in
        darwin-*)
            DARWIN_SYSTEMS="$DARWIN_SYSTEMS $SYSTEM"
            ;;
    esac
done

if [ "$DARWIN_SSH" ]; then
    # Perform remote Darwin build first.
    if [ "$DARWIN_SYSTEMS" ]; then
        do_remote_darwin_build "$DARWIN_SSH" "$DARWIN_SYSTEMS"
    elif [ "$OPT_DARWIN_SSH" ]; then
        panic "--darwin-ssh=<host> used, but --system does not list Darwin systems."
    fi
elif [ "$DARWIN_SYSTEMS" -a "$BUILD_OS" != "darwin" ]; then
    panic "Cannot build darwin binaries on this machine. Use --darwin-ssh=<host>."
fi

for SYSTEM in $SYSTEMS; do
    # Ignore darwin builds if we're not on a Darwin
    if [ "$BUILD_OS" != "darwin" ]; then
        case "$SYSTEM" in
            darwin-*)
                continue
                ;;
        esac
    fi

    build_qemu_android $SYSTEM
done

echo "Done!"
