#!/bin/bash

# BetterIcon-Craft Apps - Uninstaller / Restore Original Icons

DESKTOP_DIR="$HOME/.local/share/applications"
LOCAL_ICON_DIR="$HOME/.local/share/icons/hicolor/256x256/apps"
BACKUP_DIR="$HOME/.local/share/applications/bettericon-backup"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
RED='\033[0;31m'
NC='\033[0m'

echo -e "${BLUE}╔════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║   🔄 BetterIcon-Craft Apps - Restore Original      ║${NC}"
echo -e "${BLUE}╚════════════════════════════════════════════════════╝${NC}"
echo ""

if [ ! -d "$BACKUP_DIR" ] || [ -z "$(ls -A "$BACKUP_DIR" 2>/dev/null)" ]; then
    echo -e "${YELLOW}⚠️  No backups found. Nothing to restore.${NC}"
    exit 0
fi

echo -e "${YELLOW}🔄 Restoring original desktop entries...${NC}"
RESTORED=0

for backup_file in "$BACKUP_DIR"/*.backup; do
    if [ -f "$backup_file" ]; then
        original_name=$(basename "$backup_file" .backup)
        original_path="$DESKTOP_DIR/$original_name"

        cp "$backup_file" "$original_path"
        echo -e "   ${GREEN}✅ Restored:${NC} $original_name"
        ((RESTORED++))
    fi
done

echo ""
echo -e "${YELLOW}🗑️  Removing custom icons...${NC}"
REMOVED=0

for icon_file in "$LOCAL_ICON_DIR"/*-bettericon.{png,icns}; do
    if [ -f "$icon_file" ]; then
        rm "$icon_file"
        echo -e "   ${GREEN}✅ Removed:${NC} $(basename "$icon_file")"
        ((REMOVED++))
    fi
done

echo ""
echo -e "${YELLOW}🔄 Updating system caches...${NC}"

command -v update-desktop-database &>/dev/null && update-desktop-database "$DESKTOP_DIR" 2>/dev/null || true
command -v gtk-update-icon-cache &>/dev/null && gtk-update-icon-cache -f "$HOME/.local/share/icons/hicolor" 2>/dev/null || true

if [ "$XDG_CURRENT_DESKTOP" = "KDE" ] || [ "$DESKTOP_SESSION" = "plasma" ]; then
    command -v kbuildsycoca6 &>/dev/null && kbuildsycoca6 --noincremental 2>/dev/null || true
    command -v kbuildsycoca5 &>/dev/null && kbuildsycoca5 --noincremental 2>/dev/null || true
    echo -e "   ${GREEN}✅ KDE cache updated${NC}"
fi

echo ""
read -p "Delete backup files permanently? (y/n): " delete_backup
if [[ "$delete_backup" =~ ^[Yy]$ ]]; then
    rm -rf "$BACKUP_DIR"
    echo -e "${GREEN}✅ Backups deleted.${NC}"
else
    echo -e "${YELLOW}💡 Backups kept safely in: $BACKUP_DIR${NC}"
fi

echo ""
echo -e "${GREEN}╔════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║   🎉 Restore Complete! ($RESTORED entries, $REMOVED icons)     ║${NC}"
echo -e "${GREEN}╚════════════════════════════════════════════════════╝${NC}"
echo -e "${BLUE}💡 Logout/login again to see full changes.${NC}"
