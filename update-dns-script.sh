#!/bin/bash
# Script to update setup-dns.sh from template while preserving local customizations

# Color definitions
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m' # No Color

# Check if template exists
if [ ! -f "setup-dns.template.sh" ]; then
    echo -e "${RED}Error: setup-dns.template.sh not found!${NC}"
    echo "Make sure you are running this script from the project root directory."
    exit 1
fi

# Check if setup-dns.sh exists and make backup if needed
if [ -f "setup-dns.sh" ]; then
    BACKUP_FILE="setup-dns.sh.backup.$(date +%Y%m%d%H%M%S)"
    echo -e "${YELLOW}Creating backup of existing setup-dns.sh as ${BACKUP_FILE}${NC}"
    cp setup-dns.sh "$BACKUP_FILE"
    chmod +x "$BACKUP_FILE"
fi

# Copy template to setup-dns.sh
echo -e "${GREEN}Updating setup-dns.sh from template...${NC}"
cp setup-dns.template.sh setup-dns.sh
chmod +x setup-dns.sh

# Suggest creating settings.local.sh if it doesn't exist
if [ ! -f "settings.local.sh" ] && [ -f "settings.local.sh.example" ]; then
    echo -e "${YELLOW}No settings.local.sh found. You may want to create one from the example:${NC}"
    echo -e "cp settings.local.sh.example settings.local.sh"
    echo -e "nano settings.local.sh  # Edit with your custom settings"
fi

echo -e "${GREEN}Done! setup-dns.sh has been updated.${NC}"
echo -e "${GREEN}You can now pull Git updates without conflicts by using:${NC}"
echo -e "  1. git stash        # Temporarily stash any other changes"
echo -e "  2. git pull         # Pull the latest updates"
echo -e "  3. ./update-dns-script.sh  # Update your setup-dns.sh from template"
echo -e "  4. git stash pop    # Optional: restore other changes if needed"
