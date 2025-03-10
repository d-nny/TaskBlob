#!/bin/bash

# Master Server Setup Script
# Sets up the entire server structure and installs all components
# Usage: ./master-setup.sh domain.com

# Color definitions
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m' # No Color

# Base directories
SERVER_ROOT="/var/server"

# Check if running as root
if [ "$(id -u)" -ne 0 ]; then
    echo -e "${RED}This script must be run as root${NC}"
    exit 1
fi

# Check if domain is provided
if [ $# -lt 1 ]; then
    echo "Usage: $0 domain.com"
    exit 1
fi

DOMAIN=$1

# Load environment variables from .env if it exists
if [ -f ".env" ]; then
    # Source the .env file to get environment variables
    source .env
fi

# Use environment variables for IP addresses
PRIMARY_IP=${PRIMARY_IP}
MAIL_IP=${MAIL_IP}
IPV6_PREFIX=${IPV6_PREFIX}

# Prompt for IP addresses if not set
if [ -z "$PRIMARY_IP" ]; then
    read -p "Enter your primary IP address: " PRIMARY_IP
fi

if [ -z "$MAIL_IP" ]; then
    read -p "Enter your mail server IP address (or press enter to use primary IP): " MAIL_IP
    MAIL_IP=${MAIL_IP:-$PRIMARY_IP}
fi

if [ -z "$IPV6_PREFIX" ]; then
    read -p "Enter your IPv6 prefix (or press enter to skip IPv6): " IPV6_PREFIX
fi

# Step 1: Create directory structure
setup_directory_structure() {
    echo -e "${GREEN}Step 1: Creating directory structure...${NC}"
    
    mkdir -p "${SERVER_ROOT}"/{dns,SSL,dkim,scripts,logs,backups/{postgresql,redis},config}
    
    chmod 700 "${SERVER_ROOT}/backups"
    
    echo -e "${GREEN}Directory structure created.${NC}"
}

# Step 2: Copy scripts into place
copy_scripts() {
    echo -e "${GREEN}Step 2: Copying scripts to their locations...${NC}"
    
    # Create a src directory for script sources if it doesn't exist
    mkdir -p "${SERVER_ROOT}/src"
    
    # Ask for script source directory
    read -p "Enter the path to the directory containing the scripts (or press enter to manually copy them later): " SCRIPTS_SRC
    
    if [ -n "$SCRIPTS_SRC" ] && [ -d "$SCRIPTS_SRC" ]; then
        # Copy all scripts to src directory
        cp "$SCRIPTS_SRC"/*.sh "${SERVER_ROOT}/src/" 2>/dev/null || true
        cp "$SCRIPTS_SRC"/DNSupdate "${SERVER_ROOT}/src/" 2>/dev/null || true
        
        # Copy main DNS update script
        if [ -f "${SERVER_ROOT}/src/DNSupdate" ]; then
            cp "${SERVER_ROOT}/src/DNSupdate" "${SERVER_ROOT}/"
            chmod +x "${SERVER_ROOT}/DNSupdate"
        fi
        
        # Copy utility scripts
        if [ -f "${SERVER_ROOT}/src/check-firewall.sh" ]; then
            cp "${SERVER_ROOT}/src/check-firewall.sh" "${SERVER_ROOT}/scripts/"
            chmod +x "${SERVER_ROOT}/scripts/check-firewall.sh"
        fi
        
        if [ -f "${SERVER_ROOT}/src/setup-firewall.sh" ]; then
            cp "${SERVER_ROOT}/src/setup-firewall.sh" "${SERVER_ROOT}/scripts/"
            chmod +x "${SERVER_ROOT}/scripts/setup-firewall.sh"
        fi
        
        if [ -f "${SERVER_ROOT}/src/setup-postgres.sh" ]; then
            cp "${SERVER_ROOT}/src/setup-postgres.sh" "${SERVER_ROOT}/scripts/"
            chmod +x "${SERVER_ROOT}/scripts/setup-postgres.sh"
        fi
        
        if [ -f "${SERVER_ROOT}/src/setup-redis.sh" ]; then
            cp "${SERVER_ROOT}/src/setup-redis.sh" "${SERVER_ROOT}/scripts/"
            chmod +x "${SERVER_ROOT}/scripts/setup-redis.sh"
        fi
        
        if [ -f "${SERVER_ROOT}/src/setup-mail.sh" ]; then
            cp "${SERVER_ROOT}/src/setup-mail.sh" "${SERVER_ROOT}/scripts/"
            chmod +x "${SERVER_ROOT}/scripts/setup-mail.sh"
        fi
        
        if [ -f "${SERVER_ROOT}/src/generate-dkim.sh" ]; then
            cp "${SERVER_ROOT}/src/generate-dkim.sh" "${SERVER_ROOT}/scripts/"
            chmod +x "${SERVER_ROOT}/scripts/generate-dkim.sh"
        fi
        
        if [ -f "${SERVER_ROOT}/src/setup-config-symlinks.sh" ]; then
            cp "${SERVER_ROOT}/src/setup-config-symlinks.sh" "${SERVER_ROOT}/scripts/"
            chmod +x "${SERVER_ROOT}/scripts/setup-config-symlinks.sh"
        fi
        
        echo -e "${GREEN}Scripts copied successfully.${NC}"
    else
        echo -e "${YELLOW}No script source directory provided or directory doesn't exist.${NC}"
        echo "You'll need to manually copy the scripts to ${SERVER_ROOT}/scripts/"
    fi
    
    # Create symlinks in /usr/local/bin
    ln -sf "${SERVER_ROOT}/DNSupdate" /usr/local/bin/DNSupdate
    ln -sf "${SERVER_ROOT}/scripts/setup-postgres.sh" /usr/local/bin/setup-postgres
    ln -sf "${SERVER_ROOT}/scripts/setup-redis.sh" /usr/local/bin/setup-redis
    ln -sf "${SERVER_ROOT}/scripts/setup-mail.sh" /usr/local/bin/setup-mail
    ln -sf "${SERVER_ROOT}/scripts/setup-firewall.sh" /usr/local/bin/setup-firewall
    ln -sf "${SERVER_ROOT}/scripts/check-firewall.sh" /usr/local/bin/check-firewall
    ln -sf "${SERVER_ROOT}/scripts/generate-dkim.sh" /usr/local/bin/generate-dkim
    ln -sf "${SERVER_ROOT}/scripts/setup-config-symlinks.sh" /usr/local/bin/setup-config-symlinks
    
    echo -e "${GREEN}Script symlinks created in /usr/local/bin/.${NC}"
}

# Step 3: Configure CloudFlare credentials
setup_cloudflare() {
    echo -e "${GREEN}Step 3: Setting up CloudFlare credentials...${NC}"
    
    # Use environment variables if available
    local cf_key=${CLOUDFLARE_API_KEY:-""}
    local cf_email=${CLOUDFLARE_EMAIL:-""}
    
    # If not set in environment, prompt for them
    if [ -z "$cf_key" ]; then
        read -p "Enter your Cloudflare API key: " cf_key
    fi
    
    if [ -z "$cf_email" ]; then
        read -p "Enter your Cloudflare email: " cf_email
    fi
    
    echo "${cf_key}" > "${SERVER_ROOT}/dns/cloudflare_api_key.txt"
    echo "${cf_email}" > "${SERVER_ROOT}/dns/cloudflare_email.txt"
    
    chmod 600 "${SERVER_ROOT}/dns/cloudflare_api_key.txt"
    chmod 600 "${SERVER_ROOT}/dns/cloudflare_email.txt"
    
    echo -e "${GREEN}CloudFlare credentials set up.${NC}"
}

# Step 4: Create template.json
create_templates() {
    echo -e "${GREEN}Step 4: Creating DNS template files...${NC}"
    
    if [ -f "${SERVER_ROOT}/src/template.json" ]; then
        cp "${SERVER_ROOT}/src/template.json" "${SERVER_ROOT}/dns/"
        echo "Template JSON copied from source."
    else
        # Create template.json manually
        cat > "${SERVER_ROOT}/dns/template.json" << EOF
{
  "domain": "DOMAIN_PLACEHOLDER",
  "records": {
    "a": [
      {
        "name": "@",
        "content": "${PRIMARY_IP}",
        "proxied": true
      },
      {
        "name": "webmail",
        "content": "${PRIMARY_IP}",
        "proxied": true
      },
      {
        "name": "mail",
        "content": "${MAIL_IP}",
        "proxied": false
      }
    ],
    "aaaa": [
      {
        "name": "@",
        "content": "${IPV6_PREFIX}::1",
        "proxied": true
      },
      {
        "name": "webmail",
        "content": "${IPV6_PREFIX}::1",
        "proxied": true
      },
      {
        "name": "mail",
        "content": "${IPV6_PREFIX}::2",
        "proxied": false
      }
    ],
    "mx": [
      {
        "name": "@",
        "content": "mail.DOMAIN_PLACEHOLDER",
        "priority": 10,
        "proxied": false
      }
    ],
    "txt": [
      {
        "name": "@",
        "content": "v=spf1 mx a ip4:${PRIMARY_IP} ip4:${MAIL_IP} ip6:${IPV6_PREFIX}::/64 ~all",
        "proxied": false
      },
      {
        "name": "mail._domainkey",
        "content": "Generated dynamically by opendkim-genkey",
        "proxied": false
      },
      {
        "name": "_dmarc",
        "content": "v=DMARC1; p=none; rua=mailto:postmaster@DOMAIN_PLACEHOLDER",
        "proxied": false
      }
    ]
  },
  "ssl": {
    "domains": [
      "DOMAIN_PLACEHOLDER",
      "www.DOMAIN_PLACEHOLDER",
      "webmail.DOMAIN_PLACEHOLDER",
      "mail.DOMAIN_PLACEHOLDER"
    ],
    "webroot": "/var/www/html",
    "output_dir": "/var/server/SSL/DOMAIN_PLACEHOLDER"
  }
}
EOF
        echo "Template JSON created."
    fi
    
    # Create a domain-specific config for the provided domain
    cat > "${SERVER_ROOT}/dns/${DOMAIN}.json" << EOF
{
  "domain": "${DOMAIN}",
  "records": {
    "a": [
      {
        "name": "@",
        "content": "${PRIMARY_IP}",
        "proxied": true
      },
      {
        "name": "webmail",
        "content": "${PRIMARY_IP}",
        "proxied": true
      },
      {
        "name": "mail",
        "content": "${MAIL_IP}",
        "proxied": false
      }
    ],
    "aaaa": [
      {
        "name": "@",
        "content": "${IPV6_PREFIX}::1",
        "proxied": true
      },
      {
        "name": "webmail",
        "content": "${IPV6_PREFIX}::1",
        "proxied": true
      },
      {
        "name": "mail",
        "content": "${IPV6_PREFIX}::2",
        "proxied": false
      }
    ],
    "mx": [
      {
        "name": "@",
        "content": "mail.${DOMAIN}",
        "priority": 10,
        "proxied": false
      }
    ],
    "txt": [
      {
        "name": "@",
        "content": "v=spf1 mx a ip4:${PRIMARY_IP} ip4:${MAIL_IP} ip6:${IPV6_PREFIX}::/64 ~all",
        "proxied": false
      },
      {
        "name": "mail._domainkey",
        "content": "Generated dynamically by opendkim-genkey",
        "proxied": false
      },
      {
        "name": "_dmarc",
        "content": "v=DMARC1; p=none; rua=mailto:postmaster@${DOMAIN}",
        "proxied": false
      }
    ]
  },
  "ssl": {
    "domains": [
      "${DOMAIN}",
      "www.${DOMAIN}",
      "webmail.${DOMAIN}",
      "mail.${DOMAIN}"
    ],
    "webroot": "/var/www/html",
    "output_dir": "/var/server/SSL/${DOMAIN}"
  }
}
EOF
    
    echo -e "${GREEN}DNS template files created.${NC}"
}

# Step 5: Install dependencies
install_dependencies() {
    echo -e "${GREEN}Step 5: Installing basic dependencies...${NC}"
    
    apt-get update
    apt-get install -y jq curl wget dnsutils net-tools openssl apt-transport-https ca-certificates gnupg lsb-release
    
    # Check if Docker is already installed
    if ! command -v docker &> /dev/null; then
        echo -e "${GREEN}Installing Docker...${NC}"
        
        # Add Docker's official GPG key
        curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg
        
        # Set up the stable repository
        echo \
          "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/ubuntu \
          $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null
        
        # Install Docker Engine
        apt-get update
        apt-get install -y docker-ce docker-ce-cli containerd.io
        
        # Enable and start Docker service
        systemctl enable docker
        systemctl start docker
        
        echo -e "${GREEN}Docker installed successfully.${NC}"
    else
        echo -e "${YELLOW}Docker is already installed.${NC}"
    fi
    
    # Check if Docker Compose is already installed
    if ! command -v docker-compose &> /dev/null; then
        echo -e "${GREEN}Installing Docker Compose...${NC}"
        
        # Install Docker Compose
        curl -L "https://github.com/docker/compose/releases/download/v2.15.1/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
        chmod +x /usr/local/bin/docker-compose
        
        echo -e "${GREEN}Docker Compose installed successfully.${NC}"
    else
        echo -e "${YELLOW}Docker Compose is already installed.${NC}"
    fi
    
    echo -e "${GREEN}All dependencies installed.${NC}"
}

# Step 6: Ask which components to install
ask_components() {
    echo -e "${GREEN}Step 6: Component selection${NC}"
    
    echo "Which components would you like to install?"
    
    read -p "Setup firewall? (y/n): " SETUP_FIREWALL
    read -p "Setup PostgreSQL? (y/n): " SETUP_POSTGRES
    read -p "Setup Redis? (y/n): " SETUP_REDIS
    read -p "Setup mail server? (y/n): " SETUP_MAIL
    read -p "Setup admin panel? (y/n): " SETUP_ADMIN_PANEL
    
    # Proceed with selected installations
    if [[ "$SETUP_FIREWALL" =~ ^[Yy]$ ]]; then
        if [ -x "${SERVER_ROOT}/scripts/setup-firewall.sh" ]; then
            echo -e "${GREEN}Running firewall setup...${NC}"
            "${SERVER_ROOT}/scripts/setup-firewall.sh"
        else
            echo -e "${RED}Firewall setup script not found or not executable.${NC}"
            echo "Please ensure it's in ${SERVER_ROOT}/scripts/ and executable."
        fi
    fi
    
    if [[ "$SETUP_POSTGRES" =~ ^[Yy]$ ]]; then
        if [ -x "${SERVER_ROOT}/scripts/setup-postgres.sh" ]; then
            echo -e "${GREEN}Running PostgreSQL setup...${NC}"
            "${SERVER_ROOT}/scripts/setup-postgres.sh"
        else
            echo -e "${RED}PostgreSQL setup script not found or not executable.${NC}"
            echo "Please ensure it's in ${SERVER_ROOT}/scripts/ and executable."
        fi
    fi
    
    if [[ "$SETUP_REDIS" =~ ^[Yy]$ ]]; then
        if [ -x "${SERVER_ROOT}/scripts/setup-redis.sh" ]; then
            echo -e "${GREEN}Running Redis setup...${NC}"
            "${SERVER_ROOT}/scripts/setup-redis.sh"
        else
            echo -e "${RED}Redis setup script not found or not executable.${NC}"
            echo "Please ensure it's in ${SERVER_ROOT}/scripts/ and executable."
        fi
    fi
    
    if [[ "$SETUP_MAIL" =~ ^[Yy]$ ]]; then
        if [ -x "${SERVER_ROOT}/scripts/setup-mail.sh" ]; then
            echo -e "${GREEN}Running mail server setup...${NC}"
            "${SERVER_ROOT}/scripts/setup-mail.sh"
        else
            echo -e "${RED}Mail server setup script not found or not executable.${NC}"
            echo "Please ensure it's in ${SERVER_ROOT}/scripts/ and executable."
        fi
    fi
    
    if [[ "$SETUP_ADMIN_PANEL" =~ ^[Yy]$ ]]; then
        echo -e "${GREEN}Setting up admin panel...${NC}"
        
        # Create the admin subdomain DNS record
        echo -e "${GREEN}Adding admin subdomain to DNS...${NC}"
        if [ -f "${SERVER_ROOT}/dns/${DOMAIN}.json" ]; then
            # Check if admin A record already exists
            if ! grep -q '"name": "admin"' "${SERVER_ROOT}/dns/${DOMAIN}.json"; then
                # Insert admin A record
                echo -e "${GREEN}Adding admin A record to ${DOMAIN}.json...${NC}"
                sed -i '/      "a": \[/a \
        {\
          "name": "admin",\
          "content": "'${PRIMARY_IP}'",\
          "proxied": true\
        },' "${SERVER_ROOT}/dns/${DOMAIN}.json"
            fi
            
            # Check if admin AAAA record already exists
            if ! grep -q '"name": "admin".*"aaaa"' "${SERVER_ROOT}/dns/${DOMAIN}.json"; then
                # Insert admin AAAA record
                echo -e "${GREEN}Adding admin AAAA record to ${DOMAIN}.json...${NC}"
                sed -i '/      "aaaa": \[/a \
        {\
          "name": "admin",\
          "content": "'${IPV6_PREFIX}'::1",\
          "proxied": true\
        },' "${SERVER_ROOT}/dns/${DOMAIN}.json"
            fi
            
            # Check if admin is in SSL domains
            if ! grep -q '"admin.'${DOMAIN}'"' "${SERVER_ROOT}/dns/${DOMAIN}.json"; then
                # Add admin to SSL domains
                echo -e "${GREEN}Adding admin subdomain to SSL configuration...${NC}"
                sed -i '/      "domains": \[/a \
        "admin.'${DOMAIN}'",' "${SERVER_ROOT}/dns/${DOMAIN}.json"
            fi
            
            # Update DNS records via API
            echo -e "${GREEN}Updating DNS records...${NC}"
            if [ -x "${SERVER_ROOT}/DNSupdate" ]; then
                "${SERVER_ROOT}/DNSupdate" "$DOMAIN"
            else
                echo -e "${RED}DNS update script not found or not executable.${NC}"
            fi
        else
            echo -e "${RED}Domain JSON file not found. Cannot add admin subdomain.${NC}"
        fi
        
        # Configure Nginx for admin panel
        echo -e "${GREEN}Setting up Nginx configuration for admin panel...${NC}"
        mkdir -p ./nginx/conf
        
        cat > ./nginx/conf/admin.conf << EOF
server {
    listen 80;
    listen [::]:80;
    server_name admin.${DOMAIN};
    
    # Redirect to HTTPS
    location / {
        return 301 https://\$host\$request_uri;
    }
}

server {
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name admin.${DOMAIN};
    
    ssl_certificate /etc/ssl/nginx/${DOMAIN}/fullchain.pem;
    ssl_certificate_key /etc/ssl/nginx/${DOMAIN}/privkey.pem;
    
    # Security headers
    add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;
    add_header X-Content-Type-Options nosniff;
    add_header X-Frame-Options SAMEORIGIN;
    add_header X-XSS-Protection "1; mode=block";
    
    # Proxy to admin panel container
    location / {
        proxy_pass http://admin-panel:3001;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
EOF
        echo -e "${GREEN}Admin panel setup completed.${NC}"
    fi
}

# Step 7: Run DNS update
run_dns_update() {
    echo -e "${GREEN}Step 7: Running DNS update for ${DOMAIN}...${NC}"
    
    if [ -x "${SERVER_ROOT}/DNSupdate" ]; then
        "${SERVER_ROOT}/DNSupdate" "$DOMAIN"
    else
        echo -e "${RED}DNS update script not found or not executable.${NC}"
        echo "Please ensure it's in ${SERVER_ROOT}/ and executable."
    fi
}

# Step 8: Setup config symlinks
setup_config_symlinks() {
    echo -e "${GREEN}Step 8: Setting up configuration symlinks...${NC}"
    
    if [ -x "${SERVER_ROOT}/scripts/setup-config-symlinks.sh" ]; then
        "${SERVER_ROOT}/scripts/setup-config-symlinks.sh"
    else
        echo -e "${RED}Config symlinks setup script not found or not executable.${NC}"
        echo "Please ensure it's in ${SERVER_ROOT}/scripts/ and executable."
    fi
}

# Step 9: Create a README in the server root
create_readme() {
    echo -e "${GREEN}Step 9: Creating README file...${NC}"
    
    cat > "${SERVER_ROOT}/README.md" << EOF
# Server Configuration

This directory contains the complete server configuration and management scripts.

## Directory Structure

- \`/var/server/DNSupdate\`: Main DNS update script
- \`/var/server/dns/\`: DNS configurations and templates
- \`/var/server/SSL/\`: SSL certificates for all domains
- \`/var/server/dkim/\`: DKIM keys for mail authentication
- \`/var/server/scripts/\`: Utility scripts for server management
- \`/var/server/config/\`: Symlinks to all configuration files
- \`/var/server/logs/\`: Log files from script executions
- \`/var/server/backups/\`: Database and system backups

## Available Scripts

- \`DNSupdate\`: Update DNS records for a domain
- \`setup-postgres\`: Install and configure PostgreSQL
- \`setup-redis\`: Install and configure Redis
- \`setup-mail\`: Install and configure mail server
- \`setup-firewall\`: Configure firewall rules
- \`check-firewall\`: Verify firewall configuration
- \`generate-dkim\`: Generate DKIM keys for a domain
- \`setup-config-symlinks\`: Update configuration symlinks

## Usage Examples

\`\`\`bash
# Update DNS for a domain
DNSupdate example.com

# Check firewall configuration
check-firewall

# Setup mail server
setup-mail
\`\`\`

## Mail Database Structure

The mail system uses PostgreSQL with the following tables:
- \`domains\`: All mail domains
- \`mailboxes\`: User mailboxes
- \`aliases\`: Mail aliases/forwarders
- \`users\`: Web application users (can be linked to mailboxes)

## Maintenance Tips

1. Regular backups are stored in \`/var/server/backups/\`
2. Edit configuration files through the symlinks in \`/var/server/config/\`
3. SSL certificates are automatically renewed via cron
4. Check logs in \`/var/log/\` and \`/var/server/logs/\` for troubleshooting

Setup completed on: $(date)
For: ${DOMAIN}
EOF
    
    echo -e "${GREEN}README created.${NC}"
}

# Run all steps
setup_directory_structure
copy_scripts
setup_cloudflare
create_templates
install_dependencies
ask_components
run_dns_update
setup_config_symlinks
create_readme

echo -e "${GREEN}Server setup completed for ${DOMAIN}.${NC}"
echo "All scripts and configurations are in place."
echo "Review the README at ${SERVER_ROOT}/README.md for usage information."
