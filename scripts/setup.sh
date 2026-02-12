#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SDK_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
GAME_DIR="$SDK_ROOT/game"
CONFIG_FILE="$SDK_ROOT/sdk.cfg"

# Required game files
REQUIRED_FILES=("master.dat" "critter.dat" "patch000.dat")

usage() {
    echo "fallout2-sdk setup"
    echo ""
    echo "Usage: $0 [--from <fallout2-install-dir>] [--from-dmg <path-to-dmg>]"
    echo ""
    echo "Options:"
    echo "  --from <dir>      Copy game data from an existing Fallout 2 installation"
    echo "  --from-dmg <dmg>  Extract game data from a GOG macOS DMG installer"
    echo "  (no args)         Interactive mode — prompts for source"
    echo ""
    echo "The game data files (master.dat, critter.dat, patch000.dat, etc.) will"
    echo "be copied into $GAME_DIR for use by the SDK."
}

validate_source_dir() {
    local dir="$1"
    local missing=()
    for f in "${REQUIRED_FILES[@]}"; do
        if [ ! -f "$dir/$f" ]; then
            missing+=("$f")
        fi
    done
    if [ ${#missing[@]} -gt 0 ]; then
        echo "ERROR: Missing required files in $dir:"
        for f in "${missing[@]}"; do
            echo "  - $f"
        done
        return 1
    fi
    return 0
}

copy_game_files() {
    local src="$1"
    echo "Copying game files from: $src"
    mkdir -p "$GAME_DIR"

    cp "$src/master.dat" "$GAME_DIR/"
    cp "$src/critter.dat" "$GAME_DIR/"
    cp "$src/patch000.dat" "$GAME_DIR/"

    [ -f "$src/fallout2.cfg" ] && cp "$src/fallout2.cfg" "$GAME_DIR/"
    [ -d "$src/data" ] && cp -R "$src/data" "$GAME_DIR/"
    [ -d "$src/sound" ] && cp -R "$src/sound" "$GAME_DIR/"

    echo "Game files copied to $GAME_DIR"
}

setup_config() {
    if [ ! -f "$CONFIG_FILE" ]; then
        cp "$SDK_ROOT/sdk.cfg.example" "$CONFIG_FILE"
        echo "Created $CONFIG_FILE (pointing to ./game)"
    else
        echo "$CONFIG_FILE already exists, skipping."
    fi
}

extract_from_dmg() {
    local dmg="$1"
    echo "Mounting $dmg ..."
    local mount_output
    mount_output=$(hdiutil attach "$dmg" -nobrowse 2>&1)
    local mount_point
    mount_point=$(echo "$mount_output" | grep '/Volumes/' | awk -F'\t' '{print $NF}' | head -1)

    if [ -z "$mount_point" ]; then
        echo "ERROR: Could not mount DMG."
        exit 1
    fi
    echo "Mounted at: $mount_point"

    # GOG Mac installer nests the game inside a Wineskin wrapper
    local gog_path="$mount_point/Fallout 2.app/Contents/Resources/game/Fallout 2.app/Contents/Resources/drive_c/Program Files/GOG.com/Fallout 2"
    if [ -d "$gog_path" ]; then
        validate_source_dir "$gog_path" || { hdiutil detach "$mount_point" -quiet; exit 1; }
        copy_game_files "$gog_path"
    else
        echo "ERROR: Could not find Fallout 2 game files in DMG."
        echo "Expected path: $gog_path"
        hdiutil detach "$mount_point" -quiet
        exit 1
    fi

    echo "Unmounting DMG ..."
    hdiutil detach "$mount_point" -quiet
}

# --- Main ---

if [ $# -eq 0 ]; then
    echo "fallout2-sdk setup"
    echo ""

    # Check if game files already exist
    if validate_source_dir "$GAME_DIR" 2>/dev/null; then
        echo "Game files already present in $GAME_DIR"
        setup_config
        echo "Setup complete."
        exit 0
    fi

    echo "No game files found. How would you like to provide them?"
    echo ""
    echo "  1) Point to an existing Fallout 2 installation directory"
    echo "  2) Extract from a GOG macOS DMG installer"
    echo ""
    read -rp "Choice [1/2]: " choice

    case "$choice" in
        1)
            read -rp "Fallout 2 installation path: " src_dir
            src_dir="${src_dir/#\~/$HOME}"
            validate_source_dir "$src_dir"
            copy_game_files "$src_dir"
            ;;
        2)
            read -rp "Path to .dmg file: " dmg_path
            dmg_path="${dmg_path/#\~/$HOME}"
            extract_from_dmg "$dmg_path"
            ;;
        *)
            echo "Invalid choice."
            exit 1
            ;;
    esac
elif [ "$1" = "--from" ]; then
    [ -z "${2:-}" ] && { usage; exit 1; }
    validate_source_dir "$2"
    copy_game_files "$2"
elif [ "$1" = "--from-dmg" ]; then
    [ -z "${2:-}" ] && { usage; exit 1; }
    extract_from_dmg "$2"
elif [ "$1" = "--help" ] || [ "$1" = "-h" ]; then
    usage
    exit 0
else
    usage
    exit 1
fi

setup_config
echo ""
echo "Setup complete. Game files are in: $GAME_DIR"
echo "Configuration written to: $CONFIG_FILE"
