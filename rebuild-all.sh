#!/bin/bash
# Complete reset and rebuild script for TaskBlob
# This script will:
# 1. Stop and remove all Docker containers
# 2. Remove Docker volumes
# 3. Pull latest Git changes
# 4. Rebuild and restart the entire system

# Color definitions
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m' # No Color

# Function to print section header
section() {
  echo -e "\n${GREEN}==>${NC} $1"
}

# Check if running as root
if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}Error:${NC} This script must be run as root (or with sudo)"
  exit 1
fi

# Check current directory
if [[ ! -f "docker-compose.yml" || ! -d "postgres" ]]; then
  echo -e "${RED}Error:${NC} This script must be run from the TaskBlob root directory"
  echo -e "Please cd to /var/server/taskblob before running this script"
  exit 1
fi

# Confirm action
echo -e "${YELLOW}WARNING:${NC} This will completely reset your TaskBlob installation!"
echo -e "- All containers will be stopped and removed"
echo -e "- All data volumes will be deleted"
echo -e "- Latest code will be pulled from Git"
echo -e "- System will be rebuilt from scratch"
echo -e ""
read -p "Are you sure you want to continue? (y/N): " confirm
if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
  echo -e "Operation cancelled."
  exit 0
fi

# Stop and remove all containers
section "Stopping and removing all Docker containers"
docker-compose down || true

# List all Docker containers to force remove any stragglers
CONTAINERS=$(docker ps -a -q --filter "name=postgres|mailserver|config-api|admin-panel|webmail|nginx|redis|clamav|fail2ban")
if [ ! -z "$CONTAINERS" ]; then
  echo "Force removing containers..."
  docker rm -f $CONTAINERS
fi

# Remove all volumes
section "Removing Docker volumes"
docker volume rm taskblob_postgres_data taskblob_redis_data taskblob_mail_data taskblob_webmail_data taskblob_clamav_data 2>/dev/null || true

# Pull latest changes from Git
section "Pulling latest changes from Git"
git fetch
git reset --hard origin/main

# Make scripts executable
section "Setting permissions"
chmod +x *.sh bootstrap.js init-credentials.js upgrade-to-master-password.js
chmod +x postgres/init/*.sh dns/*.sh mail/scripts/*.sh 2>/dev/null || true

# Backup .env if it exists
if [ -f ".env" ]; then
  section "Backing up .env file"
  cp .env .env.backup
  echo -e "Your .env file has been backed up to .env.backup"
fi

# Install dependencies if needed
section "Checking dependencies"
./install-dependencies.sh

# Reset credentials if requested
section "Credential management"
echo -e "Do you want to reset your credentials?"
echo -e "If yes, you'll need to provide a new or existing master password."
echo -e "If no, your existing credentials will be kept if they exist."
read -p "Reset credentials? (y/N): " reset_creds

if [[ "$reset_creds" == "y" || "$reset_creds" == "Y" ]]; then
  # Remove old credentials if they exist
  rm -f /var/server/credentials/credentials.enc 2>/dev/null || true
  
  # Initialize new credentials
  ./init-credentials.js
else
  echo -e "Keeping existing credentials if they exist."
fi

# Start all services
section "Starting services"
node bootstrap.js docker-compose up -d

# Wait for PostgreSQL to initialize
section "Waiting for PostgreSQL initialization"
echo -e "Waiting 30 seconds for PostgreSQL to initialize..."
sleep 30

# Wait for config-api to be ready
section "Checking if config-api service is ready"
echo -e "Waiting for config-api service to be available..."
RETRY_COUNT=0
MAX_RETRIES=10
while [ $RETRY_COUNT -lt $MAX_RETRIES ]; do
  if curl -s http://localhost:3000/api/status | grep -q "running"; then
    echo -e "${GREEN}Config API service is ready!${NC}"
    break
  else
    echo -e "Config API not ready yet, waiting (attempt $((RETRY_COUNT+1))/$MAX_RETRIES)..."
    sleep 15
    RETRY_COUNT=$((RETRY_COUNT+1))
  fi
done

if [ $RETRY_COUNT -eq $MAX_RETRIES ]; then
  echo -e "${YELLOW}Warning: Could not verify config-api service is ready. DNS setup may fail.${NC}"
fi

# Run DNS setup if requested
section "DNS Configuration"
echo -e "Do you want to run DNS setup now?"
read -p "Setup DNS? (y/N): " setup_dns

if [[ "$setup_dns" == "y" || "$setup_dns" == "Y" ]]; then
  # Verify environment variables before running DNS setup
  if [ -z "$CLOUDFLARE_API_KEY" ] || [ -z "$CLOUDFLARE_EMAIL" ]; then
    echo -e "${YELLOW}Warning: CLOUDFLARE_API_KEY or CLOUDFLARE_EMAIL environment variables not set.${NC}"
    echo -e "These are required for DNS setup. Please check your .env file."
    read -p "Continue anyway? (y/N): " continue_dns
    if [[ "$continue_dns" != "y" && "$continue_dns" != "Y" ]]; then
      echo -e "DNS setup skipped. You can run it later with: node bootstrap.js ./setup-dns.sh"
      continue_dns="n"
    fi
  fi
  
  if [[ "$continue_dns" != "n" ]]; then
    echo -e "${GREEN}Running DNS setup...${NC}"
    node bootstrap.js ./setup-dns.sh
    
    # Check if DNS setup succeeded
    if [ $? -ne 0 ]; then
      echo -e "${YELLOW}DNS setup may not have completed successfully.${NC}"
      echo -e "You can run it again later with: node bootstrap.js ./setup-dns.sh"
    fi
  fi
else
  echo -e "Skipping DNS setup."
  echo -e "You can run it later with: node bootstrap.js ./setup-dns.sh"
fi

# Setup complete
section "Reset and rebuild complete!"
echo -e "Your TaskBlob system has been reset and rebuilt."
echo -e ""
echo -e "If you experience any issues:"
echo -e "1. Check Docker container logs: docker logs <container-name>"
echo -e "2. Verify your .env configuration"
echo -e "3. Ensure credentials are properly initialized"
echo -e ""
echo -e "Access your services at:"
echo -e "- Admin panel: https://admin.your-domain.com or http://your-server-ip:3001"
echo -e "- Webmail: https://webmail.your-domain.com or http://your-server-ip:8080"
echo -e ""
echo -e "${GREEN}Done!${NC}"
