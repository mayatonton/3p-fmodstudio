#!/usr/bin/env bash

FMOD_ROOT_NAME="fmodstudioapi"
FMOD_VERSION="20307"
FMOD_VERSION_PRETTY="2.03.07"

cd "$(dirname "$0")"

# turn on verbose debugging output for parabuild logs.
exec 4>&1; export BASH_XTRACEFD=4; set -x
# make errors fatal
set -e
# complain about unset env variables
set -u

# Check autobuild is around or fail
if [ -z "$AUTOBUILD" ] ; then
    exit 1
fi

if [ "$OSTYPE" = "cygwin" ] ; then
    export AUTOBUILD="$(cygpath -u $AUTOBUILD)"
fi

# Load autobuild provided shell functions and variables
set +x
eval "$("$AUTOBUILD" source_environment)"
set -x

# Form the official fmod archive URL to fetch
# Note: fmod is provided in 3 flavors (one per platform) of precompiled binaries. We do not have access to source code.
case "$AUTOBUILD_PLATFORM" in
    windows*)
    FMOD_PLATFORM="win-installer"
    FMOD_FILEEXTENSION=".exe"
    ;;
    "darwin")
    FMOD_PLATFORM="mac-installer"
    FMOD_FILEEXTENSION=".dmg"
    ;;
    linux*)
    FMOD_PLATFORM="linux"
    FMOD_FILEEXTENSION=".tar.gz"
    ;;
esac
FMOD_SOURCE_DIR="$FMOD_ROOT_NAME$FMOD_VERSION$FMOD_PLATFORM"
FMOD_ARCHIVE="$FMOD_SOURCE_DIR$FMOD_FILEEXTENSION"

case "$FMOD_ARCHIVE" in
    *.exe)
        # We can't run the NSIS installer as admin in TC
        # so we do this part manually and put the whole lot
        # into the repo instead.
        #
        bash_install_dir="$(pwd)/$FMOD_ROOT_NAME$FMOD_VERSION$FMOD_PLATFORM"
        win_install_dir=`cygpath -w "$bash_install_dir"`
        if [ -f "$bash_install_dir/api/core/inc/fmod.h" ]; then
            echo "FMOD SDK already extracted at $bash_install_dir, skipping installer"
        else
            mkdir -p $bash_install_dir
            #
            # This will invoke the UAC dialog to confirm permission before
            # proceeding.  You can run the build on a 'modified' system with
            # permissions granted to the build account or you might be able
            # to get to the dialog using remote desktop.  Either way, manual
            # preparation for this is required.
            #
            chmod +x "$FMOD_ARCHIVE"
            archive_abs_win=`cygpath -w "$(pwd)/$FMOD_ARCHIVE"`
            cmd.exe /c "$archive_abs_win /S /D=$win_install_dir"
            if [ ! -f "$bash_install_dir/api/core/inc/fmod.h" ]; then
                echo "Please run $FMOD_ARCHIVE as administrator and install to  $win_install_dir"
                exit 1
            fi
        fi
    ;;
    *.tar.gz)
        tar xvf "$FMOD_ARCHIVE"
    ;;
    *.dmg)
        hdid "$FMOD_ARCHIVE"
        mkdir -p "$(pwd)/$FMOD_SOURCE_DIR"
        cp -r /Volumes/FMOD\ Programmers\ API\ Mac/FMOD\ Programmers\ API/* "$FMOD_SOURCE_DIR"
        umount /Volumes/FMOD\ Programmers\ API\ Mac/
    ;;
esac

stage="$(pwd)/stage"
stage_release="$stage/lib/release"
stage_debug="$stage/lib/debug"

# Create the staging license folder
mkdir -p "$stage/LICENSES"

# Create the staging include folders
mkdir -p "$stage/include/fmodstudio"

#Create the staging debug and release folders
mkdir -p "$stage_debug"
mkdir -p "$stage_release"

echo "${FMOD_VERSION_PRETTY}" > "${stage}/VERSION.txt"
COPYFLAGS=""
pushd "$FMOD_SOURCE_DIR"
    case "$AUTOBUILD_PLATFORM" in
        "windows")
        COPYFLAGS="-dR --preserve=mode,timestamps"
            cp $COPYFLAGS "api/core/lib/x86/fmodL_vc.lib" "$stage_debug"
            cp $COPYFLAGS "api/core/lib/x86/fmod_vc.lib" "$stage_release"
            cp $COPYFLAGS "api/core/lib/x86/fmodL.dll" "$stage_debug"
            cp $COPYFLAGS "api/core/lib/x86/fmod.dll" "$stage_release"
        ;;

        "windows64")
        COPYFLAGS="-dR --preserve=mode,timestamps"
            cp $COPYFLAGS "api/core/lib/x64/fmodL_vc.lib" "$stage_debug"
            cp $COPYFLAGS "api/core/lib/x64/fmod_vc.lib" "$stage_release"
            cp $COPYFLAGS "api/core/lib/x64/fmodL.dll" "$stage_debug"
            cp $COPYFLAGS "api/core/lib/x64/fmod.dll" "$stage_release"

            # Stage SDK-bundled opus.dll (FSBank's encoder library, but exports
            # full decode + multistream symbols too). Used by AYAstorm's FMOD
            # codec plugin to add Opus support that libfmod itself lacks.
            cp $COPYFLAGS "api/fsbank/lib/x64/opus.dll" "$stage_release/opus.dll"
            cp $COPYFLAGS "api/fsbank/lib/x64/opus.dll" "$stage_debug/opus.dll"

            # FMOD's Windows SDK ships opus.dll without an import library, so
            # generate opus.lib from the DLL's export table using MSVC tools.
            VSWHERE="/cygdrive/c/Program Files (x86)/Microsoft Visual Studio/Installer/vswhere.exe"
            VS_INSTALL_WIN=$("$VSWHERE" -latest -property installationPath | tr -d '\r')
            VS_INSTALL=$(cygpath -u "$VS_INSTALL_WIN")
            MSVC_DIR=$(ls -d "$VS_INSTALL/VC/Tools/MSVC/"*/ | sort -V | tail -1)
            DUMPBIN="${MSVC_DIR}bin/Hostx64/x64/dumpbin.exe"
            LIBEXE="${MSVC_DIR}bin/Hostx64/x64/lib.exe"
            opus_workdir="$(pwd)/opus_implib_workdir"
            rm -rf "$opus_workdir"
            mkdir -p "$opus_workdir"
            cp "api/fsbank/lib/x64/opus.dll" "$opus_workdir/opus.dll"
            pushd "$opus_workdir"
                "$DUMPBIN" /EXPORTS opus.dll | tr -d '\r' > opus_exports.txt
                # Match dumpbin's "ordinal hint RVA name" rows: 4 fields, first
                # is decimal ordinal, last is the export symbol.  Strip CR
                # first (dumpbin emits CRLF on Windows; cygwin's gawk leaves
                # \r in the field, which breaks both `$` anchors and identifier
                # character classes — symptom: the .def file ends up empty
                # except for `LIBRARY opus`/`EXPORTS` and lib.exe silently
                # produces a 1.5KB import library that has no per-function
                # thunks).  lib.exe itself wants CRLF in the .def file.
                { printf 'LIBRARY opus\r\nEXPORTS\r\n'; \
                  awk 'BEGIN{ORS="\r\n"} NF==4 && $1 ~ /^[0-9]+$/ && $4 ~ /^[A-Za-z_][A-Za-z0-9_]*$/ {print $4}' opus_exports.txt; \
                } > opus.def
                "$LIBEXE" "/DEF:opus.def" "/MACHINE:X64" "/OUT:opus.lib"
            popd
            cp "$opus_workdir/opus.lib" "$stage_release/opus.lib"
            cp "$opus_workdir/opus.lib" "$stage_debug/opus.lib"
        ;;

        darwin*)
            cp "api/core/lib/libfmod.dylib" "$stage_release"
            # Stage SDK-bundled libopus.dylib (FSBank's encoder library, but
            # exports full decode + multistream symbols too). Used by
            # AYAstorm's FMOD codec plugin to add Opus support that libfmod
            # itself lacks. Mirrors the existing linux64 libopus staging.
            # NOTE: untested on macOS — path is a guess based on FMOD's
            # api/core/lib/libfmod.dylib layout. If this `cp` fails, search
            # the SDK for libopus.dylib and adjust the source path.
            cp "api/fsbank/lib/libopus.dylib" "$stage_release"
            pushd "$stage_debug"
              fix_dylib_id libfmodL.dylib
            popd
            pushd "$stage_release"
              fix_dylib_id libfmod.dylib
              fix_dylib_id libopus.dylib
            popd
        ;;

        "linux")
            # Copy the relevant stuff around
            cp -a api/core/lib/x86/libfmod.so* "$stage_release"
         ;;

        "linux64")
            # Copy the relevant stuff around
            cp -a api/core/lib/x86_64/libfmod.so* "$stage_release"
            # Stage SDK-bundled libopus (FSBank's encoder library, but exports
            # full decode + multistream symbols too). Used by AYAstorm's FMOD
            # codec plugin to add Opus support that libfmod itself lacks.
            cp api/fsbank/lib/x86_64/libopus.so "$stage_release/libopus.so.0"
            ln -sf libopus.so.0 "$stage_release/libopus.so"
        ;;
    esac

    # Copy the headers
    cp $COPYFLAGS api/core/inc/*.h "$stage/include/fmodstudio"
    cp $COPYFLAGS api/core/inc/*.hpp "$stage/include/fmodstudio"

    # Copy License (extracted from the readme)
    cp "doc/LICENSE.TXT" "$stage/LICENSES/fmodstudio.txt"
popd

# Stage Opus public headers (vendored from upstream Opus 1.3.1, MIT, matches
# the libopus version FMOD SDK ships). Required to compile AYAstorm's FMOD
# codec plugin that links against the SDK-bundled libopus above.
mkdir -p "$stage/include/opus"
cp opus_include/opus/*.h "$stage/include/opus/"
cp opus_include/COPYING "$stage/LICENSES/opus.txt"

