#!/bin/bash
# TaskBlob: Complete Reset Script
# This script stops and removes all related Docker containers, 
# volumes, and optionally the local files to allow for a fresh start

# ANSI color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

echo -e "${YELLOW}TaskBlob - Complete Reset${NC}"
echo -e "========================="
echo -e "${RED}WARNING: This will remove all containers, volumes, and data!${NC}"
echo -e "This is a destructive operation that cannot be undone."
echo -e "Make sure you have backups of any important data.\n"

# Ask for confirmation
read -p "Are you sure you want to continue? (y/N): " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo -e "${YELLOW}Reset operation cancelled.${NC}"
    exit 1
fi

echo -e "\n${YELLOW}1. Stopping all Docker containers...${NC}"
docker-compose down
echo -e "${GREEN}All containers stopped${NC}"

echo -e "\n${YELLOW}2. Removing all TaskBlob Docker volumes...${NC}"
docker volume rm $(docker volume ls -q | grep -E 'taskblob_|postgres_data|redis_data|mail_data|webmail_data|clamav_data') 2>/dev/null || true
echo -e "${GREEN}Docker volumes removed${NC}"

echo -e "\n${YELLOW}3. Removing Docker networks...${NC}"
docker network rm $(docker network ls -q --filter name=server_net) 2>/dev/null || true
echo -e "${GREEN}Docker networks removed${NC}"

echo -e "\n${YELLOW}4. Pruning unused Docker objects...${NC}"
docker system prune -f
echo -e "${GREEN}Docker pruned${NC}"

# Ask if user wants to also remove local files
echo -e "\n${YELLOW}Do you want to delete all local files and re-clone from Git?${NC}"
read -p "This will delete everything in the current directory. Continue? (y/N): " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    # Get git URL before deleting
    GIT_URL=$(git config --get remote.origin.url)
    CURRENT_DIR=$(pwd)
    DIR_NAME=$(basename "$CURRENT_DIR")
    
    echo -e "\n${YELLOW}5. Moving up one directory...${NC}"
    cd ..
    
    echo -e "\n${YELLOW}6. Removing local files...${NC}"
    rm -rf "$DIR_NAME"
    echo -e "${GREEN}Local files removed${NC}"
    
    echo -e "\n${YELLOW}7. Cloning fresh repository...${NC}"
    if [ -n "$GIT_URL" ]; then
        git clone "$GIT_URL" "$DIR_NAME"
        echo -e "${GREEN}Repository cloned successfully${NC}"
        
        echo -e "\n${YELLOW}8. Navigating to the cloned repository...${NC}"
        cd "$DIR_NAME"
        
        echo -e "\n${YELLOW}9. Making deploy.sh executable...${NC}"
        chmod +x deploy.sh
        chmod +x cleanup.sh
        chmod +x reset.sh
        
        echo -e "\n${GREEN}Reset complete!${NC}"
        echo -e "\nTo deploy the fresh system, run:"
        echo -e "  ${CYAN}./deploy.sh${NC}"
    else
        echo -e "${RED}Could not determine Git URL. Please clone the repository manually.${NC}"
    fi
else
    echo -e "\n${GREEN}Reset complete!${NC}"
    echo -e "\nTo deploy the fresh system, run:"
    echo -e "  ${CYAN}./deploy.sh${NC}"
fi
