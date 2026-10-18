#!/usr/bin/env bash
# link-game-content.sh - bridge this mod folder to the retail Half-Life content.
#
# The mod runs as its own game directory (-game hltps).  GoldSrc finds most
# content (maps, models, sounds, configs, sprites) by searching valve/ as a
# fallback, which is why the campaign already plays.  A few folders are read
# straight out of the *game* folder instead, with no fallback at all:
#
#   resource/   the main menu (GameMenu.res), the decorated background
#               (BackgroundLayout.txt + background/*.tga), the UI scheme and
#               icons, and the Options dialogs
#   media/      the startup intro videos (media/StartupVids.txt)
#   gfx/        the shell graphics the UI loads up front (palette, cursors)
#   logos/      the spraypaint logos listed by the Options tab
#   titles.txt  the on-screen chapter titles
#
# Because those are looked up in the mod folder itself, a fresh mod folder
# starts with a bare menu, no intro and no Options dialogs.  This
# script links the retail copies in, so the mod looks and behaves like the
# retail game without shipping or copying a single Valve asset.
#
# Nothing in valve/ is modified: the links are created inside the mod folder.
#
# Usage:
#   ./link-game-content.sh                 # run from inside the mod folder
#   ./link-game-content.sh --mod-dir DIR   # explicit mod folder
#   ./link-game-content.sh --unlink        # remove the links again
#
# Re-run it after a Half-Life update or a Steam "Verify integrity of game
# files".  The mod folder itself is never touched by Steam, so the links
# survive updates.
set -euo pipefail

MOD_DIR=""
UNLINK=0

usage()
{
    awk 'NR==1{next} /^#/{sub(/^# ?/,""); print; next} {exit}' "$0"
}

while [ $# -gt 0 ]; do
    case "$1" in
        --mod-dir) MOD_DIR=${2:?--mod-dir needs a directory}; shift ;;
        --unlink)  UNLINK=1 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Unknown option: $1 (try --help)" >&2; exit 1 ;;
    esac
    shift
done

if [ -z "$MOD_DIR" ]; then
    MOD_DIR=$(cd "$(dirname "$0")" && pwd)
else
    MOD_DIR=$(cd "$MOD_DIR" && pwd)
fi

GAME_DIR=$(cd "$MOD_DIR/.." && pwd)
VALVE_DIR="$GAME_DIR/valve"

# Folders and files the UI reads from the game folder itself.  Paths are
# relative to the mod folder.
ENTRIES=(
    resource
    media
    gfx
    logos
    titles.txt
)

link_entry()
{
    local rel=$1
    local src="$VALVE_DIR/$rel"
    local dst="$MOD_DIR/$rel"
    local target

    # Only link what the retail install actually ships.
    [ -e "$src" ] || return 0

    mkdir -p "$(dirname "$dst")"
    target=$(realpath --relative-to="$(dirname "$dst")" "$src")

    if [ -L "$dst" ]; then
        [ "$(readlink "$dst")" = "$target" ] && return 0
        rm -f "$dst"
    elif [ -e "$dst" ]; then
        # A real file or directory of the mod's own: never clobber it.
        echo "  kept    $rel (already present)"
        return 0
    fi

    ln -s "$target" "$dst"
    echo "  linked  $rel -> $target"
}

unlink_entry()
{
    local rel=$1
    local dst="$MOD_DIR/$rel"

    if [ -L "$dst" ]; then
        rm -f "$dst"
        echo "  removed $rel"
    fi
}

if [ "$UNLINK" -eq 1 ]; then
    echo "Removing retail content links from $MOD_DIR"
    for rel in "${ENTRIES[@]}"; do
        unlink_entry "$rel"
    done
    exit 0
fi

if [ ! -d "$VALVE_DIR" ]; then
    echo "Retail Half-Life content not found at:" >&2
    echo "    $VALVE_DIR" >&2
    echo >&2
    echo "This script expects the mod folder to sit next to the game's 'valve'" >&2
    echo "folder (for example Half-Life/hltps next to Half-Life/valve)." >&2
    exit 1
fi

echo "Linking retail Half-Life content into $MOD_DIR"
for rel in "${ENTRIES[@]}"; do
    link_entry "$rel"
done
echo "Done. Launch the mod with: -game $(basename "$MOD_DIR") -console"
