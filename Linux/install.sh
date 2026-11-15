#!/bin/bash

# BetterIcon-Craft Apps - Universal Linux Installer v7.0
# FIXED: Bash arithmetic crash bug & Icon cache collision
# FEATURE: Unique icon naming per theme to prevent cache issues

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DESKTOP_DIR="$HOME/.local/share/applications"
SYSTEM_DESKTOP_DIR="/usr/share/applications"
LOCAL_ICON_DIR="$HOME/.local/share/icons/hicolor/256x256/apps"
BACKUP_DIR="$HOME/.local/share/applications/bettericon-backup"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'
BOLD='\033[1m'

APP_LIST=(
    "photocraft|PhotoCraft"
    "vectorcraft|VectorCraft"
    "filmcraft|FilmCraft"
    "lightcraft|LightCraft"
    "pdfcraft|PdfCraft"
    "effectcraft|EffectCraft"
    "anicraft|AniCraft"
    "designcraft|DesignCraft"
    "figcraft|FigCraft"
    "texturecraft|TextureCraft"
    "materialcraft|MaterialCraft"
    "soundcraft|SoundCraft"
    "wordcraft|WordCraft"
    "deckcraft|DeckCraft"
    "cadcraft|CADCraft"
    "gridcraft|GridCraft"
    "craftanything|CraftAnything"
    "solidcraft|SolidCraft"
)

echo -e "${BLUE}╔════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║   🎨 BetterIcon-Craft Apps Installer v7.0          ║${NC}"
echo -e "${BLUE}║   Anti-Crash & Cache-Safe Naming                   ║${NC}"
echo -e "${BLUE}╚════════════════════════════════════════════════════╝${NC}"
echo ""

# --- STEP 1: Scan for Icon Pack Folders ---
PACKS=()
for d in "$SCRIPT_DIR"/*/; do
    [ -d "$d" ] || continue
    dirname=$(basename "$d")
    [[ "$dirname" == .* ]] && continue
    PACKS+=("$dirname")
done

if [ ${#PACKS[@]} -eq 0 ]; then
    echo -e "${RED}❌ Error: No folders found next to install.sh!${NC}"
    exit 1
fi

echo -e "${CYAN}📂 Available Icon Packs:${NC}"
for i in "${!PACKS[@]}"; do
    echo -e "   ${GREEN}$((i+1))${NC}. ${PACKS[$i]}"
done
echo ""
read -p "Select Icon Pack number (1-${#PACKS[@]}): " pack_choice

if ! [[ "$pack_choice" =~ ^[0-9]+$ ]] || [ "$pack_choice" -lt 1 ] || [ "$pack_choice" -gt "${#PACKS[@]}" ]; then
    echo -e "${RED}❌ Invalid selection!${NC}"
    exit 1
fi

PACK_DIR="$SCRIPT_DIR/${PACKS[$((pack_choice-1))]}"
echo -e "${GREEN}✅ Selected Pack: ${BOLD}${PACKS[$((pack_choice-1))]}${NC}"

# --- STEP 2: Check for Theme Subfolders ---
THEMES=()
for d in "$PACK_DIR"/*/; do
    [ -d "$d" ] || continue
    THEMES+=("$(basename "$d")")
done

if [ ${#THEMES[@]} -gt 0 ]; then
    echo ""
    echo -e "${CYAN}🎨 Available Themes:${NC}"
    for i in "${!THEMES[@]}"; do
        echo -e "   ${GREEN}$((i+1))${NC}. ${THEMES[$i]}"
    done
    echo ""
    read -p "Select Theme number (1-${#THEMES[@]}): " theme_choice

    if ! [[ "$theme_choice" =~ ^[0-9]+$ ]] || [ "$theme_choice" -lt 1 ] || [ "$theme_choice" -gt "${#THEMES[@]}" ]; then
        echo -e "${RED}❌ Invalid selection!${NC}"
        exit 1
    fi
    THEME_DIR="$PACK_DIR/${THEMES[$((theme_choice-1))]}"
    SELECTED_THEME="${THEMES[$((theme_choice-1))]}"
else
    THEME_DIR="$PACK_DIR"
    SELECTED_THEME="Root"
fi

# Create a safe lowercase version of theme name for filenames
THEME_TAG=$(echo "$SELECTED_THEME" | tr '[:upper:]' '[:lower:]' | tr ' ' '-')

echo ""
echo -e "${CYAN}🔍 Scanning system and preparing status log...${NC}"
echo ""

# --- Helper Functions ---
check_desktop_entry() {
    local app=$1
    find "$DESKTOP_DIR" "$SYSTEM_DESKTOP_DIR" -maxdepth 1 -iname "*${app}*.desktop" 2>/dev/null | grep -q . && echo "Yes" || echo "No"
}

check_icon_exists() {
    local app_name=$1
    shopt -s nullglob nocaseglob
    local matches=("$THEME_DIR"/*"$app_name"*.{png,icns,svg})
    shopt -u nullglob nocaseglob
    [ ${#matches[@]} -gt 0 ] && echo "Yes" || echo "No"
}

# --- STEP 3: Status Table ---
printf "${BOLD}%-18s | %-22s | %-18s | %-14s${NC}\n" "Application" "Entry Found" "Icon Available" "Status"
echo "---------------------------------------------------------------------------------------"

APPS_TO_INSTALL=()
declare -A APP_NAME_MAP

for item in "${APP_LIST[@]}"; do
    app_lower="${item%%|*}"
    proper="${item##*|}"

    entry_status=$(check_desktop_entry "$app_lower")
    icon_status=$(check_icon_exists "$proper")

    APP_NAME_MAP["$app_lower"]="$proper"

    if [ "$entry_status" = "Yes" ] && [ "$icon_status" = "Yes" ]; then
        status="${GREEN}🟢 READY${NC}"
        APPS_TO_INSTALL+=("$app_lower")
    elif [ "$entry_status" = "Yes" ]; then
        status="${RED}🔴 NO ICON${NC}"
    elif [ "$icon_status" = "Yes" ]; then
        status="${YELLOW}🟡 No Entry / Not Installed${NC}"
    else
        status="${RED}❌ MISSING${NC}"
    fi

    printf "%-18s | %-22s | %-18s | ${status}\n" "$proper" "$entry_status" "$icon_status"
done

echo "---------------------------------------------------------------------------------------"
echo ""

if [ ${#APPS_TO_INSTALL[@]} -eq 0 ]; then
    echo -e "${RED}❌ No applications are ready to install.${NC}"
    exit 1
fi

echo -e "${GREEN}✅ Found ${#APPS_TO_INSTALL[@]} application(s) ready for update.${NC}"
read -p "Proceed with installation? (y/n): " confirm
if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
    echo "Installation cancelled."
    exit 0
fi

# --- STEP 4: Installation ---
mkdir -p "$DESKTOP_DIR" "$LOCAL_ICON_DIR" "$BACKUP_DIR"

echo ""
echo -e "${CYAN}🔧 Processing icon updates...${NC}"

INSTALLED_COUNT=0
SKIPPED_COUNT=0

for app_lower in "${APPS_TO_INSTALL[@]}"; do
    proper="${APP_NAME_MAP[$app_lower]}"

    # Safe find loop to handle spaces in filenames
    while IFS= read -r -d '' desktop_file; do
        # Backup original
        backup_path="$BACKUP_DIR/$(basename "$desktop_file").backup"
        if [ ! -f "$backup_path" ]; then
            cp "$desktop_file" "$backup_path"
        fi

        # Find icon
        shopt -s nullglob nocaseglob
        icon_matches=("$THEME_DIR"/*"$proper"*.{png,icns,svg})
        shopt -u nullglob nocaseglob

        if [ ${#icon_matches[@]} -eq 0 ]; then
            echo -e "   ${RED}⚠️  ERROR: Icon not found for '$proper'${NC}"
            SKIPPED_COUNT=$((SKIPPED_COUNT + 1))
            continue
        fi

        icon_source="${icon_matches[0]}"
        icon_ext="${icon_source##*.}"

        # ✅ FIX 2: Unique naming per theme to prevent cache collision
        icon_name="${app_lower}-bettericon-${THEME_TAG}"

        cp "$icon_source" "$LOCAL_ICON_DIR/${icon_name}.${icon_ext}"

        if grep -q "^Icon=" "$desktop_file"; then
            sed -i "s|^Icon=.*|Icon=${icon_name}|" "$desktop_file"
        else
            sed -i "/^\[Desktop Entry\]/a Icon=${icon_name}" "$desktop_file"
        fi

        echo -e "   ${GREEN}✅ Updated:${NC} $(basename "$desktop_file")"
        INSTALLED_COUNT=$((INSTALLED_COUNT + 1)) # ✅ FIX 1: Safe arithmetic

    done < <(find "$DESKTOP_DIR" "$SYSTEM_DESKTOP_DIR" -maxdepth 1 -iname "*${app_lower}*.desktop" -print0 2>/dev/null)
done

# --- STEP 5: Cache Refresh ---
echo ""
echo -e "${CYAN}🔄 Updating system caches...${NC}"

command -v update-desktop-database &>/dev/null && update-desktop-database "$DESKTOP_DIR" 2>/dev/null || true
command -v gtk-update-icon-cache &>/dev/null && gtk-update-icon-cache -f "$HOME/.local/share/icons/hicolor" 2>/dev/null || true

# Aggressive KDE cache clearing
if [ "$XDG_CURRENT_DESKTOP" = "KDE" ] || [ "$DESKTOP_SESSION" = "plasma" ]; then
    rm -f "$HOME/.cache/icon-cache.kcache" 2>/dev/null || true
    command -v kbuildsycoca6 &>/dev/null && kbuildsycoca6 --noincremental 2>/dev/null || true
    command -v kbuildsycoca5 &>/dev/null && kbuildsycoca5 --noincremental 2>/dev/null || true
    echo -e "   ${GREEN}✅ KDE cache cleared and rebuilt${NC}"
fi

echo ""
echo -e "${GREEN}╔════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║   🎉 Installation Complete!                        ║${NC}"
echo -e "${GREEN}║   ✅ Installed: $INSTALLED_COUNT  ⚠️  Skipped: $SKIPPED_COUNT               ║${NC}"
echo -e "${GREEN}╚════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "${BLUE}💡 Tips:${NC}"
echo "   • Logout/login again for full effect"
echo "   • Backups saved in: $BACKUP_DIR"
echo "   • To restore, run: ${YELLOW}./uninstall.sh${NC}"
