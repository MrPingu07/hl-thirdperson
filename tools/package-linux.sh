#!/usr/bin/env bash
# Builds the mod for Linux (32-bit) and assembles dist/<MOD_NAME> plus a zip archive.
#
# Usage: tools/package-linux.sh [--install] [--no-build] [--no-zip] [--xash-build-dir DIR]
#
# Options:
#   --install         Copy the packaged mod into the Half-Life folder and link the
#                     retail menus/intro video into it (link-game-content.sh)
#   --no-build        Skip waf configure/build and package the existing build/
#   --no-zip          Do not create the zip archive
#   --xash-build-dir  Also package the Xash amd64 libraries from DIR
#                     (expects DIR/dlls/hl_amd64.so and DIR/cl_dlls/client_amd64.so)
#   --xash-zip-suffix Override zip filename suffix (default: xash-amd64-linux)
#
# Environment:
#   HL_DIR            Half-Life install directory used by --install
#                     (default: ~/.steam/steam/steamapps/common/Half-Life)
#   MOD_NAME          Mod folder name (default: hltps)
#   BUILD_DIR         Build directory to package (default: build). Used with --no-build
#                     to package a build produced by another toolchain (e.g. CMake).
#   XASH_BUILD_DIR    Xash build directory (alternative to --xash-build-dir)
#   XASH_ZIP_SUFFIX   Zip suffix (alternative to --xash-zip-suffix)
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT=$(pwd)
MOD_NAME=${MOD_NAME:-hltps}
HL_DIR=${HL_DIR:-$HOME/.steam/steam/steamapps/common/Half-Life}
BUILD_DIR=${BUILD_DIR:-build}
XASH_BUILD_DIR=${XASH_BUILD_DIR:-}
XASH_ZIP_SUFFIX=${XASH_ZIP_SUFFIX:-xash-amd64-linux}
DIST="$ROOT/dist/$MOD_NAME"

DO_INSTALL=0
SKIP_BUILD=0
DO_ZIP=1

usage()
{
    awk 'NR==1{next} /^#/{sub(/^# ?/,""); print; next} {exit}' "$0"
}

while [ $# -gt 0 ]; do
    case "$1" in
        --install)         DO_INSTALL=1 ;;
        --no-build)        SKIP_BUILD=1 ;;
        --no-zip)          DO_ZIP=0 ;;
        --xash-build-dir)  XASH_BUILD_DIR="$2"; shift ;;
        --xash-zip-suffix) XASH_ZIP_SUFFIX="$2"; shift ;;
        -h|--help)         usage; exit 0 ;;
        *) echo "Unknown option: $1 (try --help)" >&2; exit 1 ;;
    esac
    shift
done

# 1. Build (static libstdc++ avoids GLIBCXX errors on other distributions)
if [ "$SKIP_BUILD" -eq 0 ]; then
    export LDFLAGS="-static-libstdc++ -static-libgcc"
    ./waf configure
    ./waf build
fi

# 2. Locate the build outputs (32-bit GoldSrc)
HL_SO=$(find "$BUILD_DIR" -type f -name 'hl*.so' | head -n 1)
CL_SO=$(find "$BUILD_DIR" -type f -name 'client*.so' | head -n 1)
if [ -z "$HL_SO" ] || [ -z "$CL_SO" ]; then
    echo "Build outputs not found in $BUILD_DIR" >&2
    exit 1
fi

# 3. Assemble the mod folder
rm -rf "$DIST"
mkdir -p "$DIST/dlls" "$DIST/cl_dlls"
cp "$HL_SO" "$DIST/dlls/hl.so"
cp "$CL_SO" "$DIST/cl_dlls/client.so"
strip --strip-unneeded "$DIST/dlls/hl.so" "$DIST/cl_dlls/client.so"

# Optional Xash amd64 libraries
if [ -n "$XASH_BUILD_DIR" ] && [ -d "$XASH_BUILD_DIR" ]; then
    XASH_HL=$(find "$XASH_BUILD_DIR" -type f -name 'hl_amd64.so' | head -n 1)
    XASH_CL=$(find "$XASH_BUILD_DIR" -type f -name 'client_amd64.so' | head -n 1)
    if [ -n "$XASH_HL" ] && [ -n "$XASH_CL" ]; then
        cp "$XASH_HL" "$DIST/dlls/hl_amd64.so"
        cp "$XASH_CL" "$DIST/cl_dlls/client_amd64.so"
        strip --strip-unneeded "$DIST/dlls/hl_amd64.so" "$DIST/cl_dlls/client_amd64.so"
        echo "Included Xash amd64 libraries"
    else
        echo "Warning: Xash amd64 libraries not found in $XASH_BUILD_DIR" >&2
    fi
fi

# The liblist.gam keys mirror the retail game's, so the engine menus (New Game,
# Training Room, animated title, HD background) behave exactly like Half-Life's.
# fallback_dir makes GoldSrc find the base game content (maps, models, sounds,
# configs) in valve/; tools/link-game-content.sh links the folders the UI reads
# straight from the game folder, where that fallback does not apply.  The file
# is shared with the Windows packager, so both platforms ship the same keys.
cp tools/liblist.gam "$DIST/liblist.gam"

cp THIRDPERSON.md "$DIST/README.md"
cp LICENSE* "$DIST/" 2>/dev/null || true
install -m 0755 tools/link-game-content.sh "$DIST/link-game-content.sh"

# 4. Sanity check: Half-Life retail is a 32-bit game
for f in "$DIST/dlls/hl.so" "$DIST/cl_dlls/client.so"; do
    if ! file "$f" | grep -q 'ELF 32-bit'; then
        echo "Not a 32-bit ELF: $f" >&2
        exit 1
    fi
done

# Xash amd64 sanity check (if present)
if [ -f "$DIST/dlls/hl_amd64.so" ] && [ -f "$DIST/cl_dlls/client_amd64.so" ]; then
    for f in "$DIST/dlls/hl_amd64.so" "$DIST/cl_dlls/client_amd64.so"; do
        if ! file "$f" | grep -q 'ELF 64-bit.*x86-64'; then
            echo "Not a 64-bit x86-64 ELF: $f" >&2
            exit 1
        fi
    done
fi

# 5. Archive
if [ "$DO_ZIP" -eq 1 ]; then
    cd "$ROOT/dist"
    if [ -n "$XASH_BUILD_DIR" ] && [ -d "$XASH_BUILD_DIR" ] && [ -f "$DIST/dlls/hl_amd64.so" ]; then
        ZIP_NAME="$MOD_NAME-$XASH_ZIP_SUFFIX.zip"
    else
        ZIP_NAME="$MOD_NAME-linux.zip"
    fi
    rm -f "$ZIP_NAME"
    if command -v zip >/dev/null 2>&1; then
        zip -rq "$ZIP_NAME" "$MOD_NAME"
    else
        python3 -m zipfile -c "$ZIP_NAME" "$MOD_NAME"
    fi
    echo "Package: dist/$ZIP_NAME"
fi

# 6. Optional install into the Half-Life folder (does not touch config.cfg)
if [ "$DO_INSTALL" -eq 1 ]; then
    if [ ! -d "$HL_DIR" ]; then
        echo "HL_DIR not found: $HL_DIR" >&2
        exit 1
    fi
    mkdir -p "$HL_DIR/$MOD_NAME"
    cp -r "$DIST/." "$HL_DIR/$MOD_NAME/"
    echo "Installed to $HL_DIR/$MOD_NAME"

    # Link the retail menus, intro and options UI into the installed folder.
    if [ -d "$HL_DIR/valve" ]; then
        "$HL_DIR/$MOD_NAME/link-game-content.sh"
    else
        echo "Note: run $MOD_NAME/link-game-content.sh inside your Half-Life folder"
        echo "      to link the retail menus and intro video."
    fi
fi