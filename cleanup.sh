#!/bin/bash
# TaskBlob: Script to clean up legacy scripts and consolidate to the new system

# ANSI color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

echo -e "${YELLOW}TaskBlob - Legacy Scripts Cleanup${NC}"
echo -e "=================================="

# Create backup directory for removed scripts
BACKUP_DIR="legacy-scripts-backup"
echo -e "\n${YELLOW}Creating backup directory: $BACKUP_DIR${NC}"
mkdir -p $BACKUP_DIR

# List of scripts to be removed (all the .sh files except our new deploy.sh and cleanup.sh)
echo -e "\n${YELLOW}Identifying scripts to backup...${NC}"
SCRIPTS_TO_BACKUP=$(find . -maxdepth 1 -name "*.sh" ! -name "deploy.sh" ! -name "cleanup.sh")

# Also add PS1 files
PS1_FILES=$(find . -maxdepth 1 -name "*.ps1")

# Move scripts to backup directory
if [ -n "$SCRIPTS_TO_BACKUP" ]; then
    echo -e "\n${YELLOW}Moving shell scripts to backup directory...${NC}"
    for script in $SCRIPTS_TO_BACKUP; do
        echo -e "  Backing up: ${CYAN}$script${NC}"
        cp "$script" "$BACKUP_DIR/"
        rm "$script"
    done
    echo -e "${GREEN}All shell scripts backed up and removed${NC}"
else
    echo -e "\n${YELLOW}No shell scripts found to backup${NC}"
fi

# Move PS1 files to backup directory
if [ -n "$PS1_FILES" ]; then
    echo -e "\n${YELLOW}Moving PowerShell scripts to backup directory...${NC}"
    for file in $PS1_FILES; do
        echo -e "  Backing up: ${CYAN}$file${NC}"
        cp "$file" "$BACKUP_DIR/"
        rm "$file"
    done
    echo -e "${GREEN}All PowerShell scripts backed up and removed${NC}"
else
    echo -e "\n${YELLOW}No PowerShell scripts found to backup${NC}"
fi

# Move docker-compose.updated.yml to backup as we now use docker-compose.yml directly
if [ -f "docker-compose.updated.yml" ]; then
    echo -e "\n${YELLOW}Backing up docker-compose.updated.yml...${NC}"
    cp docker-compose.updated.yml "$BACKUP_DIR/"
    rm docker-compose.updated.yml
    echo -e "${GREEN}docker-compose.updated.yml backed up and removed${NC}"
fi

# Clean up any configuration files that have .updated suffix
UPDATED_FILES=$(find . -name "*.updated")
if [ -n "$UPDATED_FILES" ]; then
    echo -e "\n${YELLOW}Backing up .updated files...${NC}"
    for file in $UPDATED_FILES; do
        echo -e "  Backing up: ${CYAN}$file${NC}"
        cp "$file" "$BACKUP_DIR/"
        rm "$file"
    done
    echo -e "${GREEN}All .updated files backed up and removed${NC}"
fi

echo -e "\n${GREEN}Cleanup completed!${NC}"
echo -e "All legacy scripts have been backed up to ${CYAN}$BACKUP_DIR${NC}"
echo -e "You can safely remove this directory once you confirm everything is working correctly."
echo -e "\n${YELLOW}Your system is now using:${NC}"
echo -e "  - ${CYAN}deploy.sh${NC} for deployment"
echo -e "  - ${CYAN}docker-compose.yml${NC} for container configuration"
echo -e "  - The admin panel for system setup and management"
