#!/bin/bash

# TaskBlob Dependencies Installer
# This script installs all required dependencies for the TaskBlob system
# Run this after manual file transfer to ensure all dependencies are installed

# Color definitions
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m' # No Color

echo -e "${YELLOW}====== TaskBlob Dependencies Installer ======${NC}"
echo -e "This script will install all required dependencies for TaskBlob."

# Check if running as root
if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}Error:${NC} This script must be run as root (or with sudo)"
  exit 1
fi

# Record start time
START_TIME=$(date +%s)

# Function to print section header
section() {
  echo -e "\n${GREEN}==>${NC} $1"
}

# Function to check and install packages
install_package() {
  if ! command -v $1 &> /dev/null; then
    echo -e "Installing $1..."
    apt-get install -y $1
  else
    echo -e "$1 is already installed."
  fi
}

# Update package lists
section "Updating package lists"
apt-get update

# Install basic requirements
section "Installing basic requirements"
install_package curl
install_package wget
install_package gnupg
install_package lsb-release
install_package ca-certificates
install_package apt-transport-https
install_package software-properties-common
install_package dos2unix

# Install Node.js if not already installed
section "Setting up Node.js"
if ! command -v node &> /dev/null; then
  echo -e "Node.js not found. Installing current LTS version..."
  curl -fsSL https://deb.nodesource.com/setup_lts.x | bash -
  apt-get install -y nodejs
else
  NODE_VERSION=$(node -v)
  echo -e "Node.js $NODE_VERSION is already installed."
fi

# Install required npm packages
section "Installing npm packages"
npm install -g npm@latest
cd $(dirname $0)  # Change to script directory
npm install argon2 dotenv readline fs-extra

# Install Docker if not already installed
section "Setting up Docker"
if ! command -v docker &> /dev/null; then
  echo -e "Docker not found. Installing Docker..."
  curl -fsSL https://get.docker.com -o get-docker.sh
  sh get-docker.sh
  usermod -aG docker $SUDO_USER
  rm get-docker.sh
else
  DOCKER_VERSION=$(docker --version)
  echo -e "$DOCKER_VERSION is already installed."
fi

# Install Docker Compose if not already installed
if ! command -v docker-compose &> /dev/null; then
  echo -e "Docker Compose not found. Installing Docker Compose..."
  COMPOSE_VERSION=$(curl -s https://api.github.com/repos/docker/compose/releases/latest | grep 'tag_name' | cut -d\" -f4)
  curl -L "https://github.com/docker/compose/releases/download/${COMPOSE_VERSION}/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
  chmod +x /usr/local/bin/docker-compose
else
  COMPOSE_VERSION=$(docker-compose --version)
  echo -e "$COMPOSE_VERSION is already installed."
fi

# Fix line endings in scripts
section "Fixing line endings in scripts"
find . -name "*.sh" -o -name "bootstrap.js" -o -name "init-credentials.js" -o -name "upgrade-to-master-password.js" -exec dos2unix {} \; 2>/dev/null
echo -e "Line endings fixed for script files."

# Set proper permissions
section "Setting file permissions"
find . -name "*.sh" -exec chmod +x {} \;
chmod +x bootstrap.js init-credentials.js upgrade-to-master-password.js 2>/dev/null
echo -e "Execution permissions set for scripts."

# Check if WinRemote user exists
if id "WinRemote" &>/dev/null; then
  section "Setting up for WinRemote user"
  mkdir -p /var/server/mail
  chown -R WinRemote:WinRemote /var/server/mail
  echo -e "Created /var/server/mail directory with WinRemote ownership."
  
  # Inform about docker-compose.yml changes
  echo -e "${YELLOW}Note:${NC} You may need to update docker-compose.yml to use /var/server/mail for mail storage."
fi

# Setup complete
ELAPSED_TIME=$(($(date +%s) - START_TIME))
section "Setup complete!"
echo -e "All dependencies installed successfully in ${ELAPSED_TIME} seconds."
echo -e ""
echo -e "Next steps:"
echo -e "1. Create your .env file (copy from .env.template)"
echo -e "2. Run ${GREEN}./init-credentials.js${NC} to set up your master password"
echo -e "3. Start services with ${GREEN}node bootstrap.js docker-compose up -d${NC}"
echo -e ""
echo -e "For detailed instructions, see the docs/manual-deployment.md file."
