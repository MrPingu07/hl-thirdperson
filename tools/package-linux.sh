#!/usr/bin/env bash
# Builds the mod for Linux (32-bit) and assembles dist/<MOD_NAME> plus a zip archive.
#
# Usage: tools/package-linux.sh [--install]
#
# Environment:
#   HL_DIR    Half-Life install directory used by --install
#             (default: ~/.steam/steam/steamapps/common/Half-Life)
#   MOD_NAME  Mod folder name (default: hltps)
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT=$(pwd)
MOD_NAME=${MOD_NAME:-hltps}
HL_DIR=${HL_DIR:-$HOME/.steam/steam/steamapps/common/Half-Life}
DIST="$ROOT/dist/$MOD_NAME"

# 1. Build (static libstdc++ avoids GLIBCXX errors on other distributions)
export LDFLAGS="-static-libstdc++ -static-libgcc"
./waf configure
./waf build

# 2. Locate the build outputs
HL_SO=$(find build -type f -name 'hl*.so' | head -n 1)
CL_SO=$(find build -type f -name 'client*.so' | head -n 1)
if [ -z "$HL_SO" ] || [ -z "$CL_SO" ]; then
    echo "Build outputs not found in build/" >&2
    exit 1
fi

# 3. Assemble the mod folder
rm -rf "$DIST"
mkdir -p "$DIST/dlls" "$DIST/cl_dlls"
cp "$HL_SO" "$DIST/dlls/hl.so"
cp "$CL_SO" "$DIST/cl_dlls/client.so"
strip --strip-unneeded "$DIST/dlls/hl.so" "$DIST/cl_dlls/client.so"

cat > "$DIST/liblist.gam" <<'EOF'
game "Half-Life Third Person"
gamedll "dlls/hl.dll"
gamedll_linux "dlls/hl.so"
type "singleplayer_only"
EOF

cp THIRDPERSON.md "$DIST/README.md"
cp LICENSE* "$DIST/" 2>/dev/null || true

# 4. Sanity check: Half-Life retail is a 32-bit game
for f in "$DIST/dlls/hl.so" "$DIST/cl_dlls/client.so"; do
    if ! file "$f" | grep -q 'ELF 32-bit'; then
        echo "Not a 32-bit ELF: $f" >&2
        exit 1
    fi
done

# 5. Archive
cd "$ROOT/dist"
rm -f "$MOD_NAME-linux.zip"
if command -v zip >/dev/null 2>&1; then
    zip -rq "$MOD_NAME-linux.zip" "$MOD_NAME"
else
    python3 -m zipfile -c "$MOD_NAME-linux.zip" "$MOD_NAME"
fi
echo "Package: dist/$MOD_NAME-linux.zip"

# 6. Optional install into the Half-Life folder (does not touch config.cfg)
if [ "${1:-}" = "--install" ]; then
    if [ ! -d "$HL_DIR" ]; then
        echo "HL_DIR not found: $HL_DIR" >&2
        exit 1
    fi
    mkdir -p "$HL_DIR/$MOD_NAME"
    cp -r "$DIST/." "$HL_DIR/$MOD_NAME/"
    echo "Installed to $HL_DIR/$MOD_NAME"
fi
