#!/bin/bash

# Configuration Symlinks Setup Script
# Creates a centralized location for all configuration files with symlinks
# Usage: ./setup-config-symlinks.sh

# Color definitions
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m' # No Color

# Base directories
SERVER_ROOT="/var/server"
CONFIG_DIR="${SERVER_ROOT}/config"

# Check if running as root
if [ "$(id -u)" -ne 0 ]; then
    echo -e "${RED}This script must be run as root${NC}"
    exit 1
fi

# Create configuration directory structure
echo -e "${GREEN}Creating configuration directory structure...${NC}"
mkdir -p "${CONFIG_DIR}"/{nginx,postfix,dovecot,postgres,redis,firewall,ssl,clamav,spamassassin}

# Create directories if they don't exist
mkdir -p "${SERVER_ROOT}"/{dns,SSL,dkim,scripts,logs,backups/{postgresql,redis}}

# Function to create symlinks for a service
create_symlinks() {
    local service=$1
    local source_dir=$2
    local target_dir="${CONFIG_DIR}/${service}"
    
    echo -e "${GREEN}Creating symlinks for ${service}...${NC}"
    
    # Check if source directory exists
    if [ ! -d "$source_dir" ]; then
        echo -e "${YELLOW}Source directory ${source_dir} for ${service} doesn't exist. Skipping...${NC}"
        return
    fi
    
    # Create symlinks for configuration files
    for config_file in "$source_dir"/*; do
        if [ -f "$config_file" ]; then
            filename=$(basename "$config_file")
            ln -sf "$config_file" "${target_dir}/${filename}"
            echo "Created symlink for ${filename}"
        elif [ -d "$config_file" ] && [ "$(basename "$config_file")" != "." ] && [ "$(basename "$config_file")" != ".." ]; then
            dirname=$(basename "$config_file")
            mkdir -p "${target_dir}/${dirname}"
            for subfile in "$config_file"/*; do
                if [ -f "$subfile" ]; then
                    subfilename=$(basename "$subfile")
                    ln -sf "$subfile" "${target_dir}/${dirname}/${subfilename}"
                    echo "Created symlink for ${dirname}/${subfilename}"
                fi
            done
        fi
    done
}

# Create symlinks for each service
create_symlinks "nginx" "/etc/nginx"
create_symlinks "postfix" "/etc/postfix"
create_symlinks "dovecot" "/etc/dovecot"
create_symlinks "postgres" "/etc/postgresql"
create_symlinks "redis" "/etc/redis"
create_symlinks "clamav" "/etc/clamav"
create_symlinks "spamassassin" "/etc/spamassassin"

# Create firewall symlinks based on which firewall is in use
if command -v ufw &> /dev/null && ufw status &> /dev/null; then
    create_symlinks "firewall" "/etc/ufw"
    ln -sf "/lib/ufw/user.rules" "${CONFIG_DIR}/firewall/user.rules"
    ln -sf "/lib/ufw/user6.rules" "${CONFIG_DIR}/firewall/user6.rules"
elif command -v firewall-cmd &> /dev/null; then
    create_symlinks "firewall" "/etc/firewalld"
elif [ -d "/etc/iptables" ]; then
    create_symlinks "firewall" "/etc/iptables"
fi

# SSL configuration
ln -sf "/etc/letsencrypt/live" "${CONFIG_DIR}/ssl/letsencrypt-live"
ln -sf "/etc/ssl/certs" "${CONFIG_DIR}/ssl/certs"
ln -sf "/etc/ssl/private" "${CONFIG_DIR}/ssl/private"

# Create a configuration README file
cat > "${CONFIG_DIR}/README.md" << EOF
# Server Configuration Files

This directory contains symlinks to all important configuration files for server services.
It provides a centralized location to manage and edit configurations without navigating through
different system directories.

## Directory Structure

- nginx/: Web server configuration files
- postfix/: Mail server configuration files
- dovecot/: IMAP/POP3 server configuration files
- postgres/: PostgreSQL database configuration files
- redis/: Redis cache configuration files
- firewall/: Firewall configuration files
- ssl/: SSL certificates and related files
- clamav/: ClamAV virus scanner configurations
- spamassassin/: SpamAssassin spam filter configurations

## Usage Tips

1. Edit these files with your favorite text editor
2. After making changes, restart the respective service
3. These are symlinks, so changes affect the actual configuration files
4. Remember to run editors with sudo when needed

## Important Commands

- Restart Nginx: \`systemctl restart nginx\`
- Restart Postfix: \`systemctl restart postfix\`
- Restart Dovecot: \`systemctl restart dovecot\`
- Restart PostgreSQL: \`systemctl restart postgresql\`
- Restart Redis: \`systemctl restart redis-server\`
- Apply firewall changes: \`ufw reload\` or \`firewall-cmd --reload\`

Created: $(date)
EOF

echo -e "${GREEN}Configuration symlinks setup completed.${NC}"
echo "You can now access all configuration files in ${CONFIG_DIR}"