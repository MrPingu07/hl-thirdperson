#!/usr/bin/env bash
# One-command setup for a fresh clone: submodules, (optional) build
# dependencies, build, package and optionally install the third person mod.
#
# Usage: tools/setup-linux.sh [--deps] [--install] [--hl-dir DIR] [--name NAME] [--no-zip]
#
# Options:
#   --deps        Install the build dependencies for the detected package
#                 manager (off by default: without it the command is only printed)
#   --install     Copy the packaged mod into the Half-Life folder
#   --hl-dir DIR  Half-Life directory (default: autodetected, else
#                 ~/.steam/steam/steamapps/common/Half-Life)
#   --name NAME   Mod folder name (default: hltps, or $MOD_NAME)
#   --no-zip      Do not create dist/<name>-linux.zip
#   -h, --help    Show this help
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT=$(pwd)

DO_DEPS=0
DO_INSTALL=0
DO_ZIP=1
HL_DIR=${HL_DIR:-}
MOD_NAME=${MOD_NAME:-hltps}

usage()
{
    awk 'NR==1{next} /^#/{sub(/^# ?/,""); print; next} {exit}' "$0"
}

while [ $# -gt 0 ]; do
    case "$1" in
        --deps)    DO_DEPS=1 ;;
        --install) DO_INSTALL=1 ;;
        --no-zip)  DO_ZIP=0 ;;
        --hl-dir)  HL_DIR=${2:?--hl-dir needs a directory}; shift ;;
        --name)    MOD_NAME=${2:?--name needs a value}; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Unknown option: $1 (try --help)" >&2; exit 1 ;;
    esac
    shift
done

if [ ! -f wscript ]; then
    echo "wscript not found; run this from the repository." >&2
    exit 1
fi

# 1. Sources
if [ -f .gitmodules ]; then
    echo "==> Updating submodules"
    git submodule update --init --recursive
fi

# 2. Build dependencies
pkg_manager()
{
    for m in pacman apt-get dnf; do
        if command -v "$m" >/dev/null 2>&1; then
            echo "$m"
            return 0
        fi
    done
    return 1
}

deps_command()
{
    case "$(pkg_manager || true)" in
        pacman)
            echo "sudo pacman -S --needed gcc-multilib lib32-glibc cmake git python"
            ;;
        apt-get)
            echo "sudo apt-get update && sudo apt-get install -y gcc-multilib g++-multilib build-essential cmake git python3 zip"
            ;;
        dnf)
            echo "sudo dnf install -y gcc-c++ cmake git python3 glibc-devel.i686 libstdc++.i686 zip"
            ;;
        *)
            echo ""
            ;;
    esac
}

NEED_DEPS=0
if ! command -v cc >/dev/null 2>&1 && ! command -v gcc >/dev/null 2>&1; then
    NEED_DEPS=1
fi
command -v python3 >/dev/null 2>&1 || NEED_DEPS=1

if [ "$NEED_DEPS" -eq 1 ]; then
    CMD=$(deps_command)
    if [ "$DO_DEPS" -eq 1 ] && [ -n "$CMD" ]; then
        echo "==> Installing build dependencies"
        # shellcheck disable=SC2086
        eval "$CMD"
    else
        echo "Missing build tools (need a 64-bit host with a 32-bit capable C/C++ compiler and python3)." >&2
        if [ -n "$CMD" ]; then
            echo "Install them with:" >&2
            echo "    $CMD" >&2
            echo "or re-run with --deps to do it automatically." >&2
        else
            echo "Install a 32-bit capable C/C++ toolchain, python3 and git for your distribution." >&2
        fi
        exit 1
    fi
fi

# 3. Half-Life directory (only needed by --install)
find_hl_dir()
{
    local vdf lib path
    for vdf in \
        "$HOME/.steam/steam/steamapps/libraryfolders.vdf" \
        "$HOME/.steam/root/steamapps/libraryfolders.vdf" \
        "$HOME/.local/share/Steam/steamapps/libraryfolders.vdf"; do
        [ -f "$vdf" ] || continue
        while IFS= read -r path; do
            if [ -d "$path/steamapps/common/Half-Life" ]; then
                echo "$path/steamapps/common/Half-Life"
                return 0
            fi
        done < <(sed -n 's/.*"path"[[:space:]]*"\(.*\)".*/\1/p' "$vdf")
    done
    return 1
}

if [ "$DO_INSTALL" -eq 1 ] && [ -z "$HL_DIR" ]; then
    HL_DIR=$(find_hl_dir || true)
    if [ -z "$HL_DIR" ]; then
        echo "Could not find Half-Life; pass --hl-dir or set HL_DIR." >&2
        exit 1
    fi
    echo "==> Half-Life: $HL_DIR"
fi

# 4. Build and package (package-linux.sh owns the build and the archive layout)
export MOD_NAME
if [ -n "$HL_DIR" ]; then
    export HL_DIR
fi

PKG_ARGS=()
[ "$DO_ZIP" -eq 0 ] && PKG_ARGS+=(--no-zip)
[ "$DO_INSTALL" -eq 1 ] && PKG_ARGS+=(--install)

echo "==> Building and packaging"
tools/package-linux.sh "${PKG_ARGS[@]}"

echo
if [ "$DO_ZIP" -eq 1 ]; then
    echo "Package: dist/$MOD_NAME-linux.zip"
fi
if [ "$DO_INSTALL" -eq 1 ]; then
    echo "Installed to $HL_DIR/$MOD_NAME. Launch with: -game $MOD_NAME -console"
else
    echo "Install it with: tools/setup-linux.sh --install"
fi
