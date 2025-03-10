#!/bin/bash
# TaskBlob: Unified Deployment Script
# This script replaces multiple individual scripts and streamlines the deployment process.

# ANSI color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

echo -e "${YELLOW}TaskBlob - Unified Deployment System${NC}"
echo -e "====================================="

# Check if .env file exists, if not, create from template
if [ ! -f ".env" ]; then
    echo -e "\n${YELLOW}No .env file found. Creating from template...${NC}"
    cp .env.template .env
    echo -e "${GREEN}Created .env file from template.${NC}"
    echo -e "${CYAN}IMPORTANT: Edit the .env file to configure your system!${NC}"
fi

# Function to deploy containers
deploy_containers() {
    echo -e "\n${YELLOW}Stopping any running containers...${NC}"
    docker-compose down
    
    echo -e "\n${YELLOW}Building and starting containers...${NC}"
    docker-compose -f docker-compose.updated.yml up -d --build
    
    echo -e "\n${YELLOW}Checking container status...${NC}"
    sleep 5 # Give containers time to initialize
    docker-compose ps
}

# Function to check database connectivity
check_database() {
    echo -e "\n${YELLOW}Checking database connection...${NC}"
    # Wait a bit for PostgreSQL to be ready
    sleep 10
    
    # Try to connect to PostgreSQL
    docker exec postgres pg_isready -U postgres
    
    if [ $? -eq 0 ]; then
        echo -e "${GREEN}Database is running and accessible.${NC}"
        return 0
    else
        echo -e "${RED}Cannot connect to database. Please check logs.${NC}"
        return 1
    fi
}

# Main deployment process
echo -e "\n${YELLOW}Starting deployment process...${NC}"

# 1. Deploy containers first
deploy_containers

# 2. Check if database is accessible
check_database
if [ $? -ne 0 ]; then
    echo -e "${RED}Database initialization failed. Check logs for details.${NC}"
    echo -e "${YELLOW}You may need to fix issues and run this script again.${NC}"
    exit 1
fi

# 3. Display access information
EXTERNAL_IP=$(hostname -I | awk '{print $1}')
DOMAIN=$(grep DOMAIN .env | cut -d '=' -f2)

echo -e "\n${GREEN}Deployment completed successfully!${NC}"
echo -e "\n${CYAN}You can now access the admin panel at:${NC}"
echo -e "  • Local IP: http://${EXTERNAL_IP}:3001"
if [ ! -z "$DOMAIN" ] && [ "$DOMAIN" != "example.com" ]; then
    echo -e "  • Domain: http://admin.${DOMAIN} (once DNS is configured)"
fi

echo -e "\n${CYAN}First-time setup:${NC}"
echo -e "1. Login with default credentials (admin/FFf3t5h5aJBnTd) or as specified in .env"
echo -e "2. Complete the first-time setup wizard to:"
echo -e "   - Configure DNS settings"
echo -e "   - Set up mail domains"
echo -e "   - Change the admin password"
echo -e "   - Deploy the complete database schema"

echo -e "\n${YELLOW}Logs can be viewed using:${NC}"
echo -e "docker logs admin-panel"
echo -e "docker logs postgres"
